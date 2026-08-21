# Saved Deadline profile validation

**Validated:** 2026-08-21  
**Scope:** Phase 4 persistent profile catalog, selection, management, and safe live workspace input

## Implemented contract

- `DeadlineProfileRepository` owns one atomically written, versioned catalog with stable profile
  UUIDs and a persisted selected profile. Listings and fallback selection are deterministic. A
  FIFO access gate spans every awaited load/modify/save transaction, preventing actor reentrancy
  from losing overlapping mutations; the management UI disables mutation while busy.
- Version-one catalogs migrate to version two without losing profiles; malformed selections,
  duplicate IDs/names, and unsupported newer documents fail closed without rewriting the source.
- Create, update, duplicate, rename, import, export, select, and confirmed delete operations preserve
  identity rules. Imports never replace an existing identity and exports never overwrite a file.
- The repository and portable profile boundary accept only canonical UUID connection identifiers,
  matching `FTPConnection.id`. Passwords, private keys, URLs, query tokens, appended token data, and
  other connection credentials remain outside the profile document.
- A management sheet exposes selection and the repository operations. Deadline Workspace evaluates
  the exact selected saved profile and presents an empty state until the user creates or imports one;
  the former synthetic `Current Deadline` profile is gone.
- Live adapters currently expose metadata-template UUIDs and secret-free FTP connection UUIDs.
  Resource types without a stable adapter, uncaptured rename environments, unknown export
  capabilities, staging state, writability, and reachability remain explicit typed blockers rather
  than optimistic defaults. Remote paths receive only pure syntax and placeholder validation.

## Test evidence

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' \
  -destination 'platform=macOS' \
  -derivedDataPath '/private/tmp/aagedal-deadline-profile-repository-tests-01' \
  -only-testing:'Aagedal Photo Agent Tests/DeadlineProfileRepositoryTests' \
  -only-testing:'Aagedal Photo Agent Tests/DeadlinePreflightServiceTests' \
  -only-testing:'Aagedal Photo Agent Tests/DeadlinePreflightCoordinatorTests'
```

Result: **20 tests passed in 3 suites**. A separate full build-for-testing compiled the application
and test targets; PBX parsing and whitespace/diff checks also passed.

An independent concurrency/security regression run subsequently passed **51 tests in 4 suites**,
including 24 overlapping repository mutations followed by a fresh reopen and credential/token
identifier rejection.

## Remaining integration

- Add a complete profile field editor rather than relying on defaults and JSON import for content.
- Add stable live registries and revision counters for validation profiles, lists, rename recipes,
  and export presets.
- Capture real rename-directory, source permission, export capability, staging/free-space, and
  optional non-destructive destination reachability facts.
- Implement staged delivery execution and richer assignment packages.
