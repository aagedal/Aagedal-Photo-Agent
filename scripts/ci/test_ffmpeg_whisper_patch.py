#!/usr/bin/env python3
"""Compile a fault harness from the hash-pinned, patched FFmpeg source.

Uses the attributed af_whisper.c fixture by default; no network or model needed.
"""
import argparse
import importlib.util
import json
from pathlib import Path
import random
import shutil
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
PREPARE = ROOT / "scripts/ffmpeg/prepare_whisper_source.py"
spec = importlib.util.spec_from_file_location("prepare_whisper_source", PREPARE)
prepare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare)


def check(command):
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(f"Command failed: {command}\n{result.stdout}{result.stderr}")
    return result.stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path,
                        default=ROOT / "scripts/ffmpeg/fixtures/af_whisper.c")
    parser.add_argument("--cc", default="cc")
    args = parser.parse_args()
    if not shutil.which(args.cc):
        parser.error(f"C compiler unavailable: {args.cc}")
    patched = prepare.patched_source(args.source).decode("utf-8")
    functions = patched[patched.index("static char *whisper_json_escape"):patched.index("static int filter_frame")]
    functions += patched[patched.index("static int activate"):patched.index("static int query_formats")]
    harness = (ROOT / "scripts/ffmpeg/whisper_patch_harness.c").read_text()
    with tempfile.TemporaryDirectory(prefix="whisper-harness-") as directory:
        root = Path(directory)
        source, binary = root / "harness.c", root / "harness"
        source.write_text(harness.replace("/* PATCHED_FUNCTIONS */", functions))
        check([args.cc, "-std=c11", "-Wall", "-Wextra", "-Werror", "-g",
               "-fsanitize=address,undefined", str(source), "-o", str(binary)])
        cases = ["", " plain ", "[BLANK_AUDIO]", "[", "BLANK", "\\n", "\\u0041",
                 '"quoted" \\ path', "\n\r\t\b\f", "".join(chr(i) for i in range(1, 32)),
                 "Blåbær på Østlandet — 日本語 😀", "line\nsecond\r\nthird", " " * 1024]
        rng = random.Random(3000)
        alphabet = ['"', "\\", "n", "u", "å", "\n", "\r", "\t", " ", "😀", "[BLANK_AUDIO]"]
        cases += ["".join(rng.choices(alphabet, k=150)) for _ in range(50)]
        for text in cases:
            output = check([str(binary), "escape", text])
            assert output.count("\n") == 1, repr(output)
            result = json.loads(output)
            assert list(result) == ["start", "end", "text"]
            assert result == {"start": 120, "end": 170, "text": text}, repr(result)
        for fault in ["inference", "missing-context", "null-segment", "write", "metadata", "metadata-duration",
                      "overlap", "eof-last-frame", "eof-close", "eof-flush", "upstream-error",
                      "eof-success", "no-speech"]:
            check([str(binary), fault])
        # Two segments exercise append ownership as well as first-segment allocation.
        for index in range(1, 13):
            check([str(binary), "allocation", str(index)])
        wrong_source = root / "wrong.c"
        wrong_source.write_bytes(args.source.read_bytes() + b"\n")
        try:
            prepare.patched_source(wrong_source)
        except ValueError:
            pass
        else:
            raise AssertionError("unrecognized source accepted")
        existing = root / "existing.c"
        existing.write_text("preserve")
        refused = subprocess.run(["python3", str(PREPARE), str(args.source), "--output", str(existing)],
                                 capture_output=True, text=True)
        assert refused.returncode != 0 and existing.read_text() == "preserve"
    print(f"PASS: {len(cases)} exact JSON text roundtrips, 13 runtime/fault cases, "
          "12 allocation points, pinned source and overwrite refusal (ASan/UBSan).")


if __name__ == "__main__":
    main()
