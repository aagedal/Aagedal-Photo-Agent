# Logger privacy and privacy-manifest validation — 2026-08-25

## Unified-log inventory and classification

The application source contains 67 `Logger` constructions and 257 lexical unified-log severity
calls across 332 Swift files. A separate scan found no executable `print`, `debugPrint`, `dump`,
`NSLog`, or legacy `os_log` call outside that unified-log boundary.

Every explicit public interpolation was reviewed under this classification:

| Value class | Logging policy |
|---|---|
| Source/destination paths and filenames | Private with a hash mask, so repeated values can be correlated without disclosure |
| Face/person/team/watermark identifiers | Private with a hash mask |
| Editorial metadata, connection names, hosts, and user labels | Private with a hash mask |
| Subprocess arguments and tool output | Arguments are not logged; only argument counts are public. Error/tool output is private |
| Localized errors and recovery messages | Private because Cocoa, network, and process errors can embed paths, hosts, or arguments |
| Operational counts, timings, booleans, schema field names, and app-owned enum states | Public only through the narrow static allowlist |

The audit removed public source paths from folder monitoring, browser refresh, import, metadata,
sidecar, thumbnail, render/export, C2PA, and face-data logging. It also stopped FFmpeg from logging
its argument vector and made FTP connection labels, editorial titles, face identifiers, short
content hashes, and localized errors private or hash-redacted. Dynamic strings without an explicit
public annotation remain subject to Unified Logging's default privacy behavior.

## Fail-closed static gate

`scripts/ci/validate_logger_privacy.py` parses balanced Swift string interpolations in every app
Swift file. It rejects every explicit `privacy: .public` value except the reviewed non-identifying
allowlist: counts, metadata schema keys, the sidecar orientation diagnostic, and two app-owned enum
states. Adding a new public value therefore requires an intentional validator change and review.

`scripts/ci/test_logger_privacy_validator.py` proves that private path/error examples pass and that
public paths, filenames, identifiers, metadata values, destinations, subprocess arguments, and
errors all fail. Both checks run in `scripts/ci/validate_repository.sh`, before the CI build/test
steps.

Local results:

```text
logger privacy validator self-test passed (safe plus 7 prohibited categories)
logger privacy validation passed across 332 Swift files; 11 approved non-identifying public interpolation(s)
```

## Privacy-manifest conclusion

The app now includes `Aagedal Photo Agent/PrivacyInfo.xcprivacy` with tracking disabled and empty
tracking-domain and collected-data arrays. The empty declaration is deliberate:

- The app has no advertising, analytics, cross-app tracking, or developer-operated telemetry
  endpoint.
- Photos, metadata, face data, bookmarks, and settings are processed/stored locally or, when the
  user opts in, in the user's private iCloud container.
- FTP/FTPS/SFTP transfers go only to a destination the user configures. Map/search, update, and
  trust-list requests provide the requested transaction; they are not an app-developer data
  collection channel.
- The executable links the pinned Sparkle package and the repository-local SwiftExif package.
  Neither appears on Apple's current list of SDKs that mandate a privacy manifest/signature, and
  neither adds an analytics or tracking channel in this app.

Apple's [privacy-manifest documentation](https://developer.apple.com/documentation/bundleresources/privacy-manifest-files)
requires collected-data declarations on all platforms, while its required-reason-API section names
iOS, iPadOS, tvOS, visionOS, and watchOS rather than macOS. Consequently this macOS-only target does
not declare required-reason API categories. Apple's
[third-party SDK requirements](https://developer.apple.com/support/third-party-SDK-requirements/)
remain part of each dependency-update review.

The repository gate now lints tracked `.xcprivacy` documents alongside plists. A local app build
also verified that Xcode installs the manifest at
`Aagedal Photo Agent.app/Contents/Resources/PrivacyInfo.xcprivacy`, matching Apple's documented
[macOS bundle location](https://developer.apple.com/documentation/bundleresources/placing-content-in-a-bundle).

This conclusion must be revisited before adding telemetry/analytics, a developer-controlled upload
service, tracking domains, a newly listed SDK, or an iOS-family target. It does not resolve the
separate App Sandbox/helper-boundary feasibility item.

## Validation boundary

The static inventory, redaction policy, negative checker fixtures, manifest lint, bundle placement,
and repository validation are complete. The Phase 1.3 exit gate still requires a release-candidate
runtime log capture across import, face scan, edit/export, and delivery; that interactive evidence
is intentionally not inferred from static validation.
