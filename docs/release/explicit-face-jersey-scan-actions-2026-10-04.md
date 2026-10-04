# Explicit face and jersey scan actions — 2026-10-04

Baseline `cd91a1d`. The user reported noticeably slower face scanning because jersey
OCR was enabled. The persisted Sports preference was consulted by ordinary scans.
Face scans now disable OCR regardless of that legacy preference. The settings toggle
is replaced by guidance for the explicit action, so existing saved preferences cannot
silently keep slowing face scans or secondary-lens refinement.

The face bar offers Faces and a separate Faces + Jerseys action; the expanded view's
menu also offers the combined action. The current detection pipeline performs jerseys
alongside faces, so this is accurately labeled a combined scan, not jersey-only inference.
It forces a full rescan so previously face-scanned images are not skipped by incremental
signatures. Both controls share a native confirmation explaining that existing folder-local
face groups, names and jersey results are replaced. Cancel is the default. Known People
and photo metadata are unaffected by the reset. Ordinary face scans remain incremental
and retain observations for unchanged photos. Deferred Sports resolution now consults
saved jersey evidence rather than the removed toggle.

A sub-agent implemented the bounded scan intent and regression; the parent wired UI,
confirmation, native testing and integration. Independent review found no blocking issue.
An initially considered full-scan preservation conversion was removed before validation:
reset semantics remain explicit, avoiding stale jersey evidence or invented number boxes.

## Validation

Debug app 3.0.0 build 740, bundled AuraFace, arm64 macOS 27.0.1.

- 33 focused tests / three suites pass in 0.229 seconds, including a saved-true legacy
  preference regression and existing scan/signature cases:
  `build/qa-v3-continuation/jersey-focused.xcresult`.
- Repository validation and whitespace pass: `build/qa-v3-continuation/jersey-repository.log`.
- Native confirmation and cancellation pass: one test, 13.819 seconds;
  `build/qa-v3-continuation/jersey-native-final.xcresult`. The warning opens, Cancel
  returns to an enabled action and the disposable folder has no `.face_data` directory.
- Full integrated regression passes 3,832 tests / 380 suites in 121.901 seconds;
  `build/qa-v3-continuation/jersey-full.xcresult`. Final repository/whitespace validation
  passes in `build/qa-v3-continuation/jersey-repository-final.log`.

The first native run opened the correct warning but its global Cancel locator matched
both the dialog and Touch Bar. The test now scopes Cancel to the dialog; the failed run
is diagnostic evidence only. Tests use generated disposable photos and isolated UI-test
settings; no private photos or face records are intentionally changed.

Native evidence covers cancellation before scan admission, not cancellation of running OCR.
No representative sports-photo speed benchmark or real jersey-recognition quality
qualification was performed. The face-only configuration structurally skips the OCR
path; a numeric speedup is not claimed. Remaining human follow-up: compare the face-only
scan on a disposable representative folder, then explicitly confirm a combined rescan
when jersey results are needed. A true jersey-only enrichment pipeline preserving face
IDs/group decisions remains a possible later improvement, not implemented here.
