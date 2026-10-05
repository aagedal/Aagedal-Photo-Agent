# Open-source watermark research prototype

This local prototype extracts **Meta's open-source VideoSeal v1.0 watermark messages**.
It does **not detect all Meta-generated images**, does not verify Meta's proprietary
production watermark, and is **not a validated blind watermark presence detector**.
No match does not establish authenticity or exclude AI generation. PixelSeal is
not supported yet. The CLI is not connected to the macOS analyzer.

For an additional provider check, the app links to
[Meta AI Identification](https://www.meta.ai/identification/). Users choose whether
to upload an image, video or audio file, or paste a public URL there. Photo Agent
never uploads the image automatically. That service is separate from this research
model and its results do not guarantee authenticity.

## Run

Use Python 3.10–3.12 with these pinned reference dependencies (tested on 3.12):

```sh
python3.12 -m venv /private/tmp/content-seal-runtime312
/private/tmp/content-seal-runtime312/bin/pip install -r scripts/content_seal/requirements.txt
curl -fL https://dl.fbaipublicfiles.com/videoseal/y_256b_img.jit \
  -o /private/tmp/content-seal-videoseal.jit
/private/tmp/content-seal-runtime312/bin/python scripts/content_seal/detect.py image.jpg \
  --checkpoint /private/tmp/content-seal-videoseal.jit
```

Use only a trusted official checkpoint: TorchScript loading executes model code.
Checkpoint SHA-256 is recorded for reproducibility, not proof of its source.
Detection performs no network requests or automatic downloads.

JSON output records source/checkpoint hashes, preprocessing, runtime, decoded bits,
scope and limitations. Images must be single-frame opaque RGB or grayscale.
EXIF orientation is applied; no ICC transform or app develop edits are applied.
The model handles inference resizing.

The default result is always `inconclusive`. Channel zero is recorded as
`diagnostic_channel_zero_score`, **not used to classify watermark presence**:
paired tests showed overlapping values and successful extraction at lower scores.

If the actual original 256-bit payload is known, pass it via `--expected-message`
and optionally `--threshold 0.9` for an experimental bit-match decision. This is
an example cutoff, not calibrated for general images. The statuses are
`known_message_match` and `known_message_not_matched`; neither identifies Meta AI
or proves creator identity. A threshold without a known payload is rejected.

## Reproduce the Python experiment

```sh
/private/tmp/content-seal-runtime312/bin/python -m unittest discover \
  -s scripts/content_seal -p 'test_*.py'
/private/tmp/content-seal-runtime312/bin/python scripts/content_seal/benchmark.py \
  --image scripts/content_seal/artifacts/generated-market.png \
  --checkpoint /private/tmp/content-seal-videoseal.jit \
  --output scripts/content_seal/artifacts/new-run --messages 3
```

The generated photographic fixture is retained locally under `artifacts/`; large
images and transformed pairs are ignored by git. Supply another RGB image with
`--image` to repeat the experiment elsewhere. Output directories must be new to
avoid overwriting evidence. The runner creates paired PNG, JPEG quality 95/85/60/30,
half-size, 256px and center-crop fixtures, recording file hashes, expected messages,
bit recovery, embedding PSNR and raw channel-zero scores. Procedural gradient,
noise and flat controls are also generated. Seed is 42.

[Measured results and limitations](results/reference-2026-10-05.md) include raw
JSON/CSV data. Eight policy/tensor tests and two known-message end-to-end checks
passed. The benchmark completes with the official checkpoint; its metrics are
observations, not a passing accuracy benchmark.

## Next step

A blind detector requires a validated signal or a known watermark payload registry.
Do not turn the diagnostic channel into an app verdict. Expand to independent real
photographs and other published models, measure false matches on held-out data,
and investigate crop synchronization before app integration or Core ML conversion.

## Upstream

- [Meta Content Seal](https://facebookresearch.github.io/content-seal/) distinguishes the proprietary production implementation.
- [VideoSeal repository](https://github.com/facebookresearch/videoseal) provides MIT-licensed research models.
- [TorchScript inference guide](https://github.com/facebookresearch/videoseal/blob/main/docs/torchscript.md) documents the checkpoint and API.
- [Upstream evaluation](https://github.com/facebookresearch/videoseal/blob/main/videoseal/evals/full.py) compares recovered bits with known messages; detection metrics are disabled by default.
