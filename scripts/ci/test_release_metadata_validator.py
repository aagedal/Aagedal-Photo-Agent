#!/usr/bin/env python3
"""Focused tests for the credential-free release metadata validator."""

from __future__ import annotations

import base64
import plistlib
import tempfile
import unittest
from pathlib import Path

import validate_release_metadata as validator


class ReleaseMetadataValidatorTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        (self.root / "Aagedal Photo Agent.xcodeproj").mkdir()
        (self.root / "Aagedal Photo Agent").mkdir()
        self.write_project(version="3.0.0", build="738")
        self.write_info_plist()
        (self.root / "CHANGELOG.md").write_text(
            "# Changelog\n\n## 3.0.0 — Unreleased\n\n### Highlights\n\n- Ready to ship.\n",
            encoding="utf-8",
        )
        (self.root / "SECURITY.md").write_text(
            "Supported release line: `3.0.x`\n", encoding="utf-8"
        )
        self.write_appcast(version="2.2.0", build="428")

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def write_project(self, *, version: str, build: str) -> None:
        (self.root / "Aagedal Photo Agent.xcodeproj/project.pbxproj").write_text(
            f"MARKETING_VERSION = {version};\n"
            f"CURRENT_PROJECT_VERSION = {build};\n"
            "MACOSX_DEPLOYMENT_TARGET = 26.0;\n",
            encoding="utf-8",
        )

    def write_info_plist(self) -> None:
        info = {
            "CFBundleShortVersionString": "$(MARKETING_VERSION)",
            "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
            "AagedalSourceRevision": "$(AAGEDAL_SOURCE_REVISION)",
            "LSMinimumSystemVersion": "$(MACOSX_DEPLOYMENT_TARGET)",
            "SUFeedURL": "https://example.invalid/appcast.xml",
            "SUPublicEDKey": base64.b64encode(bytes(32)).decode(),
            "AuraFaceDistributionPublicEd25519Key": base64.b64encode(bytes(range(32))).decode(),
        }
        with (self.root / "Aagedal Photo Agent/Info.plist").open("wb") as handle:
            plistlib.dump(info, handle)

    def write_appcast(self, *, version: str, build: str, signature: str | None = None) -> None:
        signature = signature or base64.b64encode(bytes(64)).decode()
        (self.root / "appcast.xml").write_text(
            f'''<?xml version="1.0"?>
<rss xmlns:sparkle="{validator.SPARKLE_NAMESPACE}"><channel>
<item><title>Version {version}</title>
<sparkle:version>{build}</sparkle:version>
<sparkle:shortVersionString>{version}</sparkle:shortVersionString>
<sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
<enclosure url="https://example.invalid/App-{version}.dmg"
sparkle:version="{build}" sparkle:shortVersionString="{version}"
sparkle:edSignature="{signature}" length="123" type="application/octet-stream" />
</item></channel></rss>\n''',
            encoding="utf-8",
        )

    def test_valid_unpublished_release_metadata_passes(self) -> None:
        settings, items = validator.validate(self.root)
        self.assertEqual(settings.version, "3.0.0")
        self.assertEqual(settings.build, 738)
        self.assertEqual(items, 1)

    def test_current_published_version_must_match_project_build(self) -> None:
        self.write_appcast(version="3.0.0", build="737")
        with self.assertRaisesRegex(ValueError, "does not match project build"):
            validator.validate(self.root)

    def test_matching_current_published_version_passes(self) -> None:
        self.write_appcast(version="3.0.0", build="738")
        settings, items = validator.validate(self.root)
        self.assertEqual(settings.build, 738)
        self.assertEqual(items, 1)

    def test_project_build_must_advance_published_builds(self) -> None:
        self.write_project(version="3.0.0", build="400")
        with self.assertRaisesRegex(ValueError, "must exceed every published"):
            validator.validate(self.root)

    def test_security_policy_must_cover_release_line(self) -> None:
        (self.root / "SECURITY.md").write_text(
            "Supported release line: `2.2.x`\n", encoding="utf-8"
        )
        with self.assertRaisesRegex(ValueError, "SECURITY.md must declare"):
            validator.validate(self.root)

    def test_highlights_must_not_break_appcast_cdata(self) -> None:
        (self.root / "CHANGELOG.md").write_text(
            "# Changelog\n\n## 3.0.0\n\n### Highlights\n\n- Bad ]]> text.\n",
            encoding="utf-8",
        )
        with self.assertRaisesRegex(ValueError, "CDATA terminator"):
            validator.validate(self.root)

    def test_sparkle_signature_must_have_expected_size(self) -> None:
        self.write_appcast(version="2.2.0", build="428", signature="Zm9v")
        with self.assertRaisesRegex(ValueError, "must decode to 64 bytes"):
            validator.validate(self.root)

    def test_bundle_versions_must_derive_from_project_settings(self) -> None:
        self.write_info_plist()
        path = self.root / "Aagedal Photo Agent/Info.plist"
        with path.open("rb") as handle:
            info = plistlib.load(handle)
        info["CFBundleVersion"] = "737"
        with path.open("wb") as handle:
            plistlib.dump(info, handle)
        with self.assertRaisesRegex(ValueError, "CFBundleVersion"):
            validator.validate(self.root)

    def test_source_revision_must_derive_from_release_build_setting(self) -> None:
        path = self.root / "Aagedal Photo Agent/Info.plist"
        info = plistlib.loads(path.read_bytes())
        for value in (None, "", "$(OTHER_SETTING)", "a" * 40):
            with self.subTest(value=value):
                changed = dict(info)
                if value is None:
                    del changed["AagedalSourceRevision"]
                else:
                    changed["AagedalSourceRevision"] = value
                path.write_bytes(plistlib.dumps(changed))
                with self.assertRaisesRegex(ValueError, "AagedalSourceRevision"):
                    validator.validate(self.root)
        path.write_bytes(plistlib.dumps(info))

    def test_built_app_requires_exact_embedded_source_revision(self) -> None:
        app = self.root / "Built.app"
        (app / "Contents").mkdir(parents=True)
        info_path = app / "Contents/Info.plist"
        revision = "a" * 40
        info_path.write_bytes(plistlib.dumps({"AagedalSourceRevision": revision}))
        validator.validate_built_app_source_revision(app, revision)

        for embedded in (None, "", "A" * 40, "a" * 39, "$(AAGEDAL_SOURCE_REVISION)", "b" * 40):
            with self.subTest(embedded=embedded):
                payload = {} if embedded is None else {"AagedalSourceRevision": embedded}
                info_path.write_bytes(plistlib.dumps(payload))
                with self.assertRaises(ValueError):
                    validator.validate_built_app_source_revision(app, revision)

    def test_built_app_rejects_invalid_expected_source_revision(self) -> None:
        app = self.root / "Built.app"
        (app / "Contents").mkdir(parents=True)
        (app / "Contents/Info.plist").write_bytes(
            plistlib.dumps({"AagedalSourceRevision": "a" * 40})
        )
        for revision in ("", "A" * 40, "a" * 39, "a" * 41):
            with self.subTest(revision=revision):
                with self.assertRaisesRegex(ValueError, "expected source revision"):
                    validator.validate_built_app_source_revision(app, revision)

    def test_model_key_is_required_sized_and_separate(self) -> None:
        path = self.root / "Aagedal Photo Agent/Info.plist"
        for value in (None, "invalid", "Zm9v", base64.b64encode(bytes(32)).decode()):
            with self.subTest(value=value):
                self.write_info_plist()
                info = plistlib.loads(path.read_bytes())
                if value is None:
                    del info["AuraFaceDistributionPublicEd25519Key"]
                else:
                    info["AuraFaceDistributionPublicEd25519Key"] = value
                path.write_bytes(plistlib.dumps(info))
                with self.assertRaisesRegex(ValueError, "AuraFaceDistributionPublicEd25519Key"):
                    validator.validate(self.root)

    def test_release_gate_rejects_known_development_model_key(self) -> None:
        path = self.root / "Aagedal Photo Agent/Info.plist"
        info = plistlib.loads(path.read_bytes())
        info["AuraFaceDistributionPublicEd25519Key"] = base64.b64encode(
            validator.DEVELOPMENT_AURAFACE_PUBLIC_KEY
        ).decode()
        path.write_bytes(plistlib.dumps(info))

        # Credential-free repository validation can inspect a development checkout,
        # while the release entry point must reject this public trust anchor.
        validator.validate(self.root)
        with self.assertRaisesRegex(ValueError, "development trust anchor"):
            validator.validate(self.root, require_production_model_key=True)

        info["AuraFaceDistributionPublicEd25519Key"] = base64.b64encode(bytes(range(31, -1, -1))).decode()
        path.write_bytes(plistlib.dumps(info))
        validator.validate(self.root, require_production_model_key=True)

    def test_inconsistent_project_versions_fail_closed(self) -> None:
        project = self.root / "Aagedal Photo Agent.xcodeproj/project.pbxproj"
        project.write_text(
            project.read_text(encoding="utf-8") + "MARKETING_VERSION = 3.0.1;\n",
            encoding="utf-8",
        )
        with self.assertRaisesRegex(ValueError, "inconsistent MARKETING_VERSION"):
            validator.validate(self.root)


if __name__ == "__main__":
    unittest.main()
