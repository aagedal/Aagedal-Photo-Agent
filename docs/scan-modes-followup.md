# Follow-up plan: user-friendly Scan Modes

**Status:** proposal / not started. Secondary to core face recognition (now working).

## Context

The face UI currently has a settings **cog** (a clustering popover with a sensitivity slider) plus a
separate **rescan/reset** button. We want to replace all of that with a single, friendlier gesture:
clicking **Scan** opens a small **mode-picker overlay**; choosing a mode both selects it *and* starts
the scan in one click. This removes the cog and the standalone rescan button and makes the feature
self-explanatory via short mode descriptions instead of an opaque slider.

This also gives a clean home to capabilities that were removed/deferred during the v2.0 rewrite
(Face+Clothing, Sports) and turns the old "general image similarity" behaviour into a deliberate
**Expression** mode rather than a bug.

## UX

- **Scan button → popover** of 3–4 mode cards. Each card: SF Symbol + title + one-line description.
- **One click on a card = pick mode + run the scan.** No separate confirm.
- Remove `ClusteringSettingsPopover` (the cog) and the dedicated reset/force-rescan button.
- The last-used mode is remembered and shown as the default/highlighted card.
- **Force-full rescan** affordance (since switching mode already forces a re-embed, only the
  *same-mode* full rescan needs an explicit gesture): Option-click a card, or a small "Rescan all"
  toggle inside the popover.

### Proposed modes

| Mode | Title / description | What it does technically |
|---|---|---|
| `face` | **Face** — "Group people by who they are." | Identity only: `CoreMLFaceEmbedder` (ArcFace) + cosine clustering. The current default pipeline. |
| `sports` | **Sports** — "Identify players by face and shirt number." | ArcFace identity + `JerseyDetectionService` (number OCR) + `TeamColorClusterer` + `PlayerResolver`/roster. (Currently built but hidden/deferred to 2.1.) |
| `redCarpet` | **Red Carpet** — "Same event, same outfit — group by face and clothing." | ArcFace face distance **combined** with a clothing/torso descriptor (`ClothingFeatureService`). Helps when many similar faces appear in consistent attire. |
| `expression` | **Expression** — "Group by look and expression, not identity." | A general-appearance descriptor (Apple `VNGenerateImageFeaturePrint` on the face crop) — groups similar-looking/expression shots. Deliberately *not* identity. |

## Architecture

- Add `FaceScanMode: String, Codable, CaseIterable` with `title`, `description`, `systemImage`, and
  per-mode clustering parameters. Store the mode on `FolderFaceData` (supersedes the retained-but-unused
  `recognitionMode`). The scan-mode popover binds to this.
- **Leverage the existing `FaceEmbedder` protocol** (the rewrite already abstracts the embedder):
  - `face`/`sports`/`redCarpet` face component → `CoreMLFaceEmbedder` (identity).
  - `expression` → new `VisionFeaturePrintEmbedder: FaceEmbedder` wrapping `VNGenerateImageFeaturePrint`
    (extract the feature vector → reuse `EmbeddingCodec`/cosine, or store the observation + its
    `computeDistance`). Different distance scale → its own threshold.
  - `redCarpet` → reintroduce a combined face+clothing distance. The v2.0 rewrite deleted the old
    `clusterFacesModeAware`/`computeModeAwareDistance` + clothing storage; bring back a *lean* version:
    store an optional clothing embedding on `DetectedFace`, and cluster on
    `faceDist*w + clothingDist*(1-w)` only in this mode.
- **Embeddings are not comparable across modes** (ArcFace identity vs VNFeaturePrint appearance vs
  face+clothing). Switching a folder's mode must force a full re-embed. This is natural with the new
  UX (picking a different card = rescan). Gate via the stored mode + `embeddingVersion`.
- **Per-mode thresholds** live in `FaceRecognitionDefaults` (no user slider). Calibrate each on real
  data the way the `face` threshold (0.70) was calibrated.

### Known People interaction (important)

Only identity-bearing modes feed/match the **global Known People gallery**: `face`, `sports`,
`redCarpet` (face component). **`expression` does not** do identity matching — its groups are
appearance clusters, so auto-matching to known people should be disabled in that mode.

## Phasing (incremental — `face` ships first)

1. **Popover + `FaceScanMode` + `face` mode.** Build `ScanModePopover`, wire the Scan button, remove
   the cog and the standalone rescan button. Only the `face` card is fully functional; others can be
   shown disabled/"coming soon" or land in later phases. Shippable on its own and already a UX win.
2. **Expression mode** — `VisionFeaturePrintEmbedder` behind `FaceEmbedder`; its own threshold; skip
   Known People matching.
3. **Red Carpet mode** — reintroduce the optional clothing embedding + combined-distance clustering.
4. **Sports mode** — un-hide the existing pipeline; depends on fixing jersey-number/team-colour
   accuracy (currently deferred to 2.1).

## Open questions

- One mode per folder at a time (switching re-scans), or keep multiple modes' results side by side?
  (Recommend: one at a time — simplest, and the popover makes re-scanning cheap once we add the
  "re-cluster from stored embeddings" optimization.)
- Should `face` be a single-click "quick scan" with the other modes one level down, or are all
  modes peers in the popover?
- Force-full-rescan gesture: Option-click vs an in-popover toggle.
- Pairs with the other follow-up: **re-cluster using stored embeddings without re-embedding**, so
  same-mode re-runs (and any future per-mode threshold tweak) are instant.
