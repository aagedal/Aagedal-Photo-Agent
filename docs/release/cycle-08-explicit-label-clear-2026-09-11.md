# Coordinator cycle 8 — Face verification and explicit XMP label clear

**Trigger:** 2026-09-10 15:36 UTC; work and verification span September 10–11.
**Baseline:** clean `d0af70b` on main, implementation `34a7313`.
**State:** IMPLEMENTING. Source `b8e668a` passes focused/full/repository and native clear/relaunch checks; broad remaining gates stay open.

## Reconciliation and ownership

The coordinator read the protocol/readiness, planning index and open criteria in all four
source plans. The current 60 unchecked entries remain (nine audit, 23 investigation,
22 journalistic, six solar); no broad checkbox is closed by these bounded results.
The other active FTP Sync task uses a separate repository; Media Player is idle elsewhere.
No unrelated dirty work was present. The first native recheck reported the Mac locked;
access resumed on a later check without an unlock bypass.

The core agent owns explicit label presence through parsing, merge, JSON/XMP and field completion.
The caller agent owns rendered export and FTP field propagation with real-file regressions.
The coordinator owns Browser reload integration, builds, native testing and documentation; an
independent agent reviews the combined source. No production transfers, publication or model
installation occurs. Native testing uses only existing synthetic fixture copies.

## Native Face completion — PASS on unchanged 34a7313

Before any rebuild, the coordinator verified all executable hashes against
`build/qa-field-write-cycle7-face/tested-binary-identity-final.json` and exercised that exact
Debug 3.0.0 (738) build, arm64, macOS 27.0 (26A428), SDK macosx26.5. The app remains at the
DerivedData Debug path recorded in cycle 7. This is saved-group metadata testing; no inference
or authentic camera/recognition compatibility is inferred from the synthetic face geometry.

1. Opened the saved **Cycle 7 Added Person** group in `build/qa-field-write-cycle7-face/`.
   The group and two faces loaded without an inference model. Clicked Apply All while
   failed.xmp remained a nonempty directory. The corrected folder identity admitted writes.
2. A native **Face Operation Needs Attention** dialog reported **1 of 2 photo metadata edits
   completed**, named failed.png and its invalid-format reason. The full text is selectable
   and scrollable. Done retained an accessible Details button; reopening it displayed the same
   complete result. This verifies actual presentation, not merely the view-model error string.
3. Physical successful.png retained `Source-only person` and appended the group name; its XMP
   independently retained `XMP-only person` and appended the same name. JSON contains only the
   requested addition plus pending headline G, pending=true, and one history entry. Original
   physical headline A remains. Failed photo/JSON bytes remain exactly unchanged. Pixel payload
   hashes remain unchanged. `cycle8-after-partial-snapshot.json` records all results.
4. Removed only the named synthetic obstruction file and its otherwise-empty failed.xmp directory.
   Dismissed the notice and clicked Apply All again. failed.png now contains its original
   source-only name plus the addition; its JSON retains G pending and one history event. In the
   current image-write mode no absent XMP is created. The already-successful photo/XMP are
   byte-identical across retry and its history remains one entry: no duplicate person insertion.
5. Browser displays pending Headline G and the added person. Normal Quit was confirmed through
   native app inventory. Relaunch, folder reopen and selection retain the group, pending markers,
   headline and person. Every tracked artifact state/hash matches after relaunch
   (`cycle8-after-retry-snapshot.json` versus `cycle8-after-relaunch-snapshot.json`).
6. Quit normally and confirmed every QA app inventory entry stopped before compiling new source.

The source PNGs intentionally gain metadata; their image pixel payloads remain identical.
The source-only and XMP-only person lists deliberately differ, so retaining pending person
state is correct. These observations close cycle 7's narrow final native Face gate.

## Explicit clear implementation

Standard `xmp:Label=""` now means an explicit clear, while an absent label remains nil and
inherits an earlier carrier. The distinction survives IPTC parsing, both overlay merges,
JSON encoding/decoding and XMP resave. The field-only service writes and acknowledges the same
empty representation, preserving unrelated pending fields and an existing null snapshot.
The previous conservative XMP-clear rejection is removed only because the carrier now expresses
an effective clear. No nonstandard label text or new schema field is introduced.

Browser batch metadata accepts an empty XMP label override; a real one-photo folder-load test
runs twice for absent/clear cases and checks both presentation and untouched source bytes.
Rendered XMP/JSON overlays and FTP's explicit sidecar sync share a presence-aware field builder.
Six real-file cases prove empty clears an old embedded label, nil preserves it, unrelated
headline/rating behavior stays correct, and rendered overlays do not modify their source.
The FTP test exercises its exact field-builder/engine boundary, not network transmission.

Independent source review passes. The dependency currently drops empty **element-form** simple
properties such as `<xmp:Label/>`; app-written empty attributes round-trip and are tested. That
external serializer compatibility limitation remains visible under the interoperability gate;
this change does not claim every external XMP spelling is now handled. Dependency files were
not patched and no parser bypass was introduced.

## Integration evidence in progress

Initial focused validation ran 68 tests / five suites and found only two issues in the new
Browser fixture's URL equality assertion: folder enumeration used physical `/private/var` URLs
while temporary Foundation URL representations differed. Both actual displayed label values were
already correct. Normalizing the temporary root did not remove URL representation differences
in a second run. The test now requires exactly one image with the fixture filename, checks its
label after each actual folder reload and independently checks source bytes. No production
behavior was changed to accommodate the fixture. Final rerun results are recorded below.

