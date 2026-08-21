# Manual release-prerequisite audit — 2026-08-21

This read-only audit checked the development Mac and repository without launching GUI applications,
changing external state, or exposing connection values or secrets.

## Available

- Adobe Bridge 2026 16.0.6 and Photo Mechanic 2026.2 build 9034 are installed, and their preference
  domains exist. Activation/login and actual metadata read/write remain unverified until launch.
- Xcode 26.6, Accessibility Inspector 5.0, VoiceOver, VoiceOver Utility, `xcresulttool`, and
  `xctrace` are installed.
- Git tags and the appcast identify the historical 2.0.0, 2.1.0, and 2.2.0 releases.

## Not release-ready locally

- No Bridge- or Photo Mechanic-produced round-trip fixtures exist in the repository.
- One saved FTPS configuration has non-secret connection fields, but it has no matching Keychain
  credential. No FTP or SFTP test configuration/credential is available. Repository network tests
  use documentation addresses, localhost, or injected transports rather than representative
  servers.
- The signed 2.0.0, 2.1.0, and 2.2.0 application bundles/installers are not local. A 2.3.0 archive
  is not a substitute for the downgrade drill.
- The app's iCloud container exists, but it contains no evicted `.icloud` placeholder suitable for
  a real offline/recovery test.
- No representative disposable removable disk or explicitly read-only user test volume is mounted.
  System/recovery/toolchain volumes are unsafe targets and are excluded.
- The repository has model/static accessibility tests but no UI-test target or recorded manual
  VoiceOver, Full Keyboard Access, IME, large-text/localization, contrast/motion, window-extreme, or
  external-display Clean Feed run.

## Smallest external actions

1. Launch Bridge and Photo Mechanic, confirm activation, and execute the documented JPEG plus
   RAW/XMP read/write round trips.
2. Provision disposable FTP, explicit-FTPS, and SFTP endpoints and store their credentials through
   the app's Keychain-backed UI.
3. Download or provide archived signed 2.0.0, 2.1.0, and 2.2.0 applications for isolated downgrade
   testing.
4. Put a non-sensitive image in the app's iCloud container, wait for sync, and use Remove Download
   to create a real placeholder.
5. Attach/designate a disposable removable volume and a separate explicitly read-only test volume.
6. Run the accessibility checklist with Accessibility Inspector, VoiceOver, and Full Keyboard
   Access and record dated observations.

Connection preference and Keychain inspection reported only presence/absence. Hostnames, usernames,
remote paths, connection identifiers, and secret values were not copied into this record.
