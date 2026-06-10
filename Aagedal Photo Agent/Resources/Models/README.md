# Face recognition model — NOT in git

The face-recognition feature loads a bundled CoreML model at runtime:

```
Aagedal Photo Agent/Resources/Models/AuraFaceR100.mlpackage   (~125 MB)
```

This file is **excluded from git** (see the repo `.gitignore`) because of its size. The app still
**builds and runs without it** — but **face recognition is disabled**: `CoreMLFaceEmbedder` logs
"AuraFace CoreML model not found in app bundle" and no face embeddings are produced. Drop the model
at the path above (Xcode's synchronized group picks it up automatically) to enable recognition.

## What the model is

**AuraFace-v1** — the `glintr100` recognition net (ArcFace R100), an open, commercially-usable
ArcFace variant. **License: Apache-2.0** (see `AuraFace-LICENSE.md` in this folder).
Source: <https://huggingface.co/fal/AuraFace-v1>

## How to (re)build `AuraFaceR100.mlpackage`

The Swift pipeline expects: input **`input`** shape `[1,3,112,112]` float32, **RGB**, normalized
`(x − 127.5) / 127.5`, NCHW; output renamed **`embedding`**, 512-d (the app L2-normalizes it).

```bash
# Python 3.12 (coremltools/torch don't ship 3.14 wheels yet)
uv venv --python 3.12 .venv && source .venv/bin/activate
uv pip install coremltools torch onnx onnx2torch huggingface_hub numpy
python - <<'PY'
import numpy as np, torch, coremltools as ct
from onnx2torch import convert
from huggingface_hub import hf_hub_download
onnx = hf_hub_download("fal/AuraFace-v1", "glintr100.onnx")
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
