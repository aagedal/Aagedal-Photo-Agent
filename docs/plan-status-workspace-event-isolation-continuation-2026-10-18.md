# Workspace event isolation continuation — 2026-10-18

This continuation protects Settings shortcut recording/navigation from background workspace
monitors. It also investigates the recurrent Metal map-full diagnostics without treating a
passing suite as proof that the diagnostic has been resolved.

## Input isolation

Caption's application-wide local key monitor previously admitted Tab and caption advance
shortcuts without checking which window received the event. While Caption remained mounted,
Settings input could move Caption focus or advance/write a photo. A passive AppKit view now
tracks the workspace's actual owning window through a weak reference. Admission requires
that exact window to be key, with no modal window, attached sheet or sheet parent. This check
precedes both Tab handling and the existing text/IME-aware caption shortcut router.

Analysis had the same gap for its tool/hand/loupe key monitor and scroll zoom monitor. It
uses the shared admission policy and drops transient hand/pan/gesture/pointer state on
ownership loss, leaving persistent zoom/pan and annotations intact. Foreign key-ups pass to
their receiving window. An owning-window resign-key notification clears transient state
immediately, including when the release happens outside the application.

Both side-by-side and wipe Comparison scroll monitors now check the same window policy.
Develop preview scroll and middle-click grade copy use its existing owning-window reference
plus modal/sheet exclusions. Stale hover state therefore cannot consume another window's
wheel input or apply edits from a middle-click there. These changes add no main-window UI.

## Verification

The final full regression passed 4,348 tests in 420 suites: 4,346 passed, two existing skips
and zero failures (160.993 seconds reported by Swift Testing). Repository validation and
whitespace checks passed. The initial run found one old source-format assertion that required
Caption's transition predicates to begin the guard; it now permits the ownership predicates
before the same transition checks. The production transition checks remain intact.

Final Xcode result bundle:
`/private/tmp/aagedal-settings-search-build/Logs/Test/Test-Aagedal Photo Agent Tests-2026.10.18_18-49-50-+0200.xcresult`.

Isolated, unshown NSWindow policy tests cover unbound, nil, Settings, unrelated and non-key windows, modal panels,
attached sheets, sheet parents and restoration. They post no input events. Native recording,
caption navigation and gesture interaction still require their live smoke tests.
The current read-only reconnect to the isolated `aagedal.PhotoAgent.CoreShortcutsQA` app
failed with `Sky Computer Use native pipe closed before response`. This observation does
not establish that the QA app stopped; no app restart was inferred from the connection failure.

## Metal diagnostic attribution

On arm64 macOS 27.0.1 (26A434), with Apple Swift 6.4, a narrowly filtered
unified-log query found 788 `mdb_txn_commit error: MDB_MAP_FULL` records
across six Photo Agent test-host processes in the inspected interval. Every record identifies
`/System/Library/Frameworks/Metal.framework/Versions/A/Metal` as its sender. The full-regression
host PID 41854 accounts for 362 of those records. Searching app and checked-out dependency
sources found no LMDB implementation. This attributes the emissions to Metal; the affected
cache location, cause and user-visible impact remain unverified.

Three standalone Swift probes completed successfully outside Photo Agent:

- A Metal compute dispatch changed one shared-buffer float from 41 to 42 and completed
  with command status 4 in 0.160 seconds (PID 52188).
- Loading the built app's `default.metallib` and creating all 16 compute pipeline states
  completed in 0.728 seconds (PID 52814).
- Core Image exposure renders using half- and full-float working formats each produced
  a 16-by-16 CGImage, completing in 0.072 seconds (PID 53798).

The corresponding per-process unified-log queries found zero map-full records for each
probe. These are limited successful calculations, not representative performance results
or a reproduction/resolution of the test-host diagnostic. Probe sources/results and the
filtered attribution JSON are retained under `/private/tmp/aagedal-*-mapfull-probe*`,
`/private/tmp/aagedal-metal-library-probe*` and
`/private/tmp/aagedal-mapfull-diagnostic.json` for this session. The repository's Metal
behavior is unchanged by the investigation. Broader native, performance, interoperability
and signed-release qualification remains open.
