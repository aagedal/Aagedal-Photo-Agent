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

The conversion recipe below documents how the current package was produced, but it is **not yet a
reproducible build contract**. Its Python environment is not transitively locked; the current package
records Torch 2.12, an unversioned Core ML Tools conversion, a conversion date, and generated package
identifiers. Do not update the manifest's CoreML output hashes from a newly converted package until the
complete conversion environment is locked, generated identifiers/metadata are normalized, repeated clean
builds are byte-identical, and Torch-vs-CoreML semantic validation passes. The audit-plan item for
deterministic fetch/build/verify tooling therefore remains open.

```bash
# Python 3.12 (coremltools/torch don't ship 3.14 wheels yet)
uv venv --python 3.12 .venv && source .venv/bin/activate
uv pip install coremltools torch onnx onnx2torch huggingface_hub numpy
python - <<'PY'
import numpy as np, torch, coremltools as ct
from onnx2torch import convert
onnx = "build/model-sources/auraface/glintr100.onnx"
tm = convert(onnx).eval()
ex = torch.randn(1,3,112,112)
traced = torch.jit.trace(tm, ex)
m = ct.convert(traced,
               inputs=[ct.TensorType(name="input", shape=(1,3,112,112), dtype=np.float32)],
               minimum_deployment_target=ct.target.macOS13,
               compute_precision=ct.precision.FLOAT16, convert_to="mlprogram")
# rename the auto-named output to "embedding"
from coremltools.models import MLModel
from coremltools.models.utils import rename_feature
spec = m.get_spec()
rename_feature(spec, spec.description.output[0].name, "embedding")
MLModel(spec, weights_dir=m.weights_dir).save("AuraFaceR100.mlpackage")
PY
# then move AuraFaceR100.mlpackage into this folder
```

Validate after converting: a torch-vs-CoreML cosine similarity of ~0.9999 on random inputs, and on
real faces same-person cosine distance ≈ 0.45 vs different-person ≈ 0.9 (see `FaceEmbeddingTests`).
If same-person distances look high, flip `CoreMLFaceEmbedder.inputIsRGB` (RGB vs BGR).
