# Aagedal Photo Agent 3.0 known limitations

**Status:** release-candidate draft  
**Last reviewed:** 2026-09-22

These are material product and evidence boundaries, not a list of unfinished internal tasks.

## Analysis is evidence, not a verdict

- Metadata conflicts, C2PA state, residual patterns, edges, alpha, scopes, annotations, and timeline/map
  context can support an investigation, but none establishes that an image is authentic, manipulated, or
  AI-generated.
- Compression/residual views also react to ordinary recompression, sharpening, denoising, scaling, HDR
  processing, camera pipelines, and format conversion.
- C2PA validity and signer trust are separate. C2PA signing remains an experimental preview, and carriage
  of a credential into a new rendition does not prove the credential remains valid for that rendition.
- 3.0 does not ship an AI-origin model, automatic AI-artifact highlighter, clone/copy-move detector, or
  automatic sun/shadow consistency analyzer. The Meta and Google commands are external links, not local
  analyzers or integrations.

## Source, case, and report boundaries

- Cases and reports are tied to exact source bytes. Changed or unavailable source files can leave earlier
  evidence readable, but stale evidence is not silently rebound to different bytes.
- Analysis cases, map state, notes, and named versions are app-private JSON, not interoperable IPTC/XMP.
  On a read-only photo folder the app uses a local Application Support fallback that does not travel with
  the folder.
- A `.pint` project contains working-folder source images, matching XMP sidecars, and folder-local Photo
  Agent case/metadata/version documents. The archive manifest validates the payload before import, but it
  does not make the archive encrypted or independently attest the images' origin.
- PDF reports reproduce a frozen Photo Agent snapshot and disclose methods/limitations. They are not
  signed attestations, legal conclusions, or a substitute for preserving original evidence. Users remain
  responsible for sensitive-field and map inclusion choices.

## Maps and solar position

- Apple Maps and OpenStreetMap imagery can be unavailable, stale, incomplete, differently projected, or
  limited by network/service conditions. Reports may use a schematic fallback rather than licensed map
  imagery.
- Place search and reverse geocoding are suggestions, not proof of a photo location.
- Solar directions depend on the supplied coordinate, timezone-qualified time, fixed offset, and the
  disclosed calculation model. The overlay assumes a geometric/flat local horizon and cannot account for
  terrain, buildings, cloud, camera orientation, lens projection, edited pixels, or an incorrect clock.
  It does not inspect photographic shadows.

## Comparison and rendering

- Pan/zoom synchronization aligns normalized display coordinates; it is not feature matching or automatic
  registration. Wipe is a presentation layout, while a computed difference blend is deferred.
- Very large images, two RAW files, HDR/SDR display pairing, live Develop rendering, and external-display
  changes can increase memory or render latency. Target-tier performance budgets and hands-on display/GPU
  validation remain release gates and are not claimed by this draft.
- Color, alignment, keyboard-only, VoiceOver, upgrade/downgrade, and crash-interruption automation does not
  replace the open release-candidate manual validation passes.

## Reviewed automation publication

- Helper transcription-review presentation requires the running app and its matching signed helper.
  Copied, unsigned or differently installed peers refuse. `reviewRequired` acknowledges only a
  presentation request; exact intent is revalidated in the native UI, and consent remains unchecked.
  Helper start additionally requires a fresh exact native provider review, checked consent and
  **Allow Helper to Start Once**. Its session-only grant lasts 60 seconds and clears on provider
  changes, withdrawal, repeated review or dismissal. `executionRequested` confirms scheduling only;
  actual provider/device and broader signed lifecycle qualification remain unfinished. An exact
  linked operation handle does not prove executor liveness or completion.
- Native XMP publication requires a checked plan, dry run and separate session consent. It writes
  the sidecar and reconciles local history; helper clients cannot invoke physical publication.
- Interrupted or uncertain publication retains original/candidate recovery bytes and blocks further
  publication. Unchanged pre-write staging can be explicitly resolved after exact identity checks;
  identified partial writes can be explicitly restored after confirmation. Restoration refuses external
  changes, empty original app-history files and missing identity evidence. An empty original XMP file
  can be restored. A pre-receipt rename requires its exact retained generation; removal of an originally
  absent carrier requires an exact hidden recovery witness with the retained parent identity. Missing
  or replaced witnesses refuse restoration. Cleanup interruptions retain recovery until an explicitly
  reviewed retry completes. No automatic restoration runs.
  Completed recovery material lasts only until the next publication is staged; it is not permanent
  undo history. Original photo bytes are unchanged by this sidecar-only workflow.
