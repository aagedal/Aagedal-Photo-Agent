# Cycle 44 — app-owned descriptive draft inspection

**State:** IMPLEMENTING for 3.0. This is a read-only prerequisite for complete typed
`get_photo_metadata`; it does not resolve effective IPTC or permit a mutation.

## Behavior

- `inspect_app_photo_draft` accepts one explicit authorized photo and shares the existing
  root-anchored, no-follow source/XMP/owned-JSON evidence read and process reservation with
  `inspect_photo_revision`. It returns the three opaque revision tokens, app draft state, and a
  bounded basic descriptive field map from the exact-owner schema-1 JSON carrier.
- The field map uses persisted JSON keys for basic strings and ordered string arrays. It excludes
  structured editorial records, technical/Develop settings, transcript text, history and unknown
  JSON extensions. Missing JSON returns an empty field map and `absent` state. Output says
  `effectiveIPTCResolved: false` so an automation client cannot use the stored draft as a merged
  embedded/XMP baseline or as patch authority.
- Newer/unknown schema and malformed or oversized known fields refuse draft interpretation.
  `inspect_photo_revision` still reports the carrier revision and unsupported/unknown state
  without exposing its content. The standard MCP result-size boundary remains in force.
- The initial template-discovery approach was abandoned during this cycle because the standalone
  helper compiles only its transport core; app template storage services are not linked into it.
  Template discovery belongs behind the shared production facade.

## Verification

Baseline `6032f0e` on clean `main`, development 3.0.0 (738), arm64 macOS 27.0 with Xcode 27.0.

- Focused MCP selection: **17 tests, zero failures and zero skips** at
  `build/qa-mcp-owned-draft-fields-focused.xcresult`. Disposable fixtures prove disabled access,
  absent/pending draft state, retained revision tokens, descriptive typing, exclusion of private
  transcript/history/unknown fields and newer-schema refusal.
- `scripts/ci/validate_repository.sh` and `git diff --check` passed. The complete serial suite
  passed again with this documentation in the worktree.
- The final-source complete serial suite passed **3,775 tests, zero failures and zero skips** at
  `build/qa-mcp-owned-draft-fields-full.xcresult`. Command:
  `xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' -scheme 'Aagedal Photo Agent Tests'
  -configuration Debug -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 1
  -resultBundlePath build/qa-mcp-owned-draft-fields-full.xcresult -quiet`. Xcode reported 134.096
  seconds for the test operation. Existing compiler diagnostics appeared during the initial
  focused build; no new diagnostic was attributed to this tool.

## Remaining work

Complete `get_photo_metadata` must read embedded and XMP descriptive values through the
production reader, reconcile carrier precedence and pending/conflict state, include structured
fields, and return a bounded effective snapshot tied to the exact source/app/XMP revisions. The
production facade, UUID template discovery, operation status/cancellation, guarded workflow tools,
FFmpeg Whisper, real-client and release evidence remain open. No Phase 5A criterion is checked.
