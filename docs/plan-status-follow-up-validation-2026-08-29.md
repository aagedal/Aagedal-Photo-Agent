# Plan status follow-up validation — 2026-08-29

## Develop/scope command-router continuation

Five more user-command families now cross the scene-owned `AppCommandRouter`: Add New Mask, Remove or Reset
Selected Edit Layer, Toggle HDR, scope-mode selection, and Toggle Gamut Clipping. Existing conditional
ownership is preserved: Develop handles its commands only for an editable single-image session, while scope
commands act only when the single-selection scope panel is mounted. Five obsolete notification names and
their posts/subscriptions were removed; internal scope render-state broadcasts remain notifications.

## Rejected-file async boundary

Move Rejected to Folder no longer performs destination creation, collision probes, or transactional image
and sidecar moves on the main actor. The operation crosses the serialized filesystem actor, reports
cancellation before or between complete bundles, and discards stale completion if the user navigates to a
different folder while a slow volume is still working. Existing collision association and rollback behavior
remain covered alongside new pre-cancellation and stale-navigation characterizations.

The combined current-source verification compiled the complete application and test targets and passed all
**13 tests in 2 suites**: four `RejectMoveServiceTests` and nine `AppCommandRouterTests`, with
`** TEST SUCCEEDED **`. The result bundle is:

```text
/tmp/aagedal-reject-boundary-20260829-1548/Logs/Test/
Test-Aagedal Photo Agent Tests-2026.08.29_15-46-01-+0200.xcresult
```

## Manual validation still required

The automated tests establish typed routing, ordering, payload preservation, cancellation, rollback, and
stale-result behavior. They do not establish that macOS menus, shortcuts, focus, visual feedback, and slow
volume responsiveness behave correctly in the packaged UI.

Run the following before merging this continuation into a release candidate. Repeat the slow-volume portion
on each supported macOS tier before marking the broader Phase 3.1 exit gate complete.

### Develop and scope commands

1. Open one editable image in Develop. Invoke Add New Mask (Command-J), Remove or Reset Selected Edit Layer
   (Control-Option-Delete), and Toggle HDR (Control-Option-H) from both their menus and shortcuts. Confirm
   each action occurs once in the active window and preserves the existing selection/confirmation behavior.
2. With the single-image scope panel visible, select Waveform, Parade, Vectorscope, and Gamut using both the
   View menu and Control-Option-1 through Control-Option-4. Toggle gamut clipping with Control-Option-G and
   confirm the scope and Develop preview update once.
3. Repeat the commands with no image, multiple selected images, Caption active, and Develop closed. Confirm
   commands intended for an unavailable workspace remain harmless and do not change another pane/window.
4. If multi-window operation is enabled for the release candidate, open two windows and verify menu commands
   affect only the window that owns the active menu command.

### Move Rejected to Folder

1. On a representative local folder, reject RAW and raster files that have adjacent XMP and editorial JSON
   sidecars. Include a pre-existing same-name bundle in `.Rejected`. Confirm each image remains associated
   with both sidecars and collision suffixes match across the complete bundle.
2. Repeat on a deliberately slow network/external volume while Thread Performance Checker is enabled.
   Confirm the window remains responsive and no main-thread filesystem warning is reported.
3. Start the move on the slow volume, then navigate to another folder before it completes. Confirm the app
   stays in the new folder and the completed operation does not reopen or replace it.
4. Inject or arrange a permission/read-only failure for one sidecar and confirm the affected bundle rolls
   back, other completed bundles remain accurate, and the app shows a recoverable failure rather than
   reporting complete success.

Record the macOS version, volume type, fixture composition, result, and any Thread Performance Checker
finding in a dated validation record. Until that record exists, these changes are implemented and
automatically verified, but their manual UI/slow-volume release gate remains open.

## Implemented continuation

The next bounded Phase 4.1 command-router slice moved six user-initiated operations, represented by seven
typed cases, from the process-wide notification bus to the scene-owned `AppCommandRouter`:

- Import Photos;
- Back Up Edited Files;
- Open in Internal Editor and Open in External Editor;
- Move to Trash; and
- Move Rejected to Folder.

The application menu retains the existing saved-preference decision between the internal and external
editor. Content, browser, and safety handlers retain their previous behavior while receiving commands only
from their owning scene. Folder-row backup commands preserve their exact URL as a typed payload. Seven
obsolete notification declarations, menu/folder-row posts, and subscriptions were removed.

## Validation

Characterization coverage was authored before the production command cases and includes the folder URL
payload contract. After implementation, a fresh arm64 build compiled the complete application and test
targets, and `AppCommandRouterTests` passed all **8 tests in 1 suite** with `** TEST SUCCEEDED **`. The result
bundle is:

```text
/private/tmp/aagedal-command-router-followup-20260829/Logs/Test/
Test-Aagedal Photo Agent Tests-2026.08.29_15-20-05-+0200.xcresult
```

This is incremental progress toward the broad command-router checklist item. Template, metadata, and other
application-command notifications remain, so that item stays open.

## Import scan responsiveness follow-up

Primary and second-source discovery now publish immutable progress snapshots every five seconds while the
serialized filesystem actor continues scanning off the main actor. The Import window immediately presents a
bordered progress status with an indeterminate spinner plus live regular-file and supported-image counts;
second sources also show their WAV count. Once second-source enumeration finishes, the status explicitly
changes to voice-memo match analysis instead of continuing to claim that files are being scanned.

Characterization covers the five-second production cadence and exact file/image/WAV counts. The combined
`ImportSourceDiscoveryServiceTests` and `ImportViewModelTests` run passed all **17 tests in 2 suites** with
`** TEST SUCCEEDED **`. The result bundle is:

```text
/private/tmp/aagedal-command-router-followup-20260829/Logs/Test/
Test-Aagedal Photo Agent Tests-2026.08.29_15-28-35-+0200.xcresult
```

## Upload command-router continuation

Upload Selected and Upload All now use typed, scene-owned commands. The existing selection scope is
preserved exactly: selected upload snapshots only selected URLs, while Upload All snapshots the current
folder's images; empty sets still do nothing. Both obsolete notification declarations, posts, and
subscriptions were removed. Other upload state and transport behavior is unchanged.

## Import preflight async boundary

Same-date duplicate discovery and overwrite collision probes for primary and backup destinations now run on
the serialized `ImportPreflightService` actor instead of the main actor. One immutable result freezes
duplicate skips, companion voice-memo skips, per-job collision expectations, counts, and the confirmation
signature together. Reset cancels and invalidates the active request so a late result cannot restore an old
preflight or create a destination. Execution retains its fail-closed collision-signature revalidation before
the first destination write.

Characterization covers duplicate/companion propagation, exact in-batch and on-disk collision evidence,
pre-cancellation with zero probes, actor serialization, and stale-result rejection after reset. The rejected
bundle suite also now deterministically cancels between two complete transactions and proves the first
commit remains durable while the second bundle is untouched.

## Integrated validation

A complete arm64 `build-for-testing` succeeded. The focused `test-without-building` run then passed all
**34 tests in 4 suites**: `AppCommandRouterTests`, `RejectMoveServiceTests`,
`ImportPreflightServiceTests`, and `ImportViewModelTests`. The xcresult action status is `succeeded` with
34 tests and no reported issues:

```text
/private/tmp/aagedal-focused-20260829-172219.xcresult
```

The Phase 3.1 and Phase 4.1 checklist boxes remain open: lower-priority filesystem paths, slow-volume and
Thread Performance Checker measurements, manual menu/focus/multi-window validation, and remaining user
command families have not been completed by this bounded continuation.