The next independent writer work remains concrete: Browser rotation still uses the generic
whole-record helper, promotes nil snapshots and cannot persist its omitted EXIF orientation in
JSON history-only mode. Metadata Review still trims before an untracked generic merge and
separates XMP completion. A technical orientation carrier and retained Review replay/recovery
remain required before those paths can be called complete. Archive/reassociation, transcription,
variables/delivery and broader native/hardware/external release gates also remain.

## Native XMP-only clear and relaunch — PASS

Final focused v3 passes **68 tests / five suites (1.878 seconds)**. The coordinator then tested
that unchanged compiled source (12 dirty source/test files on d0af70b) before the full suite.
`build/qa-label-clear-cycle8/tested-binary-identity.json` records Debug 3.0.0 (738), SDK macosx26.5,
executable SHA-256 `51d054502a53e4ecc05bdfa7d4915d390f3ddb4c23ba97a7ca4532e780e32a60` and debug
dylib `19f78515ca2f02590aa0c6417cf8f21698170e2990e0deeb6bee174465abe454`, at the same DerivedData
Debug app path as cycle 7. Hardware/OS remain arm64, macOS 27.0 (26A428).

1. Prepared `build/qa-label-clear-cycle8/` from the prior synthetic Browser PNG. All three PNGs
   physically contain Blue/Review and rating 3. known.png and unknown.png have pending headline G;
   their original snapshots are respectively known and null. absent.png has a rating-only XMP
   with no Label and no JSON, providing the inheritance control.
2. In native Settings, recorded the Professional preset, and Custom's existing standard-image
   setting Write To Image File (RAW/C2PA remained XMP). Temporarily selected Custom and Standard
   Images → Write To XMP Sidecar. No other preference was changed.
3. Opened the fixture and verified all three photos initially displayed Blue. Selected known.png,
   then clicked its selected Blue label to clear. Repeated for unknown.png. Both now display None
   and retain pending metadata/Headline G indicators. The absent-label control still displays Blue.
4. Independently read all destinations: both source PNGs are **byte-identical** with embedded
   Review unchanged. Both XMP records contain the standard empty Label attribute. JSON stores
   label="", G and pending=true. The known snapshot acknowledges label=""; the unknown snapshot
   remains null. Unrelated fields and the entire absent-control PNG/XMP remain unchanged.
5. Inspected a native screenshot: both edited thumbnails show pending indicators and no color
   label, while absent.png retains its Blue stripe; the selected editor displays G.
6. Restored Custom's Standard Images setting to Write To Image File, restored the Professional
   preset, returned Settings to its original General page, and quit normally. Native inventory
   confirmed the app stopped. Relaunch and folder reopen still show None/None/Blue with the two
   expected pending markers. All eight original tracked artifact states/hashes match exactly
   (`after-clear-snapshot.json` versus `after-relaunch-snapshot.json`). Quit and inventory again
   confirmed the QA app stopped before integrated testing.

This is actual native XMP-only writing followed by effective reopen in the restored original
mode; it is not a simulated UI result. Automated tests separately cover sole clear completion,
finalization failure and export/FTP field application. Real external applications and network
transmission remain separate gates.


## Final integration and decision

Committed implementation: **`b8e668a226293dee094e1f358c72dc238d7c232d`**, twelve owned source/test
files. No source edits followed final focused/native checks. Integrated validation passes **2,554
tests / 285 suites (90.348 seconds)**. `scripts/ci/validate_repository.sh` passes, including metadata,
privacy, provenance, property-list and conflict/whitespace checks. Logs are
`/private/tmp/aagedal-coordinator-cycle8-focused-v3.log`, `...-full.log` and `...-repository.log`.
The standard coordinator xcodebuild command was used; focused selectors were the five suites
MetadataFieldMutationWriteServiceTests, ExplicitXMPLabelClearTests, MergedTests,
FieldMutationCallerTests and EditExportPipelineTests. The earlier two focused failures were
fixture identity assertions only and are retained above.

The integrated build relinked the same source, so its final hashes differ from the pre-full native
write build. `build/qa-label-clear-cycle8/final-binary-identity.json` records executable
`ec9b537467f5df5dfcaf111e6434b16580fdf8d2d29f943c990ac014f2375abe` and debug dylib
`bc3b4fd78c67e8ac1ff9b3c2e65127caa37534a9f18a1902d3df942ec9452fe5`.
The coordinator launched this final binary separately, reopened the same fixture and confirmed
None/None/Blue with correct pending markers. All eight original artifact states/hashes remain
unchanged (`after-final-build-snapshot.json`). Normal Quit and inventory confirm all QA apps stopped.
This separates actual tested identities instead of assuming relinking preserved bytes.

The HTML checklist's A16 now explicitly compares empty and absent Label across write-mode restore
and relaunch. It remains a 31-case draft with no candidate assigned and human results unrun.
No broad plan checkbox closes and no final readiness notification is warranted. There is no
all-work blocker: the next bounded work is orientation, Metadata Review and remaining writer
completion, followed by the already inventoried feature and release gates. No-progress count is
zero; the existing automation remains active.

Final static checklist validation passes: 31 unique complete cases (16 agent, six user, nine
external), all case and updated planning links resolve, and `node --check` passes for the extracted
script. Visual HTML verification remains separately pending under the recorded local-URL policy
restriction; no browser route was used to bypass it.
