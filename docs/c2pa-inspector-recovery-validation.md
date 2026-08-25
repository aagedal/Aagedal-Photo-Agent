# C2PA inspector recovery validation

**Date:** 2026-08-25  
**Scope:** App improvement audit plan 2.1, Content Credentials inspector slice

The inspector sheet is now presented before C2PA metadata parsing begins, so its first
state is an explicit loading indicator rather than silence. The sheet keeps metadata
loading and signature validation as separate phases and provides keyboard-operable
**Retry** actions for absent credentials and every recoverable failure.

The UI distinguishes malformed credentials, a missing validation tool, source access
denial, and an environmental validation failure. Failure copy is derived from typed
states and never interpolates parser, process, claim, filename, or source-path details.
Thumbnail extraction remains best effort and cannot suppress readable manifest data.

Focused validation passed:

```sh
xcodebuild test -quiet \
  -scheme 'Aagedal Photo Agent Tests' \
  -destination 'platform=macOS' \
  -only-testing:'Aagedal Photo Agent Tests/C2PAValidationTests'
```

Result: 12 C2PA validation tests passed. The run compiled the production app target,
including `ContentView`, `C2PADetailSheet`, and the typed inspection-failure model. New
cases verify distinct failure mapping, nested Cocoa/POSIX permission errors, and that
private error details cannot enter user-facing recovery messages.

The centralized accessibility-announcement checklist item was subsequently completed; see
the [announcement validation](accessibility-announcement-validation.md).
