# Cycle 27 — visible voice-memo delivery policy

**State:** COMPLETE for the explicit Deadline WAV disposition, frozen-plan execution and
privacy-safe receipt criterion. Overall 3.0 readiness remains **IMPLEMENTING** because native and
real-server delivery evidence, transcription/application breadth, authentic Sony/volume evidence
and the wider release gates remain open.

## Source and scope

- The implementation continues cycle 26 from `efb656f` on `main`. Verification ran from a dirty
  tree containing only the cycle 27 source, test and documentation changes. Independent review and
  native UI execution were not run in this cycle.
- Every Deadline profile now makes one of three explicit choices: exclude WAV companions, include
  each proven WAV when available, or require a proven WAV for every selected image. Existing
  schema-1 profiles migrate to **Exclude**, so an upgrade cannot begin transmitting audio silently.
- Preflight resolves the persisted image/WAV relationship and captures the exact WAV revision.
  Exclusion and inclusion are visible informational results; missing or invalid optional companions
  are warnings; and the required policy blocks Send when any companion is absent, missing or invalid.
- Delivery preparation recaptures the current relationship and WAV identity. Schema-2 frozen plans bind
  the exact audio SHA-256, byte count, source revision and final `image-basename.WAV` output name into
  both item and plan fingerprints. A relationship or byte change after preflight refuses preparation.
  Existing schema-1 retained plans remain verifiable through their original fingerprint only when
  their migrated policy is exclusion and they contain no audio artifact.
- Staging reserves WAV space and names, revalidates the exact source before and after copying, and
  verifies the completed staged bytes. Upload re-inspects the staged WAV, sends it only after the
  image artifact, applies the same optional remote-size policy and retains anonymous exact evidence
  in the resumable checkpoint.
- Receipt schema 3 records the frozen policy plus exact source/delivered WAV identity, protocol
  acknowledgement and remote-stat result. Activity and text-summary projections show the policy,
  delivered count, anonymous size and acknowledgement state while continuing to omit filenames,
  paths, hashes, credentials, transcript text and editorial values.

## Automated verification

- The focused end-to-end roster passes 123 tests across Deadline profile/preflight/planning,
  staging, upload/checkpoint, receipt assembly/repository/Activity, and retained workflow suites.
  New coverage proves all policy states, legacy exclusion, exact plan binding and drift refusal,
  verified WAV copy, sequential transfer/checkpoint evidence, terminal receipt assembly and
  privacy-safe presentation.
- The complete serial suite passes 2,896 tests in 314 suites with zero failures in 142.376 seconds.
- `scripts/ci/validate_repository.sh` and `git diff --check` pass.
- Tests ran with Xcode's macOS destination on macOS 27.0 (26A428), arm64, against development
  version 3.0.0 build 738. The complete suite result is
  `Test-Aagedal Photo Agent Tests-2026.09.13_17-23-05-+0200.xcresult` in Xcode Derived Data and is
  not committed. Existing compiler and QoS runtime warnings remain visible; no new warning is
  attributed to this slice.

## Remaining work

1. Exercise all three policies in the built app with absent, valid, missing and changed companion
   states; inspect confirmation, cancellation, retained-workflow resume and Activity after relaunch.
2. Send disposable image/WAV batches through real FTP, verified/unverified FTPS and SFTP endpoints;
   verify exact remote names/sizes, partial image-before-WAV failure behavior and cleanup.
3. Complete malformed/empty/finalization/install-cancellation, offline, long-file cancellation and
   reservation-limit transcription coverage, then run authorized Sony WAV drills.
4. Broaden authentic archive/recovery/reassociation, physical-volume, keyboard and VoiceOver evidence.
