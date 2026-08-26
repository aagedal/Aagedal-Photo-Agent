# Face recognition model — NOT in git

The face-recognition feature loads a bundled CoreML model at runtime:

```
Aagedal Photo Agent/Resources/Models/AuraFaceR100.mlpackage   (~125 MB)
```

This file is **excluded from git** (see the repo `.gitignore`) because of its size. The app still
**builds and runs without it**, but the omission is an explicit packaged capability: the face bar shows
**Unavailable**, its help text explains that AuraFace is not included, and scan requests fail closed before
changing face data. Drop the model at the path above (Xcode's synchronized group picks it up automatically)
to enable recognition.

For an intentionally model-free release, inspect the archived app to confirm that
`Contents/Resources/AuraFaceR100.mlmodelc` is absent and add the exact disclosure required by the root
`README.md` release checklist to `CHANGELOG.md` under `### Highlights`. A release that advertises face
recognition must instead contain the compiled resource and pass manifest verification.

## What the model is

**AuraFace-v1** — the `glintr100` recognition net (ArcFace R100), an open, commercially-usable
ArcFace variant. **License: Apache-2.0** (see `AuraFace-LICENSE.md` in this folder).
Source: <https://huggingface.co/fal/AuraFace-v1>

## How to (re)build `AuraFaceR100.mlpackage`

The Swift pipeline expects: input **`input`** shape `[1,3,112,112]` float32, **RGB**, normalized
`(x − 127.5) / 127.5`, NCHW; output renamed **`embedding`**, 512-d (the app L2-normalizes it).

Fetch the exact ONNX source declared in `Resources/bundled-components.json` with the supported
Hugging Face `hf` CLI. The repository tool reads the immutable commit and source SHA-256 from that
manifest, downloads into a staging directory, and installs the file only after its digest matches:

This is developer/release provenance tooling only. The app never invokes `hf`, downloads ONNX, or runs
ONNX-to-Core ML conversion on a user's Mac. The planned on-demand product component is the already-converted,
quantized Core ML artifact hosted on `aagedal.me`.

```bash
python3 scripts/fetch_auraface_source.py fetch
# Offline recheck of an existing download:
python3 scripts/fetch_auraface_source.py verify build/model-sources/auraface/glintr100.onnx
```

The conversion environment is locked by `scripts/auraface/uv.lock`. The manifest content-pins that lock,
the project file, exact Python patch release, fetcher, and converter. `uv --frozen` refuses to resolve a
different graph. The converter uses a fixed trace input and seed, removes converter timestamps, writes stable
model metadata and package identifiers, and performs two clean conversions. It will not install an output
unless every package file is byte-identical between those builds and three seeded Torch-vs-CoreML comparisons
meet the declared cosine-similarity threshold.

```bash
# Standard-library/offline checks of the reviewed contract and shipped file hashes:
python3 -B scripts/build_auraface_coreml.py contract
python3 -B scripts/build_auraface_coreml.py verify

# Materialize only the locked environment, then build twice and verify semantics:
uv sync --frozen --project scripts/auraface
uv run --frozen --project scripts/auraface \
  python scripts/build_auraface_coreml.py reproduce
```

`reproduce` defaults to `build/auraface/AuraFaceR100.mlpackage`, prints the three file hashes for review,
and does not overwrite an existing output without `--replace`. To semantically recheck the manifest-declared
package against the pinned ONNX source, run `verify --source build/model-sources/auraface/glintr100.onnx`
through the same `uv run --frozen` command. A reviewed artifact update must copy the generated package into
this folder, update all three `artifactFiles` hashes in `bundled-components.json`, and rerun repository
validation. Keep the declared RGB channel order aligned with `CoreMLFaceEmbedder.inputIsRGB`; changing it
changes the embedding space and requires a migration/version bump.

## Prepare the pre-converted on-demand artifact

After the reviewed package hashes are in `bundled-components.json`, create the user-facing archive and its
download descriptor without invoking the conversion environment:

```bash
python3 -B scripts/package_auraface_distribution.py package \
  --download-url https://aagedal.me/models/auraface/AuraFaceR100.mlpackage.zip
python3 -B scripts/package_auraface_distribution.py verify
```

The ZIP uses sorted, uncompressed entries with fixed timestamps and permissions, so the same package bytes
produce the same archive bytes on every run. The canonical JSON descriptor binds the exact archive SHA-256
and byte count, all three inner package hashes, the model version, and `FaceRecognitionDefaults.embeddingVersion`
to one credential-free HTTPS URL on `aagedal.me`. Packaging refuses undeclared files, package hash drift,
embedding-version drift, mutable/query URLs, and overwrite unless `--replace` is explicitly supplied. This
produces release candidates only; publishing the files, signing or pinning the descriptor in the app, and
real-server download tests remain separate release operations.
