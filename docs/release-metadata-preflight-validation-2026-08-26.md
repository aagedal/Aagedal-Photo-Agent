# Release metadata preflight validation — 2026-08-26

**Scope:** credential-free release metadata and exact-revision gate controls  
**Result:** automated preflight complete; signed packaging and external publication remain manual

## Automated boundary

`scripts/ci/validate_release_metadata.py` now fails closed when release declarations drift before CI
or signing begins. It checks that:

- the Xcode project has one consistent semantic marketing version, positive integer build, and
  minimum macOS version;
- `Info.plist` derives its bundle versions and minimum OS from those build settings, uses an absolute
  HTTPS Sparkle XML feed, and contains a structurally valid 32-byte EdDSA public key;
- the current version has a `CHANGELOG.md` section with at least one Sparkle-ready Highlights bullet,
  with no CDATA terminator that could corrupt the generated appcast;
- `SECURITY.md` covers the current major/minor release line;
- every published appcast entry has a unique version and build, strictly decreasing build order,
  matching title/element/enclosure versions, a versioned HTTPS DMG URL, positive length, expected
  content type, and a structurally valid 64-byte EdDSA signature; and
- an already-published current version matches the project build, while an unpublished project build
  is newer than every published build.

The repository validation gate runs the validator's focused self-tests and then the real-repository
check. `scripts/release.sh` repeats the real check before the exact-revision CI lookup, signing
credentials, keychain, archive, or notarization work.

The exact-revision release-gate harness also proves that a successful pull-request run for the same
SHA is rejected: only a successful `push` run can authorize a normal release. It now separately proves
that an emergency override with a reason shorter than the documented minimum is rejected without
writing an audit acceptance record.

## Validation

Run from the repository root on 2026-08-26:

```sh
python3 -B scripts/ci/test_release_metadata_validator.py
python3 -B scripts/ci/validate_release_metadata.py
scripts/ci/test_release_test_gate.sh
bash -n scripts/release.sh scripts/ci/validate_repository.sh scripts/ci/test_release_test_gate.sh
scripts/ci/validate_repository.sh
git diff --check
```

Results:

- 9 release-metadata validator tests passed;
- repository metadata passed for project version 3.0.0, build 738, minimum macOS 26.0, and all six
  published appcast items;
- the release test-gate harness passed exact-SHA acceptance plus stale-SHA, pull-request, dirty-tree,
  and emergency-override rejection/audit controls;
- all edited shell scripts passed syntax validation; and
- the complete repository validation gate passed generated-document, release-metadata, JSON/plist,
  bundled-component, logger-privacy, investigation-privacy, conflict-marker, and whitespace checks.

## Remaining release boundary

This automation detects declaration drift; it does not claim any external or hardware-dependent
release result. A release operator must still obtain target-hardware performance/GPU/display evidence,
complete manual accessibility/privacy/recovery/upgrade tests, resolve the SwiftExif license conflict,
obtain a protected-branch required-check setting and release-candidate sign-off, and perform the signed
archive, Apple notarization, DMG publication, feed synchronization, tag, and Homebrew-cask update with
the required accounts and credentials.
