# Cycle 73 — Template byte authority and accessible editor actions

Baseline: `37c8418`, clean at initial inspection. Three sub-agents handled template
storage preservation, snapshot authority, and accessibility/review. The coordinator owns
integration, native verification, documentation and commits.

## Scope

Bind metadata and Develop editor saves/deletion to the exact decoded file bytes and the
identity of their captured directory. Preserve the original editor evidence across list
refreshes and retries. Keep Save as New available for conflict recovery. Prevent
unsupported JSON content from silently disappearing during compatibility writes.
Expose independent Edit/Trash actions and keyboard cancellation in both template lists.

## Implemented

Production inventories decode each admitted file once and retain its exact bytes, canonical
UUID filename, and directory device/inode/creation identity. Existing saves and deletion
require matching authority before any shortcut reassignment or Trash access. Duplicate UUIDs
and mismatched filenames remain visible but confer no mutation authority. Shortcut conflicts
are preflighted together so an ambiguous record cannot cause earlier valid records to change.
Editors keep their original evidence independently of later list refreshes; retry cannot adopt
new bytes. Save as New uses an independent UUID. Import completion carries actual refreshed
inventory evidence on the captured root; derived partial/cancelled inventories carry none.
Storage also refuses an existing target whose decoded UUID differs from the requested UUID.

Metadata extension values at the root and retained field UUIDs survive supported edits,
including field reorder. Removing a field removes its entire record; clearing known optional
members does not restore their old values. Develop root extensions survive, while a lossy
round trip of nested settings refuses the overwrite. Duplicate JSON keys and unknown numeric
extensions refuse rather than risking collapse or precision loss. This is semantic preservation
of supported extension values, not byte-identical reserialization. Save as New copies supported
fields and keeps the original intact; typed bundle export is not an unknown-field archive.

Template lists expose distinct borderless Edit/Trash buttons with names and UUID identifiers.
Editors initially focus Template Name; Escape cancels and Return saves (or retries on failure).
Metadata field controls also gain descriptive accessibility labels.

## Verification

The final focused run passes **62 tests / six suites** in 2.955 seconds. After the final
uppercase-extension regression, the complete integrated run passes **3,055 tests / 323 suites**
in 122.692 seconds, with zero failures or skips confirmed by the result bundle. Repository
validation and whitespace checks pass. Twelve Thread Performance Checker entries and existing
`MDB_MAP_FULL` test-host diagnostics remain observations, not resolved issues.
Independent final review found no remaining actionable defect in this batch. No broad release
gate is closed.

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 1 \
  -resultBundlePath build/qa-v3-cycle73-full.xcresult
scripts/ci/validate_repository.sh
git diff --check
```

The focused command additionally selects TemplateFileAuthorityTests,
TemplateJSONPreservationTests, TemplateDeletionConflictTests, DevelopTemplateTests,
MetadataTemplatePersistenceTests and DevelopTemplateSchemaTests.


The first focused run executed 61 tests and reported five issues: four mismatch-guard
assertions compiled after the app object had already been built, plus an older recovery test
that recreated the storage directory. The final source is being rebuilt after review edits.
The recovery test now restores the same renamed-aside directory and original bytes, preserving
its transient-failure/retry contract; separate tests require refusal for a replaced directory.
No assertion or timeout was weakened to allow stale replacement.

Commands use the Debug test schemes, macOS destination, disabled parallel testing and one
build job. Evidence is under `build/qa-v3-cycle73-*`. Host: arm64 macOS 27.0 (26A428).


Independent review caught and corrected omitted production authority, ambiguous shortcut
mutations, import evidence propagation and filename/decoded-UUID mismatch. Regression tests
cover those behaviors, byte-only peer changes, same-path directory replacement, retained
editor evidence across reload/retry, Save as New and exact-byte refusal of unsafe JSON.

Unrelated project-file comment/order normalization appeared during this session.
It is semantically unchanged and is being preserved separately from the new test registrations.


## Native verification

`CoreWorkflowSmokeTests.testTemplateEditorActionsAndByteConflictRecovery` passes on the
final built Debug 3.0.0 build 739 in 37.375 seconds. App path:
`/Users/truls.aagedal/Library/Developer/Xcode/DerivedData/Aagedal_Photo_Agent-hlgfpmukfpendwestygmmhxmllgk/Build/Products/Debug/Aagedal Photo Agent.app`.

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent UI Smoke Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 1 \
  -only-testing:'Aagedal Photo Agent UI Smoke Tests/CoreWorkflowSmokeTests/testTemplateEditorActionsAndByteConflictRecovery' \
  -resultBundlePath build/qa-v3-cycle73-ui-v2.xcresult
```

The test creates temporary metadata/Develop templates and a synthetic photo, routes the
app and Settings through the existing opt-in test root, and opens Settings → Templates.
For each template kind it observes distinct Edit/Trash accessibility buttons and their
contextual labels, activates Edit, types into the initial name responder without refocusing,
and presses Escape. Both original files remain byte-identical.

It then opens a new draft, changes the fixture file by appending whitespace without changing
its decoded values, and presses Return. Save refuses, exposes Retry Save and retains the exact
draft name. Save as New creates exactly one independent UUID with the recovered name while
preserving the peer bytes. The test checks the actual JSON files after each operation.

The initial native run passed metadata refusal/recovery but used a wrong fixed document-count
expectation: the existing launch seam also seeds a voice-memo template. The corrected test
captures its starting inventory and requires exactly one additional recovery copy. No product
code changed for this test correction. Native result/log: `build/qa-v3-cycle73-ui-v2.*`.
Temporary fixtures are removed by test teardown. CUA inventory afterward confirms every Photo
Agent app entry stopped. No user template folder or automation authorization was changed.
Spoken VoiceOver, full Tab traversal, relaunch persistence and provider races were not exercised
by this narrow test; the complete UI target and broader acceptance gates remain separate.

## Remaining boundaries

Template import-preview conflict authority, noncooperating external writers, stable-UUID
MCP template discovery/application, remaining production operation tools and FFmpeg Whisper
remain separate work. Full VoiceOver and keyboard accessibility, authentic source/server/
cloud/device evidence, legal review, remote CI enforcement and final candidate packaging
remain open. Publication is not authorized by this development cycle.
