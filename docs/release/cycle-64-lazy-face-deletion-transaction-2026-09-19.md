# Cycle 64 — Transactional lazy face deletion

State: IMPLEMENTING. Baseline `e097ade`; checkout initially clean. This report describes
working-tree changes on that baseline.

## Implementation

Photo-based face deletion when no face document is loaded now runs its read/edit/write
sequence on the serialized filesystem actor under one exclusive folder reservation.
The reservation covers document loading/recovery, thumbnail reads, group repair, document
commit and orphan-thumbnail cleanup. There is no longer an unreserved interval between
fallback loading and a separately queued save.

The operation removes only the selected photos' faces, updates group membership and
representatives (including legacy records with missing face-side group IDs), and retains
other faces and thumbnail bytes. A document whose stored folder differs from the reserved
folder is refused before writing. Failed saves return the original snapshot for display;
failed thumbnail cleanup returns the committed snapshot and a visible error. Cancellation
before commit preserves the document; cancellation after commit remains recorded as committed
with incomplete cleanup. Navigation still prevents stale result/error publication.

## Verification

Focused ActivityHistoryTests validation passes **23 tests / 44 executions**, zero failures,
skips or runtime warnings; `build/qa-face-transaction-focused-2.xcresult`.
Host: arm64 MacBook Pro, macOS 27.0 (26A428), Debug test build.
New regressions exercise the reservation from read through save and thumbnail cleanup,
write failure with original presentation, cleanup failure with committed presentation,
cancellation on either side of commit, foreign-folder ownership, and lease release.
Existing contention, retry, equivalent directory URL and navigation tests also pass.

Commands use `xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' -scheme
'Aagedal Photo Agent Tests' -configuration Debug -destination 'platform=macOS'
-parallel-testing-enabled NO -jobs 1`; the focused selector is ActivityHistoryTests.
The first sandboxed attempt could not access compiler/package caches; the authorized
Xcode run passed. The App Intents metadata extraction warning remains the known build-only
no-framework diagnostic. Fixtures use disposable temporary folders and synthetic documents.
No native UI interaction or supported-client evidence is claimed.

Complete serial validation passes **3,015 tests / 3,939 executions** across 319 suites,
zero failures or skips, in a 114.938-second test operation;
`build/qa-face-transaction-full.xcresult`. The same four previously recorded QoS warnings
remain in CaptionSessionTests and MetadataEditorReadServiceTests. Repository validation
and `git diff --check` pass; `build/qa-face-transaction-repository-final.log`.

## Remaining release work

Already-loaded interactive edits still need stale-snapshot reconciliation across processes.
This change closes only the lazy deletion transaction; it does not claim general face-data
transactionality or crash-atomic multi-file cleanup. Remaining GUI writers, production MCP
workflow tools, durable operation status/cancellation, guarded IPTC prepare/commit,
template/provider discovery and FFmpeg Whisper remain unfinished.
Native/accessibility, authentic camera/editor/transport, cloud, hardware/performance and
migration/recovery evidence, legal review, remote CI enforcement, exact-candidate packaging,
final acceptance and authorized distribution remain release gates.
