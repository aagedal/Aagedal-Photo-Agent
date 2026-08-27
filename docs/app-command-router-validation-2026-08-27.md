# Scene app-command router validation — 2026-08-27

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

After the migration, this focused command passed:

```sh
xcodebuild test \
  -scheme 'Aagedal Photo Agent Tests' \
  -destination 'platform=macOS' \
  -only-testing:'Aagedal Photo Agent Tests/AppCommandRouterTests'
```

Result: 6 tests passed in the `Scene app command router` suite, including the new rotation characterization.
`git diff --check` also passed.
