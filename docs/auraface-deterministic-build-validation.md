# AuraFace deterministic build tooling validation — 2026-09-12

## Result

The AuraFace audit item now has one manifest-driven fetch/build/verify chain pinned to Hugging Face commit
`af6d057c9b0ec4071d4c49c80e3539258798b609`. The existing fetcher downloads only `glintr100.onnx` at that
commit with the supported `hf` CLI and installs it only after SHA-256
`a7933ea5330113b01c9b60351d8f4c33003f145d8470ac5f0e52ee2effe25c60` matches.

The conversion project pins Python 3.12.11, uv 0.11.19, five direct packages, and all 40 resolved packages
and artifact hashes in `scripts/auraface/uv.lock`. `bundled-components.json` content-pins the fetcher,
converter, Python version file, project declaration, lock, distribution packager, and color-asymmetric
RGB fixture. The general bundled-component validator
and the converter's standard-library `contract` command fail on drift. The latter also confirms that every
registry artifact in the transitive lock has a SHA-256 and that its exact direct requirements match the
manifest and project.

`scripts/build_auraface_coreml.py reproduce` enforces the build gate. It verifies the ONNX source hash and
exact macOS arm64 runtime, uses a fixed seed and trace tensor, converts twice in clean directories, replaces
Core ML conversion dates/generated metadata with declared values, derives package identifiers from a
fixed UUID namespace, and serializes the model protobuf deterministically. It requires the three package
files to be byte-identical across both builds, runs three seeded Torch-vs-CoreML comparisons at a minimum
cosine similarity of 0.999, and evaluates the checked-in asymmetric image in RGB and swapped-BGR order
through both runtimes. The package and canonical build receipt install as one rollback-capable pair and
refuse an unreviewed overwrite. `verify` checks the declared package file set and SHA-256s
offline; when given `--source` through the locked environment, it also repeats the semantic comparison.
The offline contract check additionally compares the input/output names and sizes, normalization constants,
and RGB/BGR switch against `CoreMLFaceEmbedder.swift`.

The receipt binds the upstream repository/revision/source hash, every recipe and lock hash, runtime and
model-interface contracts, generated and declared artifact hashes, random-tensor similarities, image hash,
normalized Torch/Core ML reference vectors, and the BGR negative control. Two independent locked processes
produced identical package files and receipt. The reviewed package now replaces the older ignored local
artifact and its three hashes are pinned in `bundled-components.json`; both receipts record
`matchesDeclaredArtifactFiles: true`.

The compact checked-in Core ML reference is bound to the same model and decoded fixture hashes. An
always-run Swift test compares all 37,632 normalized NCHW inputs from the actual
`CoreMLFaceEmbedder.makeInput(CGImage)` path with the fixture's RGB bytes. When the optional declared model
is present, a second test compiles it and runs `CoreMLFaceEmbedder.embed(CGImage)`: RGB must agree with the
reference at cosine similarity 0.999 or better, while the red/blue-swapped negative must remain at or below
0.8 and at least 0.15 below RGB. A clean model-free checkout records the model-backed case as skipped while
the complete production preprocessing check still runs.

`scripts/ci/verify_auraface_reproduction.py` turns the independent-process check into a repeatable release
gate. It requires a clean committed tree and a new evidence directory, launches two distinct locked
processes with `PYTHONHASHSEED=0`, streams exact package comparisons, requires canonical identical receipts
whose generated and declared artifacts match, rechecks the source/manifest/HEAD boundaries, and writes one
exclusive compact evidence document. Its offline fault suite covers dirty or overlapping inputs, stale
evidence, subprocess failure, noncanonical/mismatched receipts and false declared-artifact matches.

The repository tests are deliberately offline-safe: they do not download the 260.7 MB ONNX source, install
the approximately 1 GB ML environment, or mutate the ignored local model. They cover content drift, exact
dependency/lock agreement, minimum clean-build and semantic thresholds, deterministic package manifest
normalization, unexpected package files, cosine edge cases, numeric-type drift, byte drift between clean
builds, canonical receipt tampering, package/receipt rollback and channel-control failure. The resource-intensive end-to-end conversion
remains an explicit release-engineering command; when run, the command itself supplies the byte-identity and
semantic evidence or fails without installing a candidate.

## Validation

```text
python3 -B scripts/ci/test_auraface_coreml_build.py
Ran 13 tests — OK

python3 -B scripts/ci/test_verify_auraface_reproduction.py
Ran 8 tests — OK

# Run from a clean committed checkout; the evidence directory must not exist.
python3 -B scripts/ci/verify_auraface_reproduction.py \
  --evidence-directory build/auraface/reproduction-evidence-001

python3 -B scripts/ci/test_auraface_source_fetch.py
Ran 6 tests — OK

python3 -B scripts/ci/test_bundled_component_validator.py
Ran 5 tests — OK

python3 -B scripts/build_auraface_coreml.py contract
AuraFace build contract verified (7 content-pinned files)

uv lock --check --offline --project scripts/auraface
Using CPython 3.12.11
Resolved 40 packages

python3 -B scripts/ci/validate_bundled_components.py
FFmpeg, c2patool, and AuraFace artifacts/declarations: validated

Two independent `PYTHONHASHSEED=0 ... reproduce` processes:
model b60588562fd76717d0d6ddcfcb8a4bf2d2bda3d61b356721b379318adf366f85
weights c189aaf7d6758dafb1603b4ea7f7c2161b69639434ddbce800e0cc632b26d7e0
manifest d2d7d38c9b21464299e620f0b87bf8037fde9d776174b9fc871508c4eb92be0a
receipt 3264fb603f80f10a9c5445ea39043ff912a7cf8cb3925ba1c088e2e1e7d8d2ef
matchesDeclaredArtifactFiles true
RGB Torch/Core ML 0.999688128; BGR-to-RGB 0.695475955 Torch / 0.692539032 Core ML

xcodebuild ... -only-testing:'Aagedal Photo Agent Tests/AuraFaceChannelReferenceTests'
2 tests / 1 suite — passed
```
