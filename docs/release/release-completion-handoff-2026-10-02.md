# What is still needed to finish 3.0

**Reviewed:** 2026-10-02, source baseline `86ac666`; continued in [cycle 123](cycle-123-native-helper-transcription-start-2026-10-02.md). This is a planning
handoff, not a readiness decision or a record of completed manual tests. The four
owning plans and the [coordinator protocol](coordinator.md) remain authoritative.

Implementation can continue without a new decision from the user. Final acceptance
testing is not ready: production automation executors, model lifecycle integration
and broader release qualification remain unfinished. Preparing the resources below
now can prevent a wait when those workflows reach verification.

## Work the agent owns

1. Qualify the implemented guarded helper transcription start using exact one-use native
   consent, rooted reservations and durable operation history with actual native providers. The
   signed Debug workflow now passes with synthetic recognition; complete face scans, metadata-template
   and Develop-template batches, physical two-phase IPTC commits and accurate status/
   cancellation. Complete remaining GUI/MCP coordination and live provider discovery.
2. Finish curated Whisper signed descriptor/catalog/Settings integration, verified
   model lifecycle and the supported audio-format expansion. Qualify actual Apple
   Speech and embedded Whisper inference, offline behavior, timing, quality, GPU,
   cancellation and source-drift refusal. Record complete reproducible FFmpeg
   component/source packaging and update-size evidence.
3. Audit remaining blocking file work and retained-write ownership; define concrete
   supported hardware tiers and measurable memory/latency budgets, then measure
   representative RAW/HDR, Compare, Develop, analysis, navigation and delivery work.
4. Run remaining actual-app persistence/failure/recovery, map/style/offline/report,
   permission, interoperability and delivery cases with the available test resources.
   Existing narrow native passes count only for the paths they observed.
5. Reconcile every unconditional plan requirement with evidence; perform independent
   review and candidate-specific regression/package verification. Freeze and launch
   the exact candidate, identify its checksum and known issues, and prepare the
   [HTML checklist](manual-testing-checklist.html) before requesting final acceptance.

The agent can run the computer-use lane (A01–A26), automated tests, profiling and
many external cases after their prerequisites are provided. “Manual” in a plan does
not automatically mean the user must perform every step.

## Resources or decisions the user can prepare

| Resource / owner action | Why it is needed | Checklist |
| --- | --- | --- |
| Confirm the existing authorized ILCE-1 v4.00 private sample is accessible for current workflow tests; supply more body/firmware and duplicate/orphan/card cases only for additional claimed combinations. Keep private originals outside Git. Also supply authorized decodable HEIC/HEIF and camera RAW fixtures if they are not already available. | Prove actual camera association/lifecycle, metadata preservation, transcription and image-plus-WAV delivery. Existing real-sample association evidence does not establish the full current workflow. | A12, E01, E08 |
| Confirm Bridge and Photo Mechanic launch/activation. Use disposable outputs and authorize fixture redistribution before committing third-party examples. | Run IPTC tests and dated editor round trips, including Original Filename. The agent can operate the installed apps when activation permits. | E01 |
| Designate disposable FTP, explicit FTPS and SFTP test destinations. Enter credentials through the app’s Keychain UI, rather than in chat. | Real delivery, certificate/host-key failure, disconnect and retry evidence. A saved production profile is not permission to use it. | E02 |
| Designate a disposable removable disk, read-only target, actual evicted iCloud test image and isolated sync data. Provide access to a second Mac if needed for the claimed multi-Mac sync behavior. | Real permission/revocation, disconnect, cloud offline/recovery and reconciliation drills. The agent can create bounded local disk images for capacity cases. | E04; Known People lifecycle |
| Identify target Mac/macOS tiers and provide the hardware unavailable locally; connect the intended HDR/SDR external displays. The agent can propose budgets and measure available devices. | Supported performance, GPU and Clean Feed disconnect/reconnect claims require actual hardware evidence. | E05, E06 |
| Provide an isolated profile/data clone. The agent should first recover and verify the existing 2.1.0 download and public appcast releases; help locating older signed artifacts is needed only if that fails. | Actual older-binary downgrade behavior cannot be inferred from current code or Git tags. The required binaries are 2.0.0, 2.1.0 and 2.2.0. | E03 |
| Assign a qualified privacy/legal reviewer for biometric data, optional cloud sync, deletion/export and component/license/source obligations. | The agent can prepare a concrete review packet and inspect runtime behavior, but cannot supply qualified legal sign-off. | E07; audit §2.2 |
| Have an authorized repository owner enforce the CI workflow on the protected release branch after reviewing the exact required check. | Local passing tests do not establish remote branch protection. Remote configuration requires separate authorization under the coordinator protocol. | audit §1.1 |

