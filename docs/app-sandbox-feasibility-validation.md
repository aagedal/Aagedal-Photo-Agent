# App Sandbox feasibility and constrained-helper assessment — 2026-08-25

## Decision

Enabling App Sandbox is **feasible for the application's core browser, import, metadata, Develop,
analysis, iCloud, map, update, and delivery workflows**, but it is not a safe entitlement-only change.
It is a release-sized migration that needs an isolated prototype and an explicit compatibility gate.
The current release remains Hardened Runtime-enabled and unsandboxed.

The main reasons full sandboxing is feasible are that user file access already begins with standard
open/save panels, persistent browser and workflow locations already use security-scoped bookmarks,
application-owned state has centralized Application Support/iCloud locations, and all network use is
outgoing. The main migration risks are:

1. bundled and system command-line tools are launched directly with `Process` and are not signed or
   packaged for App Sandbox inheritance;
2. Adobe DNG Converter is discovered and executed from `/Applications` or `~/Applications`, which a
   sandboxed app cannot continue doing implicitly;
3. Sparkle's sandbox installer service and communication entitlements are disabled;
4. existing unsandboxed Application Support, preferences, bookmarks, and Keychain continuity need a
   tested one-time migration; and
5. several default paths assume `~/Photos` before the user has granted access.

This record closes the audit's **feasibility evaluation** only. It does not claim that App Sandbox has
been enabled, that a sandboxed build has passed, or that current subprocesses are already safe in a
sandbox.

## Current signed boundary

- Both Debug and Release explicitly set `ENABLE_APP_SANDBOX = NO`, while keeping Hardened Runtime on
  (`Aagedal Photo Agent.xcodeproj/project.pbxproj:793-865`).
- The current entitlement file contains the iCloud Documents container and ubiquity key-value store,
  but no App Sandbox, user-selected file, bookmark, network, or location entitlement
  (`Aagedal Photo Agent/Aagedal Photo Agent.entitlements:5-18`).
- The app has one application target and one unit-test target. It has no application-owned XPC or
  helper target (`Aagedal Photo Agent.xcodeproj/project.pbxproj:398-438`).
- FFmpeg and c2patool are copied into the app resources and re-signed with Hardened Runtime, but the
  build phase supplies no `com.apple.security.app-sandbox` / `com.apple.security.inherit` helper
  entitlements (`Aagedal Photo Agent.xcodeproj/project.pbxproj:494-512`).

## Workflow feasibility matrix

