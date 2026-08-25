# Privacy-safe accessibility announcement validation

**Date:** 2026-08-25  
**Scope:** App improvement audit plan 2.1, centralized accessibility announcements

`AppAccessibilityAnnouncement` is the single typed source of spoken action feedback. Its
success, failure, cancellation, and recovery categories accept only fixed-copy enum cases;
there is no string or error associated value through which a filename, path, identifier,
editorial value, or error description can enter an announcement. The main-actor
`AccessibilityAnnouncementCenter` is the only production path that posts
`.announcementRequested` through AppKit.

Caption Save & Next and Write & Next now use the shared center. Metadata and Develop
template editors post fixed success, cancellation, and recovered-after-retry results. A
failed template save retains the existing accessibility focus move to the inline error and
uses the same shared fixed failure copy as its label, avoiding a second announcement for one
failed action. The C2PA inspector posts fixed inspection/validation failures and final
success or recovery results, distinguishes a no-credentials retry result, and announces an
in-progress inspection cancellation when its sheet is dismissed.

Focused validation used an isolated DerivedData directory to avoid concurrent build locks:

```sh
xcodebuild test -quiet \
  -derivedDataPath /private/tmp/aagedal-accessibility-announcements-dd \
  -scheme 'Aagedal Photo Agent Tests' \
  -destination 'platform=macOS' \
  -only-testing:'Aagedal Photo Agent Tests/AccessibilityKeyboardAuditTests' \
  -only-testing:'Aagedal Photo Agent Tests/CaptionWorkspaceSpeedToolsTests' \
  -only-testing:'Aagedal Photo Agent Tests/C2PAValidationTests' \
  -only-testing:'Aagedal Photo Agent Tests/DevelopTemplateTests' \
  -only-testing:'Aagedal Photo Agent Tests/MetadataTemplatePersistenceTests'
```

Result: 53 tests passed, with 0 failures or skips. The focused accessibility regression
enumerates every fixed announcement, rejects path/interpolation markers, verifies no error
description enters the center, rejects direct announcement posts in the migrated views, and
rejects the former interpolated template error label. Swift parsing and `git diff --check`
also passed.

Actual VoiceOver speech, focus timing, and announcement coalescing remain part of the manual
OS-level release gate; this validation closes the implementation and automated privacy gate
without claiming that manual observation.
