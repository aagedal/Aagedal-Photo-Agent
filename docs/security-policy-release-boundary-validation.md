# Security-policy release-boundary validation

**Date:** 2026-08-25
**Scope:** App improvement audit plan 1.3, supported-version policy and release check

## Implemented boundary

- `SECURITY.md` now identifies the current 3.0 release line, the GitHub reporting
  destination, the existing acknowledgement/update process, and the current parser,
  bundled-helper, network, and media surface without naming removed native SwiftExif
  dependencies.
- The supported release line has a machine-readable marker.
- `scripts/release.sh` derives the expected `major.minor.x` line from Xcode's
  `MARKETING_VERSION` and exits before signing, notarization, or artifact mutation when
  the security policy does not cover it.

## Automated evidence

The following checks passed against marketing version 3.0.0:

```sh
bash -n scripts/release.sh
release_version="$(awk -F' = ' '/MARKETING_VERSION =/{gsub(/;|[[:space:]]/,"",$2); print $2; exit}' \
  'Aagedal Photo Agent.xcodeproj/project.pbxproj')"
release_line="${release_version%.*}.x"
grep -F "Supported release line: \`$release_line\`" SECURITY.md
git diff --check
```

The complete release assistant was deliberately not run because it performs signing,
notarization, packaging, and appcast mutation. The remaining item 1.3 logging, privacy
manifest, sandbox/helper, and runtime log-capture gates remain open.
