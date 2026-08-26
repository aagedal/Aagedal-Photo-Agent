# AuraFace deterministic build tooling validation — 2026-08-25

## Result

The AuraFace audit item now has one manifest-driven fetch/build/verify chain pinned to Hugging Face commit
`af6d057c9b0ec4071d4c49c80e3539258798b609`. The existing fetcher downloads only `glintr100.onnx` at that
commit with the supported `hf` CLI and installs it only after SHA-256
`a7933ea5330113b01c9b60351d8f4c33003f145d8470ac5f0e52ee2effe25c60` matches.

The conversion project pins Python 3.12.11, uv 0.11.19, five direct packages, and all 40 resolved packages
and artifact hashes in `scripts/auraface/uv.lock`. `bundled-components.json` content-pins the fetcher,
converter, Python version file, project declaration, and lock. Both the general bundled-component validator
and the converter's standard-library `contract` command fail on drift. The latter also confirms that every
registry artifact in the transitive lock has a SHA-256 and that its exact direct requirements match the
manifest and project.

`scripts/build_auraface_coreml.py reproduce` enforces the build gate. It verifies the ONNX source hash and
exact macOS arm64 runtime, uses a fixed seed and trace tensor, converts twice in clean directories, replaces
Core ML conversion dates/generated metadata with declared values, and derives package identifiers from a
fixed UUID namespace. It then requires the three package files to be byte-identical across both builds and
runs three seeded Torch-vs-CoreML comparisons at a minimum cosine similarity of 0.999. Installation is the
last step and refuses an unreviewed overwrite. `verify` checks the declared package file set and SHA-256s
offline; when given `--source` through the locked environment, it also repeats the semantic comparison.
The offline contract check additionally compares the input/output names and sizes, normalization constants,
and RGB/BGR switch against `CoreMLFaceEmbedder.swift`.

The repository tests are deliberately offline-safe: they do not download the 260.7 MB ONNX source, install
the approximately 1 GB ML environment, or mutate the ignored local model. They cover content drift, exact
dependency/lock agreement, minimum clean-build and semantic thresholds, deterministic package manifest
normalization, unexpected package files, cosine edge cases, byte drift between clean builds, and the rule
that installation occurs only after semantic verification. The resource-intensive end-to-end conversion
remains an explicit release-engineering command; when run, the command itself supplies the byte-identity and
semantic evidence or fails without installing a candidate.

## Validation

```text
python3 -B scripts/ci/test_auraface_coreml_build.py
Ran 8 tests — OK

python3 -B scripts/ci/test_auraface_source_fetch.py
Ran 6 tests — OK

python3 -B scripts/ci/test_bundled_component_validator.py
Ran 5 tests — OK

python3 -B scripts/build_auraface_coreml.py contract
AuraFace build contract verified (5 content-pinned files)

uv lock --check --offline --project scripts/auraface
Using CPython 3.12.11
Resolved 40 packages

python3 -B scripts/ci/validate_bundled_components.py
FFmpeg, c2patool, and AuraFace artifacts/declarations: validated
```
