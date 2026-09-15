# Cycle 42 — anchored photo revision reads

**State:** IMPLEMENTING for 3.0. This hardens the read-only MCP revision prerequisite; typed metadata and mutation tools remain open.

## Behavior

- Revision inspection opens the granted root, checks its recorded device and inode, then opens each nested directory using `openat` with `O_DIRECTORY` and `O_NOFOLLOW`. The photo's directory descriptor anchors source, adjacent XMP and owned app-sidecar reads. A retargeted ancestor cannot redirect an absolute carrier read outside the granted folder.
- The target file's descriptor-relative identity must match the admitted photo before hashing. Each carrier uses `O_NOFOLLOW`, regular-file and single-link checks, plus descriptor-relative identity and modification checks after reading. The private metadata directory is itself opened without following a link. Missing XMP and private-directory evidence is checked again before publication.
- The existing shared photo lease covers the entire capture, and the exact photo is reauthorized afterward. The tool returns only opaque tokens and presence flags; it does not disclose private metadata values.

## Verification

The final focused MCP test selection passes with `xcodebuild` exit 0 at `build/qa-mcp-cycle42-focused-final.xcresult` (ignored). It covers nested carrier inspection and refusal of linked private metadata storage, alongside the earlier identity, busy-photo and carrier cases. Repository validation and `git diff --check` pass. The last complete serial-suite evidence remains cycle 41's 3,767 zero-failure, zero-skip executions; this cycle did not repeat the full suite. This is no real MCP-client workflow, typed metadata read or complete concurrent filesystem-retargeting fault matrix.

## Beta and final-release distance

Beta still needs typed production metadata reads; guarded metadata/Develop template, face-scan, transcription and two-phase IPTC operations with status/cancellation; complete GUI/MCP admission; the reproducible FFmpeg Whisper build and model lifecycle; and real-client end-to-end evidence. This cycle removes one read-path security gap but closes no Phase 5A tool-workflow gate.

Final release additionally needs exact-candidate hardware/performance, accessibility, physical-volume and recovery drills; authentic Sony, cloud, server and interoperability evidence; independent privacy/legal and readiness review; protected CI; user acceptance; and signed/notarized distribution. A calendar estimate is not defensible until the beta workflows and those external gates have evidence.
