# 3.0.0 Beta 5 public release record

Release identity: **3.0.0-beta.5**, build **744**, minimum macOS **26.0**, **Apple Silicon**.
Application source: `1ff6a6fcd1b5670cfb39598faa7c28005bc93657`.
The numeric bundle short version remains `3.0.0`; `AagedalReleaseVersion`
provides the beta label. The Sparkle item uses the **beta** channel and build 744.

## Changes

Beta 5 adds the Adobe Bridge-style browser layout (drag tabs to pane edges to split, up to
eight panes), the thumbnail icon legend, Export All Versions in the unified Develop version
menu, two-at-a-time batch export on a separate GPU lane, Develop backup and save-echo fixes,
uncapped wide anonymizer blurs and several crash fixes, as listed in the changelog.

## Verification

- [Required clean CI](https://github.com/aagedal/Aagedal-Photo-Agent/actions/runs/41195611476)
  passes on the exact application source (4,996 tests across 476 suites, Xcode 26.6).
  No emergency release-gate override was used.
- Two fixes landed after the Beta 5 prep commit and before the release build:
  - #88: `main` failed its clean build after #86 (a `@TaskLocal` static on the
    MainActor-default `MetalEditPipeline` got a main-actor accessor). PR CI skips the clean
    build, so it was only caught on `main`. The task-local moved to a top-level nonisolated
    enum.
  - #89: the release machine's Xcode was updated to 27.2 during the release, whose SDK marks
    `CIRAWDecoderVersion.version9`/`version9DNG` macOS 27-only; one test was guarded with
    `#available`. Xcode 27.2 also needed `xcodebuild -downloadComponent MetalToolchain`.
- The release archive was built with **Xcode 27.2 (27B52)**, while CI used Xcode 26.6.
- Release test gate (AuraFace app-level preprocessing/reference) passes.
- Apple Silicon Release archive and Developer ID export succeed; Gatekeeper accepts the DMG.
  App and DMG have accepted Apple notarizations and stapled tickets. Sparkle EdDSA
  signature matches the app's embedded public key.
- App notarization: `177ae12e-30fe-40eb-9e3e-d45f60c6f469` — **Accepted**.
- DMG notarization: `77def766-f531-4650-bdbb-4a9bbcfaf252` — **Accepted**.

## Artifact

File: `Aagedal-Photo-Agent-3.0.0-beta.5.dmg`
Size: **268,165,383 bytes**
SHA-256: `b24028ae7022d677c2c977665425e34717cba8824a079b3facb2d263fa45f981`

FFmpeg corresponding source (GPLv3 §6), published as a release asset next to the DMG:
`ffmpeg-9.0.2-photo-agent-source.tar`, SHA-256
`7537e7d1e12647073caee42d2d86b411d5b79fe35a5725baf57eef7c554012c1`. The bundled FFmpeg
binary and its recipe are unchanged since Beta 4, so this is the same archive as Beta 4's
(re-downloaded from that release and hash-checked; the original build workspaces no longer
exist).

## Publication

GitHub is the primary download host and appcast source: the Sparkle enclosure points at
`https://github.com/aagedal/Aagedal-Photo-Agent/releases/download/3.0.0-beta.5/Aagedal-Photo-Agent-3.0.0-beta.5.dmg`,
and the canonical feed is the GitHub `main` `appcast.xml`. Betas are not mirrored to the
aagedal.me backup host (`https://aagedal.me/apps/photoagent/`); it is only updated for
stable releases.
