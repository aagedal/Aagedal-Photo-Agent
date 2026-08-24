# Metadata field customization validation

**Validated:** 2026-08-24  
**Scope:** Metadata Settings field order, visibility, requirement severity, persistence, recovery,
Metadata panel ordering, and Caption navigator ordering.

## Implemented behavior

- Metadata Settings presents one ordered row per customizable editor field with visibility and
  Optional/Warn/Require state together.
- Rows support native drag/drop with an always-before-target contract plus explicit,
  keyboard-focusable and VoiceOver-labelled move up and move down actions. Core fields remain
  visible, while their requirement level is editable.
- Hidden fields continue through the shared requirement engine; visibility does not weaken warning
  or blocking validation.
- One persisted order drives both the Metadata panel and the non-Deadline Caption navigator.
  Deadline profiles retain their own explicit field configuration.
- Fresh installs use the established editor order and seven-field visibility default. Stored
  visibility and requirement preferences remain authoritative during upgrade.
- Order decoding removes duplicates, ignores unknown IDs in the live UI, restores missing/new
  fields, and preserves unknown future IDs when this build saves. Hidden-state and requirement
  writers likewise retain entries unknown to this build.

## Automated evidence

The focused command passed on 2026-08-24:

```sh
xcodebuild test -quiet -scheme 'Aagedal Photo Agent Tests' \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/aagedal-field-review-derived \
  -only-testing:'Aagedal Photo Agent Tests/IPTCMetadataTests' \
  -only-testing:'Aagedal Photo Agent Tests/CaptionWorkspaceSpeedToolsTests'
```

Coverage includes fresh/default and legacy visibility behavior, requirement migration, repaired
and round-tripped field order, direct upward/downward always-before reorder behavior, preservation
of unknown order/visibility/requirement entries, global no-Deadline Caption and Deadline-profile
layout ordering, and static UI audits for the compact checklist, Metadata Settings link, field
guidance, unified rows, drag/drop, and accessible reorder controls.

## Manual boundary

The automated audit verifies the native interaction hooks and accessibility labels but does not
operate a live macOS VoiceOver session. Final release validation still includes hands-on drag,
keyboard focus, and VoiceOver announcements in the built Settings window.
