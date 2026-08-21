# Environmental failure drills — 2026-08-21

Deterministic Phase 6 drills now exercise the application's injected filesystem, bookmark, source,
staging, upload, and registry boundaries without relying on CI-specific `chmod` behavior. Simulated
facts cover source permission denial, an unavailable/offline iCloud source, a read-only staging
root, insufficient capacity, disk-full failures during rendering and metadata writing, stale and
denied bookmark access, and network loss both before and during a file.

The tests prove that staging refuses before mutation when prerequisites are unavailable; a mid-write
failure retains only previously verified evidence; bookmark refresh is persisted only after access
succeeds; upload cancellation waits for the active-file boundary; retry begins at the failed file;
and paths, credentials, bookmark bytes, and editorial values do not escape through sanitized errors
or checkpoints. Real local filesystem assertions verify `0700` workflow/staging directories and
`0600` plan, manifest, and staging-evidence documents. Existing filesystem-backed offline-source
scanner coverage is included.

Validation selected staging, verified upload, Caption code replacement, workflow registry, and
source revision suites. The xcresult contained 52 logical tests (62 passed parameterized executions)
with zero failures; xcodebuild reported 6.255 seconds. Swift parse validation, project-file lint, and
whitespace checks passed. No production change was necessary because all exercised boundaries
already failed closed, retained only valid prior evidence, and sanitized underlying errors.

The following remain manual release drills because simulations cannot establish operating-system or
server behavior: actually revoked/stale security-scoped bookmarks; real iCloud-evicted placeholders
and offline-account recovery; external-volume ACL/TCC and genuinely read-only media; physical-volume
exhaustion; FTP/FTPS/SFTP disconnects and partial remote files on representative servers; and real
Keychain/credential combinations.
