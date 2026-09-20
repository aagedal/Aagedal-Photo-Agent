#!/usr/bin/env python3
"""Compare two local FFmpeg artifacts on synthetic photo encode/preview paths.

This is a reproducible candidate experiment, not a visual color/HDR acceptance gate.
Both artifacts decode both sets of encoded files, exposing encoder and decoder drift
separately. Only disposable output is written; no installed binary is replaced.
"""

import argparse
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import zlib


def sha(data):
    return hashlib.sha256(data).hexdigest()


def png_pixels(path):
    """Unfilter non-interlaced RGB/RGBA PNG samples without color conversion."""
    data = path.read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("Expected PNG output")
    offset, compressed, header = 8, bytearray(), None
    while offset < len(data):
        length = struct.unpack_from(">I", data, offset)[0]
        kind = data[offset + 4:offset + 8]
        payload = data[offset + 8:offset + 8 + length]
        if kind == b"IHDR":
            header = struct.unpack(">IIBBBBB", payload)
        elif kind == b"IDAT":
            compressed.extend(payload)
        offset += length + 12
    if header is None:
        raise ValueError("Missing PNG header")
    width, height, depth, color, compression, filtering, interlace = header
    if depth not in (8, 16) or color not in (2, 6) or (compression, filtering, interlace) != (0, 0, 0):
        raise ValueError(f"Unsupported comparison PNG header: {header}")
    channels = 3 if color == 2 else 4
    pixel_bytes = channels * (depth // 8)
    stride = width * pixel_bytes
    raw = zlib.decompress(compressed)
    if len(raw) != height * (stride + 1):
        raise ValueError("Unexpected decoded PNG length")
    previous = bytearray(stride)
    pixels = bytearray()
    for row_index in range(height):
        start = row_index * (stride + 1)
        mode = raw[start]
        row = bytearray(raw[start + 1:start + 1 + stride])
        for i in range(stride):
            left = row[i - pixel_bytes] if i >= pixel_bytes else 0
            up = previous[i]
            corner = previous[i - pixel_bytes] if i >= pixel_bytes else 0
            if mode == 0:
                predictor = 0
            elif mode == 1:
                predictor = left
            elif mode == 2:
                predictor = up
            elif mode == 3:
                predictor = (left + up) // 2
            elif mode == 4:
                p = left + up - corner
                distances = (abs(p - left), abs(p - up), abs(p - corner))
                predictor = (left, up, corner)[distances.index(min(distances))]
            else:
                raise ValueError("Unsupported PNG row filter")
            row[i] = (row[i] + predictor) & 255
        pixels.extend(row)
        previous = row
    return {"width": width, "height": height, "bitDepth": depth,
            "channels": channels, "sampleSHA256": sha(pixels)}


def run(binary, arguments, log):
    result = subprocess.run([str(binary), "-nostdin", "-hide_banner", "-y", *arguments],
                            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, timeout=90)
    log.write_bytes(result.stdout)
    if result.returncode:
        raise RuntimeError(f"FFmpeg failed ({result.returncode}); see {log}")


def local_input(path):
    return ["-protocol_whitelist", "file", "-i", str(path)]


def local_output(path):
    return ["-protocol_whitelist", "file", str(path)]


def avif_color(path):
    """Read the nclx property in the generated AVIF's ISO BMFF item properties."""
    def properties(data):
        offset = 0
        while offset < len(data):
            if len(data) - offset < 8:
                raise ValueError("Truncated AVIF box")
            size, kind = struct.unpack_from(">I4s", data, offset)
            header = 8
            if size == 1:
                size = struct.unpack_from(">Q", data, offset + 8)[0]
                header = 16
            elif size == 0:
                size = len(data) - offset
            if size < header or offset + size > len(data):
                raise ValueError("Invalid AVIF box extent")
            payload = data[offset + header:offset + size]
            if kind in (b"meta", b"iprp", b"ipco"):
                yield from properties(payload[4:] if kind == b"meta" else payload)
            elif kind == b"colr" and payload[:4] == b"nclx":
                yield list(struct.unpack(">HHHB", payload[4:11]))
            offset += size
    values = list(properties(path.read_bytes()))
    if len(values) != 1:
        raise ValueError("Expected exactly one AVIF nclx property")
    return values[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", required=True, type=Path)
    parser.add_argument("--candidate", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    source = root / "Aagedal Photo Agent Tests/Fixtures/EditorialMetadata/synthetic-gradient.tiff"
    binaries = {"baseline": args.baseline.resolve(strict=True),
                "candidate": args.candidate.resolve(strict=True)}
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    # A 16-bit gradient exercises the force16Bit path independently of the 8-bit
    # tracked container fixture. PPM uses network-order RGB samples.
    source16 = output / "gradient16.ppm"
    samples = [component for y in range(32) for x in range(32)
               for component in (x * 2113 + y, y * 2113 + x, (x + y) * 1057)]
    source16.write_bytes(b"P6\n32 32\n65535\n" + struct.pack(f">{len(samples)}H", *samples))
    avif_base = ["-c:v", "libaom-av1", "-crf", "13", "-b:v", "0",
                 "-cpu-used", "6", "-still-picture", "1"]
    cases = []
    for name, primaries, transfer, matrix, codes in [
        ("srgb", "bt709", "iec61966-2-1", "bt709", [1, 13, 1, 128]),
        ("p3", "smpte432", "iec61966-2-1", "bt709", [12, 13, 1, 128]),
        ("rec2020", "bt2020", "bt2020-10", "bt2020nc", [9, 14, 9, 128]),
        ("adobe-fallback", "smpte432", "gamma22", "bt709", [12, 4, 1, 128]),
        ("hlg-p3", "smpte432", "arib-std-b67", "bt2020nc", [12, 18, 9, 128]),
        ("hlg-rec2020", "bt2020", "arib-std-b67", "bt2020nc", [9, 18, 9, 128]),
    ]:
        hdr = name.startswith("hlg")
        cases.append((f"avif-{name}", "avif", source16 if hdr else source,
                      ["-pix_fmt", "yuv420p10le" if hdr else "yuv420p",
                       "-color_range", "pc", "-color_primaries", primaries,
                       "-color_trc", transfer, "-colorspace", matrix, *avif_base],
                      ["-color_primaries", primaries, "-color_trc", transfer], codes))
    for name, input_path, pixel_options, distance in [
        ("sdr", source, [], "3.0"),
        ("sdr16", source16, ["-pix_fmt", "rgb48le"], "3.0"),
        ("lossless16", source16, ["-pix_fmt", "rgb48le"], "0.0"),
    ]:
        cases.append((f"jxl-{name}", "jxl", input_path,
                      [*pixel_options, "-c:v", "libjxl", "-distance", distance, "-effort", "7"], [], None))
    report = {"artifacts": {key: {"sha256": sha(path.read_bytes()), "bytes": path.stat().st_size}
                            for key, path in binaries.items()},
              "sources": {path.name: sha(path.read_bytes()) for path in (source, source16)},
              "scope": "Synthetic encoding and unconverted PNG sample parity; no visual HDR/color acceptance.",
              "cases": []}
    for name, extension, input_path, options, input_color, expected_color in cases:
        entry = {"name": name, "encodings": {}, "decodings": {}}
        for encoder_name, binary in binaries.items():
            encoded = output / f"{name}-{encoder_name}.{extension}"
            # Synthetic samples are already in the selected encoding space. Declare
            # that interpretation before -i, as production does for its rendered input.
            run(binary, [*input_color, *local_input(input_path), *options, *local_output(encoded)],
                output / f"{name}-{encoder_name}-encode.log")
            entry["encodings"][encoder_name] = {"sha256": sha(encoded.read_bytes()), "bytes": encoded.stat().st_size}
            if expected_color is not None:
                color = avif_color(encoded)
                if color != expected_color:
                    raise ValueError(f"Unexpected AVIF color signaling: {encoded}: {color}")
                entry["encodings"][encoder_name]["nclx"] = color
            for decoder_name, decoder in binaries.items():
                decoded = output / f"{name}-{encoder_name}-{decoder_name}.png"
                run(decoder, [*local_input(encoded), "-frames:v", "1", "-vf",
                              "scale=24:24:force_original_aspect_ratio=decrease", *local_output(decoded)],
                    decoded.with_suffix(".log"))
                pixels = png_pixels(decoded)
                expected = (24, 24, 16) if input_path == source16 else (24, 18, 8)
                if (pixels["width"], pixels["height"], pixels["bitDepth"]) != expected:
                    raise ValueError(f"Unexpected preview dimensions/depth: {decoded}")
                entry["decodings"][f"{encoder_name}/{decoder_name}"] = pixels
        values = list(entry["decodings"].values())
        entry["allDecodedSamplesEqual"] = all(value == values[0] for value in values)
        report["cases"].append(entry)
    report["allDecodedSamplesEqual"] = all(case["allDecodedSamplesEqual"] for case in report["cases"])
    (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"report": str(output / "report.json"), "cases": len(cases),
                      "allDecodedSamplesEqual": report["allDecodedSamplesEqual"]}))


if __name__ == "__main__":
    main()
