#!/usr/bin/env python3
"""Exercise the actual local FFmpeg Whisper process without downloading models.

The default smoke check needs no model. Supply --model for CPU silence and
destination-failure checks, and optionally --audio for a local speech WAV.
This is process qualification, not recognition accuracy or GPU certification.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import wave


ROOT = Path(__file__).resolve().parents[2]
OPTIONS = {"model", "language", "use_gpu", "translate", "max_len", "destination", "format"}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def validate_options(text: str) -> None:
    require("Filter whisper\n" in text, "Whisper filter is unavailable")
    actual = set(re.findall(r"^\s+(\w+)\s+<[^>]+>", text, re.MULTILINE))
    require(OPTIONS <= actual, f"Whisper options missing: {sorted(OPTIONS - actual)}")


def unique_object(pairs: list[tuple]) -> dict:
    result = {}
    for key, value in pairs:
        require(key not in result, f"duplicate transcript field: {key}")
        result[key] = value
    return result


def validate_transcript(path: Path, duration_ms: int, *, require_text: bool = False) -> int:
    require(path.is_file(), "successful process did not create a transcript")
    count, has_text = 0, False
    for line in path.read_text(encoding="utf-8").splitlines():
        require(bool(line.strip()), "transcript contains an empty record")
        record = json.loads(line, object_pairs_hook=unique_object)
        require(isinstance(record, dict) and set(record) == {"start", "end", "text"},
                "transcript record does not have canonical start/end/text fields")
        start, end, text = record["start"], record["end"], record["text"]
        require(type(start) is int and type(end) is int,
                "transcript timestamps must be integer milliseconds")
        require(0 <= start <= end <= duration_ms, "transcript timestamps exceed supplied audio")
        require(isinstance(text, str), "transcript text must be a string")
        has_text |= bool(text.strip()) and text.strip().upper() != "[BLANK_AUDIO]"
        count += 1
    require(not require_text or has_text, "speech probe produced no non-marker text")
    return count


def audio_duration(path: Path) -> int:
    with wave.open(str(path), "rb") as audio:
        require(audio.getcomptype() == "NONE" and audio.getnframes() > 0,
                "probe audio must be a nonempty PCM WAV")
        return audio.getnframes() * 1000 // audio.getframerate()


def arguments(*, model: str = "model.bin", destination: str = "output.json") -> list[str]:
    # Match the app runner's local WAV input and canonical JSON output contract.
    return ["-hide_banner", "-nostdin", "-xerror", "-loglevel", "error",
            "-protocol_whitelist", "file", "-format_whitelist", "wav", "-f", "wav",
            "-i", "input.wav", "-map", "0:a:0", "-vn", "-sn", "-dn", "-af",
            f"whisper=model={model}:language=en:use_gpu=false:translate=false:"
            f"max_len=0:destination={destination}:format=json", "-f", "null", "-"]


def process(binary: Path, directory: Path, args: list[str], name: str,
            timeout: float, *, expected_error: str | None = None) -> dict:
    try:
        result = subprocess.run([str(binary), *args], cwd=directory,
                                stdin=subprocess.DEVNULL, capture_output=True, timeout=timeout)
    except subprocess.TimeoutExpired as error:
        (directory / f"{name}.log").write_bytes((error.stdout or b"") + (error.stderr or b""))
        raise ValueError(f"{name} timed out after {timeout} seconds; inspect its log") from error
    output = result.stdout + result.stderr
    (directory / f"{name}.log").write_bytes(output)
    if expected_error is None:
        require(result.returncode == 0, f"{name} failed (exit {result.returncode}); inspect its log")
    else:
        require(result.returncode > 0 and expected_error.encode() in output,
                f"{name} did not report the expected controlled failure; inspect its log")
    return {"name": name, "exitCode": result.returncode, "passed": True}


def probe(binary: Path, directory: Path, *, model: Path | None = None,
          audio: Path | None = None, timeout: float = 120) -> dict:
    require(audio is None or model is not None, "--audio requires --model")
    report = {"schemaVersion": 1, "artifactSHA256": sha256(binary), "cases": [],
              "scope": "CPU process contract; no accuracy, GPU, cancellation or clean-rebuild claim"}
    help_result = subprocess.run([str(binary), "-hide_banner", "-h", "filter=whisper"],
                                 stdin=subprocess.DEVNULL, capture_output=True, timeout=15)
    require(help_result.returncode == 0, "Whisper option probe failed")
    help_text = (help_result.stdout + help_result.stderr).decode("utf-8")
    validate_options(help_text)
    (directory / "filter-options.log").write_text(help_text, encoding="utf-8")
    report["cases"].append({"name": "filter-options", "passed": True})
    with wave.open(str(directory / "silence.wav"), "wb") as silence:
        silence.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
        silence.writeframes(b"\0" * 16000 * 2 * 5)
    shutil.copyfile(directory / "silence.wav", directory / "input.wav")
    baseline = arguments()
    index = baseline.index("-af")
    del baseline[index:index + 2]
    report["cases"].append(process(binary, directory, baseline, "decode-input", timeout))
    for name, model_name in [("missing-model", "absent.bin"), ("malformed-model", "bad.bin")]:
        if name == "malformed-model":
            (directory / model_name).write_bytes(b"invalid-whisper-model")
        report["cases"].append(process(binary, directory, arguments(model=model_name), name, timeout,
                              expected_error="Failed to initialize whisper context from model"))
    if model is not None:
        report["modelSHA256"] = sha256(model)
        shutil.copyfile(model, directory / "model.bin")
        for name, fixture in [("silence", None), ("speech", audio)]:
            if name == "speech" and fixture is None:
                continue
            if fixture is not None:
                shutil.copyfile(fixture, directory / "input.wav")
            destination = f"{name}.json"
            case = process(binary, directory, arguments(destination=destination), name, timeout)
            case["audioSHA256"] = sha256(directory / "input.wav")
            case["durationMilliseconds"] = audio_duration(directory / "input.wav")
            case["segments"] = validate_transcript(directory / destination,
                case["durationMilliseconds"], require_text=name == "speech")
            report["cases"].append(case)
        (directory / "destination-directory").mkdir()
        report["cases"].append(process(binary, directory,
            arguments(destination="destination-directory"), "invalid-destination", timeout,
            expected_error="Could not open destination-directory"))
    report["modelChecksExecuted"] = model is not None
    report["speechCheckExecuted"] = audio is not None
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=ROOT / "Aagedal Photo Agent/Resources/ffmpeg")
    parser.add_argument("--model", type=Path)
    parser.add_argument("--audio", type=Path, help="optional nonempty PCM speech WAV; requires --model")
    parser.add_argument("--output", type=Path, help="new evidence directory (otherwise temporary)")
    args = parser.parse_args()
    try:
        require(args.audio is None or args.model is not None, "--audio requires --model")
        with tempfile.TemporaryDirectory(prefix="photo-agent-whisper-probe-") as temporary:
            directory = args.output.resolve() if args.output else Path(temporary)
            if args.output:
                directory.mkdir(parents=True, exist_ok=False)
            report = probe(args.binary.resolve(), directory,
                           model=args.model.resolve() if args.model else None,
                           audio=args.audio.resolve() if args.audio else None)
            (directory / "report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
            print(json.dumps(report, indent=2))
    except (OSError, ValueError, wave.Error, subprocess.SubprocessError) as error:
        print(f"Whisper process probe failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
