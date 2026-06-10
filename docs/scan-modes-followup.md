# Follow-up plan: face lenses (always-scan, switch-view)

**Status:** proposal / not started. Supersedes the earlier "pick a scan mode up front" draft.

## Context

The face UI currently has a settings **cog** (a clustering popover with a sensitivity slider), a
standalone **rescan/reset** button, and a **Teams** button (sports). We're replacing the
"pick one mode, which forces a re-embed" idea with a simpler model:

**Always scan; default to the Face view; let the user switch lenses on already-computed data.**

Face recognition always runs first and its results are visible and usable immediately, while the
other lenses finish embedding in the background. Switching lenses never re-detects and never
re-embeds — it just re-clusters from stored embeddings, so it's effectively instant.

This reframes the old "modes" (mutually exclusive, pick one, re-scan to switch) as **lenses**
(alternative groupings over a single scan). It also dissolves the previous draft's central pain
point — "embeddings aren't comparable across modes, so switching forces a full re-embed" — because
we compute and keep every lens's embedding up front.

## Core model: detect once, embed many, cluster per lens

1. **Detect once.** One detection pass produces the canonical set of aligned face crops
   (`FaceDetectionService`). This is the expensive part and is never repeated when switching lenses.
2. **Embed many.** Per face we store more than one embedding: the ArcFace **identity** vector
   (always), plus — prewarmed after Face completes — an **appearance** vector (Expression) and a
   **clothing** vector (Red Carpet).
3. **Cluster per lens.** Each lens is a different clustering/labeling over the same crops, cached on
   disk. Switching the view re-clusters from stored embeddings (or shows the cached result).

This leans on machinery that already exists: the `FaceEmbedder` protocol is already an abstraction,
and the scan pipeline already streams partial results (`scanFolder` saves `scanningGroups` every ~10
batches with `scanComplete: false`).

## Lenses

| Lens | Title / description | What it does technically | Identity? |
|---|---|---|---|
| `face` | **Face** — "Group people by who they are." | ArcFace identity (`CoreMLFaceEmbedder`) + cosine clustering. The default; runs first, streams. | yes |
| `expression` | **Expression** — "Group by look and expression, not identity." | Apple `VNGenerateImageFeaturePrint` on the face crop → its own threshold. Deliberately *not* identity. | no |
| `redCarpet` | **Red Carpet** — "Same event, same outfit — group by face and clothing." | ArcFace face distance **combined** with a clothing/torso descriptor (`ClothingFeatureService`): `faceDist*w + clothingDist*(1-w)`. Disambiguates similar faces in consistent attire. | yes (face component) |

**Sports is deferred to the next release and has no UI in this work.** The underlying services
(`JerseyDetectionService`, `TeamColorClusterer`, `PlayerResolver`) stay in the codebase but are
unhooked from the UI here. Sports is *not* a clustering lens like the others — it's enrichment +
roster resolution (jersey OCR, team color, back-turned players with a number but no face) and needs
a configured roster — so it will land as its own thing, not as a fourth segment, when we pick it up.

## UX

- **Default view is Face.** The compact face bar stays Face-only — no lens switcher there.
- **Lens switcher lives in the expanded all-groups view** (`ExpandedFaceManagementView`), as a
  segmented control at the top: `Face · Expression · Red Carpet`. These are alternative top-level
  groupings of the whole folder, not drill-downs inside one identity group, so the switcher belongs
  at the all-groups level, not in the single-group detail.
- **Prewarm after Face.** When the Face scan completes, a low-priority background task computes the
  Expression and Red Carpet embeddings so switching to those views is instant. Until a lens's
  embeddings are ready, its segment shows a small in-progress state rather than blocking.
- **No mode picker, no re-scan to switch.** Picking a lens just re-clusters stored data.

### Button cleanup

- **Cog / sensitivity slider (`ClusteringSettingsPopover`)** — removed. Per-lens calibrated
  thresholds in `FaceRecognitionDefaults` replace the user-facing slider. (The popover also currently
  holds experimental sports settings — those go away with the Sports UI for now.)
- **Rescan / orange reset button** — demoted off the bar into an overflow/context menu in the
  expanded view. A full re-detect is rarely needed: an `embeddingVersion` bump already auto-forces
  one, and lens switches re-cluster from stored embeddings.
- **Teams button** — removed for now (Sports deferred). When Sports returns, its controls live with
  the Sports surface, not in the global toolbar.

## Architecture

- **Replace `FolderFaceData.recognitionMode`** (retained but unused) with per-lens state:
  - per-lens cluster results (the `[FaceGroup]` for each lens),
  - per-lens status (`notStarted` / `embedding` / `clustering` / `complete`),
  - per-lens embedding version, so bumping the Expression model doesn't invalidate Face identity.
  The currently-active lens for the folder is remembered for the expanded view.
- **`DetectedFace` grows from one embedding to a small set:** `identity` (ArcFace, always present)
  plus optional `appearance` (VNFeaturePrint) and `clothing` (torso descriptor). Each is an encoded
  blob (reuse `EmbeddingCodec`); all optional so legacy `face_data.json` keeps decoding.
- **Reuse the `FaceEmbedder` protocol.** Add `VisionFeaturePrintEmbedder: FaceEmbedder` wrapping
  `VNGenerateImageFeaturePrint` for the Expression appearance vector (different distance scale → its
  own threshold). Red Carpet reuses the existing `ClothingFeatureService` for the clothing vector and
  clusters on the combined distance.
- **Per-lens thresholds** live in `FaceRecognitionDefaults` (no user slider). Calibrate each on real
  data the way the `face` threshold (0.70) was calibrated.
- **Known People gating.** Only identity-bearing lenses feed/match the global Known People gallery:
  `face` and the face component of `redCarpet`. **`expression` does not** — its groups are appearance
  clusters, so auto-matching is disabled and the naming/assignment UI is hidden in that view.

## Phasing (incremental — `face` view ships first)

1. **Lens switcher + Face lens + button cleanup.** Add the segmented switcher to
   `ExpandedFaceManagementView`, make the compact bar Face-only, remove the cog/slider, demote the
   rescan affordance, remove the Teams button + Sports UI. Per-lens `FolderFaceData` scaffolding with
   only `face` populated. Shippable on its own and already a UX win.
2. **Expression lens** — `VisionFeaturePrintEmbedder` behind `FaceEmbedder`; multi-embedding storage
   on `DetectedFace`; prewarm-after-Face pipeline; its own threshold; skip Known People matching.
3. **Red Carpet lens** — clothing embedding via `ClothingFeatureService` + combined-distance
   clustering; prewarmed alongside Expression.
4. **Sports** — next release. Un-hide/extend the existing pipeline as its own surface (roster setup,
   jersey resolution, back-turned players); depends on fixing jersey-number/team-colour accuracy.

## Resolved decisions

- Switcher location → **expanded all-groups view** (`ExpandedFaceManagementView`).
- Expression / Red Carpet timing → **prewarm in the background after Face completes**.
- Sports → **removed from the UI for now**, returns as its own surface next release.

## Open questions

- One active lens per folder at a time (recommended — simplest; switching is cheap once we
  re-cluster from stored embeddings), or keep multiple lenses' groupings side by side?
- Prewarm both secondary lenses eagerly after Face, or only the one the user is most likely to open?
  (Default: prewarm both; they're cheap embedding passes over already-detected crops.)
- Red Carpet combined-distance weight `w`: fixed default vs. calibrated per dataset.
