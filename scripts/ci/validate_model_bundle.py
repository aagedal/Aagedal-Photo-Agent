#!/usr/bin/env python3
"""Verify that an exported app contains the reviewed compiled AuraFace model."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
from pathlib import Path


REPOSITORY = Path(__file__).resolve().parents[2]
MANIFEST = REPOSITORY / "Aagedal Photo Agent/Resources/bundled-components.json"
MODEL_NAME = "AuraFaceR100.mlmodelc"
WEIGHTS_RELATIVE_PATH = "Data/com.apple.CoreML/weights/weight.bin"
REQUIRED_COMPILED_FILES = {
    "model.mil", "metadata.json", "coremldata.bin", "weights/weight.bin"
}


def expected_weights_hash() -> str:
    graph = json.loads(MANIFEST.read_bytes())
    component = next(
        item for item in graph["components"] if item["id"] == "auraface-r100-coreml"
    )
    return component["artifactFiles"][WEIGHTS_RELATIVE_PATH]


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def inspect_app(app: Path) -> dict:
    app = app.resolve(strict=True)
    if not app.is_dir() or app.suffix != ".app":
        raise ValueError("expected an existing .app directory")
    contents = app / "Contents"
    with (contents / "Info.plist").open("rb") as source:
        info = plistlib.load(source)
    executable = info.get("CFBundleExecutable")
    if (not isinstance(executable, str) or Path(executable).name != executable
            or not (contents / "MacOS" / executable).is_file()):
        raise ValueError("the exported app executable is missing or invalid")

    resources = contents / "Resources"
    model = resources / MODEL_NAME
    if model.is_symlink() or not model.is_dir() or model.resolve(strict=True) != model:
        raise ValueError("the compiled AuraFace model is missing or linked")
    for relative in sorted(REQUIRED_COMPILED_FILES):
        file = model / relative
        if file.is_symlink() or not file.is_file() or file.stat().st_size == 0:
            raise ValueError(f"the compiled AuraFace model is missing {relative}")
        if not file.resolve(strict=True).is_relative_to(model):
            raise ValueError(f"the compiled AuraFace model links outside its bundle: {relative}")
    weights = model / "weights/weight.bin"
    actual_hash = sha256(weights)
    declared_hash = expected_weights_hash()
    if actual_hash != declared_hash:
        raise ValueError("the compiled AuraFace weights differ from the reviewed package")

    # The compiled model is the single release payload. Shipping the developer
    # package or on-demand ZIP as well would duplicate it and inflate updates.
    for directory, directories, files in os.walk(resources, followlinks=False):
        for name in directories + files:
            path = Path(directory) / name
            if path == model:
                continue
            if "auraface" in name.lower() and path.suffix.lower() in {
                ".mlmodelc", ".mlpackage", ".mlmodel", ".onnx", ".zip"
            }:
                raise ValueError(f"the app includes a duplicate AuraFace payload: {path.relative_to(app)}")

    return {
        "schemaVersion": 1,
        "app": str(app),
        "modelBundled": True,
        "model": str(model.relative_to(app)),
        "weightsByteCount": weights.stat().st_size,
        "weightsSHA256": actual_hash,
        "version": info.get("CFBundleShortVersionString"),
        "build": info.get("CFBundleVersion"),
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    args = parser.parse_args()
    try:
        print(json.dumps(inspect_app(args.app), indent=2, sort_keys=True))
    except (OSError, ValueError, StopIteration, KeyError, plistlib.InvalidFileException) as error:
        parser.exit(1, f"error: {error}\n")


if __name__ == "__main__":
    main()
