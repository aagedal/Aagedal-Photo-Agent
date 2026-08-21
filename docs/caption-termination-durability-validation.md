# Caption termination durability validation — 2026-08-21

Caption draft persistence now exposes an asynchronous durable drain on the existing serial FIFO
queue, so application termination can wait without blocking AppKit's main actor. Failed work remains
at the queue head and is retried in exact order; retry does not recapture or duplicate the current
draft.

`AppDelegate.applicationShouldTerminate` preserves the existing active import/upload warning, then
returns `terminateLater` and flushes Caption before the named Develop version. A reply latch prevents
reentrant termination and duplicate `NSApplication.reply` calls. Failure identifies the Caption or
Develop stage and offers Retry Save, Keep App Open, or an explicit Quit Without Saving choice.

Tests cover rapid opposite navigation, FIFO failure and retry, no duplicate draft capture,
nonblocking termination drain, Caption-before-Develop ordering, retry/keep-open/explicit-quit
decisions, duplicate-reply prevention, template/code-replacement/autocomplete focus wiring, and
workspace-specific focus restoration. The fresh build and focused same-build run passed 53 tests
across five suites with no failures or skips. PBX lint, conflict scan, and `git diff --check` passed.

Unit tests cannot drive macOS's complete real termination-modal/`NSApplication.reply` lifecycle or
visually inspect live AppKit first responders through sheets, popovers, and IME composition. Those
outer interactions remain part of the manual application-level pass.