| Boundary | Current implementation evidence | Sandboxed design | Conclusion |
| --- | --- | --- | --- |
| Browser and arbitrary photo folders | Folder selection uses `NSOpenPanel`; recents/favorites create explicit security-scoped bookmarks and retain one balanced access claim for asynchronous descendants (`BrowserViewModel.swift:634-642`; `RecentFoldersStore.swift:3-95,119-131,164-189`). | Add user-selected read/write and app-scoped bookmark entitlements. Preserve the root bookmark while thumbnails, metadata, monitors, sidecars, rename, reject, archive, and export use descendants. | Feasible; the existing ownership model is a strong foundation. A sandboxed end-to-end folder test is still required. |
| Import, backup, archive, custom templates, lists, and signing inputs | Import and settings locations use open panels plus `.withSecurityScope` bookmarks; the RAW archive service has the same bookmark contract (`ImportViewModel.swift:2155-2201`; `SettingsViewModel.swift:651-675`; `RAWArchiveService.swift:133-172`). | Require a selected/bookmarked root before touching external storage. Replace the ungranted `~/Photos` defaults with a not-configured state or first-use folder picker. | Feasible after removing implicit home-directory fallbacks. |
| App-owned persistence | `AppPaths` centralizes Application Support, cache, certificates, templates, and C2PA trust data (`AppPaths.swift:49-131`). | Let Foundation resolve the sandbox container, then perform a one-shot, read-back-verified import from the legacy unsandboxed location before stamping migration completion. Preserve rollback and retry. | Feasible, but existing-user migration is a P0 data-continuity gate. |
| iCloud | Existing entitlements declare the public CloudDocuments container and KVS; `AppPaths` resolves that exact container (`Aagedal Photo Agent.entitlements:5-18`; `AppPaths.swift:15-46`). | Retain the iCloud entitlements alongside App Sandbox and exercise local/iCloud migration, placeholders, coordination, and conflicts in a signed sandboxed build. | Feasible; no separate broad filesystem entitlement is justified. |
| Maps, geocoding, trust-list refresh, OSM, updates, and delivery | Network activity is outbound through MapKit, URLSession/NWPathMonitor, Sparkle, and `/usr/bin/curl`. Delivery needs FTP/FTPS/SFTP client connections only. | Add `com.apple.security.network.client`; do not add network-server. Network client also lets Sparkle avoid its Downloader XPC service. | Feasible with one broad outbound-client entitlement; transport isolation is still recommended below. |
| Current location | `CurrentLocationProvider` uses Core Location and the plist has a usage description (`GPSSectionView.swift:11-95`; `Info.plist:51-52`). | Add `com.apple.security.personal-information.location` and retain the runtime permission flow. | Feasible. |
| Sparkle | Sparkle 2.9.6 is resolved; the feed is HTTPS, but `SUEnableInstallerLauncherService` is false (`Package.resolved:5-11`; `Info.plist:53-60`). | Set the installer launcher service to true and add Sparkle's documented installer communication entitlement. Because the app needs network client anyway, do not enable Sparkle's Downloader service. Verify archive/export signatures and update installation. | Supported by Sparkle, but the present settings are incompatible with a sandboxed app. |
| FFmpeg and c2patool | Both bundled binaries are launched with `Process`; c2patool parses untrusted C2PA-bearing files and FFmpeg parses/encodes multiple media containers (`FFmpegService.swift:23-46`; `C2PASigningService.swift:268-279,437-451`). | Repackage/sign executable children with App Sandbox inheritance for the prototype, then move their narrow operations behind the constrained XPC boundary below. | Technically feasible; current helper signing is insufficient. |
| `/usr/bin/ditto` archive work | Known People, keyword-list, and analysis-project import/export launch `ditto` directly (`KnownPeopleService.swift:1354-1395`; `KeywordListsArchive.swift:343-356`; `ImageAnalysisProjectArchive.swift:512-514`). | Prefer an in-process bounded archive implementation. If retained, prove the system tool can access only bookmark-authorized input/output in the sandbox prototype. | Feasible to replace; do not rely on undocumented subprocess behavior as the release contract. |
| `/usr/bin/curl` FTP/SFTP | Legacy and Deadline delivery launch system curl and pass a 0600 netrc path in the app temporary directory (`FTPService.swift:89-108,203-221`; `DeliveryFTPTransportFactory.swift:267-300,388-410`). | Put delivery in a dedicated network-client XPC service or ship a signed, inherited helper. Pass one read-only input bookmark and an operation-specific credential, never a general argument vector. | Feasible, but must be proven against real FTP/FTPS/SFTP servers from a signed sandboxed archive. |
| Adobe DNG Converter | The app scans `/Applications/Adobe DNG Converter.app` and `~/Applications` and executes the discovered binary (`AdobeDNGConverterService.swift:41-108`). | Do not grant an unsandboxed helper broad filesystem/process authority to preserve auto-discovery. For the sandboxed build, either disable this optional integration with an explicit unavailable state, replace it with an app-owned decoder, or prototype an explicit user-selected executable grant and retain it only if signed release testing proves it. | This is the only known current feature that cannot retain its implicit behavior under a strict sandbox. It does not make core sandboxing impractical. |
| Keychain | FTP secrets and signing material use app-owned Keychain entries; portable iCloud preferences deliberately exclude them. | Keep secrets in the main app's access group or a narrowly shared access group only if a delivery helper needs it. Prefer passing a single credential to the helper for one request rather than granting it general Keychain access. | Feasible; continuity must be verified with an upgraded signed build. |

The required proposed main-app sandbox capabilities are therefore limited to:

- App Sandbox;
- user-selected files read/write;
- app-scoped security-scoped bookmarks;
- outgoing network client;
- Location Services; and
- the existing iCloud container/KVS entitlements plus Sparkle's documented installer communication.

No evidence supports Pictures-folder-wide, Downloads-folder-wide, incoming-network, automation,
camera, microphone, USB, or full-disk access.

## Constrained XPC/helper boundary

App Sandbox reduces ambient access, but the most important parser boundary is still the code that consumes
attacker-controlled image, metadata, archive, and C2PA bytes. The recommended migration is two small,
stateless services rather than one general-purpose command runner.

### Media inspection service

Create `MediaInspectionService.xpc` with no network, iCloud, location, Keychain, or arbitrary user-file
entitlements. Its protocol should accept:

- a closed operation enum, initially `inspectC2PA`, `renderFFmpegDerivative`, and narrowly selected metadata
  extraction operations;
