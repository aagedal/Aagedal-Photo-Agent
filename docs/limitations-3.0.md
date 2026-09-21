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
  retains an immutable local plan across helper restart for `get_iptc_patch_plan` to revalidate until its five-minute expiry. It does not
  persist a committable plan. It captures production normalization and preservation preflight
  evidence but does not execute or verify physical writes. Settings supports explicit local
  exact-plan approval and revocation within the review session; this cannot authorize an MCP
  commit in the current build. A separate native **Apply to Pending Draft** action consumes
  consent to save the exact changes in app-owned metadata history, preserving source and XMP bytes.
  It refuses photos selected in any metadata editor and private extensions the production codec
  cannot preserve. A verified `iptc_draft` operation confirms this draft only; physical publication
  still uses the normal metadata workflow. The internal operation registry can mark a known stopped owner's
  unresolved work as recovery required, but executor-liveness detection and actual recovery
  integration remain unfinished. `get_operation_status` and `cancel_operation` expose these durable
  records with fresh automation authorization. Cancellation records a cooperative request. The native draft executor checks it before
  installation and verifies an already installed draft to completion. Other workflow executors
  remain unconnected, and crash/relaunch owner-liveness detection and recovery remain unfinished.
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
validated application plans. iCloud template stores, template application,
production executor integration and guarded IPTC commits remain separate implementation work.
Template import preview authority detects changed inventory before writes and between entries;
it does not provide filesystem compare-and-swap against arbitrary noncooperating writers.
The bundled FFmpeg now includes Whisper with corrected canonical JSON escaping and sample-bound
timestamps. It is derived from Media Converter's attributed full build and retains image codecs;
nine synthetic image comparisons preserve exact decoded samples. Network/device features are
compiled in, while transcription restricts protocols to local files, uses exact private WAV snapshots,
and enforces cancellation/deadlines and canonical output validation. This protocol restriction is not
a general process sandbox. See [artifact provenance](provenance/ffmpeg-whisper-bundled.md).

Settings → Transcription offers explicit Tiny/Base/Small downloads from a pinned immutable model
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
