# Full-screen loading recovery validation

**Date:** 2026-08-25
**Scope:** App improvement audit plan 3.3 loading-guidance action

Full-screen edited-preview loads now explain that pressing **E** turns edits off when
faster high-resolution loading matters. The same action is visible in shortcut help.
Hard cold-decode and cached-preview upgrade failures use a generation-checked recovery
state with **Retry**, **Reveal in Finder**, and user-initiated **Copy Details** actions.

Focused validation passed:

```sh
xcodebuild test \
  -scheme 'Aagedal Photo Agent Tests' \
  -destination 'platform=macOS' \
  -only-testing:'Aagedal Photo Agent Tests/FullScreenShortcutTests' \
  -only-testing:'Aagedal Photo Agent Tests/FullScreenLoadingRecoveryTests'
```

Result: 5 tests across 2 suites passed. The full integrated suite is recorded separately.
