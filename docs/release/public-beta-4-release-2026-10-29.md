# 3.0.0 Beta 4 public release record

Release identity: **3.0.0-beta.4**, build **743**, minimum macOS **26.0**, **Apple Silicon**.
Application source: `80114c4e67b841c614b59bbe872943229cf228dc`.
The numeric bundle short version remains `3.0.0`; `AagedalReleaseVersion`
provides the beta label. The Sparkle item uses the **beta** channel and build 743.

## Changes

Beta 4 replaces the Anonymizer's single strength slider with the full Redact Anonymizer
control set (distortion, blur and mosaic layers, cell shapes, cell/colour noise,
desaturate, blur after mosaic, frosted glass and a stored seed) rendered as separate
passes, and includes the save-failure reporting, sidecar-authoritative export, RAW+JPEG,
import, Develop, performance, upgrade, accessibility and reliability work listed in the
changelog.

## Verification

- [Required clean CI](https://github.com/aagedal/Aagedal-Photo-Agent/actions/runs/40946577615)
  passes on the exact application source (4,960 tests across 472 suites). The first
  attempt failed one Caption preview cache test ("Returning to a photo, or asking for a
  smaller size, is served from memory"); its rerun passed, and the test passes locally
  3/3. No emergency release-gate override was used.
- Local full suite before merge: 4,960 tests, two failures unrelated to the release — the
  MCP helper hardened-runtime signature check (always fails in unsigned local runs) and
  `AnalysisCaseTests` "workspace stays usable and exposes fallback portability state",
  which fails identically on the unchanged Beta 4 prep commit `3defa64` locally and passes
  in CI.
- Repository validation and app-level AuraFace RGB preprocessing/reference checks pass.
- Apple Silicon Release archive and Developer ID export succeed; Gatekeeper accepts the DMG.
  App and DMG have accepted Apple notarizations and stapled tickets. Sparkle EdDSA
  signature matches the app's embedded public key.
- App notarization: `b1766182-512a-4e1f-bb40-973499c86697` — **Accepted**.
- DMG notarization: `92a93e21-fa64-4701-aa0b-a2ad014516ee` — **Accepted**.
- Redact rendering was checked against the plugin's reference image with offscreen
  renders (default, triangle/hexagon, frosted glass, blur after mosaic, legacy strength,
  cropped export aligned to the uncropped render). The Develop panel controls have not
  been inspected in the running app.

## Artifact

File: `Aagedal-Photo-Agent-3.0.0-beta.4.dmg`
Size: **265,941,992 bytes**
SHA-256: `66396d330d0e7208ee534fce8cdf48395f40025b587ca2a84f9ccd9687201997`

FFmpeg corresponding source (GPLv3 §6), published as a release asset next to the DMG:
`ffmpeg-9.0.2-photo-agent-source.tar`, 79 files, 219.3 MB, SHA-256
`7537e7d1e12647073caee42d2d86b411d5b79fe35a5725baf57eef7c554012c1`.
The bundled binary is the `photo-agent` variant of
[ffmpeg-apple-silicon](https://github.com/aagedal/ffmpeg-apple-silicon); the companion's recipe
matches that repository's commit `857fee2` except `scripts/12-ffmpeg.sh`'s resume path for the
`full` variant (not used by the `photo-agent` build). The recipe alone is not the corresponding
source (it downloads upstream archives and clones a moving x264 `stable` branch), so the
companion archive is published as well.

## Publication

From Beta 4, GitHub is the primary download host and appcast source: the Sparkle
enclosure points at the GitHub release asset
`https://github.com/aagedal/Aagedal-Photo-Agent/releases/download/3.0.0-beta.4/Aagedal-Photo-Agent-3.0.0-beta.4.dmg`,
and the canonical feed is the GitHub `main` `appcast.xml`. aagedal.me is the backup host
(`https://aagedal.me/apps/photoagent/`), served by the website fallback feed.
`scripts/release.sh` now defaults to these.
Codeberg is no longer used (it doesn't allow AI agents); its legacy feeds are not updated
from Beta 4 on.
