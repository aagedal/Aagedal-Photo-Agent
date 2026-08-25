# Continuous integration and release-gate validation — 2026-08-25

Phase 1.1 now has a repository-defined macOS CI gate and an exact-source release preflight.

## Automated boundary

- `.github/workflows/ci.yml` runs on pull requests, pushes to `main`, and manual dispatches. Its one
  macOS job checks generated metadata documentation, every tracked JSON/plist plus the Xcode project,
  unresolved conflict markers, and `git diff --check`. It then performs `clean build-for-testing` and
  the complete, unfiltered `test-without-building` action using one isolated DerivedData directory.
- A failed workflow writes a compact `xcresulttool` summary to the GitHub job summary and retains the
  `.xcresult` plus build/test logs as a 14-day artifact. A build failure can occur before an `.xcresult`
  exists, so the artifact step deliberately tolerates that missing path while retaining the build log.
- `scripts/release.sh` invokes `scripts/ci/verify_release_test_gate.sh` before inspecting credentials or
  creating release artifacts. Normal operation requires a clean worktree and an authenticated GitHub
  Actions push result whose workflow, successful conclusion, and `headSha` match the exact
  local `HEAD`. It records the accepted run as JSON under `build/release/`.
- Archives and exported apps receive adjacent source-revision markers. Resume/reuse accepts an artifact
  only when its version, build, signature where applicable, and marker all match the gated `HEAD`; an
  older build cannot borrow a newer commit's successful test result.
- The emergency path still rejects dirty source. It requires the literal `EMERGENCY` opt-in, a reason
  of at least 20 characters, and full-SHA confirmation; it prints a high-visibility warning and writes
  both the current record and a JSON-lines audit entry. Release records must retain these ignored build
  outputs outside the disposable checkout.

## Local validation

The repository validation script passed over 24 tracked JSON documents, the tracked application plist,
and `project.pbxproj`; metadata generation, conflict-marker scanning, and `git diff --check` also passed.
`bash -n` passed for the release and CI shell scripts, and Python byte-compilation passed for the summary
and metadata-generator scripts. The release verifier was exercised with mocked GitHub CLI results: an
exact successful SHA was accepted, a stale successful SHA was rejected, a dirty tree was rejected, and
the explicitly confirmed emergency route emitted both audit records.

The GitHub branch-protection rule remains an external administrative action: require **macOS CI / Clean
build and unfiltered tests** on the protected release branch. This repository change intentionally does
not attempt to mutate remote branch settings.
