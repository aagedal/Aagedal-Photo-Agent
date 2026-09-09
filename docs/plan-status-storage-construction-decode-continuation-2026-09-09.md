# Storage construction, backup snapshots and decode context — 2026-09-09

## Scope

This continuation advances audit Phase 3.1 and delivery Phase 12. Audit remains
**66 of 75** and delivery **119 of 142** complete. The remaining broad storage,
manual, device and release gates are still open.

- Analysis repositories now open asynchronously. Source canonicalization and default
  Application Support preparation run on the retained filesystem executor; the private
  initializer only builds paths from immutable roots. Workspace opening and rename
  reassociation await construction, and workspace generations reject stale success or
  failure even when the same source is reopened.
- Fallback case and folder-map saves share admission for their canonical index across
  repository instances. Ownership spans document/index writes and actor suspension;
  cancelled waiters write nothing, admitted transactions finish their index after
  cancellation, and failure releases ownership. Other fallback roots and portable local
  writes remain independent. The actual fallback paths retain the canonical support root,
  so retargeting a symlink while a save waits cannot move its I/O to another index.
- Cold Known People detail/representative edits, deletion, add-or-merge, two-person merge,
  thumbnail replacement and archive import prepare legacy `database.json` migration on
  the archive worker. Whole-root reservations exclude synchronous peers while migration
  runs. Existing per-person records win, and the legacy file is retired only after all
  missing records are durable. Partial writes invalidate peer databases even after a
  failure; stale roots cannot publish. Once the legacy read begins, the admitted migration
  finishes despite cancellation. Pre-read cancellation leaves storage untouched. Embedding
  model-readiness stamps and tombstone suppression remain intact. Background clear also
  uses asynchronous root routing.
- Keyword snapshots capture managed source text on the managed filesystem worker, then
  release it while a shared history worker deduplicates and writes the immutable backup.
  Slow history access no longer blocks list restores. The shared writer prevents duplicate
  snapshots across service instances, checks cancellation before each I/O boundary, and
  retains success for a completed write. Retention remains independent. A racing restore
  can change the managed list while the backup still saves its earlier captured bytes.
- General HDR/raster preview and full-resolution decoding retain caller task context on
  per-request serial executors targeting a shared concurrent Dispatch queue. Enforced
  utility-QoS work items preserve the Core Image priority-inversion safeguard without
  serializing independent decodes. Cancelled queued requests skip provider access; pixels
  completed after cancellation are discarded. Embedded RAW keeps its enforced-default
  work-item boundary and now checks cancellation before dispatch and after completion.
  Orientation, decode sizing and the existing pixel loaders remain unchanged.

Three sub-agents implemented analysis, Known People and decode changes. The parent
implemented snapshot history isolation, reviewed integration, ran validation and updated
the plans. Cross-review found no further actionable backup or Known People regressions.

## Validation

