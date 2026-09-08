# Template recovery, workspace navigation, and thumbnail writes — 2026-09-08

## Scope

This continuation completes three deferred implementation candidates and advances the
Known People portion of audit Phase 3.1 and delivery Phase 12. The audit remains
**66 of 75** and delivery remains **119 of 142** complete: broad storage ownership
and manual/device/release gates are still open.

- Metadata and Develop template deletion now uses coordinated Move to Trash, retaining
  exact persisted bytes, including fields unknown to the current app. Failed trash
  operations preserve the source and visible inventory; there is no permanent-delete
  fallback. Recovery requires restoring the JSON file and reopening the template list.
- Workspace and Layout are separate toolbar controls. Workspace includes an explicit
  Browser destination; Metadata Review also offers Back to Browser. Layout appears only
  in Browser and changes panes without switching workspace. Caption and Develop exits
  retain their existing persistence flush guards. Develop entry with an empty selection
  chooses the first image rather than a non-image file at the top of the folder.
- The production forced-cast audit replaces the scope image notification with a typed
  Swift payload and makes map-camera copying conditional. The sole remaining production
  `as!` bridges a Security-framework identity only after exact Core Foundation type
  validation; Swift does not support a conditional downcast to this CF type.
- Representative Known People thumbnail replacement moves the thumbnail/record write
  pair to the serialized archive worker. Process-wide destination reservations fence
  conflicting local changes while the request suspends. Durable writes invalidate peer
  caches even when later work fails or cancellation/storage changes prevent UI publication.
  Ordinary CRUD and other thumbnail mutations still contain synchronous MainActor work.

Three sub-agents implemented the template, forced-cast, and storage slices; the parent
implemented navigation, reviewed integration, and ran integrated validation.

Implementation commits: `a56f618` (template recovery), `37be99f` (thumbnail writes),
and `ac6a8f2` (workspace navigation and typed UI boundaries).

## Validation

The application/test build and unfiltered suite passed **2,235 tests in 260 suites**,
zero failures, in **75.433 seconds** of Swift Testing execution. New coverage includes:

- Three template tests covering exact/future-schema bytes, failed Trash with retained
  service and view-model inventories, repeated deletion, and restored-file reload.
- Three typed scope-notification tests covering image/HDR round-trip, clearing, and
  rejection of malformed payloads.
- One parameterized Known People test with four outcomes: success, cancellation during
  image I/O, storage replacement, and record-write failure. It verifies off-main writes,
  conflicting-write reservations, unrelated CRUD preservation, peer thumbnail invalidation,
  and reservation release.

Repository validation and `git diff --check` passed. An initial sandboxed Xcode attempt
could not write package/compiler caches; the approved run used the existing caches and
completed successfully. Subsequent source changes were comment-only. Navigation review
verified the existing flush paths and layout ownership; actual keyboard/VoiceOver and
Finder/custom-volume recovery behavior still require manual validation.

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO
scripts/ci/validate_repository.sh
git diff --check
```

Logs: `/private/tmp/aagedal-improvements-template-navigation-2026-09-08-tests.log`
and `/private/tmp/aagedal-improvements-template-navigation-2026-09-08-repository.log`.
The `.xcresult` is under the existing Xcode DerivedData test log directory with timestamp
`2026.09.08_18-31-24-+0200`.

## Remaining work

1. **Storage ownership:** Known People root/database loading, ordinary CRUD, migrations,
   conflicts/tombstones, clearing, other thumbnail mutations, and deferred event replay
   retain synchronous work. Admission uses a process-wide FIFO. Keyword preference and
   route publication remain separate from final actor writes, and snapshot copying occupies
   the shared keyword actor. In-process coordination does not establish cross-process or
   cloud-device atomicity.
2. **Manual interaction and performance:** template recovery on actual local/custom/iCloud
   and unavailable-Trash volumes; Workspace/Layout navigation and Metadata Review exit with
   keyboard and VoiceOver; Advanced Export on small and changing displays; hardware tiers
   and budgets; local/network/placeholder/read-only/large-folder measurements, Instruments,
   RAW/HDR, GPU/cancellation stress, IME, localization, and permission/privacy checks.
3. **Recovery and external gates:** upgrade/downgrade, backup/restore, crash-interruption
   drills, protected release-branch CI enforcement, Known People privacy/legal review,
   and real FTP/FTPS/SFTP certificate/host-key/failure drills.
4. **Model and release:** supported-macOS production-server model install/offline/update/
   rollback/removal/relaunch and interrupted/corrupt downloads; a current-source release
   candidate and signed/notarized distribution. Conditional AI-origin analysis still needs
   model/license/corpus decisions and explicit product approval.
5. **Other deferred work:** a strings catalog, pseudolocalization, and layout tests if
   multilingual distribution is planned. Recovery is through Trash, with no in-app Undo.
