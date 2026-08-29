# Scene app-command router validation — 2026-08-27

## Develop and scope command slice — 2026-08-29

Add New Mask, Remove or Reset Selected Edit Layer, Toggle HDR, the four scope-mode choices, and Toggle
Gamut Clipping now use five typed scene commands. The scope-mode command carries
`ScopeViewModel.ScopeMode` directly rather than recovering an untyped notification object.

Ownership remains identical to the previous UI behavior: the mounted Develop workspace consumes mask/HDR
commands only while it can edit one image, and the conditional single-selection scope panel consumes scope
commands only while that panel exists. Other scene consumers explicitly ignore the cases. Internal rendered
scope-image and slider-drag-state changes remain on `NotificationCenter` because they are state broadcasts,
not application commands.

Five obsolete process-wide notification declarations, their menu posts, and their subscriptions were
removed. Characterization coverage asserts exact command identity, the scope-mode payload, and monotonic
delivery ordering. A fresh combined build passed all **13 tests in 2 suites**: four
`RejectMoveServiceTests` and nine `AppCommandRouterTests`, with `** TEST SUCCEEDED **`. The result bundle is:

```text
/tmp/aagedal-reject-boundary-20260829-1548/Logs/Test/
Test-Aagedal Photo Agent Tests-2026.08.29_15-46-01-+0200.xcresult
```

Manual menu, shortcut, focus, unavailable-workspace, and multi-window checks are still required before this
slice enters a release candidate. The exact procedure and completion boundary are listed under **Manual
validation still required** in
[`plan-status-follow-up-validation-2026-08-29.md`](plan-status-follow-up-validation-2026-08-29.md).

## Workspace and safety command slice — 2026-08-29

Import Photos, Back Up Edited Files, Open in Editor, Move to Trash, and Move Rejected to Folder now send
typed scene commands. Back Up Edited Files preserves the exact folder URL when invoked from a folder row.
The internal/external editor choice remains resolved from the same saved preference, but the chosen operation
is delivered only to the owning scene. The scene's existing content, browser, and safety handlers still
invoke the same actions as before.

Seven obsolete process-wide notification names, their application-menu/folder-row posts, and their matching
subscriptions were removed. State-change broadcasts remain on `NotificationCenter`.

Characterization coverage was added before the production cases and asserts typed identity, the folder URL
payload, and monotonic ordering for all seven cases. A fresh arm64 test build compiled the complete
application and test targets, then the focused `AppCommandRouterTests` selector passed all **8 tests** with
`** TEST SUCCEEDED **`.

## Selection operation command slice

Rename Selected, Duplicate Selected, Reset All Edits, and Remove All IPTC Metadata now send typed
`AppCommand` cases through the owning scene router from both the SwiftUI application menus and the AppKit
thumbnail context menu. `ContentView` consumes each delivery through the same `BrowserViewModel` methods as
before. Caption Workspace and the scene-level AppKit bridge explicitly ignore the commands they do not own.

The four obsolete process-wide notification names, menu/context-menu posts, and `ContentView` subscriptions
were removed. Genuine state-change and process broadcasts remain on `NotificationCenter`.

## Rotation command slice

Rotate Right and Rotate Left now send the typed `AppCommand.rotateClockwise` and
`AppCommand.rotateCounterclockwise` cases through the owning scene's `AppCommandRouter`. The existing
Command-R and Shift-Command-R menu shortcuts and `BrowserViewModel` rotation methods are unchanged. The
scene content consumes each delivery once; Caption's nested command observer explicitly ignores rotation so
it does not duplicate the scene-level action.

The obsolete `rotateClockwise` and `rotateCounterclockwise` `Notification.Name` declarations, menu posts,
and `ContentViewModifiers` notification receivers were removed. Process-wide state-change broadcasts remain
on `NotificationCenter`; other user-command families remain incremental Phase 4.1 work.

## Characterization and focused validation

The router characterization was added first and initially failed to compile because the two typed cases did
not yet exist. It asserts clockwise/counterclockwise identity and monotonically increasing delivery order.

After the rotation migration, this focused command passed:

```sh
xcodebuild test \
  -scheme 'Aagedal Photo Agent Tests' \
  -destination 'platform=macOS' \
  -only-testing:'Aagedal Photo Agent Tests/AppCommandRouterTests'
```

Result: 6 tests passed in the `Scene app command router` suite, including the new rotation characterization.
`git diff --check` also passed.

The selection-operation follow-up added a characterization for typed identity and monotonic delivery order.
The same focused selector then passed all **7 tests** in the suite with `** TEST SUCCEEDED **`.

## Upload command slice — 2026-08-29

Upload Selected and Upload All now send typed commands through the owning scene router. `ContentView`
preserves the existing selected-image versus full-folder URL collection and does not present the upload
sheet for an empty set. The two obsolete process-wide notification declarations, menu posts, and
subscriptions were removed; all other command and state notifications are unchanged.

Characterization asserts both command identities and monotonic ordering. The integrated focused run below
passed this suite together with the Import preflight and rejected-bundle suites; the broader Phase 4.1 item
remains open for the metadata, template, workspace, and other user-command families.

```text
/private/tmp/aagedal-focused-20260829-172219.xcresult
34 tests passed in 4 suites; action status: succeeded
```