- Template previews support filename, bounded request-order sequence variables and retained acyclic
  scalar/list `{field:key}` chains whose sources are unchanged by the template. Approved Keywords,
  other context variables and shared production template/face-scan/transcription executors remain open.

## Metadata and delivery interoperability

- Generated support tables describe Photo Agent's implemented read/write path. They do not claim current
  round trips through every Adobe Bridge, Photo Mechanic, HEIC/HEIF, RAW, or delivery-server combination.
- External tools can interpret metadata differently. Consult the
  [metadata support table](metadata-field-support.md) before relying on a particular carrier/write mode.
- Deadline Send supports staged SDR JPEG/TIFF and HDR Adaptive JPEG gain-map/16-bit TIFF derivatives only.
  Original-file and XMP-sidecar-only delivery are rejected.
- FTP/FTPS/SFTP protocol success and remote existence/size are non-cryptographic acknowledgements. SFTP
  supports password/netrc authentication, not SSH private keys, and a narrow local path
  time-of-check/time-of-use interval remains before `curl` opens a verified staged file.
- Persisted voice memos support explicit Caption playback and companion-preserving Duplicate,
  alongside ingest, transactional rename, companion-aware Move/Reject and recoverable memo Trash.
  Restore the entire Trash folder to retain its hidden relationship and metadata. New relationships
  retain photo/WAV hashes, and Caption can restore a missing adjacent WAV from an explicitly selected
  exact copy or confirmed replacement. Caption can also search a user-selected folder for an exact
  moved relationship; duplicate, changed and missing results are not adopted. Native validation of
  archive and reassociation breadth remains incomplete. Caption can explicitly use Apple on-device
  speech after an explicit language download, show an exact-WAV-bound read-only transcript, and persist
  generated provenance when transcription completes. Saved transcripts from Caption, Browser batches,
  or helper requests are ready for `{voiceMemoTranscript}` without review or approval. The variable
  revalidates the saved text and exact WAV identity before each metadata write; braces in transcript text
  remain literal. The supported Description, Extended Description, Headline and Instructions
  destinations are enforced. Processing variables starts directly; one invalid transcript or audio
  identity refuses the entire transcript batch before mutation. Native accessibility and relaunch
  workflow validation remain incomplete. Deadline profiles
  explicitly exclude WAV companions,
  include proven companions when available, or require one for every image. Included audio is
  exact-revision-bound, staged, verified, uploaded and recorded in privacy-safe receipts. Injected
  malformed/empty/finalization/install-cancellation and speech-language reservation-limit handling
  is covered, including explicit release-before-download recovery. Native/offline, authorized-Sony,
  relaunch application and real-server image-plus-WAV delivery evidence remain incomplete.
  Move/Reject stage verified copies before retiring originals; this requires temporary
  disk space and is not a process-crash-atomic multi-file operation. Physical cross-volume/recovery
  and broader camera workflows remain unverified. General Move reports separate XMP/editorial
  failures as partial success, and retained source backups are explicit cleanup warnings.
  Playback detects ordinary file-revision changes while loading and before starting. Persisted
  schema-1 relationships remain filename based; their selected WAVs cannot be called historical
  matches and require replacement confirmation before a schema-2 identity is recorded.
  Validation does not cover every Sony camera/firmware layout.

## Optional model availability

Face detection uses Apple Vision and face matching uses the optional packaged AuraFace CoreML model. A
build without that model reports face recognition as unavailable and must not advertise scans as working.
This is separate from the unapproved AI-origin analyzer described above.

## Local automation boundary

