# 3.0 documentation-readiness validation — 2026-08-25

**Scope:** Phase 12 README, feature help, limitations, privacy text, licenses, and CHANGELOG draft  
**Result:** complete; all six release-facing drafts and license labels are consistent

## Release-facing set

| Required draft | Evidence | Result |
|---|---|---|
| README | [`README.md`](../README.md) now summarizes the implemented 3.0 analysis, OSINT/report, comparison, named-version, metadata, and Deadline boundaries and links the detailed drafts. The stale `x-default`-only Title statement was corrected to match the checked-in SwiftExif fork and current validation. | Draft complete |
| Feature help | [`feature-help-3.0.md`](feature-help-3.0.md) gives task-oriented help for the focused workspaces, reports/projects, comparison, named versions, rename/delivery, and external authenticity links. Static inspection also found control-level `.help`/accessibility copy in the analysis, comparison, Develop-version, Caption, Deadline, map/solar, shortcut, and Known People privacy surfaces. | Draft complete; hands-on help/accessibility review remains a separate Phase 12 gate |
| Limitations | [`limitations-3.0.md`](limitations-3.0.md) consolidates evidence, source/report, maps/solar, comparison/rendering, metadata/delivery, optional-model, and release-readiness boundaries. It does not present conditional forensic analyzers as shipped. | Draft complete |
| Privacy text | [`PRIVACY.md`](../PRIVACY.md) documents local/folder storage, Application Support fallback, optional iCloud categories, face data, Keychain, delivery evidence, network features, external links, logs/reports, retention, and deletion. It is explicitly a release-candidate draft pending the separate runtime and external legal/privacy gates. | Draft complete |
| Licenses | The README component table, Settings → Licenses, checked-in license resources, and `bundled-components.json` were audited. FFmpeg, c2patool, Sparkle, AuraFace, SwiftExif, and the application have present, consistent texts/labels; the manifest validator accepts every declared binary/model artifact. | Draft complete |
| CHANGELOG | [`CHANGELOG.md`](../CHANGELOG.md) describes the implemented 3.0 investigation, comparison/version, metadata, Caption/Deadline, privacy, and documentation scope and explicitly excludes the unapproved conditional analyzers. | Draft complete |

## SwiftExif license reconciliation — 2026-08-27

The exact pinned upstream revision was inspected in the public
[`aagedal/SwiftExif`](https://github.com/aagedal/SwiftExif) repository:

- revision `47249c72b613ebab8e4514f4adf05bb8000a1908` is the fork's `main` revision;
- its `LICENSE` is the GNU GPL version 3 text;
- its README explicitly identifies the project as GPL-3.0;
- the repository's initial revision also contains the GNU GPL version 3 license text.

The stale local-fork README sentence was corrected from MIT to GPL-3.0. The vendored README and license,
in-app component label/text, and public component table now agree. This documentation-only reconciliation
does not change source or license terms.

## Scope reconciliation

The drafts were compared with the authoritative 3.0 plans and current implementation surfaces. In
particular, they distinguish the implemented deterministic solar-position direction overlay from the
unapproved sun/shadow consistency analyzer, distinguish optional AuraFace face matching from an unapproved
AI-origin detector, describe Meta/Google checks as user-opened external pages rather than integrations,
and retain the documented delivery, C2PA, metadata-interoperability, hardware, display, privacy, recovery,
and manual-validation limits.

This result does not close the separate Phase 12 privacy, accessibility/localization, performance/GPU,
device/display, recovery, upgrade/downgrade, or release-packaging gates.

## Automated checks

Run from the repository root on 2026-08-25:

```sh
python3 -B scripts/generate_bundled_component_docs.py --check
python3 -B scripts/generate_metadata_field_support.py --check
python3 -B scripts/ci/test_bundled_component_validator.py
python3 -B scripts/ci/validate_bundled_components.py
scripts/ci/validate_repository.sh
```

Results:

- bundled-source README offer current;
- generated metadata support table current;
- bundled-component validator self-tests passed (4 tests);
- FFmpeg 9.0.1, c2patool 0.26.69, and optional packaged AuraFace declarations/artifacts validated;
- repository JSON, property-list/project, privacy, conflict-marker, and whitespace gates passed; and
- repository validation exited successfully.
