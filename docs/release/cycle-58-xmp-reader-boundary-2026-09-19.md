# Cycle 58 — Captured XMP reader dependency boundary

State: IMPLEMENTING. Baseline `92fb9bc`, initially clean checkout.

Extracted `XMPMetadataReader` from the filesystem/write-oriented `XMPSidecarService`.
The guarded MCP snapshot reader now invokes this byte decoder directly. Interactive sidecar
loads and transactional write read-back use the same implementation, retaining localized Title
clears, orientation precedence, GPS forms, IPTC dates and lazy sensor-aspect crop conversion.
The shared namespace constants also remove the embedded dictionary adapter's dependency on
`XMPDataBuilder`. The decoder itself performs no path reads or mutations; callers own byte
capture and supply any required sensor aspect.

This is a dependency-boundary prerequisite, not a new helper endpoint. MCP's existing complete
XML validation, captured revision evidence, photo reservation and publication checks are
unchanged. The helper still needs typed-model/parser target membership and dependency closure,
then guarded `get_photo_metadata` dispatch and real-client validation. No Phase 5A or readiness
gate closes. No GUI behavior change is intended; no new native UI evidence is claimed.

## Verification

Tests use literal in-memory XMP and the existing generated-image snapshot fixtures. No user
photos or preferences were modified. Host: arm64 macOS 27.0, Debug test configuration.
New regression coverage verifies explicit Title/Label clears, TIFF orientation precedence over
EXIF, directional/DMS GPS, IPTC date retention, and sensor-aspect access only for angled crops.

- Focused suite: **15 tests / 36 executions**, zero failures/skips,
  `build/qa-xmp-reader-focused-2.xcresult`.
- Final-source complete serial suite: **2,996 tests / 3,891 executions**, zero failures/skips,
  `build/qa-xmp-reader-full.xcresult`; 133.973-second test operation. The four previously
  recorded QoS warnings remain in CaptionSessionTests and MetadataEditorReadServiceTests.
- Repository validation passes: `build/qa-xmp-reader-repository.log`.
- `git diff --check` passes.

The first sandbox invocation could not write the standard compiler/package caches. The
approved retry passed. Its build log contained transient compiler-driver messages about
commands exiting zero without output, but the completed result reports a passing run. The
subsequent full-suite invocation passed without these build diagnostics.

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 1 \
  '-only-testing:Aagedal Photo Agent Tests/XMPMetadataReaderTests' \
  '-only-testing:Aagedal Photo Agent Tests/MCPMetadataSnapshotReaderTests' \
  -resultBundlePath build/qa-xmp-reader-focused-2.xcresult -quiet

xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 1 \
  -resultBundlePath build/qa-xmp-reader-full.xcresult -quiet

scripts/ci/validate_repository.sh
git diff --check
```
