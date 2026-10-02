# Cycle 124 — existing Sony folder linking and automatic Import qualification

Baseline: `ef9c05e`, initially clean. Implementation commit: `5de09ee`; frozen hashes match that commit.
State remains **IMPLEMENTING**. No whole readiness gate or camera/firmware matrix closes.
Sub-agents implemented/reviewed the service and tests; the parent wired native controls,
built and tested production sample copies, reconciled documentation and committed changes.

## Reported issue and resulting behavior

The user opened the Sony A1 camera's `DCIM/100MSDCF` JPEG/WAV folder directly. Caption
reported “No associated voice memo” despite three corresponding adjacent pairs. Playback
intentionally resolves persisted relationships only, and direct folder opening had neither
created them nor offered a way to establish the initial link. “Find moved relationship” only
recovers a previously saved relationship. Thus Apple Speech language controls were hidden.
The reported screenshot is manual discovery evidence, not a passing acceptance observation.

Caption now offers **Find matching voice memo…** when no saved relationship exists. Discovery
scans the complete adjacent supported image/WAV inventory using the production Sony camera,
firmware, capture/subsecond/UTC-offset and post-capture WAV evidence rules. Matching names
alone do not authorize association. A native dialog shows the exact photo/WAV pair and explains
the record-only change. **Link Voice Memo** confirms one initial link; Cancel, refresh, photo
selection or leaving Caption discards the preview. Confirmation clears its observed preview
before suspension. Independent review found the initially ignored preview observation and fixed
it; an observation regression covers cancellation.

The filesystem actor captures complete content/inode/time inventory and folder identity,
then rescans and revalidates after acquiring shared folder ownership. The repository creates
schema-2 content identities with no transcript approval. Descriptor-anchored exclusive installation
refuses any occupied relationship name. Revalidation failure quarantines the candidate before
owned-inode/bytes rollback; unrelated replacements are preserved/restored. Neither discovery nor
confirmation modifies the JPEG or WAV. Linking refreshes existing playback/transcription controls.

The user clarified that this layout is exactly what the camera supplies and should support
automatic card Import. That production path already exists: Import scans accepted Sony evidence,
uses verified streaming copies and persists relationships from successful copy receipts.
A new opt-in production sample test proves the actual scanner, ImportCopyService and the same
saveImportedAssociations receipt path used by ImportViewModel. It establishes three automatic
links and verifies all six source and destination hashes. It does not run the complete GUI Import
selection/configuration/backup drill or prove all camera combinations.

## Verification

| Check | Result / evidence |
| --- | --- |
| Focused final service/repository suites | 52 tests / three suites pass, 0.807 seconds; `build/qa-v3-cycle124-focused-final.xcresult` |
| Production Sony initial linking | All three pairs discovered and linked on ignored copies; opt-in test passed, 0.367 seconds, included above |
| Import filesystem suite | Eight tests / one suite pass, 0.121 seconds; real sample scanner/verified copy/three-link persistence passes in 0.101 seconds; `build/qa-v3-cycle124-import.xcresult` |
| Full final regression | 3,797 tests / 370 suites, zero failures/skips, 124.905 seconds; both opt-in Sony sample tests passed; `build/qa-v3-cycle124-full.xcresult` |
| Repository and whitespace | `build/qa-v3-cycle124-repository-final.log` passes; whitespace/source/link/checklist validation passes |
| Native interaction | New controls compile; actual confirmation-alert/playback/download interaction remains a specific manual follow-up. No final acceptance pass claimed. |

Nine new service tests cover read-only discovery and confirmation, inventory/source drift,
competing records, ambiguity/symlinks, observable cancellation, reservation conflict and exclusive
installation races, plus opt-in production qualification. The Import test is separately enabled
with APA_SONY_EXISTING_FOLDER_FIXTURE. Tests never hardcode the user's private path.

The first focused run built the new native control but omitted the new test file from the explicit
Xcode test target; its 43 existing tests are not new-feature evidence. The file was registered,
and final focused evidence includes all nine new tests. Xcode also normalized project entries
and recovered an existing reference into a group; those current contents were preserved. Automatic
approval review rejected reconstructing the project from Git because it could discard unrelated
edits; that replacement was abandoned, and only additive test registration was performed.

Private media copies stay in ignored build/QA storage and are not committed. All six originals
were hashed before and after testing and their exact source inventory remains unchanged.
No original relationship, transcript or metadata record was created. Production audio content was
not transcribed or included in reports. No model download, publication, production authority,
automation schedule or release version/build change occurred.

## Frozen source identity

| File | SHA-256 |
| --- | --- |
| `Aagedal Photo Agent.xcodeproj/project.pbxproj` | `c4e3fbe4d82441741ad6ed80388eea43925de3559eae4bf3fa29132149b79a56` |
| `Aagedal Photo Agent/Services/CaptionVoiceMemoAssociationService.swift` | `a0343931fc9c4472c87d2bfbd9c2e429038908bcf3b17da3ec79fc3f55a84586` |
| `Aagedal Photo Agent/Services/VoiceMemoCompanionRepository.swift` | `bfdc7b559025b0c77fd13fe154870311cef42bbd39ec1b8332bc2d72f32f4431` |
| `Aagedal Photo Agent/Views/Metadata/CaptionVoiceMemoPlayerView.swift` | `638707d6667b06294e3b796c6715a1cb7b649bfdf10c69b0c47d01e79d801d8e` |
| `Aagedal Photo Agent Tests/CaptionVoiceMemoAssociationServiceTests.swift` | `0e454d876f158cb58e4f133f699bf5a8fafd16b2279391dffe52e6b538239279` |
| `Aagedal Photo Agent Tests/ImportFilesystemExecutorTests.swift` | `ccd442e03deee46bf4efdffb8872d0e7b956b98fc3e0603c69bd171b86ea634c` |

## Manual follow-up and remaining release work

Save any current editing work before relaunching the updated Debug build. Open a disposable copy
of the Sony JPEG/WAV folder in Caption. Find the matching memo, cancel once, review again and
confirm Link Voice Memo; check the exact memo filename and explicit playback. Select Apple Speech
in Transcription Settings; the Caption language picker should then offer English (United States)
and Download Language when the asset is absent. Existing installed assets show Transcribe instead.
Repeat a card Import to a separate disposable destination to verify the full native selection flow.
A12 in the manual checklist now records these checks; results remain unrun.

This sample verifies the ILCE-1 v4.00 JPEG/WAV layout only. Real native providers, offline/device/
model lifecycle, broader Sony/card edge cases, signed distribution, remaining executors and wider
external/performance/accessibility/privacy/legal/CI/candidate gates remain as described in the
[release handoff](release-completion-handoff-2026-10-02.md). Final release acceptance is not ready.
