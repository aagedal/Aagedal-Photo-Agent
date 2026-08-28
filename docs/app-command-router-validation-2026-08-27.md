# Scene app-command router validation — 2026-08-27

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
