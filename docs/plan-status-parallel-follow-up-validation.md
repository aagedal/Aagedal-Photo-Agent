# Plan-status parallel follow-up validation — 2026-08-25

## Scope and checklist result

This follow-up reconciled the clean `main` worktree against `TODO.md`, the 3.0 delivery plan, and
the app improvement audit, then implemented independent code-completable items in parallel. Nine
audit substeps moved from open to complete:

1. one-shot migration failures show a retained, privacy-safe recovery notice;
2. bundled binaries/models have a pinned, machine-checked provenance manifest;
3. the FFmpeg corresponding-source offer is generated from that manifest;
4. release preflight rejects missing, mismatched, or drifted required bundled artifacts locally;
5. new delivery profiles prefer verified SFTP and insecure selections have persistent badges;
6. insecure profile saves and first uploads require an exact-state acknowledgement;
7. delivery Activity and receipts record protocol/verification evidence without credentials;
8. Metadata Review failures have persistent severity icons/reasons and equivalent accessibility
   descriptions;
9. face selection, ingest split cells, scope modes, and copyable metadata rows use semantic
   keyboard/VoiceOver-operable controls instead of gesture-only activation.

The real-server FTP/FTPS/SFTP drill remains open.

## Migration recovery notice

`MigrationRecoveryNoticeCenter` retains failures that occur before `ContentView` exists. Keyword Lists and
Known People migrations record only fixed category identifiers, and the launch alert builds its message only
from fixed display names. Paths, filenames, error strings, list contents, identifiers, and person data cannot
enter the notice. A successful retry clears its category.

Focused validation passed 11 tests across the Known People and Keyword List migration suites, including
backup/write failure, retained retry state, fixed-copy privacy, and clearing after recovery.

## Bundled-component provenance

`Aagedal Photo Agent/Resources/bundled-components.json` records versions, artifact SHA-256 values, immutable
upstream revisions, licenses, build-recipe revisions, target architectures, and runtime capabilities for
FFmpeg, c2patool, and AuraFace. The declarations were independently checked against:

- FFmpeg 9.0.1 tag commit `bf1b838f2ab88b4f8fd83443325c782ea0e0f7fa` and the photo-build recipe at
  `00023f51d635ac7ab5b83f5419e57f004254318e`;
- c2patool 0.26.69 release commit `363c3e55b545327fc748905f256a18b82de19815`, its universal macOS release
  workflow, and the official release binary hash;
- AuraFace revision `af6d057c9b0ec4071d4c49c80e3539258798b609`, the `glintr100.onnx` LFS SHA-256,
  and every file in the local CoreML package.

The AuraFace conversion recipe now downloads that immutable revision. Its repository-local recipe content is
itself SHA-256 pinned. `validate_bundled_components.py` rejects missing required artifacts, artifact or recipe
hash drift, version drift, architecture drift, malformed component entries, and missing version expectations.
Three focused validator tests pass, including two negative drift/contract cases. The optional AuraFace
package may be absent in ordinary checkouts; its
declaration remains validated while runtime absence continues to use the existing unavailable behavior.

`generate_bundled_component_docs.py --check` keeps the FFmpeg version, source archive, and build recipe in
the GPL source-offer section of `README.md` synchronized with the manifest.

Release preflight now reruns the manifest validator against the local checkout before any keychain, signing,
notarization, archive, or appcast work. A missing required binary, checksum drift, version drift, architecture
drift, or declaration/recipe error therefore fails before release credentials or artifacts are touched. A
focused negative test covers a missing required artifact.

The deterministic model source-fetch and conversion tooling was completed and validated after this pass.
The later [on-demand packaging validation](auraface-on-demand-packaging-validation.md) adds a reproducible
hostable archive/descriptor contract, binds model and embedding versions, and defines seven explicit runtime
availability states. Production hosting, trust anchoring, app-side download/install/rollback/removal, and
real-server validation remain open. Explicit packaged-unavailable-state disclosure is recorded separately in
[its validation](auraface-packaged-unavailable-validation.md).

## Delivery transport safety and evidence

