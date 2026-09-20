# Aagedal Photo Agent 3.0 known limitations

**Status:** release-candidate draft  
**Last reviewed:** 2026-09-15

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
  speech after an explicit language download, show an exact-WAV-bound editable draft, and persist
  generated/reviewed provenance only after explicit approval. Editing revokes approval, and
  incremental edits serialize toward the latest complete durable review before a photo or locale
  transition. The native review fixture verifies complete editing, relaunch and approval without
  changing the WAV or relationship bytes. The shared
  `{voiceMemoTranscript}` variable can place that reviewed text through an explicit template/variable
  operation and revalidates the exact approval before each metadata write; braces in transcript text
  remain literal. The supported Description, Extended Description, Headline and Instructions
  destinations are enforced, and a dedicated affected-image
  preview shows exact Append/Replace changes before confirmation; one invalid authority refuses the
  entire transcript batch before mutation. A disposable native fixture verifies Escape cancellation,
  Return confirmation, all four destinations and persisted metadata read-back after relaunch; this is
  narrow workflow evidence rather than a complete VoiceOver/accessibility gate. Deadline profiles
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

- Local MCP automation is off by default, uses a bundled STDIO helper, and opens no network listener.
  Only explicitly selected, unchanged folder roots are eligible. The current implementation exposes
  read-only capability/photo-input-format/root/path-admission, revision, owned-draft and effective editorial
  metadata tools. Effective reads accept one explicit photo per call and refuse malformed or oversized
  records without truncation. `prepare_iptc_patch` previews a bounded descriptive-field subset
  against exact read revisions, with before/proposed values and IIM compatibility warnings. It
  retains an immutable session-memory plan for `get_iptc_patch_plan` to revalidate. It does not
  persist a committable plan or evaluate physical write normalization/preservation.
  Develop, face, template, transcription,
  status/cancellation, and two-phase IPTC mutation tools are still release work and are not advertised by
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
validated application plans. iCloud template stores, template application,
operation status/cancellation and guarded IPTC commits remain separate implementation work.
Template import preview authority detects changed inventory before writes and between entries;
it does not provide filesystem compare-and-swap against arbitrary noncooperating writers.
The current FFmpeg artifact still lacks Whisper. Local-file protocol restrictions are implemented,
but binary replacement, full image regression, provenance/notices and the transcription/model
lifecycle remain open. The restriction is not a sandbox for other local files referenced by a container.

The original candidate Whisper filter wrote transcript text into JSON without escaping it.
An isolated full candidate with the pinned correction now builds and passes nine image comparisons
and initial CPU process/runner probes. It has not replaced the shipped artifact. The custom model
probe also exposed speech misrecognition and silence timestamps beyond input duration; accuracy,
timing, trusted models and final packaging remain open. A bounded process runner now uses exact private input snapshots,
WAV-only local decoding, cancellation/deadlines and canonical JSON validation. An explicit internal
provider adapter revalidates the WAV relationship and produces unapproved editable drafts with
persisted build/model identity, language settings and segment evidence. It requires artifact
authorization and is not yet connected to the transcription UI or model lifecycle. Complete blank-audio-marker segments are excluded from
drafts while original segment evidence is retained; real-model silence still needs validation. See the
[output investigation](release/ffmpeg-whisper-json-evidence-2026-09-20.md).