The final-source unfiltered suite passed **2,360 tests in 274 suites**, zero failures,
in **81.766 seconds**. Repository validation and whitespace checks passed. No new test
file registration was needed; coverage was added to existing test files.

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO
scripts/ci/validate_repository.sh
git diff --check 9eb7482..HEAD
```

The final `.xcresult` in existing DerivedData is timestamped
`2026.09.09_21-05-01-+0200`. Logs:
`/private/tmp/aagedal-plan-workers-final-tests.log` and
`/private/tmp/aagedal-plan-workers-final-repository.log`.

Coverage includes actual executor isolation, task-local/priority retention, observed
utility thread QoS, independent and queued decode requests, real oriented-TIFF geometry,
legacy migration read/write/removal failures and durable prefixes, root reservations and
switches, snapshot/restore overlap, shared snapshot deduplication, and concurrent fallback
case/map writes through a retargeted alias. Fixtures use temporary local storage and
injected provider boundaries; they do not establish physical-volume, production-server,
manual interaction or target-hardware performance evidence.

The initial sandboxed Xcode command could not write existing compiler/package caches;
approved Xcode access resolved that restriction. Intermediate builds encountered test-first
API additions and a test-only actor-isolation annotation. The first unfiltered run found
four failures: two assertions compared whole documents across JSON date precision loss,
one HDR fixture expected a fractional extent instead of Core Image's enclosing 27 × 40
pixels, and one exposed a real fallback-alias admission gap. A Foundation probe confirmed
that resolving an absent index descendant leaves its support symlink unresolved. Capturing
the existing support root during asynchronous construction corrected admission and I/O
identity before the final passing run. The date tests now assert exact source match,
identity and hash; folder-map fixtures use an integral timestamp.

Implementation commits: `5ea8940` (analysis construction), `bc9dd5d` (Known People migration),
`b491fa8` (decode workers), `3de0337` (integral HDR fixture), `c7b6d70` (snapshot history),
and `52cac5a` (fallback transactions and canonical storage roots).

## Current-source unsigned Release candidate

A clean-source candidate built from `52cac5ade5a84fc6cb628f77968f3a97bacb61a7`, version
**3.0.0 (738)**, with Xcode 26.6 (17F113) on arm64 macOS
27.0 (26A5425a). Model omission passed and all **79** ZIP payload
entries match the built application. The bundle contains 73 regular files totaling
145,485,442 bytes; the ZIP is 49,793,495 bytes.
ZIP SHA-256: `4a3b522fcd5aa066aac9fee558e695642bb6fcc350420ecae4ec1aa7c10d3ecc`.

```sh
python3 -B scripts/ci/build_model_free_candidate.py \
  build/model-omission-candidate-storage-construction-decode-2026-09-09
```

The application, ZIP, build log and `measurement.json` remain in that ignored output
directory. Xcode used approved access to existing caches. This establishes unsigned
build/package consistency; launch, signing, notarization, distribution and production-server
model validation remain open. The subsequent documentation-only commit changes no
candidate application source.

## Remaining work

1. **Storage ownership:** Known People cold database assembly, embedding migration,
   compatibility CRUD/thumbnail helpers, conflicts/tombstones and deferred events still
   have synchronous MainActor paths. Cold `removeEmbedding` and export lookups also remain;
   admission still serializes unrelated roots. Keyword managed source reads and recovery
   scans still occupy the managed worker, and route/preferences publication remains
   separate from file commits. Atomic JSON/template ordering remains per service instance.
   Analysis fallback documents and their index use separate atomic writes, so a process
   crash between them is not a multi-file atomic transaction. Cross-process/device writers
   and local last-writer behavior remain unchanged. Continue the lower-level ImageIO/Metal
   closure audit; embedded RAW intentionally still crosses a continuation without caller
   task context, and blocking decode work cannot be preempted mid-call.
2. **Performance and interaction:** agree hardware tiers and latency/memory budgets, then
   measure SSD, network, iCloud placeholders, read-only and large-folder workloads with
   Instruments, including large RAW/HDR, two-image comparison, GPU memory, startup and
   navigation/export cancellation. Run VoiceOver, keyboard/IME, contrast, Reduce Motion,
   permission, fixture alignment/color and changing-display/Clean Feed drills.
3. **Recovery and external gates:** upgrade/downgrade/newer-schema, backup/restore and
   process-crash exercises; protected release-branch CI enforcement; focused Known People
   privacy/legal review; real FTP/FTPS/SFTP certificate, host-key and transfer-failure tests.
4. **Model and release:** signed/notarized distribution and production-server model install,
   offline use, update, rollback, removal/relaunch and interrupted/corrupt downloads across
   supported macOS versions. The unsigned candidate establishes build/package consistency.
5. **Conditional work:** AI-origin analysis needs explicit product approval and
   model/license/corpus decisions. Multilingual strings, pseudolocalization and layout
   coverage remain conditional; template recovery still uses Trash without in-app Undo.
