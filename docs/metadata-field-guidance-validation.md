# IPTC metadata field guidance validation

**Date:** 2026-08-23  
**Scope:** concise guidance for each stable `MetadataFieldID`, shared hover help, accessibility
hints, and localization-ready source strings in the Metadata panel.

## Implemented contract

- Every one of the 33 stable metadata field identities has an exhaustive `guidance` definition
  with a common editorial use and a short example.
- Each fragment is created with `String(localized:)`; the shared sentence containing the
  translated use and example is localized as well.
- One reusable `metadataField(_:)` view modifier owns the stable navigation ID, macOS hover help,
  and accessibility hint. Field composition sites use that modifier instead of duplicating help
  behavior inside text, token, picker, date, controlled-vocabulary, or structured-supplier
  editors.
- Existing field visibility and ordering behavior is unchanged.

## Automated evidence

Focused command:

```sh
xcodebuild test \
  -scheme 'Aagedal Photo Agent Tests' \
  -destination 'platform=macOS' \
  -only-testing:'Aagedal Photo Agent Tests/CaptionWorkspaceSpeedToolsTests'
```

Result: **passed**, 12 tests in one suite. The focused guidance checks verify that all 33 cases
have non-empty, bounded use/example copy and that Metadata panel composition routes every editor
through the shared hover/accessibility behavior.

Source parsing also passed for `MetadataFieldID.swift`, `MetadataPanel.swift`,
`ImageSupplierMetadataEditor.swift`, and `CaptionWorkspaceSpeedToolsTests.swift`.
`git diff --check` reported no whitespace errors.

The test host continued to emit its known environmental diagnostics for the detached-signature
database, LMDB map size, a repeated SwiftUI update, and a background-thread publish. They did not
fail the focused suite and are not caused by field guidance.

## Remaining validation boundary

Translated catalogs and a manual VoiceOver/hover review remain useful release QA, but are not
required to establish the source and accessibility contract above. Unified Settings field
management and accessible reordering remain separate plan items.
