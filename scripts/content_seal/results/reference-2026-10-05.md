# VideoSeal reference experiment — 2026-10-05

**Message extraction works in this experiment; blind presence detection remains unvalidated.**
This checks only the published open-source VideoSeal v1.0 model, not Meta's
proprietary production watermark or all Meta-generated images.

A photorealistic Bergen market scene was generated with the imagegen tool as an
RGB fixture. It is synthetic and does not depict a verified real event. Its
unaltered version is a negative control for this specific VideoSeal payload,
not evidence that an AI-generated image lacks other provenance signals.

The generated asset is 1254 × 1254. The model embeds three different seeded
256-bit messages into copies. Gradient, random noise and flat gray procedural
controls add three content regimes. Nine transforms per source/message, each
with matched watermarked/unwatermarked pairs, produce **216 inference cases**.
These cases contain only one photographic scene; repeats and transforms are
correlated. They cannot establish population-level false-positive rates.

CPU reference runtime: Python 3.12, PyTorch 2.4.1, Pillow 11.3.0, NumPy 1.26.4.
Seeds, exact runtime versions and source/checkpoint/file hashes are recorded in
[JSON](reference-2026-10-05.json) and [CSV](reference-2026-10-05.csv).
Raw scores in those files are sigmoid(channel-zero logit), retained for diagnosis,
not detection decisions.

## Photographic fixture results

Mean agreement with the original payload across three messages:

| Transform | Unwatermarked control | Watermarked copy |
| --- | ---: | ---: |
| PNG | 51.04% | 99.74% |
| JPEG quality 95 | 51.56% | 99.61% |
| JPEG quality 85 | 50.13% | 99.61% |
| JPEG quality 60 | 50.26% | 99.74% |
| JPEG quality 30 | 50.39% | 99.61% |
| Resize to half size | 51.30% | 99.74% |
| Resize to 256 × 256 | 52.21% | 99.74% |
| Center crop, retain 75% of each side | 47.53% | 78.65% |
| Center crop, retain 50% of each side | 52.60% | 49.74% |

Chance agreement is approximately 50%. Crop percentages describe **side lengths**:
the latter retains 25% of the image area. Float (before file encoding) recovery
was 98.83%, 100%, and 100% for the photographic fixture.

## Findings affecting the prototype

1. **The initial score interpretation was unsuitable.** The first-channel sigmoid
   was about 0.531 on plain market PNG and 0.497 on watermarked PNG, despite nearly
   complete payload recovery. Across other content/transforms, scores overlap.
   The CLI now labels it diagnostic and refuses threshold-based blind decisions.
2. **Known-message comparisons work on this fixture.** Two end-to-end checks with
   the first photographic payload and an explicit experimental 90% agreement
   cutoff returned `known_message_match` for the watermarked PNG (99.22%) and
   `known_message_not_matched` for the control (47.27%). This does not provide a
   payload for arbitrary images or identify their creator.
3. **Cropping is a major limitation** in this configuration, without synchronization
   or crop search. Heavy cropping brings recovery back to chance.
4. **Quantization and content matter.** Flat gray had about 99.2% float recovery,
   but only 55.6% after saving to 8-bit PNG and 49.1% after JPEG quality 85.
   Gradient PNG recovery was 73.2%; random noise PNG was 98.7%.
5. **The previous Python 3.14 smoke result was reproducible on Python 3.12.** The
   smooth 256px synthetic texture still recovered 52.3%. This was not simply an
   unsupported runtime issue; the new content/resolution regimes produce different
   results.

Eight policy/tensor tests pass, including malformed/non-finite predictions,
spatial pooling, payload validation, and preventing diagnostic-score verdicts.
No production Meta images were tested. There is no validated detection threshold.

The macOS UI links separately to [Meta AI Identification](https://www.meta.ai/identification/)
for a user-initiated provider check, with a notice that uploads occur on Meta's
site and results do not guarantee authenticity.
