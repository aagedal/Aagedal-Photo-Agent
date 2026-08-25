# AuraFace pinned-source fetch validation — 2026-08-25

## Result

The repository now has deterministic **source fetch and verification**, but not a deterministic CoreML
conversion. The full audit checklist item remains open.

`scripts/fetch_auraface_source.py` reads the AuraFace declaration from
`Aagedal Photo Agent/Resources/bundled-components.json`, requires one `huggingface.co` repository, a full
40-character commit, one safe source basename, and a lowercase SHA-256. Its network path invokes the
supported `hf download` command with that exact repository, file, and revision. Downloaded bytes remain in
a same-volume temporary directory until the declared SHA-256 passes; installation is atomic, and a failed or
unreviewed replacement leaves an existing destination untouched. `verify` performs the same digest check
without network access.

This command is developer/release provenance tooling, not an app feature. User devices will receive the
pre-converted quantized Core ML artifact from `aagedal.me`; they will not contact Hugging Face, download
ONNX, or run the Python conversion environment.

An `hf download --dry-run` resolved the declared object without downloading its 260.7 MB payload:

```text
repository: fal/AuraFace-v1
revision: af6d057c9b0ec4071d4c49c80e3539258798b609
file: glintr100.onnx
reported size: 260.7M
declared SHA-256: a7933ea5330113b01c9b60351d8f4c33003f145d8470ac5f0e52ee2effe25c60
```

Six offline tests cover exact command construction, rejection of mutable revisions and unsafe filenames,
hash drift, verified atomic installation, failed-download preservation, and reuse of an already verified
source. They make no Hub request.

## Why the build item remains open

The current README conversion snippet is a historical procedure, not a reproducible build environment:

- Python and all conversion dependencies are unpinned and have no transitive lock;
- the installed CoreML package records Torch 2.12 but does not record a usable Core ML Tools version;
- it records a conversion date;
- its package manifest contains generated identifiers; and
- the recipe traces a random input and does not perform an automated Torch-vs-CoreML comparison.

Closing the audit item requires a complete macOS/Python/toolchain lock, deterministic input and normalized
metadata/package identifiers, two byte-identical clean builds, exact output-file hashes, and a deterministic
semantic comparison including confirmation of RGB/BGR preprocessing. This follow-up deliberately does not
invent output hashes or relabel the current package as reproducible.

## Validation

```text
python3 -B scripts/ci/test_auraface_source_fetch.py
Ran 6 tests — OK

scripts/ci/validate_repository.sh
generated-document checks: passed
JSON/plist/project validation: passed
bundled provenance: 4 validator tests + 6 source-fetch tests passed
FFmpeg, c2patool, and AuraFace artifacts/declarations: validated
logger privacy, conflict-marker, and whitespace checks: passed
```
