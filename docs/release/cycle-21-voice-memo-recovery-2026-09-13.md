# Cycle 21 — verified adjacent voice-memo recovery

**State:** COMPLETE for the code-level identity and missing-adjacent-memo recovery slice and
automated verification. Overall 3.0 readiness remains **IMPLEMENTING** because general relocated
photo/relationship discovery, authentic Sony/native-volume evidence, transcription/delivery and
broader release gates remain open.

## Source and scope

- Implementation commits: `d876330`, archive identity follow-up `6b8100b` and stale-picker ownership
  follow-up `026d4f2` on `main`, based on cycle-20 checkpoint `e35071b`.
- The hidden relationship advances compatibly from schema 1 to schema 2 with optional photo and WAV
  byte counts/SHA-256 values, explicit association provenance and an optional audio-hash binding
  reserved for reviewed transcript approval.
- New save/import/copy/move/archive relationships capture the final identities available at their
  commit boundary. Existing schema-1 records remain readable and retain version 1 until an explicitly
  confirmed recovery migrates them; current hashes are never presented as historical proof.
- Caption recovery applies when the current photo and relationship are present but the adjacent WAV
  is missing. It is not a general search for a relocated photo or relationship record.

## Recovery boundary

Caption offers a WAV-only picker for a persisted missing relationship. Candidate hashing and recovery
run on a retained utility executor with balanced picker/folder security scopes. If both the current
photo and selected WAV match the stored identities, recovery proceeds as exact. A changed photo,
changed WAV or incomplete/legacy identity pauses for an explicit destructive replacement decision.

The selected WAV is copied, never moved. Recovery stages a private sibling copy, compares exact bytes,
revalidates candidate/photo/record evidence, refuses an occupied destination and installs without
replacement. Only after installation does it atomically update the relationship and verify read-back.
A failure restores the exact prior record, removes only the operation-owned installed copy and reports
any cleanup residual. Unknown relationship fields survive migration. Exact recovery can retain a
future transcript approval only when it is bound to the same audio hash; replacement clears it and
records new provenance. Playback refreshes after success and never autoplays. Navigation/disappearance
cancels ownership and prevents a late assessment from publishing or committing recovery.

Archive relationships now bind the memo to the already captured post-signing output image identity as
well as the WAV identity. This allows an archive-derived relationship to participate in exact recovery
without mistaking the source RAW hash for the derivative image hash.

## Automated verification

- Final affected roster: 56 tests / three suites pass with zero failures or skips. It covers the 44
  companion-repository/Caption tests plus all 12 RAW archive transaction tests.
- New recovery cases cover exact restoration, retained selected source, legacy confirmation and
  unknown-field preservation, changed photo/audio, approval invalidation, relationship-write rollback,
  utility-executor/security-scope ownership and navigation cancellation. Archive coverage now asserts
  persisted derivative image/memo identity and provenance.
- Final complete serial no-rebuild suite on the exact compiled implementation: 2,859 tests / 312
  suites passed, zero failures, in 126.744 seconds (Xcode elapsed 133.362 seconds).
- Repository validation passes generated documentation, release metadata, 29 JSON documents, two
  property lists plus the Xcode project, bundled component/model provenance, logger/investigation
  privacy, conflict-marker and whitespace checks.

Existing KVS/App Intents, LMDB map-full and synthetic media diagnostics remain visible. Independent
review and native UI interaction were not performed for this cycle.

## Remaining evidence and work

1. Add user-scoped discovery and transaction ownership for a relocated photo plus relationship record,
   representing exact, duplicate/ambiguous, changed and missing outcomes without filename adoption.
   Refresh durable path/resource hints only after verified commit.
2. Exercise exact and replacement recovery through the native picker on authorized real Sony samples,
   including relaunch, keyboard/VoiceOver, source disappearance, destination collision and physical
   volumes. Never commit the private media.
3. Exercise all RAW archive formats with real inputs, DNG Converter and C2PA, then prove playback and
   exact recovery after the archive source is unavailable.
4. Implement reviewed local transcription with the reserved audio-hash binding, carrier-neutral
   transcript variables and visible Deadline WAV policy/receipts.
