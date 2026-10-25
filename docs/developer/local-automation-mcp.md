# Local automation (MCP): developer reference

> **Experimental in 3.0.** Automation is off by default and limited to read-only inspection and
> previews. Anything that would change a photo waits for explicit approval in the app. See
> [known limitations](../limitations-3.0.md) for the user-facing summary and the
> [feature guide](../feature-help-3.0.md#connect-a-local-automation-client) for setup.

This page keeps the detailed tool contract that used to live in the README.

- A separately built, hardened-runtime `photo-agent-mcp` helper is bundled for local STDIO MCP clients;
  it does not listen on the network.
- Automation is disabled by default. Settings → Automation manages explicit folder grants and provides a
  copyable setup for Codex CLI, Claude Code, OpenCode 1.x, and OpenCode v2.
  Authorization refreshes shared preferences on every read, so persistent clients see revocation and
  fresh grant generations; failed refreshes or saves refuse authority.
- The current foundation exposes read-only server, photo-input-format, root, path-admission and photo-revision tools with strict canonical-path,
  identity, link, special-file, and private-store refusal. The helper shares photo/folder reservations
  with retained field, variable/template, Write All, Primary Develop and Batch Rename GUI execution. The helper
  discovers stable metadata/Develop template UUIDs, names and revision hashes with `list_templates`
  from explicitly authorized default local or custom template folders (template iCloud sync must be off).
  `inspect_develop_template` returns production-decoded controls and crop policy for an exact template
  UUID/revision, with destination-state and layer-identity requirements. Inspection grants no application
  authority. `preview_develop_template` compares saved destination controls with the template using
  exact photo revisions, crop policy and fresh ephemeral layer IDs. Decoder/as-shot state remains
  unresolved; Develop-template execution remains unavailable through MCP. Photo-revision inspection
  captures opaque source, XMP and owned app-sidecar tokens. `preview_metadata_template` previews a
  template for one photo using exact template and photo revisions, with Append/Replace
  behavior matching the editor for descriptive fields, creators, organisations, scene/subject codes,
  date, country, source type, urgency, Media Topic, Genre and Image Supplier. `preview_metadata_template_batch` extends the same preview
  to 1–8 explicit photos, retaining and revalidating every photo and returning no partial result. Both previews resolve `{filename}` from each retained photo in Headline, Description, Extended Description and Instructions. Other variables, Keywords, instant processing and unsupported
  fields are refused; it creates no draft or approval. `get_photo_metadata` returns bounded, typed
  effective editorial values with field provenance, pending/conflict state and those revision tokens.
  `prepare_iptc_patch` returns read-only, revision-bound normalized before/after values, exact inputs and compatibility warnings
  for supported descriptive fields, exact carrier hashes and preservation baselines. Keyword edits
  bind the exact local Approved Keywords list and settings, using
  the editor's Strict policy, canonical spelling and duplicate handling. iCloud keyword lists
  are not yet supported by patch previews. `get_iptc_patch_plan` revalidates the retained preview
  and keyword authority. These expiring read-only plans survive helper restart in a bounded
  private local archive but cannot be committed by MCP. `get_native_review_request_capacity` explicitly
  initializes or migrates request coordination storage and returns its durable `requestEpoch`.
  `request_iptc_patch_review` queues a durable request with that epoch, a new lowercase UUID
  `requestID`, the `planID`, and purpose `pendingDraft`
  or `xmpPublication`. In Settings → Automation → Show Client Review Requests, refresh and inspect the
  request, then explicitly approve and apply it. `get_native_review_request` reports the retained
  intent, linked operation ID and matching retained outcome; unavailable history stays explicitly
  unconfirmed. Settings shows these outcomes and lets you request cancellation during execution.
  `cancel_native_review_request` cancels before admission or requests
  cooperative cancellation of linked work. Status, cancellation and exact retries retain the original
  epoch and request ID across helper restart;
  requests grant no consent and interrupted admission is never replayed. This private archive retains
  at most 256 requests without automatic eviction. Settings can explicitly remove requests cancelled
  before admission, or separately remove linked requests whose exact retained operation confirms a
  finished outcome, and rotate the epoch. Cleanup preserves operation and recovery history. Active,
  admitted, uncertain and missing-history requests remain retained. An uncertain XMP operation is
  eligible only with an exact matching retained receipt for completed restoration or unchanged staging;
  missing, replaced or incomplete recovery evidence keeps the request retained. Removed intents
  cannot be retried; clients must never silently resubmit them under a
  new epoch. Retained requests keep their original epochs. Settings can explicitly apply an approved
  plan to a pending local draft after the photo is deselected in all editors, preserving the photo
  and XMP. Template application, face scans and physical photo mutation tools remain
  under implementation for 3.0; transcription start uses the separate native grant below.
  `list_operations` discovers up to 256 retained local operation handles after reconnect, with compact
  summaries and unknown executor liveness. History includes native and helper-linked operations;
  it is shared by the local automation authority, rather than scoped to a client or folder.
  `get_operation_status` and `cancel_operation` expose durable coordination records and cooperative
  cancellation requests. The native pending-draft executor is connected with distinct `iptc_draft`
  outcomes. Available transcription batch status includes ordered per-photo outcomes without paths
  or transcript text. Saved transcripts are ready for metadata variables; failed or cancelled batches can
  retain a saved prefix. Caption launches the shared batch backend after explicit native consent;
  helper transcription invocation remains unfinished. A request is not completion.
  `get_photo_voice_memo` inspects one photo's saved adjacent WAV relationship under the authorized
  root and returns exact relationship/audio revision evidence. It does not expose audio or transcript
  content, decode WAVs, inspect provider readiness, or start transcription.
  `prepare_voice_transcription` retains an immutable five-minute preview for one to eight explicit
  photos and requested provider options. `get_voice_transcription_plan` rechecks every photo,
  metadata, relationship, WAV and root grant before returning it. Preparation writes private
  coordination storage; neither tool grants consent, starts inference or saves drafts.
  Separate epoch-bound transcription review requests can be queued, inspected and cancelled through
  MCP, then revalidated in Settings → Automation → Transcription Intent Review. Photo order and
  requested provider options remain exact. Settings can separately review the exact selected native
  provider, locale/model/runtime and options, then start one durably linked operation after explicit
  consent. Whole-set rooted reservations and identity checks span recognition and verified create-only
  transcript saves. Existing transcripts refuse admission; cancellation preserves saved drafts. Closing
  Settings does not stop admitted work, and linked requests never replay. Helper tools can request
  cooperative cancellation and inspect the linked operation.
  `open_voice_transcription_review` asks the running app to open one exact original request/epoch.
  A private local socket authenticates both processes against the matching signed app/helper pair.
  The app repeats whole-set validation and the native UI clears previous execution consent.
  `reviewRequired` acknowledges a presentation request only; an already linked request returns its
  exactly matched operation handle without claiming completion. No provider consent or execution
  authority is supplied by the helper. Copied, unsigned, mismatched, stale and unavailable peers refuse.
  After exact native provider review and checked consent, **Allow Helper to Start Once** enables
  `start_voice_transcription` for that request for 60 seconds while the review stays open.
  The app consumes this session-only grant once and schedules guarded admission; `executionRequested`
  confirms scheduling, never durable admission, inference or completion. Provider changes, consent
  withdrawal, dismissal and repeat review revoke the grant. Exact linked retries return the original
  operation handle without starting again. Saved drafts still require separate caption approval.
- `create_team` adds a team with a complete numbered roster to the Teams library. Enable
  **Allow team creation** in Settings → Automation as well as local automation. With Teams iCloud
  sync on, the request stays local until you open **Teams → Review Imports**, review the roster and
  choose **Add Team** or **Reject**. Approved imports use the app’s coordinated iCloud storage;
  unavailable iCloud leaves the request pending. Retry the same MCP call to check its
  `awaiting_confirmation`, `accepted`, or `rejected` status. A connected AI client can research this week's team sheets using its own web tools,
  then submit the team name, sport, kit colours and players. The helper itself does not browse.
  Supply a client-generated `teamID` UUID and reuse it with the same content on retries. Creation
  never replaces existing teams, assigns teams to a match, or links players to Known People.
  Player numbers must be unique integers from 0 through 9999. Unknown names, numbers and colours
  should be verified from a reliable source before submission.
- **Settings → Transcription** selects **Apple Speech**, **Whisper** with embedded FFmpeg,
  or advanced **Custom FFmpeg Whisper**. Download Tiny, Base, Small, multilingual Turbo or Large v3 explicitly in the app;
  installed models are checked against pinned size/SHA-256 before use. Inference stays local,
  and Caption retains compact playback, Transcribe and review controls. Language, English translation
  and GPU request settings persist and are recorded in each editable draft. Custom files still require
  explicit session execution consent. Provider discovery does not expose transcription execution to MCP.

## Tool reference from the feature guide

The server exposes read-only capability, photo-format, metadata-field, authorized-root, path-admission, revision, owned-draft,
and effective metadata tools. Call `list_metadata_fields` to discover the stable editorial JSON keys,
typed value shapes and read limits. This catalog contains no photo values and grants no write authority.
Call `get_photo_metadata` with one absolute `path` to read the same effective
editorial values selected by Photo Agent, including per-field carrier, pending/conflict state and captured
revision tokens. These tokens describe that read and do not authorize a later write. It rejects
relative/traversal paths, symlinks, Finder aliases, hard links, special files, changed folder identities,
Photo Agent private folders, and targets outside the selected roots. Unreadable carriers and oversized
metadata records fail as a whole. Face scan, template application, transcription, and IPTC mutation tools are not yet
exposed. Returned paths and metadata values can be
sensitive and are subject to the connected client's privacy and retention policy.

Call `get_photo_voice_memo` with one absolute photo `path` to inspect its saved adjacent WAV
relationship. It returns revision evidence for the photo, relationship and audio, with the WAV
length. An adjacent WAV without a saved relationship is not discovered automatically. Unsafe,
missing, unsupported, stale or oversized inputs are refused; automation limits are 1 MiB for the
relationship record and 256 MiB each for audio and photo bytes.
This inspection does not return audio
or transcript content, verify audio decoding, check provider readiness, or start transcription.
It requires a relationship bound to the current photo filename; recover renamed relationships in
the app first. Historical recovery identities are reported separately from the captured current
revisions; an ordinary photo edit can change the historical comparison.

Call `prepare_voice_transcription` with an ordered `photos` array of one to eight entries.
Each entry supplies `path` and the exact `sourceRevision`, `appSidecarRevision`,
`xmpSidecarRevision`, `relationshipRevision` and `audioRevision` returned by
`get_photo_voice_memo`. Supply `provider` (`appleSpeech`, `whisper` or `customWhisper`),
`language`, `translate` and `useGPU` explicitly. Apple requests use a locale such as `en-US`
with both booleans false; Whisper requests use `auto` or a supported language identifier.
Provider availability and installed/custom model identity must still be checked in the app.
The tool writes only a private, immutable preview and returns a `planID`, valid for five minutes.
`get_voice_transcription_plan` accepts only that `planID` and returns the unchanged preview after
rechecking every input and folder grant. Changed or expired plans require a new preparation.
Neither tool runs inference, downloads assets, saves drafts, approves text or grants consent.
To request native intent review, call `get_voice_transcription_review_capacity` without arguments
for the transcription-specific `requestEpoch`, then `request_voice_transcription_review` with that
epoch, a client-generated lowercase canonical `requestID`, and the `planID`. Reuse all three for
an exact retry. New requests revalidate the whole ordered set while retaining its reservations;
retries retrieve retained status even after the preview expires. These are separate from IPTC
review handles. `list_voice_transcription_review_requests` takes no arguments;
`get_voice_transcription_review_request` and `cancel_voice_transcription_review_request` accept only
`requestID` and its original `requestEpoch`.

To open that exact request, call `open_voice_transcription_review` with its original `requestID`
and `requestEpoch` while the matching signed Photo Agent app is running. The app and bundled helper
authenticate their private local connection. `reviewRequired` acknowledges the presentation request;
the native UI independently revalidates and clears prior execution consent. An already linked request
returns its exact operation ID for separate status inspection. Unavailable, copied or mismatched peers
refuse. The tool cannot consent, start transcription, change providers or approve text.

In **Settings → Automation → Transcription Intent Review**, refresh requests and choose
**Inspect Transcription Intent** to revalidate the preview and display photo order and requested
provider/language/translation/GPU options. **Cancel Before Admission** retains a cancelled intent.
Changed or expired previews cannot be inspected, but their request remains cancellable. The archive
retains at most 64 requests without automatic eviction. Inspecting supplies no provider consent.
Configure the matching provider and options in **Settings → Transcription**, then choose
**Review Selected Provider** in the intent review. For Apple Speech, enter the exact installed
locale. The review displays that locale or the exact Whisper runtime/model paths, hashes and options.
It downloads nothing and requests no permissions. Check the explicit consent box, then choose
**Start Confirmed Transcription**. A mismatch, existing transcript or changed input refuses admission.
The confirmed operation saves transcripts in order, ready for metadata variables; IPTC stays unchanged.
Closing Settings preserves admitted work. Request cancellation in the active workflow or from its
retained request after reopening Settings; use the linked operation ID to inspect actual completion.
A cancellation request is not confirmation of teardown. Saved drafts survive a later cancellation or
failure. Linked and interrupted admissions cannot be replayed.

To start the same reviewed request from the helper, check native consent and choose
**Allow Helper to Start Once**, then call `start_voice_transcription` with the original
`requestID` and `requestEpoch` within 60 seconds. Keep the review open. The one-use grant
is stored only in the running app; provider changes, consent withdrawal, dismissal and
another accepted review presentation revoke it. Helper-supplied consent is refused.
`executionRequested` confirms grant consumption and scheduled guarded admission, not
durable linkage or completion. Inspect the retained request and operation status to
confirm admission and actual outcomes, including after a lost response. Exact linked
retries return the original operation ID without starting work again.
Choose **Review transcription request capacity** to see the retained count and eligible
cancellations, then **Remove cancelled transcription requests** and confirm to retire only
requests cancelled before admission. Cleanup rotates the current epoch and preserves awaiting,
admitted, linked and uncertain evidence. Retained handles keep their original epochs; removed
intent cannot be retried with its old epoch. A changed confirmation epoch refuses cleanup.

After reconnecting, call `list_operations` with no arguments to recover retained operation handles.
With automation enabled, it returns at most 256 compact summaries, newest-created first. This is
shared local history including native and helper-linked operations, rather than a client or folder
filter. Paths, transcript text, recovery receipts and per-photo progress are omitted; inspect an
explicit handle for details. Discovery performs no recovery or cleanup and does not prove that a
recorded executor is alive or that interrupted work can be replayed.

`get_operation_status` and `cancel_operation` accept one `operationID` UUID with automation enabled.
They inspect durable coordination records and request cooperative cancellation. A request does not
mean the executor has stopped: inspect `state`, `outcome`, and `cancellationRequested` separately.
Available `batchProgress` contains completed counts and ordered photo indices/states/outcomes,
without paths or transcript text. A saved transcript is ready for metadata variables,
with IPTC unchanged. Failed or cancelled batches can retain saved drafts; inspect each outcome
before retrying. Uncertain saves retain recovery evidence. Executor liveness is reported as unknown.
These endpoints do not start work or authorize photo writes. Batch transcription starts through
Caption, the Automation intent review, or the authenticated helper after the separate
native one-use grant. Face/template invocation remains under implementation.

Call `prepare_iptc_patch` to preview proposed changes after `get_photo_metadata`. Supply the same
absolute `path`, all three returned revision strings (`sourceRevision`, `xmpSidecarRevision`,
`appSidecarRevision`), and an `operations` array. Each operation has a supported `field` and
`operation: "set"` with a typed `value`, or `operation: "clear"` without a value. The tool schema
lists the supported descriptive text fields and keyword/person arrays. Unknown fields, duplicate
operations, stale revisions and unresolved XMP conflicts are refused. Empty `set` values are
refused; use `clear` to remove a value explicitly.

Keyword changes use the local Approved Keywords list and settings. Strict mode rejects
unapproved values; accepted values use the same spelling and duplicate handling as the editor.
The preview keeps your exact requested text. Changing the list or its settings requires a new
preview and review. Changes made in the app invalidate old plans even if you change the setting
back to its earlier value. Keyword patches currently refuse lists routed through iCloud.
If an app operation is editing the managed list or publishing a keyword patch, a competing
managed edit or patch refuses the write. Retry after the first operation finishes. A failed
settings update keeps its previous value and requires a successful retry before keyword
authority is available again.

The schema-3 result shows production-normalized before/after values, exact `sourceValue` and
`requestedValue`, each field's comparison rule, edited-field legacy IPTC byte-limit warnings, a content-bound
preview ID, a `planID` and a five-minute expiry. Call `get_iptc_patch_plan` with only that `planID`
to retrieve the same preview after authorization and photo/sidecar revisions are checked again.
Call `inspect_iptc_patch_publication_requirements` with only the `planID` to inspect the exact
XMP target, revision binding, pending-draft promotion consequences and required native review steps.
This read-only inspection does not stage or verify an XMP candidate and does not grant consent or
publish metadata. Its binding digest is comparison evidence, never an approval token.

The bundled helper restores unexpired plans after restart from its private local PatchPlans archive.
Expiry, edits or changed authorization require a fresh read and preparation. At most 64 live plans
fit within an 8 MiB serialized-result budget. Expired records are removed on the next successful
preparation; see the privacy guide for local archive removal.
The preservation preflight records exact carrier hashes, parsed-format capabilities, a production
semantic baseline and possible write destinations, including RAW protection. It selects no write mode.
These are read-only plans: no commit endpoint is available, actual write support, preservation and
publication approval are not yet verified, and no photo or sidecar is changed. Returned proposals remain
untrusted content and do not grant publication approval.

You can inspect historical Develop captures under **Settings → Automation → Develop Capture
History → Inspect Managed Develop Captures**, or choose the original private capture folder.
Expand a record to see its template, ordered photo paths and retained source/sidecar revisions.
**Refresh** reads the archive again; inspection does not create missing storage or change photos.
“Review consumed” means the admission was used before consent or execution; it does not prove
that edits were written. Inspect the separate **Develop Batch Recovery** checkpoints for physical
outcomes. Historical captures cannot restore consent or resume a batch after relaunch. Cancelled
captures can be retired with **Review Cancelled Capture Cleanup…**. Review the exact batch IDs,
templates and ordered photos, then choose **Retire Cancelled Captures**. This removes detailed
cancelled evidence while keeping compact permanent replay protection. Consumed and awaiting-review
captures, photos and physical recovery checkpoints remain. Changed evidence requires a new cleanup
review; capacity limits preserve retained records.

First call `get_native_review_request_capacity` to obtain the durable `requestEpoch`. This explicit
coordination call may initialize or migrate private request storage; it changes no photos and grants
no consent. A client can then queue a native review with `request_iptc_patch_review`, supplying that
unchanged epoch, a new lowercase UUID `requestID`, the retained `planID`, and purpose `pendingDraft`
or `xmpPublication`. Open
**Settings → Automation → Proofreading Plan Review → Show Client Review Requests**, then
**Refresh Review Requests** and **Inspect Requested Plan**. This rechecks the current plan and
clears any earlier approval. Review and explicitly approve the requested action; requests do not
provide consent. You can also **Cancel Review Request** before admission. Linked requests show
the last recorded operation outcome and separate recovery resolution. **Request Cancellation**
remains available while work runs, including when operation confirmation is unavailable.
Cancellation is a request; wait for the recorded outcome before assuming work stopped.

`get_native_review_request` returns durable request status and, after native admission, its exact
operation ID and a matching operation snapshot when retained. `operationStatus` reports
`available`, `confirmation-unavailable`, or `not-linked`; `operation` is null when no matching operation record can
be confirmed. Recovery resolution remains separate from the original publication outcome.
`get_operation_status` also exposes this evidence. Retry with the original request epoch, request ID
and identical plan/purpose to retrieve status after helper restart. Supply the original epoch to
`get_native_review_request` and `cancel_native_review_request` too; omit it only for retained legacy
epochless requests. `cancel_native_review_request` cancels an awaiting request
or requests cooperative cancellation of linked work. An unknown admission cannot be replayed;
inspect operation history and recovery before preparing another request. The archive retains up to
256 requests without automatic eviction, including cancelled requests. In the client request section,
choose **Review request capacity**, then **Remove cancelled review requests** and confirm to remove
only requests cancelled before admission. Cleanup clears current native review consent and atomically
rotates the epoch. Alternatively, choose **Remove finished review requests** and confirm to remove
linked requests with exactly matching retained terminal outcomes of verified, failed, cancelled or
stale. A failed or stale outcome does not mean metadata was published. Operation kind and timing must
match the request; missing, mismatched or older evidence cannot permit removal. Operation and recovery
history remains available. An XMP request with a recovery or uncertain outcome is also eligible when
its operation records the exact retained receipt for completed restoration or unchanged staging,
with matching plan, operation, disposition, digest and timing. The original outcome remains unchanged;
cleanup does not establish successful publication. Missing or replaced receipts, unresolved or incomplete
recovery, uncertain draft outcomes, active work and uncertain admissions remain retained. Only the
current retained recovery journal can qualify; a historical digest alone is insufficient. Both confirmations bind
the capacity epoch you reviewed and clear current native consent. Retired requests cannot be retried;
clients must never silently submit them under a new epoch. A separate new intent needs a new request
ID and the current epoch. Retained retries keep their original epoch even after cleanup. If a full
archive has no eligible cancelled or finished requests, it remains full. The helper's capacity tool
reports pre-admission cancellation eligibility only; finished eligibility requires native inspection.

To inspect a plan in Photo Agent, open **Settings → Automation → Proofreading Plan Review**,
paste its exact `planID`, and choose **Inspect Plan**. The app rechecks the current authorization
and photo/sidecar revisions on a background worker before displaying normalized before/proposed
values and warnings. Repeatable values use quoted lists to preserve item boundaries. Changing the
ID or leaving the view clears the displayed review; expired plans require fresh preparation.
After reviewing all changes and warnings, **Approve Reviewed Plan** rechecks the exact files and
authorization and records consent for this review session. **Revoke Approval**, **Clear Review**,
changing the ID or leaving the review removes that consent. Approval writes no photo metadata;
direct MCP commit remains unavailable. The displayed values are a checked snapshot, not live monitoring.

**Verify XMP Dry Run** builds a temporary XMP sidecar using the production writer, checks every
writable editorial value and the parsed unrelated/Develop properties, then rechecks the plan and
live carriers. It removes the temporary candidate and shows the proposed destination and verification
details. Starting a dry run revokes any existing approval. Pending values outside the patch are included
and explicitly disclosed. This check does not approve publication or save beside the photo; embedded
writes, arbitrary XML extension preservation, C2PA trust and recoverable installation remain separate.

After a successful dry run, **Approve XMP Candidate** records separate consent for those exact candidate
bytes. Read the publication consequences and acknowledge C2PA/preservation limitations; when the candidate
includes pending draft values, their promotion needs its own acknowledgement. Clearing, leaving,
expiry, withdrawing an acknowledgement or granting a different approval revokes this consent. The
approval itself changes no files. **Publish Approved XMP** then rechecks authority and revisions,
publishes the checked XMP sidecar, reconciles local metadata history, and verifies both carriers.
Deselect the photo in all metadata editors first. Successful completion is retained in operation
history and permits a newly reviewed publication. If publication is interrupted or uncertain,
original and candidate recovery bytes remain protected and block later publication. Use
**Inspect Retained Recovery** under **Interrupted XMP Publication**. For older records, enter the
original photo path. **Resolve Unchanged Staging** is available only when the original photo, XMP
and app-history identities are still unchanged. It rechecks them and retains a separate receipt;
it changes no live metadata. When retained publication identities still match, **Restore Original Metadata…**
offers a separate confirmation for the inspected photo. It restores the original XMP and app history,
removes metadata files that were originally absent, and retains a restoration receipt. Deselect the
photo in all editors first. External changes, missing identity evidence and empty original app-history
files remain blocked. An originally empty XMP file is recreated as an empty file. If interrupted,
inspect again: restoration can resume from a durable receipt or an exact retained file generation.
Removing an originally absent metadata file retains a hidden recovery copy until restoration and
cleanup are verified; a missing file alone cannot prove that removal succeeded.
Original photo bytes are unchanged by these sidecar-only actions.

After approval, **Apply to Pending Draft** saves the exact reviewed changes into Photo Agent's
local `.photo_metadata` history. First finish or discard editor changes and deselect the photo
in every Photo Agent window. This action consumes the approval, rechecks authority under the
photo reservation, preserves the source and XMP bytes, and verifies the saved effective values.
It refuses unsupported private extensions before replacing the draft. Review and publish the
pending draft through the normal metadata workflow; this action grants no physical-publication approval.
The result includes an operation ID with kind `iptc_draft`. A verified result means the local draft
was verified. Cancellation before saving leaves it unchanged; a cancellation arriving after installation
does not undo a verified draft. An uncertain result requires inspection before retrying.

Settings → Automation → **Operation History** lists retained outcomes and provides **Refresh**,
**Request Cancellation**, and confirmed removal of completed records. Removing a record does not undo
metadata changes or delete a pending draft. Records with uncertain effects remain protected until
their exact restoration or unchanged-staging receipt is reconciled. History keeps the original
publication outcome and shows the separate recovery result; restoration does not mark publication
verified. Refresh retries this handoff after a crash or a history-storage failure. A resolved record
can then be removed explicitly without deleting its retained recovery receipt.
Opening or refreshing history checks process locks for new managed operations: if the owning process
has stopped, unfinished work becomes **Recovery required**. Inspect the affected photo and pending
metadata before retrying. No operation is automatically replayed or repaired; older records without
owner-lock evidence remain unresolved.

Settings → Automation → **Develop Batch Recovery** provides **Review Managed Develop
Recovery** for the app's retained checkpoint location, or **Choose Develop Recovery
Folder…** for an original private checkpoint folder. Refresh preserves the evidence
and reports an empty managed location without creating storage. Expand an entry to
review ordered photos, physical write receipts and unresolved effects. This inspection
does not check current photo bytes or authorize applying edits again.

The browser face-scan button's context menu offers **Review Authorized Face Scan…**. Enable
local automation and authorize the current folder in Settings first. **Prepare Current Folder
Face Scan** checks the installed model and lists the exact immediate photos without starting work.
Choose incremental or full scanning and optional jersey recognition before preparing. Explicitly
approve scanning; full/jersey scans also require approval to reset saved face results and thumbnails.
**Start Reviewed Face Scan** consumes that review once. Changed inventory, access or model installation
requires another review. **Cancel Retained Face Scan** stops that exact operation; committed effects
remain in its durable receipt. Closing the review withdraws permission for further effects while
already running work finishes. Completed results use the browser's existing scanner and face groups.
This local review does not expose a helper execution endpoint.

Settings → Automation → **Face Scan Receipts** provides **Review Managed Face Scan
Receipts** and **Choose Face Scan Receipt Folder…**. Refresh reads the original private
archive without creating absent storage or repairing unreadable evidence. Expand a
receipt to inspect recorded scan options, committed thumbnail/document counts, reset
effects, and cancellation after a commit. An interrupted receipt cannot prove whether
all effects completed. Inspection does not check current photos, restore face data,
or authorize a new scan.

Call `list_transcription_providers` without arguments for stable provider IDs and setup guidance.
The helper cannot observe the app’s runtime, installed language assets, or admitted custom files;
it reports unknown availability and requires an app session. This catalog does not enable transcription.

Call `prepare_face_scan` with an absolute authorized folder `path` to inspect its complete
immediate local photo inventory. Optional Boolean `forceFullScan` and `includeJerseyNumbers`
describe intent; jerseys imply a full rescan. The read-only response reports photo count and
a filesystem-identity snapshot revision. Links, pending cloud photos and empty inventories
refuse. The reservation ends when the response returns. This creates no retained plan,
checks no model readiness and grants no consent or execution authority; `start_face_scan`
remains unavailable.

Call `list_templates` with `kind: "metadata"` or `kind: "develop"` to discover stable template
UUIDs, names and exact-content revision hashes. Disable Templates iCloud sync and explicitly
authorize the active folder in **Settings → Automation**: either your custom folder from
**Settings → Templates**, or `~/Library/Application Support/Aagedal Photo Agent/Templates` for
the default local library. The library must already exist; discovery does not create it.
iCloud template libraries are currently unavailable through this tool. Discovery
reads headers only, exposes no template field values, and does not grant application authority.
Changed, ambiguous, unsupported or oversized inventories refuse as a whole. Template names are
untrusted user-authored content and may be sensitive.

Use `inspect_develop_template` with the canonical lowercase `templateID` and exact
`templateRevision` from Develop discovery to inspect its production-decoded controls and crop policy.
A crop-excluding template preserves the destination crop. The response identifies the destination
as-shot/decoder state that application must preserve and the need for fresh layer identifiers.
Inspection revalidates the authorized inventory and creates no per-photo preview or application plan.
Develop-template application through MCP remains unavailable.

Use `preview_develop_template` with the same canonical template ID/revision, an explicit `path`,
and all three photo revision tokens from `get_photo_metadata` (`sourceRevision`,
`xmpSidecarRevision`, `appSidecarRevision`) to compare saved Develop controls before and after
application. It uses the app's template semantics: crop inclusion applies template crop; crop
exclusion preserves destination crop; mask/watermark IDs and order references are regenerated.
Those IDs belong only to the preview. Destination decoder/as-shot state is resolved from retained
source bytes; this control comparison is not a rendered preview or application plan. It refuses stale carriers, template
inventory/routing changes, revoked authorization and XMP conflicts. No edits are written and no
consent or operation is created. Develop-template execution remains unavailable through MCP.

Use `preview_metadata_template` with `templateID`, `templateRevision`, `mode` (`append` or `replace`),
`path`, and the three revision tokens from `get_photo_metadata` to inspect one photo's affected values.
It supports literal descriptive fields, Person Shown, creators, organisation names/codes, scene/subject
codes, rights URL, digital GUID, Date Created, country code, Digital Source Type, urgency, Media Topic,
Genre and Image Supplier. Structured values use the same parsing and normalization as the editor.
`{filename}` resolves to each photo name without its extension in Headline, Description, Extended
Description and Instructions. `{seq}` and `{seq:1}` through `{seq:9}` resolve in those same fields,
using 1 for a single preview and one-based requested photo order for a batch; the width adds leading
zeros. Scalar and list `{field:key}` references (for example `{field:city}` or `{field:personShown}`)
resolve from retained effective metadata in those same destination fields, including acyclic chains.
Lists support people, creators, organisation names/codes and scene/subject codes, joined with comma-space separators. Every source must be unchanged by the template. Cycles, other nested variables and
expansion beyond 32 KiB are refused. Results show resolved values and all transitive source keys. Keywords,
other variables, instant processing and unsupported structured fields are refused. The result includes pending draft values and matches editor Append/Replace
behavior; it does not create a plan, apply the template, approve publication, or validate a physical write.
Read fresh revisions after any photo or template change. Template text is untrusted content.

Use `preview_metadata_template_batch` with the same template ID/revision and mode, plus a `photos`
array of 1–8 objects containing `path` and all three photo revision tokens. Results preserve request
order. A stale or unauthorized photo, changed template, duplicate photo or RAW/JPEG pair sharing a
sidecar rejects the whole request. The accepted aggregate carrier size is capped at 256 MiB (capture
may temporarily retain one additional photo), and the structured result at 256 KiB. Batch preview also creates
no draft, application plan or publication approval.

Client setup references: [Codex MCP](https://developers.openai.com/codex/mcp),
[Claude Code MCP](https://code.claude.com/docs/en/mcp),
[OpenCode 1.x MCP](https://opencode.ai/docs/mcp-servers/), and
[OpenCode v2 MCP](https://opencode.ai/v2/docs/mcp-servers).