- The shared transcription batch backend accepts up to eight explicit photos and saves only
  previously absent transcripts. Existing saved drafts or human reviews are preserved.
  Caption now launches a captured Browser selection through explicit provider/language consent.
  Every target must have a supported WAV relationship, and targets sharing a metadata sidecar
  cannot be included together. Preparation refuses any existing saved transcript, and active/unsaved current reviews block launch. Source/WAV drift
  after confirmation refuses admission. Read-only rooted helper inspection now captures a saved
  adjacent WAV relationship and exact revisions, with bounded hashing and final drift checks.
  It refuses stale filenames and audio exceeding 256 MiB, reports historical content matches
  separately, and does not establish WAV decoding
  or provider readiness. Immutable helper batch previews additionally bind requested provider
  options and every photo/metadata/relationship/WAV revision for five minutes. They write private
  coordination storage only. Separate epoch-bound review requests retain that exact intent and
  can be inspected or cancelled in Automation Settings; the transcription archive retains at most
  64 records without automatic eviction. Inspection revalidates the plan and grants no consent.
  Internal admission now binds the original request, epoch, intent and reserved operation UUID;
  exact configured-operation linkage precedes scheduling, and interrupted admission cannot replay.
  Native Settings now connects the exact rooted provider/session binding to separate provider review,
  explicit consent and durable reserved-operation admission. Whole-set photo/metadata/WAV/relationship
  authority and original directory identities remain retained across recognition and anchored create-only
  draft installation. Only exact verified own transcript carrier generations advance the baseline;
  unrelated fields and unknown extensions remain preserved. Existing transcripts refuse admission,
  provider/locale/provenance drift refuses saving, and cancellation preserves saved prefixes. Closing
  Settings retains provider capacity until the owner confirms terminal completion. Preview expiry gates
  admission; it does not expire already consented recognition. Actual inference and offline/device
  behavior remain qualification gates. The archived managed-owner flag does not establish liveness.
  Native confirmed capacity cleanup retires only pre-admission cancellations and rotates the epoch;
  awaiting, admitted, linked and uncertain evidence remains retained. Stale confirmation refuses.
  Authenticated helper start consumes only an exact fresh one-use native grant; helper request
  values cannot supply consent. Native batch confirmation additionally binds the raw relationship
  bytes and inode/mtime/ctime revision, with a final check inside the create-only save lock. Native deterministic fixtures verify the
  integration, while real Apple/Whisper inference, cancellation and broader lifecycle qualification
  remain release gates.
  Durable per-photo history retains numbered outcomes, without source paths or text; it does not
  permit automatic replay or prove current executor liveness. Failed or cancelled batches can leave
  verified drafts saved. Uncertain writes retain recovery evidence and stop the unprocessed suffix.
  Operation archive schema 2 is required while batch records remain; older helpers refuse it.
  Legacy records remain readable, and removing the last batch record returns the archive to schema 1.

- MCP native review requests persist intent only. Selecting or retrying a request cannot grant
  consent; native review, approval and execution remain separate. Request and operation status
  do not prove executor liveness. Missing, removed or unverifiable linked history cannot confirm
  completion. A cancellation request may race successful completion; the recorded outcome wins.
  Resolved recovery is separate evidence and cannot turn an uncertain publication into success.
  Interrupted admission without a linked operation has unknown
  disposition and cannot be replayed. The private request archive retains at most 256 records without
  automatic eviction. Separate confirmed native actions remove requests cancelled before admission,
  or linked requests with exact matching terminal verified/failed/cancelled/stale operation evidence.
  XMP recovery/uncertain outcomes additionally require an exact retained completed restoration or
  unchanged-staging receipt matching the operation, plan, digest, disposition and current request timing.
  Only the current retained recovery journal can qualify; replaced or removed journals leave historical
  requests retained even if their operation keeps a recovery digest. Original outcomes, operation and
  recovery history remain retained. Cleanup rotates a
  durable epoch, refusing stale submissions and handles. Retained requests keep their original epochs;
  clients must never silently resubmit retired intents under a new epoch. Missing or mismatched history,
  active work, uncertain admissions, uncertain drafts and unresolved/incomplete recovery
  cannot be removed through these actions. A request cancellation recorded after its terminal operation
  evidence or exact recovery resolution conservatively prevents finished cleanup. Physical crash/link-loss, archive deletion/rollback and broader cloud qualification
  remain unfinished. Authenticated IPC and direct helper commits remain under implementation.
