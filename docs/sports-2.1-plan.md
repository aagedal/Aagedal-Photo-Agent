# Sports mode 2.1 — confirm-before-write, decoupled identity

The 2.0 release shipped the full sports-tagging pipeline (jersey OCR, colour clustering,
rosters, resolution) but flag-gated the Sports lens off. 2.1 turns it on and reworks the trust
model so it's safe for press use, where a wrong `PersonInImage` (a supporter in a similar shirt,
an OCR misread, the opposing team's number) is a real liability.

## Core model: numbers are *claims*, decoupled from body geometry

A photo of a match usually has several players. The pixels of a number sitting over a face's
*estimated* torso may belong to a different player — connecting a jersey to a face by geometry is
unreliable, and a recognised face plus a nearby number can be two correct, different people. So:

- Each detected number is an image-level **claim** (`NumberDetection`) that a given player is in
  the photo — never a silent rename of the face it happened to overlap.
- The face↔number torso link survives only as a hint (`associatedFaceID`) used to suggest a card
  and to enable auto-confirmation. `applyJerseyNumberMerges` (merge groups by number) is now an
  explicit, user-initiated action only — it no longer runs automatically on lens switch.

## Confirm-before-write + auto-confirm on agreement

`NumberDetection.claimState`: `suggested` → `confirmed` → `rejected` (optional/back-compat; nil =
suggested). Only **confirmed** claims write a name, and only while the **Sports lens is active**
(switch to Face and number-derived names stop applying; detections stay in `.face_data`).

Auto-confirm rule (the only automatic write): a still-`suggested` claim is confirmed iff its image
already holds an **independently identified** face — a group named by face recognition or the user,
never by a number — naming the **same** player. Two agreeing signals. Everything else waits in the
review queue. `rejected` is sticky; `confirmed` drops back to `suggested` if its resolved name
changes (e.g. a colour-side flip).

Pure, tested core: `FaceRecognitionViewModel.reconcileNumberClaims(...)` (nonisolated static, like
`jerseyMergePlan`). Tests in `SportsTaggingTests.swift`.

## UI (Sports lens assist strip)

- **Confirmed players** — identity-centric cards (face thumbnail + name + photo count). Right-click
  → remove player (rejects their number claims). These are what Apply writes.
- **Review queue** — one row per suggested/ambiguous claim: number badge (click → full-screen to
  verify the digits), resolved name, reason (`number only — no face`, `face not yet identified`,
  `on both teams — pick a side`), and Confirm / Reject (or Home / Away for ambiguous).
- **Not on a team sheet** — standalone numbers with no roster match.

View-model API: `confirmedPlayerCards`, `sportsReviewItems`, `confirmNumberClaim`,
`rejectNumberClaim`, `detachNumberFromFace`, `assignSide`.

## Gating

`FaceRecognitionDefaults.sportsLensEnabled = true` ships Sports independently of `multiLensEnabled`
(Expression / Red Carpet stay gated until calibrated). `availableLenses` adds `.sports` only when
the folder produced jersey data.

## Done in this pass
- [x] `NumberClaimState` + claim-of-record model (migration-safe)
- [x] Decoupled resolution (`reconcileNumberClaims`), no group renaming, no auto-merge
- [x] Auto-confirm on agreement; sticky reject; confirm-on-name-change reset
- [x] Apply gated on `confirmed` + Sports lens active
- [x] Confirmed-player cards + review queue + remove/confirm/reject/detach
- [x] `sportsLensEnabled` independent gate
- [x] Unit tests for the trust core
- [x] **Bib mode (individual sports)** — `MatchRoster.mode` (`team` | `event`, optional/back-compat;
  `effectiveMode` → `.team`). Event mode: single startlist in the home slot, `setEventStartlist`,
  `runSportsResolution` skips clustering and the colour-confirm step, `PlayerResolver` resolves the
  bib by number alone (never ambiguous). `MatchSetupView` has a Team-match / Individual-event
  segmented picker. Tests cover event resolution + legacy decode. (17 sports tests passing.)
- [x] Stale "merge groups" lens caption replaced.

- [x] **Number-crop thumbnails** — review rows show a crop of the detected number (verify "6" vs
  "8") with a `#N → Name` label, via `NumberCropService` + `NumberCropCache` (downsampled decode,
  memoised). Unmatched-number badges show the crop on hover.
- [x] **Drag a number onto a person** — review-queue rows and unmatched badges are draggable
  (`number:<id>` string payload); the existing `FaceGroupCollectionView` drop handler binds the
  claim to the dropped-on group (`bindNumberDetection`), confirming it.
- [x] **Correct a misread number** — pencil button on review rows → popover (0–99); `correctNumber`
  updates the claim + face hint, re-resolves against the roster, resets to `suggested`. Confirm (✓)
  writes on Apply; Reject (✗) marks `rejected` — never written, never reappears.

- [x] **Team categorisation + library search/filter** — `Team.sport` (`TeamSport`, optional →
  `effectiveSport` = `.other`); Teams library has a search field + sport filter menu (only sports
  in use are listed). Picker in the team editor.
- [x] **Home/away kit colours** — `Team.secondaryColor` (alternate/away kit). `Team.kitColors`
  exposes [primary, secondary, goalkeeper]; `TeamColorClusterer.cluster` now takes `homeKits` /
  `awayKits` candidate lists and maps a cluster to the side with the *nearest* candidate, so a team
  in its change strip still lands on the right side. Tested.

- [x] **Name a group from the team sheet** — face-group ⋯ menu → "Name from Team Sheet…" (Sports
  lens, match ready): enter number + team, see the suggested player live, confirm. For numbers the
  photographer can read but can't place, or that OCR missed (stylised fonts). `rosterName(forNumber:
  side:)` + `nameGroup(_:fromNumber:side:)`; `NameFromTeamSheetView` sheet.
- [x] **Teams in Settings** — Settings ▸ People and Groups ▸ Teams hosts the same `TeamsLibraryContent`.

## Next
- [ ] Team-sheet / startlist paste import is already present in the team editor.
- [ ] Tournament-wide "recognised from earlier" via the `knownPersonID` bridge.
- [ ] Referee / non-player exclude action.
- [ ] `(number)` caption token.
- [ ] Threshold calibration on real match photos.
