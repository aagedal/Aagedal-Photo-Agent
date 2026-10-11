# 3.0.0 Beta 3 public release record

Release identity: **3.0.0-beta.3**, build **742**, minimum macOS **26.0**, **Apple Silicon**.
Application source: `e2933e4159f5f1f1d4a624af298a9cbd34041d4b`.
The numeric bundle short version remains `3.0.0`; `AagedalReleaseVersion`
provides the beta label. The Sparkle item uses the **beta** channel and build 742.

## Changes

Beta 3 includes image-based description drafts, microphone dictation, Apple Foundation
Models on macOS 27, description styles/custom presets and expanded local model discovery;
video still extraction with timecode and 16-bit JPEG XL output; expanded Pixel Analysis;
multiple structured keyword lists/live multilingual IPTC Media Topics; a collapsible
face bar; metadata, voice-memo, face pruning, batch retry and Whisper lifecycle fixes;
and retained-operation discovery plus revision-bound Develop-template inspection/previews.
Deadline Workspace UI is deferred to 3.1. See the changelog for details.

## Verification

- Complete development-signed local suite: **3,947 passed, two existing skips, zero
  failures**, 3,949 total, 134.717 seconds. Results are retained in
  `build/beta3-signed-tests.xcresult`.
- [Required clean CI](https://github.com/aagedal/Aagedal-Photo-Agent/actions/runs/38176588811)
  passes on the exact application source: 3,949 discovered tests across 390 suites.
  CI reproduces the pinned AuraFace model and performs a clean build and unfiltered
  test run. No emergency release-gate override was used.
- Repository validation and app-level AuraFace RGB preprocessing/reference checks pass.
- Apple Silicon Release archive and Developer ID export succeed. Exported and
  mounted-DMG apps pass strict/deep signatures, compiled-model validation, exact
  source/version/build checks and Gatekeeper assessment as **Notarized Developer ID**.
  App and DMG have accepted Apple notarizations and stapled tickets. Final Sparkle
  EdDSA verification passes.
- App notarization: `998c8a5b-8de9-48e6-b88f-9c17d96813e9` — **Accepted**.
- DMG notarization: `f0ec2449-9b5a-46fa-8779-899fbeedc464` — **Accepted**.

Evidence is retained under `build/release-beta3/`, including repository validation,
local/remote test logs, exact-revision gate, archive/export/notarization logs, final
artifact verification, model checks, release notes and checksum.
Broader real-provider/model lifecycle, signed automation, accessibility,
upgrade/downgrade, performance and hardware qualification remains open. This beta
uses the stable app's identity and data locations; backups and disposable photo
copies are recommended. No stable 3.0 acceptance is claimed.

## Artifact

File: `Aagedal-Photo-Agent-3.0.0-beta.3.dmg`  
Size: **205,878,479 bytes**  
SHA-256: `a699ebfca2149aa485e8a5ff128e3d00aadf96e2ce09425b593be29f466dcf17`

## Publication

[Beta 3 is public on GitHub](https://github.com/aagedal/Aagedal-Photo-Agent/releases/tag/3.0.0-beta.3)
with the notarized DMG and `SHA256SUMS.txt`. Its tag resolves to the exact application
source above. GitHub's uploaded asset digest/size and an anonymous complete download
match the verified artifact. GitHub still identifies **2.2.0** as latest stable;
the stable Homebrew cask was not changed.

The canonical GitHub feed was published in main commit `f09dbae`; the separate
Codeberg history was preserved and only its feed updated in `4bf3db6`.
Anonymous downloads of both public feeds match the validated local appcast byte for
byte. The Beta 3 item is on the beta channel, with the verified DMG signature and
size. Stable clients continue to use the default channel.

The separately hosted website fallback at
`https://aagedal.me/apps/appcast/photoagent.xml` still serves **2.2.0**.
No website upload path is configured in this release checkout; fallback
synchronization remains a hosting follow-up. The public release, canonical updater
feed and Codeberg mirror are live.
