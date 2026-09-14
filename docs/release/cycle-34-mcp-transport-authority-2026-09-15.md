# Cycle 34 — MCP transport and authority

**State:** COMPLETE for the bounded Phase 5A transport and filesystem-authority foundation. Overall
3.0 readiness remains **IMPLEMENTING** because production workflow tools, shared GUI/MCP operation
coordination, FFmpeg Whisper, native real-client evidence and wider release gates remain open.

## Source and scope

- The implementation continues from `341d33b` on `main`. Verification ran from a dirty tree containing
  only the cycle 34 source, project, test and documentation changes. Independent review was not run in
  this cycle.
- A separate arm64 `photo-agent-mcp` executable is built with hardened runtime, development-signed and
  copied into the app's `Contents/MacOS` directory. It is a sequential local STDIO server with no
  network listener and keeps stdout restricted to newline-delimited JSON-RPC protocol messages.
- The initial MCP surface negotiates the supported lifecycle and exposes three bounded, accurately
  annotated read-only tools for server capabilities, authorized roots and path-admission inspection.
  Production metadata, Develop, face, transcription and mutation tools are deliberately not claimed.
- Settings → Automation owns one coherent cross-process preference record. Automation starts disabled;
  users must enable it and select explicit folder roots. The Settings surface also supplies the exact
  bundled-helper path and a copyable `codex mcp add` command.
- The helper reloads authority for each call. Existing canonical regular files and directories are
  accepted only under an unchanged selected root. Traversal, symlinks, Finder aliases, hard links,
  special files, root replacement, filesystem-root grants, out-of-root paths and Photo Agent private
  stores are refused.

## Automated verification

- The focused MCP run passes all 9 tests. Coverage includes default-off configuration; root, traversal,
  symlink, alias-capable component, hard-link, FIFO/private-store and replaced-root refusal; lifecycle,
  tool annotations, malformed requests and notifications; protocol-clean STDIO; and the exact bundled
  helper's execution, hardened-runtime flag and development team identity.
- A direct helper probe completes initialize, initialized and tool calls with one JSON-RPC response per
  line and no stderr output.
- The exact final source tree's complete serial suite passes 2,916 tests across 315 suites with zero
  failures in 116.434 seconds. The result is
  `Test-Aagedal Photo Agent Tests-2026.09.15_00-09-09-+0200.xcresult` in Xcode Derived Data and is not
  committed.
- `xcodebuild -list`, an unsigned app build, `plutil -lint`, `scripts/ci/validate_repository.sh` and
  `git diff --check` pass. The repository validator was rerun after the final documentation update.
- Tests ran with Xcode's macOS destination on macOS 27.0, arm64, against development version 3.0.0
  build 738. Existing compiler and runtime diagnostics remain visible; no new warning is attributed to
  this slice.

## Native observation

- A read-only inspection of the exact built app confirms that Automation appears in the Settings
  sidebar. Its detail view visibly reports `Enable local automation` as off and `No folders authorized`,
  exposes the bundled helper path and Codex install command, and explains the STDIO/no-network-listener,
  per-call authority and current read-only retention boundaries. No automation preference or folder
  grant was changed during this observation.
- This is Settings-surface evidence only. A production MCP workflow from a real client is not claimed;
  those tools do not exist yet and remain an explicit Phase 5A gate.

## Remaining work

1. Define a shared production-service facade and cross-process photo/folder reservations so MCP and GUI
   work cannot bypass the same revision, conflict, cancellation, rollback and verification rules.
2. Add bounded metadata reads, operation status/cancellation, face scan, metadata/Develop template and
   batch-transcription tools, followed by the prepared/confirmed two-phase IPTC patch flow.
3. Build the Aagedal Media Converter FFmpeg product with embedded whisper.cpp, hardened model delivery,
   capability reporting and the existing editable-review/approval boundary.
4. Exercise production tools from a real MCP client, including cancellation, disconnect/relaunch,
   stale-source refusal, concurrent GUI activity and privacy-safe diagnostic checks.
