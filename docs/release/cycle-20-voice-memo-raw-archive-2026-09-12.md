# Cycle 20 — transactional RAW voice-memo archive

**State:** COMPLETE for the code-level RAW archive preservation slice and automated verification.
Overall 3.0 readiness remains **IMPLEMENTING** because source reassociation, authentic-media/native
archive validation, transcription/delivery and broader release gates remain open.

## Source and scope

- Implementation commit: `3a49c0e` on `main`, based on cycle-19 checkpoint `7917eb1`.
- All six RAW archive commands—linear/camera JPEG XL, linear/camera TIFF and lossless/lossy DNG—
  now use one `RAWArchiveTransactionService` around the existing renderer and optional signer.
- This slice creates an independent archive memo and relationship. It does not move, relink or
  otherwise change the source image, source memo or source relationship.
- Generic Save As, edited-folder backup, Deadline delivery and source reassociation retain their
  separately specified policies and are not silently broadened by this change.

## Transaction boundary

The service runs synchronous storage work on a retained utility executor and creates a mode-0700
staging directory on the destination volume. Before rendering it captures stat/hash/stat evidence
for the source image and optional XMP, exact relationship bytes, and the associated regular memo's
identity and digest. A missing, corrupt or newer relationship fails closed; an absent relationship
does not infer one from a nearby WAV.

Destination selection reserves a coherent image, XMP, hidden full-filename relationship and, when
associated, memo name. The renderer output and XMP are normalized to the reserved final basename
before signing, so a collision suffix cannot invalidate basename-sensitive C2PA work. Image and
sidecar bytes are captured after signing and revalidated after companion preparation. Unsafe source
XMP, rendered artifacts, memo symlinks and unsafe staged companions are rejected.

The archive receives a verified independent WAV and a freshly encoded relationship with the final
image/memo filenames and original profile identifier. Installation uses non-replacing same-volume
moves. A late collision rolls back only paths installed by this operation and preserves the foreign
arrival. Cancellation before commit discards staging; cancellation observed once commit begins lets
the synchronous bundle finish and is returned in the receipt. A successful archive remains reported
as successful if later staging cleanup fails, with the exact residual path shown in batch details.

## Automated verification

- Focused `RAWArchiveTransactionServiceTests`: 12 tests / one suite pass in 0.454 seconds. Cases
  cover complete image/XMP/WAV/record installation, source preservation, coherent suffixes,
  unassociated behavior, source mutation, signing failure/cancellation, install rollback, unsafe
  signer sidecars, source/staged memo symlinks, cancellation during commit, cleanup receipts, late
  arrivals and rendered-byte mutation during companion preparation.
- Final complete serial suite on the exact implementation: 2,851 tests passed, zero failures and
  zero top-level skips in 131.125 seconds. Xcode reports 3,691 expanded parameter passes and one
  device-configuration skip.
- Repository validation passes generated documentation, release metadata, 29 JSON documents, two
  property lists plus the Xcode project, bundled component/model provenance, logger/investigation
  privacy, conflict-marker and whitespace checks.

An initial parallel complete-suite attempt stalled after a test worker crashed while Xcode waited
for worker materialization; it was interrupted after 399.081 seconds without a test assertion.
The clean serial rerun above passed. Existing LMDB map-full diagnostics, compiler/App Intents
warnings and four QoS runtime warnings remain visible. Independent review was not performed.

## Remaining evidence and work

1. Exercise every format with redistributable real RAW material, the actual Adobe DNG Converter
   paths and actual C2PA parent signing. Confirm archive lookup/playback after the source is absent.
2. Exercise same-folder and mirrored destinations on representative physical volumes, including
   collision, cancellation, cleanup and process-crash recovery. Series-of-renames crash atomicity
   is not claimed; no startup recovery manifest was added.
3. Implement the separate source-reassociation boundary with persisted photo and memo content
   identity, explicit user-selected candidates/replacements and transcript-approval invalidation.
4. Decide and implement editorial/transcript carrier copying and visible Deadline WAV policy rather
   than treating the relationship record as complete editorial-history delivery.