- an input bookmark or file descriptor and, only when needed, an output bookmark created for that request;
- typed, bounded options rather than raw executable paths, environment values, or command arguments; and
- cancellation plus an output-size/time limit.

The service resolves only the supplied resources, validates that output is distinct from input, launches
only app-bundled, manifest-verified helpers signed for the service's sandbox, and returns bounded typed data.
It must not receive the browser root bookmark when access to one file is sufficient. A crash or malformed
result fails the operation without changing source data. Unknown fields remain preserved by the main app's
existing atomic metadata boundary rather than being rewritten by the helper.

### Delivery transport service

Create a separate `DeliveryTransportService.xpc` because it requires outgoing network access and briefly
handles credentials. It should have network-client access but no iCloud, location, broad folder bookmark,
or persistent Keychain entitlement. For one request the main app supplies:

- a single staged-file read bookmark/file descriptor;
- a validated transport profile without stored secret material;
- one credential loaded immediately before the request; and
- an upload/stat operation with fixed argument construction.

The service writes its netrc-equivalent only inside its own temporary container with mode 0600, deletes it
on every termination path, returns privacy-bounded evidence, and never accepts an executable URL or free-form
arguments. A service crash produces an indeterminate/retryable delivery result, never a success receipt.

Keeping these services separate prevents a compromised media parser from gaining network access and prevents
a compromised delivery tool from receiving the user's browser or iCloud library roots. It also avoids a
single non-sandboxed helper that would recreate the main app's present ambient authority.

## Required prototype and release gates

Full sandboxing should proceed on a dedicated branch/configuration and remain off in production until all of
the following are recorded from a signed archive:

1. Add only the proposed entitlements and verify the effective signatures of the app, Sparkle services, XPC
   services, and bundled helpers with `codesign -d --entitlements :-`.
2. Prove clean-install and upgrade continuity for Application Support, preferences, bookmarks, Keychain,
   iCloud local/remote records, and recovery notices. Inject interruption before and after every migration
   install/stamp boundary.
3. Complete browser, import/backup, Caption, Develop/sidecars, Batch Rename, reject/trash, Deadline staging,
   report/archive import/export, and external-volume workflows using selected roots and restored bookmarks.
4. Exercise bookmark denial/staleness, parent-folder moves, TCC/ACL/read-only media, iCloud eviction, app
   relaunch, and revoked external volumes without falling back to unscoped paths.
5. Test FFmpeg, c2patool, archive replacement, and delivery helpers with malformed inputs, cancellation,
   crash/restart, oversized output, and source/output alias attempts. Confirm the media service has no network
   and the delivery service cannot read an unrelated selected folder.
6. Install a Sparkle update from the sandboxed release candidate and verify installer-service signatures,
   rollback behavior, and app relaunch.
7. Run real FTP, explicit FTPS, and SFTP upload/stat/failure drills from the signed sandboxed archive.
8. Decide the Adobe DNG Converter outcome explicitly and disclose any unavailable state before shipping.

Until these gates pass, Hardened Runtime plus the existing manifest, security-scoped bookmark, atomic-write,
and privacy-log controls remain the supported release boundary.

## Authoritative platform references

- Apple, [Configuring the macOS App Sandbox](https://developer.apple.com/documentation/xcode/configuring-the-macos-app-sandbox)
- Apple, [Accessing files from the macOS App Sandbox](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)
- Apple, [Embedding a command-line tool in a sandboxed app](https://developer.apple.com/documentation/xcode/embedding-a-helper-tool-in-a-sandboxed-app)
- Apple, [XPC](https://developer.apple.com/documentation/xpc)
- Sparkle, [Sandboxing with Sparkle](https://sparkle-project.org/documentation/sandboxing/)

## Validation

This was a static feasibility and architecture audit. It intentionally did not change entitlements, add a
helper target, sign an archive, launch network connections, or claim runtime sandbox validation.

Repository documentation and static gates were run after this record and the checklist link were added; the
exact results were:

```text
audit checkboxes: total=75 done=37 open=38
broken local links in the audit plan and this record: none

scripts/ci/validate_repository.sh
metadata support and bundled-source generated-document checks: passed
tracked JSON documents: 24 valid
property lists and project.pbxproj: valid
bundled-component validator tests: 4 passed
FFmpeg, c2patool, and AuraFace declarations/artifacts: validated
logger privacy validation: passed across 334 Swift files
conflict-marker scan: passed
git diff --check: passed
```
