# Voice memo archive and source reassociation design

Investigated 2026-09-10 against cycle-2 implementation `dfaf98e7` and its handoff.
This is a proposal, not implemented behavior or passing release evidence. The broader
[Sony lifecycle criterion](../journalistic-metadata-workflow-plan.md#sony-alpha-voice-memos--ingest-foundation-implemented-for-30)
remains open. The coordinator owns subsequent integration and validation.

## Actual archive paths

- `ContentView.archiveSelectedRAW(as:)` chooses a destination, acquires configured
  security scopes, calls `EditExportPipeline.renderItem`, optionally signs the output
  with C2PA, and only then adds it to the successful batch. Source RAWs remain intact.
- JXL and TIFF use `EditedImageRenderer.convertRAWTo16BitJXL` and
  `convertRAWTo16BitTIFF`; `ExportArtifactFinalizationService.finalize` then copies the
  authoritative XMP through `RAWArchiveService.copySidecarIfPresent` and ensures visibility.
- DNG uses an early branch in `EditExportPipeline.renderItem`:
  `AdobeDNGConverterService.convert` creates the DNG and copies XMP itself. Its later
  finalization request has `copiesRAWArchiveSidecar: false`. Extending only that Boolean
  path would silently omit voice memos for both DNG archive formats.
- All six formats choose names through `RAWArchiveService.uniqueDestinationURL`, which
  currently checks only image and XMP. The optional signing failure handler knows only
  archive image and archive XMP. It cannot safely clean up newly added memo artifacts.
- Archive rendering is a derivative operation. The repository's
  `copyImagePreservingCompanion` must not be called with a RAW source and a DNG/JXL/TIFF
  output: that API copies the source bytes as the destination photo.
- `EditedFolderBackupService` copies complete selected edited-folder directories. That
  preserves companions already present in those directories; it does not solve creation
  of a RAW archive's new association. Generic rendered export and Deadline delivery need
  their separately specified audio policies rather than implicitly inheriting archive policy.

## Proposed archive transaction

Use one archive-specific orchestration service for all formats, with injectable renderer,
signer, companion preparation, filesystem installation and cleanup. Keep blocking storage
work on a retained utility executor. Avoid further filesystem orchestration in the view.

1. Resolve only the source's persisted memo record. Missing, corrupt or unsupported records
   fail before conversion; absence means no association and must never adopt adjacent WAVs.
   Reject symbolic-link or nonregular audio for copying and preserve the source untouched.
   Freeze record bytes, source revision and memo SHA-256/size before rendering; revalidate
   before committing so edits during a long conversion cannot silently mix source revisions.
2. Reserve a complete destination name set: photo, XMP, hidden full-filename memo record,
   memo WAV when associated, and any editorial metadata carriers actually included. Check
   absent record destinations too, to prevent an unassociated archive adopting an orphan.
   Choose a fresh suffix for a collision; perform exclusive installation to close the later
   arrival race. Do not interpret a matching WAV hash as permission to reuse someone else's file.
3. Render into a private directory on the destination volume. Give the existing renderer
   that directory and arrange its source-stem output name to match the reserved final name.
   A directory argument alone is insufficient when collision suffixes differ: add explicit
   destination-name support or rename all owned staged carriers coherently before signing.
   Copy the source XMP exactly once for every format. Preserve the current same-folder
   shared-XMP contract deliberately; staging changes must not accidentally overwrite it.
4. Prepare a verified independent WAV copy even for a shared source RAW/JPEG memo. Write a
   fresh association with final archive image/memo filenames and the original profile ID.
   Copying must leave the source WAV and every source record intact. Do not increment an
   implicit cross-folder reference count or link the archive to source audio.
5. Complete metadata overlay and requested signing on the staged archive. Signing can change
   output bytes, so final destination identity is captured afterward. Signing must retain its
   real source as parent, not the private temporary path. Verify any URI/basename-sensitive
   signing behavior with the actual signing service before moving the result. A failed signer
   leaves no successful visible archive and cleans only operation-owned staged files.
6. Revalidate frozen source evidence, then install the completed photo/XMP/WAV/record bundle
   exclusively with same-volume renames. Record each successful installation. On failure,
   remove only those owned files; report every cleanup residual by exact path. Do not delete
   pre-existing XMP, JSON or WAV. Return a receipt including created artifact URLs and cleanup
   issues so a committed artifact is not misreported as absent after a later cleanup error.
7. Publish success to the Browser only after this boundary. Cancellation before installation
   discards owned staging; installation/rollback completes synchronously once begun. A series
   of file renames is not process-crash-atomic: retain the existing physical-volume/crash gate
   unless a recoverable manifest and startup recovery are implemented and exercised.

The current signing cleanup request's source-XMP inequality is not an ownership receipt.
Do not extend it to delete inferred WAV/record filenames after signing failure. Prefer a
common stage/sign/install transaction; if implemented incrementally, pass explicit owned
artifact receipts and preserve source/destination state when final ownership is uncertain.

For editorial JSON and future reviewed transcripts, preserve opaque extension fields and
explicitly update only destination source naming/identity through its serialized repository.
`MetadataSidecarService.moveSidecar` removes source carriers, so it is unsuitable for archive
copying. Decide archive editorial-copy policy before including those carriers; voice memo
relationship persistence alone must not be described as complete editorial-history copying.

## Source reassociation evidence boundary

`VoiceMemoCompanionRepository.reassociateRenamedRecords` already validates destinations
after the app's Batch Rename transaction moved photo, WAV and record together. Its lookup
can derive the renamed memo basename from the moved record's filename. This is the app-owned
rename case; it is not a general search/relink workflow.

The current schema-1 record contains only version, profile ID, image filename and memo
filename. It cannot prove that a separately found image or WAV is the original bytes.
`SourceImageDiscoveryService` supports current-path/resource-ID/content-hash hints, but
returns a located source only after comparing a previously persisted SHA-256. It also
returns ambiguous, changed and missing states. Its present production caller is
`DevelopVersionCatalogRepository.discoverSource`; no general memo locate/reassociate UI
exists. Develop catalog reassociation does not carry memo records.

Implement an explicit companion recovery service and Caption recovery action, with two
separate provenances:

- For a previously captured photo and memo revision, discover only within user-selected
  candidate locations. Exact bytes may reattach; ambiguous copies require an explicit choice.
  Changed bytes must not inherit old transcript approval or be called an exact reassociation.
  Refresh bookmarks/resource/path hints only after successful installation and read-back.
- For existing schema-1 records without prior content evidence, explain that original-byte
  identity is unavailable. Allow an explicit user-selected replacement audio association if
  product policy permits it; record that new provenance and clear/revoke dependent approvals.
  Do not retroactively hash today's file and call it proof of the historical association.

Prefer adding optional versioned identity evidence while preserving schema-1 compatibility,
or a dedicated identity extension in the app's existing serialized editorial sidecar, over
blindly replacing every record with a schema that the current decoder rejects. Freeze the
identity design with the transcript implementation: it also requires WAV hash provenance.
Preserve unknown fields and old records in migrations; never silently erase review history.

The repository requires an adjacent memo and image. When an explicitly selected memo is
elsewhere, make a verified independent adjacent copy with exclusive collision handling;
do not delete or move the selected original. Install the new record only after the copy is
complete. Preserve the old record on failure, report residuals, refresh the player, and never
autoplay. A pure Develop geometry reassociation must not automatically authorize memo relinking.

## Focused test and native verification hooks

Reuse `VoiceMemoCompanionCopyIO`, injected revision/hash snapshots, and fixture patterns in
`VoiceMemoCompanionRepositoryTests`. `EditExportPipelineTests` already has injected
`ExportArtifactFinalizationIO`, archive destination tests, worker/cancellation evidence,
and RAW security/signing cleanup probes; extend behavior tests rather than source-text checks.
Inject renderer/signing closures so most failure tests need neither a real RAW decoder nor
Adobe DNG Converter. The existing `SourceImageDiscoveryServiceTests` cover exact, ambiguous,
changed and missing matches; recovery orchestration still needs its own durable outcomes.

Required archive cases: all six routes; no association with orphan WAV/record destinations;
exclusive and shared RAW/JPEG memos; same folder and mirrored destination; every carrier
collision and late arrival; source photo/WAV/record changes during rendering; corrupt/newer
records; symlink audio; cancellation before/during conversion and commit; renderer/XMP/signing
failures; every install/rollback/cleanup failure; source bytes untouched; fresh archive lookup
after relaunch; complete receipt paths for residuals.

Required reassociation cases: exact move/copy; duplicate exact candidates; changed image or
memo; missing old identity; explicit replacement provenance; no automatic filename adoption;
foreign selected memo retained; adjacent destination collision; write/rollback failures;
cancelled picker/session; approval invalidation on changed audio; persistence and player
refresh after relaunch.

Coordinator native testing must use redistributable real RAW/Sony material when available,
exercise archive playback after source unavailability, and verify the actual DNG converter
path separately. Synthetic files and injected converter outputs prove transaction behavior,
not camera compatibility or decoding fidelity. Physical-volume recovery and actual signed
archive evidence remain separately open until observed.