- Local MCP automation is off by default, uses a bundled STDIO helper, and opens no network listener.
  Only explicitly selected, unchanged folder roots are eligible. The current implementation exposes
  read-only capability/photo-input-format/root/path-admission, revision, owned-draft and effective editorial
  metadata tools. Effective reads accept one explicit photo per call and refuse malformed or oversized
  records without truncation. `prepare_iptc_patch` previews a bounded descriptive-field subset
  against exact read revisions, with before/proposed values and IIM compatibility warnings. It
  binds keyword changes to the exact local Approved Keywords list and effective settings,
  enforcing the editor's Strict policy and canonical spelling at preparation and native mutation.
  iCloud keyword-list authority is unsupported. Settings checks bind current values and a persisted
  generation from cooperating app writers; app changes away and back invalidate old plans. Legacy
  settings without recorded history remain explicitly untracked. Cooperating managed-list and
  settings writers now share reservations with native keyword publication through verification.
  Busy operations refuse before writing. Missing-list aliases share the same reservation, and
  path drift refuses the write. Arbitrary user-selected export destinations, raw preference/file
  edits, external cloud writers and physical power-loss durability remain outside this evidence. It
  retains an immutable local plan across helper restart for `get_iptc_patch_plan` to revalidate until its five-minute expiry. It does not
  persist a committable plan. `inspect_iptc_patch_publication_requirements` revalidates one retained
  plan and reports its exact native binding, target and review requirements, without staging a
  candidate, transporting consent, creating an operation/recovery record or granting write authority.
  It captures production normalization and preservation preflight
  evidence but does not execute or verify physical writes. Settings supports explicit local
  exact-plan approval and revocation within the review session; this cannot authorize an MCP
  commit in the current build. A separate native **Apply to Pending Draft** action consumes
  consent to save the exact changes in app-owned metadata history, preserving source and XMP bytes.
  It refuses photos selected in any metadata editor and private extensions the production codec
  cannot preserve. A verified `iptc_draft` operation confirms this draft only; physical publication
  still uses the normal metadata workflow. Opening or refreshing native Operation History uses
  retained process locks to mark abandoned new managed operations as recovery required. Live owners,
  legacy records and missing lock evidence are not inferred to have stopped. Recovery records remain
  protected from removal until an exact restored/unchanged receipt for that operation is reconciled.
  History preserves the original uncertain outcome and records recovery separately; resolved records
  may be explicitly removed without deleting recovery evidence. Legacy/unrelated records are not
  matched heuristically. Automatic replay/repair and broad interruption coverage remain unfinished. `get_operation_status` and `cancel_operation` expose these durable
  records with fresh automation authorization. Cancellation records a cooperative request. The native draft executor checks it before
  installation and verifies an already installed draft to completion. Other workflow executors
  remain unconnected. Per-owner lock files are retained to prevent lock identity reuse; pruning them
  requires a future coordinated cleanup protocol.
  Develop, face, template, transcription,
  execution coordination, and two-phase IPTC mutation tools are still release work and are not advertised by
  the server.
- Folder authorization limits Photo Agent, not the connected client's own filesystem or network access.
  Tool results can contain sensitive paths and editorial values. The
  connected client has its own privacy, retention, confirmation, and network behavior.
- The bundled helper and strict admission tests do not yet constitute native end-to-end evidence from a
  real MCP client. Cross-process GUI/MCP operation coordination, disconnect/relaunch/fault injection, and
  complete protocol coverage remain open release gates.

## Privacy and legal readiness

The repository contains a [3.0 privacy draft](../PRIVACY.md) and automated privacy checks. Runtime log
capture, filesystem-interruption/network-capture review, and external legal/privacy approval remain open
release gates; this documentation does not claim those reviews have occurred.

### Template compatibility

Template editors refuse stale file bytes or a replaced storage folder and retain the draft
for Save as New. Supported string, boolean, null, array and object extension values are
preserved in metadata templates and at the root of Develop templates. Unknown numeric
extensions and unsupported nested Develop settings refuse in-place saves rather than being
silently discarded. Save as New keeps supported fields in an independent template; the original
file remains unchanged. Template bundle exports still use the typed supported schema and are
not an archival backup of unknown extensions. Races with noncooperating external writers remain a separate limitation.

### Template automation and import authority

