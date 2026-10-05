# 3.0.0 Beta 2 public release record

Release identity: **3.0.0-beta.2**, build **741**, minimum macOS **26.0**.
Application source: `1e1ad5d351babc67db23360c6173b0b9bf7140c8`.
The numeric bundle short version remains `3.0.0`; `AagedalReleaseVersion`
provides the beta label. The Sparkle item uses the **beta** channel and build 741.
The stable Homebrew cask and GitHub latest stable release remain unchanged.

## Changes

Beta 2 includes the merged local Description Assistant, batch transcription language
selection, multilingual Whisper Turbo/Large v3 downloads, simplified batch consent,
clearer Activity cancellation/layout, nested-folder disclosure fixes, media-key
support and bundled-model/runtime/recovery improvements. The Description Assistant
was recovered from merged PR #5. Stable 3.0 qualification remains open.

## Verification

- Full local development-signed suite: **3,832 passed, two existing skips, zero
  failures**, 3,834 total. Physical Metal decoder evaluation and signed-helper
  team/runtime checks pass.
- [Required clean CI](https://github.com/aagedal/Aagedal-Photo-Agent/actions/runs/37236013761)
  passes on the exact application source. All 3,834 tests are discovered; three
  explicit skips include the physical-GPU decoder on the virtual runner. CI also
  reproduces and verifies the pinned AuraFace model from its immutable source.
  No emergency release-gate override was used.
- The CI ad-hoc test host omits restricted iCloud entitlements. Recognition tests
  separately check background execution and serial filesystem access. Ad-hoc
  helper launch/protocol/signature checks remain active; Apple-signed builds retain
  team and hardened-runtime assertions. CI does not qualify iCloud or distribution
  signing. Initial failed CI runs and corrections are recorded in the final checks.
- Universal Release archive and Developer ID export succeed. Exported app and
  mounted-DMG app pass strict/deep signatures, compiled-model validation, and
  exact source/build checks. Gatekeeper accepts the mounted app as **Notarized
  Developer ID**. Both app and DMG have accepted Apple notarizations and stapled
  tickets. Final Sparkle EdDSA verification passes.
- App notarization: `3a199bd7-7c7b-41eb-ba55-11d285a00240` — **Accepted**.
- DMG notarization: `7c19cd80-b538-4d6a-a6e9-469aab62746c` — **Accepted**.

Evidence is retained under `build/release-beta2/`, including exact-revision gate,
archive/export/notarization logs, model checks, release notes and checksum. The
complete final local suite is in `build/beta2-final-signed-tests.xcresult`.
Broader native UI, actual provider/model lifecycle, description inference,
accessibility, hardware/performance, upgrade/downgrade and interoperability gaps
remain listed in the release limitations. No stable acceptance is claimed.

## Artifact

File: `Aagedal-Photo-Agent-3.0.0-beta.2.dmg`  
Size: **205,253,666 bytes**  
SHA-256: `54f3d574a8cf042ec67c57e328cf17f3a365ec61e522d568683bb397defd6a3e`

## Publication

[Beta 2 is public on GitHub](https://github.com/aagedal/Aagedal-Photo-Agent/releases/tag/3.0.0-beta.2)
with the notarized DMG and `SHA256SUMS.txt`. Its tag resolves to the exact application
source above. GitHub's uploaded asset digest/size and an anonymous complete download
match the verified artifact. GitHub still identifies **2.2.0** as latest stable.
A transient DNS failure interrupted the first asset upload; its retained draft was
safely resumed and published after digest verification.

The canonical GitHub feed was published in main commit `5583a0a`; the separate
Codeberg history was preserved and its feed updated in `74cbdc5`. Anonymous public
downloads of both feeds match the validated local appcast byte for byte. Generated
Beta 2 note continuations were joined and Markdown emphasis converted to HTML
before publishing; enclosure bytes/signature are unchanged.

The separately hosted website fallback still serves **2.2.0**. No website upload
path is configured in this release environment; synchronization remains a hosting
follow-up. The public release, canonical updater feed and Codeberg mirror are live.
