# 3.0.0 Beta 6 public release record

Release identity: **3.0.0-beta.6**, build **745**, minimum macOS **26.0**, **Apple Silicon**.
Application source: `6a44997893a6316040b0be1cd0294f2bfa9fda82`.
The numeric bundle short version remains `3.0.0`; `AagedalReleaseVersion`
provides the beta label. The Sparkle item uses the **beta** channel and build 745.

## Changes

Beta 6 ships everything merged since Beta 5 (#90–#114): the Locations sidebar browser, Known
People and Templates iCloud sync safety, browser-tab keyboard shortcuts, the experimental SAM 2.1
AI mask engine with Add/Subtract points and drag preview, the Specific Folder export location,
scopes that match the HDR/SDR preview, Image Analysis OSINT time and map fixes, hideable
structured metadata groups and resizable multi-line fields, hostile-input hardening, and several
crash fixes, as listed in the changelog.

Build 745 was set when Beta 6 was first prepared (#104, 2026-11-10) and was never published,
so it was not bumped when the release was refreshed (#114).

The release source's `CHANGELOG.md` was missing entries for #91, #92, #93, #95, #97 and #103,
which merged after the Beta 5 tag but before Beta 6 was first prepared. They were added
with the appcast, along with a Highlights bullet. The changelog is not bundled in the app, so the
DMG is unaffected; the appcast notes come from the corrected Highlights.

## Verification

- [Required clean CI](https://github.com/aagedal/Aagedal-Photo-Agent/actions/runs/44544743829)
  passes on the exact application source (5,066 tests across 481 suites, Xcode 26.6).
  No emergency release-gate override was used.
- The release archive was built with **Xcode 27.2 (27B52)**, while CI used Xcode 26.6.
- Release test gate (AuraFace app-level preprocessing/reference) passes; AuraFace is
  included in the app bundle.
- Apple Silicon Release archive and Developer ID export succeed; Gatekeeper accepts the DMG.
  App and DMG have accepted Apple notarizations and stapled tickets. Sparkle EdDSA
  signature matches the app's embedded public key.
- App notarization: `6d756836-65be-4108-87cd-2218f805637c` — **Accepted**.
- DMG notarization: `27430d1f-4398-42e8-826d-fd189758ba3a` — **Accepted**.

## Artifact

File: `Aagedal-Photo-Agent-3.0.0-beta.6.dmg`
Size: **266,267,208 bytes**
SHA-256: `124906b4f6e54dbb6a3d94737396c4f68f2f35a2fa9d8c274638f560e7e8eaea`

FFmpeg corresponding source (GPLv3 §6), published as a release asset next to the DMG:
`ffmpeg-9.0.2-photo-agent-source.tar`, SHA-256
`7537e7d1e12647073caee42d2d86b411d5b79fe35a5725baf57eef7c554012c1`. The bundled FFmpeg
binary and its recipe are unchanged since Beta 4, so this is the same archive as Beta 5's
(re-downloaded from that release and hash-checked).

## Publication

GitHub is the primary download host and appcast source: the Sparkle enclosure points at
`https://github.com/aagedal/Aagedal-Photo-Agent/releases/download/3.0.0-beta.6/Aagedal-Photo-Agent-3.0.0-beta.6.dmg`,
and the canonical feed is the GitHub `main` `appcast.xml`. Betas are not mirrored to the
aagedal.me backup host (`https://aagedal.me/apps/photoagent/`); it is only updated for
stable releases.