MCP template discovery supports explicitly authorized default local or custom Templates folders
with template iCloud sync disabled. It returns headers and content revisions, not complete
validated application plans. `preview_metadata_template` additionally provides read-only single-photo
previews for literal descriptive, people/creator/organisation, scene/subject, date, country, source-type
urgency, Media Topic, Genre and Image Supplier fields, bound to exact template/photo revisions. `preview_metadata_template_batch` supports
1–8 explicit photos with retained per-photo authority and no partial output. Duplicate/shared-sidecar
inputs are refused. `{filename}` is resolved from each retained photo for Headline, Description,
Extended Description and Instructions, alongside request-order sequence variables and bounded acyclic
retained scalar/list field references. Other contextual variables, Keywords, instant processing, unsupported
structured fields and batch application remain unavailable. No draft,
approval or physical write is created. A photo stored in the active Templates directory is refused by
the folder/photo reservation boundary. iCloud template stores, template application,
production executor integration and guarded IPTC commits remain separate implementation work.
Native XMP publication consent now has a separate exact-candidate/mode-bound foundation requiring
explicit C2PA and pending-draft acknowledgements in native review. Internal one-shot admission retains
original and candidate XMP/app-history bytes. An internal transaction now installs XMP through retained
directory descriptors, reconciles app history and verifies both carriers. It refuses pending Capture Date
changes and orientation drafts that it cannot publish. Native Publish Approved XMP runs this transaction
with separate consent and records verified completion; no helper commit endpoint exposes it. Interrupted
publication retains recovery material and blocks another publication until explicitly resolved. Completed
receipts remain until the next staged publication; they are not permanent undo history.
Signed Whisper release authorization persists and revalidates signed high-water evidence across
rollback. Internal install/update transactions now copy, hash and synchronize model bytes before committing
release state; rollback and lookup reverify retained bytes. Missing current or rollback-candidate bytes
can be restored internally under the existing authenticated ledger without selecting another release,
consuming rollback or lowering the replay floor. Verified-directory locks serialize cooperating
processes; external ledger deletion/restoration remains outside replay protection. Production signing
authority, catalog fetching and managed Settings integration remain unfinished; the shipped pinned-download
path has not switched to this lifecycle. Interrupted-install orphan cleanup and storage-failure qualification
remain open.
Template import preview authority detects changed inventory before writes and between entries;
it does not provide filesystem compare-and-swap against arbitrary noncooperating writers.
The bundled FFmpeg now includes Whisper with corrected canonical JSON escaping and sample-bound
timestamps. It is derived from Media Converter's attributed full build and retains image codecs;
nine synthetic image comparisons preserve exact decoded samples. Network/device features are
compiled in, while transcription restricts protocols to local files, uses exact private WAV snapshots,
and enforces cancellation/deadlines and canonical output validation. This protocol restriction is not
a general process sandbox. See [artifact provenance](provenance/ffmpeg-whisper-bundled.md).

Settings → Transcription offers explicit Tiny/Base/Small, multilingual Turbo/Large v3, and Norwegian NbAiLab downloads from a pinned immutable model
revision, with byte-count/SHA-256 verification, progress, cancellation, local installation and removal.
Checksum verification establishes that the downloaded bytes match the app's catalog; it is not a
signed update channel, independent model safety review or an accuracy guarantee. No speech, photo or
transcript is uploaded for inference. Models occupy local Application Support storage and are not
installed automatically. Signed catalog updates, rollback/recovery breadth and final offline/GPU
acceptance remain release work. Complete FFmpeg corresponding-source distribution, final signing and
notarized candidate validation also remain open.

Whisper produces unapproved editable drafts with model/build identity, requested language, translation
and GPU settings, exact segment text and normalized timing. Actual GPU execution depends on the
backend and model. CPU probes pass speech/silence and failure paths, but misrecognition remains possible;
review every draft. Complete blank-audio-marker segments are omitted from editable text while original
segment evidence is retained. Translated evidence uses provenance schema 2 and is refused by older readers.
Advanced custom executable/model selection stays in Settings → Transcription. Its file bookmarks persist,
while execution consent and artifact admission reset after quitting. Missing custom files require
reconnecting or reselection. Managed and custom preparation do not grant MCP execution authority;
provider discovery reports app-session readiness as unknown. See the historical
[output investigation](release/ffmpeg-whisper-json-evidence-2026-09-20.md).
