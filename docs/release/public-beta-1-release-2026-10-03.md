# 3.0.0 Beta 1 public release record

Release identity: **3.0.0-beta.1**, build **740**, minimum macOS **26.0**.
Application source: `9e2527d55c375a3ec73d2f77cb005f46787474dc`.
The bundle short version remains numeric `3.0.0`; `AagedalReleaseVersion`
provides the beta label. Sparkle orders updates by build and the beta item uses
`<sparkle:channel>beta</sparkle:channel>`. Beta builds opt into that channel and
remain eligible for the eventual stable release, which must have a higher build.
The stable Homebrew cask and GitHub latest release are unchanged.

## Verification

- Complete development-signed local suite: **3,812 tests / 373 suites**, zero
  failures, 122.382 seconds. Two obsolete assertions from the merged transcription
  simplification were corrected; physical metadata non-mutation and malformed
  current relationship authority remain checked.
- Repository validation, **21** release-metadata tests, release test-gate harness,
  and independent source/package review pass.
- Release build and universal archive/export succeed. Final app and mounted DMG
  app pass strict/deep signature verification, compiled-model verification and
  Gatekeeper assessment. App and DMG receive fresh accepted Apple notarizations
  and stapled tickets. Final DMG Sparkle signature verification passes.
- Native smoke: launched the exact exported app, confirmed its executable path,
  observed the Browser workspace and **Version 3.0.0-beta.1** in Settings →
  Licenses. No photos were opened or application preferences changed. This narrow
  smoke does not close the broader qualification gaps in the release handoff.

No remote CI success is claimed. The remote repository had no active workflow;
exact-revision gate lookup failed. The release owner explicitly authorized the
README's documented emergency override for the exact application source above.
The accepted override and its reason are retained in
`build/release/release-test-gate.json` and `release-test-gate-audit.jsonl`.

## Packaging adjustment

The existing project membership exception excludes the developer AuraFace
`.mlpackage`, while the release policy requires the compiled model. The first
Release bundle therefore correctly failed model verification. The pinned package
was hash-verified, compiled into staging with **Xcode 27.0 (27A266a)**, and only
`AuraFaceR100.mlmodelc` was copied into the Developer ID exported app. The app was
re-signed with the same identity, preserving entitlements, identifier, requirements,
flags and runtime metadata. Before/after entitlements match; source revision,
version/build, reviewed model weights and strict/deep signatures were rechecked
before fresh notarization. Application source is unchanged; signing changes the
resource seal and executable signature bytes.

The explicit packaging commands were:

```sh
xcrun coremlcompiler compile \
  'Aagedal Photo Agent/Resources/Models/AuraFaceR100.mlpackage' \
  build/release/model-staging
ditto build/release/model-staging/AuraFaceR100.mlmodelc \
  'build/release/export/Aagedal Photo Agent.app/Contents/Resources/AuraFaceR100.mlmodelc'
codesign --force --sign 'Developer ID Application: Truls Aagedal (3R5QGG9DW6)' \
  --timestamp --preserve-metadata=identifier,entitlements,requirements,flags,runtime \
  'build/release/export/Aagedal Photo Agent.app'
```

`RELEASE_BUILD_MODE=reuse` then resumed the assistant with the verified exported
app. The model compilation/signature hashes are retained in
`build/release/model-packaging-audit.json`; final model verification is in
`model-bundle.json` and `dmg-model-bundle.json`. The assistant also required an empty
`build/release/export` directory before its first artifact search. Tooling should
incorporate these two reproducibility fixes before the next release.

## Final artifact

File: `Aagedal-Photo-Agent-3.0.0-beta.1.dmg`  
Size: **192,826,714 bytes**  
SHA-256: `cde305353ff3fc6381153452253d0977a004b80e70fd347c28262ef32f1f2b37`

Release notes disclose shared application/data identity, backup guidance,
upgrade/downgrade risks and unfinished provider, automation, model lifecycle,
performance, accessibility and external qualification. This beta is not a stable
3.0 acceptance decision; owning plans and the prior release handoff remain open.

## Publication

[3.0.0 Beta 1 is public on GitHub](https://github.com/aagedal/Aagedal-Photo-Agent/releases/tag/3.0.0-beta.1).
Its tag resolves to the exact application source above and its published assets are
marked uploaded. An anonymous complete download matches the final DMG SHA-256 and
byte count. GitHub still identifies **2.2.0** as the latest stable release.

The canonical GitHub appcast is published in commit `335152c`. The separate
Codeberg history is preserved; only its appcast is updated in commit `c0fd044`.
Anonymous downloads of both public appcasts match the validated local feed byte
for byte. Stable clients receive the default channel; beta installations also
receive the beta channel.

The separately hosted website fallback appcast still serves the prior feed. There
is no configured upload path in this release environment. The public GitHub
release, canonical updater feed and Codeberg mirror are live; website fallback
synchronization remains a separate upload follow-up.