New profiles start as SFTP on port 22 with host verification enabled. The server editor, Settings list, and
upload selector show a persistent protocol/verification badge; color is supplementary. Every insecure save
requires explicit confirmation. The legacy upload workflow stores a first-use acknowledgement for the exact
security state and invalidates it when protocol or verification changes.

The shared Deadline transport boundary rejects an unacknowledged insecure first upload before local hashing,
credential lookup, or curl launch. Deadline confirmation also shows the exact protocol/verification state and
uses protocol-specific warning copy plus an explicit **Acknowledge Insecure Transport and Send** action.
Acknowledgement is persisted only while the connection UUID and current security state still match; a changed
state keeps confirmation open with a typed error. Legacy upload Activity and staged-delivery receipts/summaries
persist only the protocol kind and whether server verification was enabled. Legacy records decode with absent
evidence.

Focused validation passed 26 tests across FTP connection, Activity, and receipt assembly plus all 10
Delivery FTP transport-boundary tests. The dedicated Deadline acknowledgement follow-up passed 30 tests across
the Deadline execution and FTP transport suites. Receipt repository/library and delivery workflow suites also
passed.

## Metadata Review accessibility

Every validation failure now has a persistent blocker/warning/information symbol and a visible
severity-prefixed reason. The same description is exposed as the field value and failure accessibility label;
border color and hover help are no longer the sole explanation. Four presentation tests cover required,
warning, minimum-length, and valid states. Manual VoiceOver/high-contrast validation remains part of the
broader accessibility release gate.

## Gesture-only accessibility controls

Face selection is now semantically operable in all three relevant surfaces. The SwiftUI face-detail and
assignment grids use labelled Buttons with selected state, keyboard multi-selection guidance, and an
accessible Full Screen action where applicable. The main AppKit face-card grid retains arrow-key navigation
and now exposes each visible face thumbnail as a VoiceOver button whose accessibility press selects that
face. Import split cells, expanded/collapsed scope controls and individual scope modes, and copyable
technical-metadata rows are also Buttons with explicit labels, values, hints, and selected state where
applicable.

The focused accessibility suite passed 14 tests in one suite after the changed views compiled. Coverage
includes a source regression for all four named areas and a runtime check that an AppKit face thumbnail's
accessibility press invokes its selection action. This closes the semantic-control substep only. Manual
VoiceOver rotor/speech/order, Full Keyboard Access focus rings, IME, contrast, motion, localization/window
stress, and external-display Clean Feed remain in the separate OS-level release gate.

## Integrated validation

A fresh isolated arm64 test build succeeded:

```text
xcodebuild build-for-testing -project "Aagedal Photo Agent.xcodeproj" \
  -scheme "Aagedal Photo Agent Tests" -destination "platform=macOS,arch=arm64" \
  -derivedDataPath /private/tmp/aagedal-plan-status-20260825 CODE_SIGNING_ALLOWED=NO
** TEST BUILD SUCCEEDED **
```

After the final Deadline confirmation-path integration, the unfiltered test bundle passed all
**1,450 tests in 160 suites** with zero failures in 38.725 seconds; Xcode's test operation took
41.464 seconds. The result bundle is:

```text
/private/tmp/aagedal-plan-status-20260825/Logs/Test/
Test-Aagedal Photo Agent Tests-2026.08.25_17-22-38-+0200.xcresult
```

After the fail-closed legacy upload guard landed, a refreshed unfiltered run passed **1,452 tests in 161
suites** with zero failures. Its result bundle is:

```text
/private/tmp/aagedal-child-validation-20260825/Logs/Test/
Test-Aagedal Photo Agent Tests-2026.08.25_17-38-48-+0200.xcresult
```

The later semantic-control and packaged-model availability changes received fresh arm64 test builds plus
14 focused accessibility tests and 16 focused face-embedding/activity tests, all passing. They did not receive
another redundant unfiltered run.

`scripts/ci/validate_repository.sh` also passed generated-document drift checks, JSON/plist/project lint,
four focused bundled-provenance tests, six offline pinned-source-fetch tests, all present
artifact/recipe/version/architecture checks, logger privacy validation, conflict-marker scanning, and
`git diff --check`.

Automated evidence does not replace the still-open hardware-tier benchmarks, manual accessibility and
display checks, legal/privacy review, real-server drills, recovery exercises, or signed release packaging.
