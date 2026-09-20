# Cycle 85 — move Whisper configuration out of Caption

Baseline `a46d1b6`, initially clean. Implementation committed as `1cdc45b`. Implements the requested product correction: custom Whisper
configuration belongs in Settings, while Caption stays focused on the photo and transcript.

## Behavior

- Settings → Transcription owns provider choice, custom executable/model selection, language,
  English translation, GPU request, execution consent, identity admission and clearing saved files.
- Caption has a compact Transcribe action and a direct Transcription Settings shortcut. Custom
  configuration controls are absent; retained inference evidence sits in a collapsed disclosure.
- Settings and Caption share one app-session setup model. Closing Settings, changing photos or
  reopening Caption does not discard readiness. Quitting the app resets consent and admitted
  identities; retained bookmarks/options still require fresh consent and admission on relaunch.
- Active transcription disables configuration changes across windows. A model-level check also
  refuses a file picker opened before a job began, preserving the admitted files and consent.
- Existing Apple Speech language controls remain unchanged; this correction moves the custom
  Whisper configuration and shared provider choice requested by the user.

## Validation

Evidence files use `build/qa-v3-transcription-settings-*`. Xcode commands use Debug,
`-destination 'platform=macOS' -parallel-testing-enabled NO -jobs 2` and project
`Aagedal Photo Agent.xcodeproj`. Native fixtures use isolated preferences and disposable photos,
WAVs, sidecars and custom files; fixture executables are not run for inference.

Initial focused setup validation passes 13 tests. The complete regression passes
**3,210 tests / 336 suites**, zero failures, in **129.715 seconds** (`full.{log,xcresult}`),
including the file-picker race regression. `scripts/ci/validate_repository.sh` and whitespace checks
pass (`repository-final.log`).
Independent review identified the already-open file-picker race; the guard and a regression test
were added before final validation. The first native run passed file-picker cancellation but
exposed grouped Form toggles using a different accessibility role from the existing checkbox
controls. Explicit checkbox styling fixes the mismatch; reruns retain the assertions.
The second native run reached enabled Caption transcription after Settings closure, then lost its
UI-testing connection on relaunch; subsequent cases reported AX authorization failures. This
interrupted run is not counted as passing workflow evidence.

The fresh native session passes **three workflows**, zero failures, in **165.169 seconds**
(`native-final.{log,xcresult}`): retained bookmarks/consent/clearing (90.276 s), option persistence
(34.017 s), and file-picker cancellation/preserved review (40.876 s). These assert setup controls
are absent from Caption, its shortcut opens Transcription Settings, and closing Settings preserves
ready transcription without executing fixture software. Relaunch resets consent and preserves
options/bookmarks; photo, WAV, relationship and sidecar bytes remain unchanged.

After the full suite, MCP provider guidance was updated to point to Settings → Transcription.
Final focused validation passes **68 tests / two suites** in **1.460 seconds**
(`focused-final.{log,xcresult}`), covering FFmpegWhisperSetupModelTests and MCPServerCoreTests.
The actual embedded-helper probe passes and verifies both provider setup instructions point to
Settings → Transcription (`helper.{json,log}`). Helper SHA-256:
`6dfc5a5dbd7e894581dfcabc7ddfcd8ae28b7d6ad1291a2fddf922a2ebe1e568`.
These final checks use the implementation committed as `1cdc45b`. The host and app remain the
arm64 macOS 27.0 / Xcode 27.0 environment and Debug app path recorded in cycle 84 (3.0.0, build 739).

The production executor, verified IPTC commit, trusted Whisper artifact/model delivery and broader
release acceptance gates from cycle 84 remain open. This is a UI organization and session-lifetime
correction, not a distribution release.