Resources should be provisioned as disposable test inputs. Activation, cloud eviction,
physical connections and access to additional devices may need the user; subsequent
tests should be run by the agent where feasible and recorded with exact identities.

**Observed provider prerequisite:** The actual baseline Debug app reached the native
English Apple Speech drill on 2026-10-02, but the test skipped because the `en_US`
on-device speech asset is not installed (`build/qa-v3-cycle123-apple-native.xcresult`,
one test, one skip, zero failures, 22.289 seconds). This is an open verification gate,
not a pass. With Apple Speech selected in Settings → Transcription, Caption provides
the language selector and explicit Download Language action for a photo with an
associated voice memo. Install the test language explicitly before repeating real
Apple inference; no download occurred during this drill. Broader offline/locale and
native helper execution evidence remains separate.

## Actual human testing and release approval

The agent should notify the user when a specific prerequisite first blocks an otherwise
testable workflow, naming the smallest action needed. This differs from declaring the
whole release ready for acceptance.

Once unconditional readiness gates pass, the user receives the exact candidate and
checklist for first-use Deadline, a 100-image keyboard session, spoken VoiceOver/Full
Keyboard Access, window/localization/contrast/motion behavior, photographer review
of color/edits/analysis, and a complete card-to-caption-to-delivery rehearsal
(U01–U06). Existing accessibility tree/UI automation does not establish spoken
VoiceOver usability or the user’s product acceptance.

Publication remains a later explicit release-owner action: version/build changes,
distribution signing/notarization, Sparkle/appcast and Homebrew steps follow acceptance
and their required authorization (E09).

## Current availability and stale notes

A read-only check on 2026-10-02 found Bridge 2026 **16.0.8**, Photo Mechanic
**2026.2 build 9034**, and Xcode **27.0** at their installed paths. Launch/activation
and interoperability were not checked. `codex`, `claude`, `opencode`, `xcrun` and
`ffmpeg` are available on PATH; this does not prove the required client/version matrix
or actual provider readiness. Only the Recovery volume was listed besides Macintosh
HD; it is not a disposable test target. A filename inventory found
`/Users/truls.aagedal/Downloads/Aagedal-Photo-Agent-2.1.0.dmg`; its content and signature
have not been verified. The repository appcast names public 2.0.0, 2.1.0 and 2.2.0
download URLs; their present availability has not been checked. Recovering these is
agent work before asking the user to supply missing installers. Credentials, external
endpoints and iCloud contents were not inspected.

The project now contains the **Aagedal Photo Agent UI Smoke Tests** target and shared
scheme, with actual native workflow and signed-helper qualification evidence in
cycles 122–123. The August “no UI-test target” observation is superseded. These tests do
not constitute complete accessibility coverage or actual provider inference evidence.

[Existing Sony evidence](../sony-alpha-voice-memo-companion-validation.md) records a
user-supplied private ILCE-1 v4.00 two-card sample with three RAW/JPEG/WAV exposures
and passing production association parsing. Its current private location was not
inspected. Request access to that existing sample before asking for replacement media;
additional body/firmware claims require additional evidence. Old unimplemented-feature
bullets in that August record are historical and superseded by current cycle evidence.

The [August prerequisite audit](../manual-release-prerequisite-audit.md) is historical;
its app/toolchain versions and missing-resource statements must not be treated as
permanent blockers. The September [gate inventory](gate-inventory.md) predates most
mandatory MCP work; current plan criteria and cycle evidence take precedence.

The 2026-09-15 decision bundles AuraFace. Its old on-demand production-server gate
is explicitly deferred for this release, despite an unchecked historical plan item.
Unapproved conditional forensic/AI-origin analyzers and llama.cpp/GGUF (3.1) also do
not become mandatory 3.0 work. Existing implemented model/template/transcription
primitives must be assessed against their complete acceptance criteria rather than
rebuilt because an older action note still describes them as missing.
