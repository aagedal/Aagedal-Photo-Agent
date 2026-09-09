# Local voice-memo transcription integration design

Date: 2026-09-09. Status: **proposed implementation; no transcription gate is satisfied**.
This read-only investigation inspected application source, the installed Xcode Speech
framework interface, and Apple documentation. It did not run recognition, install models,
request permissions, inspect private audio, or establish accuracy/offline/device evidence.

## Recommended production path

Use the system `SpeechAnalyzer` with `SpeechTranscriber` for explicitly requested WAV
transcription. The app already targets macOS 26.0; these APIs are available from macOS
26.0 in the installed SDK. They add no package dependency or app-hosted speech model.
Check runtime availability and selected-language support before offering transcription;
unsupported systems retain playback and explain why transcription is unavailable.
Apple documents device support through `isAvailable` and language support through
`supportedLocales`/`supportedLocale(equivalentTo:)`.
([SpeechTranscriber](https://developer.apple.com/documentation/speech/speechtranscriber))

This is an integration proposal, not an assertion that Speech is already in the app.
Current source uses `AVAudioPlayer(contentsOf:)` for playback and
`VoiceMemoCompanionRepository.lookup(for:)` for persisted associations, with
`CaptionVoiceMemoPlaybackService` retaining its player and security access on a Dispatch
executor. No `Speech` import, recognizer, speech package, or transcript implementation was
found. The only package references are SwiftMediaMetadata and Sparkle. The existing
`AuraFaceComponentInstaller` and `Resources/Models/README.md` describe a specific signed
face-model installer, not a general speech installer. Keep its component contract separate.

## Exact current SDK contract

The inspected interface is
`/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks/Speech.framework/Versions/A/Modules/Speech.swiftmodule/arm64e-apple-macos.swiftinterface`.
Its header identifies Swift 6.3.2 and target macOS 26.5. All APIs below carry macOS 26.0
availability. Confirm against the selected build SDK during implementation.

1. Read `SpeechTranscriber.isAvailable`; resolve the explicitly selected language using
   `await SpeechTranscriber.supportedLocale(equivalentTo:)`. Populate the picker from
   supported locales, distinguishing `await SpeechTranscriber.installedLocales`.
2. Construct `SpeechTranscriber(locale:preset: .transcription)` and query
   `await AssetInventory.status(forModules: [transcriber])`. Status cases are
   `.unsupported`, `.supported`, `.downloading`, and `.installed`.
3. Offer a distinct **Download language** action for missing assets. After that action,
   reserve the locale using `try await AssetInventory.reserve(locale:)` and obtain
   `try await AssetInventory.assetInstallationRequest(supporting: [transcriber])`.
   The optional request exposes `progress` and `downloadAndInstall() async throws`.
   Recheck status after completion; do not interpret a nil request as independently
   verified installation. Track reservations and the system's `maximumReservedLocales`;
   release a user-removed reservation with `release(reservedLocale:)`.
4. Open the associated file using `AVAudioFile(forReading:)` on the retained file worker.
   Create `SpeechAnalyzer(modules: [transcriber])`. Consume `transcriber.results`
   concurrently with `try await analyzer.analyzeSequence(from: audioFile)`. When that
   returns a last sample, call `finalizeAndFinish(through:)` and await completion of
   result consumption. A nil last sample needs `cancelAndFinishNow()` and an explicit
   empty/no-audio outcome. Do not await result completion before feeding/finalizing.
5. Convert each result's `AttributedString` with `String(result.text.characters)`;
   retain range/timing separately if needed. Start with final-only `.transcription`
   output. Do not append repeated volatile hypotheses as final text.
6. Cancellation owns and cancels both the result consumer and analyzer operation,
   invokes `await analyzer.cancelAndFinishNow()`, and drains teardown before releasing
   the audio file and folder access. Cancellation/selection guards also run after final
   validation, before publishing or saving. A request cancelled during installation
   must not automatically proceed to transcription when installation eventually ends.

Apple's file example establishes the concurrent result-consumer, analyze, and finalize
sequence. Some WWDC25 sample names are now obsolete: the inspected SDK has
`.transcription`, not `.offlineTranscription`, and `reserve`/`release`, not
`allocatedLocales`/`deallocate`. Do not copy the historical snippet verbatim.
([Apple SpeechAnalyzer session](https://developer.apple.com/videos/play/wwdc2025/277/))

## Privacy, availability, and offline behavior

SpeechAnalyzer modules do not send voice audio to Apple's servers. Apple's speech
recognition authorization procedure applies to `SFSpeechRecognizer`; do not add that
network-capable API as an invisible fallback or request its permission for this path.
This feature reads an existing WAV and does not capture microphone audio. Keep microphone
capture out of scope; verify the signed app's actual first-use behavior before claiming
permission testing passed.
([Apple permission guidance](https://developer.apple.com/documentation/speech/asking-permission-to-use-speech-recognition))

Apple manages speech assets, downloads them from its servers, shares them across apps,
and updates them automatically. Show **Apple on-device speech**, the selected language,
and installed/download-required/downloading/unavailable state. Missing assets while offline
must produce an actionable unavailable state, not empty text or a server transcription
fallback. Asset downloads are explicit actions; browsing photos never installs a language.
Reservations are limited, and releasing one is not a promise to remove a shared system
model. These are separate UI semantics from the app's AuraFace component removal.
([AssetInventory](https://developer.apple.com/documentation/speech/assetinventory))

Do not claim a pinned speech-model version, hash, model size, language list, Apple
Intelligence requirement, or blanket hardware support. The inspected public API does not
expose a reproducible model build identifier. Record provider/API identity, language,
transcription settings, macOS version/build, app version, and generation timestamp; label
the underlying model **system managed; exact version unavailable**. Runtime checks and
real supported-hardware/locale testing remain required.

## State, provenance, and durable review

Add `VoiceMemoTranscriptionService.swift` with an injectable local recognition session,
file preparation/revalidation, and asset inventory boundary. Add
`CaptionVoiceMemoTranscriptModel.swift` to own current request, cancellation, and review
state. Extend the existing Caption voice-memo panel with language, model availability,
explicit Transcribe/Cancel, and a separate review editor. Navigation/refresh/disappearance
invalidate the request before enqueueing cleanup, following the corrected playback model.

Suggested states: unavailable(reason), needsLanguageDownload, downloading(progress),
ready, transcribing, draft, reviewed, sourceChanged, cancelled, and failed(reason).
Generated text is always a draft. Persist original generated text separately from reviewed
text and approval time; editing approved text revokes approval until explicitly reviewed
again. A failed/cancelled replacement transcription must not erase a prior approved record.
No result, partial text, or approval action writes an IPTC field by itself.

Persist the transcript as a versioned, app-owned `voiceMemoTranscript` extension in the
existing `.photo_metadata/<full-image-filename>.meta.json`, outside `metadata` and
`imageMetadataSnapshot`. This avoids another independently moved companion. Implement its
codec and read/patch operation through `MetadataSidecarService`'s existing serialized
per-photo transaction ownership and Dispatch actor, not an independent file writer.
`preservingUnknownFields` already retains unknown top-level same-schema extensions, and
relocation's `updatingSourceFile` preserves other JSON. Keep the extension outside
`MetadataSidecar.persistedJSONFieldNames` unless every save path explicitly carries its
value; adding an optional known field with default nil can otherwise erase it during
unrelated saves. Newer nested transcript schemas must remain untouched/read-only.
The proposal requires tests of every save/clear/history/move path before this storage
choice is considered durable; current unknown-field support alone does not prove that.

Bind the transcript to the memo's exact content hash and byte count, plus the validated
association/profile and original filename hints. `SourceImageRevision.capture(at:)`
already streams SHA-256 on a retained executor, rejects changes during capture, and allows
nil pixel metadata; it can supply WAV identity without decoding the WAV as an image.
The cheaper playback revision tuple is insufficient for persisted transcript provenance.
Revalidate the current relationship and memo digest before approval and variable use.
Image metadata edits alone must not invalidate an otherwise identical memo transcript.
Image URL changes invalidate the active request; relocations can retain approval only
when the current persisted association still resolves to those exact WAV bytes. A path,
inode, or reused filename alone never approves a different memo.

## Template and apply contract

Add `{voiceMemoTranscript}` to `PresetVariableInterpolator.resolve` via an immutable
optional approved-transcript context, not by pretending the transcript is an IPTC field.
Propagate that context through recursive `{field:...}` resolution. Only reviewed text for
the exact current memo can resolve the variable. Insert it literally; transcript text
containing `{date}`, `{field:description}`, or another token is not executable template
syntax and must never be recursively expanded.

`TemplateViewModel.resolveTemplate`, `MetadataViewModel.variablePattern`, the single and
batch variable-processing paths, and `VariableReferenceView` all require integration.
Load/revalidate per-image transcript contexts asynchronously before the pure interpolator.
An unapproved/missing/stale transcript is an explicit unresolved dependency: leave the
destination field unchanged and surface the reason. Do not erase existing text or persist
an unresolved token through `applyTemplateFieldsAndProcessVariables`'s existing batch
pre-save. Template preview must identify affected images before any mutation.

Permit free-text destination fields (initially Description and Extended Description), with
explicit Append/Replace preview preserving existing text by default. Route the confirmed
operation through the current Caption flush/transition barrier and normal
`MetadataViewModel` save/history/verification boundary. Do not reuse the template pipeline
for constrained code/date/identifier fields without validating its result. Raw audio and
generated/edited/approved transcript provenance remain distinguishable from the final
human-approved field content. Applying a transcript does not set an AI-generated-image
source type. Delivery's audio-companion policy is a separate open requirement.

## Required tests and remaining evidence

Inject asset status/install, recognizer session/result stream/finalization/cancel,
revision capture, clock, and transcript storage; no test suite should download a language
or depend on the developer's installed assets. Cover unsupported locale/device, offline
missing assets, cancelled install, empty WAV/no speech, malformed audio, consumer failure,
finalization failure, long-file cancellation, stale navigation, reassociation and source
replacement, approval revocation, and a cancelled draft preserving an approved record.

Add persistence regressions for ordinary metadata saves, history clear/restore, exact
review revision, newer nested schema preservation, interrupted writes, copy/rename/move/
reject/archive/restore, and RAW/JPEG companions sharing audio. Add variable tests for
unapproved/stale/missing records, per-image batch identity, literal braces in spoken text,
recursive field references, partial batch failure, Append/Replace, and no metadata mutation
before explicit application. Use existing `CaptionWorkspaceSpeedToolsTests.swift`,
`PresetVariableInterpolatorTests.swift`, and `MetadataSidecarServiceTests.swift` where
appropriate; register any new files according to the existing Xcode target setup.

Native evidence still required: supported Mac/locale first use; explicit language download
and failure/retry; installed-model recognition with networking disabled; no unexpected
authorization prompts; real Sony WAV accuracy including names/numbers; cancellation during
long transcription and navigation; stale source rejection; persisted review after relaunch;
and template application followed by normal metadata readback. The journalistic plan's
transcription, variables, sidecar-durability, and end-to-end gates remain unchecked.
