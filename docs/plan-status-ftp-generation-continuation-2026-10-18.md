# FTP upload generation isolation — 2026-10-18

This continuation prevents a cancelled or superseded upload from publishing into its
replacement. It adds no main-window controls.

## Changes

Both original-file and edited-JPEG uploads now verify task cancellation and generation
ownership after filesystem, metadata, render, signing and transfer awaits. Errors, per-file
completion, rendered-folder disclosures, history completion and phase changes belong to the
current generation. Obsolete renders stop before filename sequencing, signing or upload;
obsolete signing results stop before transfer. Temporary staging cleanup still runs.

Progress callbacks also require the current uploading generation and reject updates to completed
files or backwards fractions. Delayed callbacks cannot lower completed-file or completed-batch
progress. Starting an original-file run clears the previous run's render counters.

Injectable execution and preferences boundaries allow real public view-model workflows to be
tested without production preferences, saved credentials, FTP access, render hardware or signing
certificates. Production defaults retain the existing services. A captured completion awaiter
joins one generation even after another replaces the current task.

## Verification

The focused run passed seven tests in two suites, including eight parameterized lifecycle cases
and two transport acknowledgement tests. Gated operations deliberately ignore cancellation and
return late success or errors. Coverage includes transfer restart, completed-file callbacks while
a following file is still uploading and after batch completion, obsolete render/signing results,
and direct replacement into another rendering generation. Fixtures use real small JPEG files,
private defaults, bounded watchdogs and awaited cleanup.

The final full regression passed 4,375 tests in 424 suites: 4,373 passed, two existing skips
and zero failures (147.411 seconds reported by Swift Testing). Repository validation and
whitespace checks passed.

Final Xcode result bundle:
`/private/tmp/aagedal-settings-search-build/Logs/Test/Test-Aagedal Photo Agent Tests-2026.10.18_19-36-37-+0200.xcresult`.

Logs: `/private/tmp/aagedal-ftp-generation-focused.log`,
`/private/tmp/aagedal-ftp-generation-full.log` and
`/private/tmp/aagedal-ftp-generation-repository.log`.

## Remaining qualification

These tests verify local lifecycle ownership, not real-server cancellation or remote partial-file
semantics. Already-running encoders/signers may finish their local work after cancellation;
completed local renders remain available for recovery. Export destination reservations from the
preceding continuation keep overlapping cooperative writers apart.

Native keyboard editor/Save/signing interaction, representative storage and export timing,
metadata interoperability, real-network behavior and the final signed release gates remain open.
The native automation connection failure and Metal MDB_MAP_FULL diagnostics remain unresolved.
