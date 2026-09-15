# Cycle 37 — Codex, Claude Code and OpenCode setup

**State:** IMPLEMENTING for 3.0. The bundled STDIO server now has copyable client-specific setup in
Automation Settings, but production tools and real-client end-to-end evidence remain open.

## Change

- Settings displays the exact bundled helper path and Codex CLI, Claude Code and OpenCode v2 local
  STDIO install commands. OpenCode 1.x receives a JSON configuration block with the server directly
  under `mcp`; Settings tells users to merge that entry into an existing `opencode.json`. The JSON is
  generated with Foundation serialization so executable paths containing spaces or quotes are escaped.
- This extends client setup, not server authority. The helper remains default-off, root-scoped,
  protocol-clean and read-only at its current tool boundary. No client configuration was written by
  Photo Agent during this cycle.
- The 3.0 plan now names Codex CLI, Claude Code, OpenCode 1.x and OpenCode v2 for disposable-config
  connection and tool-discovery checks before its full workflow evidence gate can close.

## Evidence

- The official [Codex MCP](https://developers.openai.com/codex/mcp),
  [Claude Code MCP](https://code.claude.com/docs/en/mcp),
  [OpenCode 1.x MCP](https://opencode.ai/docs/mcp-servers/), and
  [OpenCode v2 MCP](https://opencode.ai/v2/docs/mcp-servers) documentation support the displayed
  command/configuration shapes. The locally installed OpenCode Homebrew path identifies version
  1.18.30. Its executable exited 137 without output even for read-only CLI help, including an
  unsandboxed attempt; live OpenCode connection is not claimed.
- The `Aagedal Photo Agent` scheme builds successfully after the Settings update. Codex and Claude
  CLI `mcp add --help` display the expected local STDIO command form. Repository validation and
  whitespace checks pass.
- The built helper completed a STDIO `initialize` / `notifications/initialized` / `tools/list`
  exchange with OpenCode-shaped client information and returned the three current read-only tool
  definitions. This proves protocol discovery through the executable, not an OpenCode CLI launch.

## Remaining work

Connect each targeted client through disposable configuration, prove launch/initialize/tool discovery
and clean disconnect, then exercise the eventual production workflows and GUI contention from a real
client. OpenCode v2 cannot be tested locally until its CLI is available; OpenCode 1.x currently fails
to launch on this host even for help output. Phase 5A's production service facade, tools and FFmpeg
Whisper gates are unchanged.
