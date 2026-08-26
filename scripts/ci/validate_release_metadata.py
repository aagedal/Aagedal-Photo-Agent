#!/usr/bin/env python3
"""Validate credential-free release metadata before CI or release signing."""

from __future__ import annotations

import argparse
import base64
import binascii
import plistlib
import re
import sys
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlparse


SPARKLE_NAMESPACE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
VERSION_PATTERN = re.compile(r"[0-9]+(?:\.[0-9]+){2}")


@dataclass(frozen=True)
class ReleaseSettings:
    version: str
    build: int
    minimum_system_version: str


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def unique_build_setting(project: str, key: str) -> str:
    values = set(
        re.findall(rf"^\s*{re.escape(key)}\s*=\s*([^;]+);", project, re.MULTILINE)
    )
    require(values, f"Xcode project does not declare {key}")
    require(len(values) == 1, f"Xcode project has inconsistent {key} values: {sorted(values)}")
    return next(iter(values)).strip()


def read_release_settings(root: Path) -> ReleaseSettings:
    project_path = root / "Aagedal Photo Agent.xcodeproj/project.pbxproj"
    project = project_path.read_text(encoding="utf-8")
    version = unique_build_setting(project, "MARKETING_VERSION")
    build_text = unique_build_setting(project, "CURRENT_PROJECT_VERSION")
    minimum_system_version = unique_build_setting(project, "MACOSX_DEPLOYMENT_TARGET")
    require(VERSION_PATTERN.fullmatch(version) is not None, f"invalid MARKETING_VERSION: {version}")
    require(build_text.isdigit() and int(build_text) > 0, f"invalid CURRENT_PROJECT_VERSION: {build_text}")
    require(
        re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,2}", minimum_system_version) is not None,
        f"invalid MACOSX_DEPLOYMENT_TARGET: {minimum_system_version}",
    )
    return ReleaseSettings(version, int(build_text), minimum_system_version)


def decoded_base64(value: str, field: str, expected_bytes: int) -> bytes:
    try:
        decoded = base64.b64decode(value, validate=True)
    except (binascii.Error, ValueError) as error:
        raise ValueError(f"{field} is not valid base64") from error
    require(len(decoded) == expected_bytes, f"{field} must decode to {expected_bytes} bytes")
    return decoded


def validate_info_plist(root: Path) -> None:
    path = root / "Aagedal Photo Agent/Info.plist"
    with path.open("rb") as handle:
        info = plistlib.load(handle)
    require(info.get("CFBundleShortVersionString") == "$(MARKETING_VERSION)",
            "Info.plist must derive CFBundleShortVersionString from MARKETING_VERSION")
    require(info.get("CFBundleVersion") == "$(CURRENT_PROJECT_VERSION)",
            "Info.plist must derive CFBundleVersion from CURRENT_PROJECT_VERSION")
    require(info.get("LSMinimumSystemVersion") == "$(MACOSX_DEPLOYMENT_TARGET)",
            "Info.plist must derive LSMinimumSystemVersion from MACOSX_DEPLOYMENT_TARGET")
    feed_url = str(info.get("SUFeedURL", ""))
    parsed_feed = urlparse(feed_url)
    require(parsed_feed.scheme == "https" and parsed_feed.netloc and parsed_feed.path.endswith(".xml"),
            "SUFeedURL must be an absolute HTTPS XML URL")
    decoded_base64(str(info.get("SUPublicEDKey", "")), "SUPublicEDKey", 32)


def validate_changelog(root: Path, settings: ReleaseSettings) -> None:
    changelog = (root / "CHANGELOG.md").read_text(encoding="utf-8")
    heading = re.search(
        rf"^##[ \t]+{re.escape(settings.version)}(?:[ \t]+[^\n]*)?$", changelog, re.MULTILINE
    )
    require(heading is not None, f"CHANGELOG.md has no section for {settings.version}")
    section_start = heading.end()
    next_heading = re.search(r"^##\s+", changelog[section_start:], re.MULTILINE)
    section_end = section_start + next_heading.start() if next_heading else len(changelog)
    section = changelog[section_start:section_end]
    highlights = re.search(r"^###\s+Highlights\s*$", section, re.MULTILINE)
    require(highlights is not None, f"CHANGELOG.md {settings.version} has no Highlights section")
    highlights_start = highlights.end()
    next_subheading = re.search(r"^###\s+", section[highlights_start:], re.MULTILINE)
    highlights_end = (
        highlights_start + next_subheading.start() if next_subheading else len(section)
    )
    highlight_text = section[highlights_start:highlights_end]
    bullets = re.findall(r"^-\s+\S.*$", highlight_text, re.MULTILINE)
    require(bullets, f"CHANGELOG.md {settings.version} Highlights has no release-note bullet")
    require("]]>" not in highlight_text,
            "CHANGELOG.md Highlights contains a CDATA terminator that would break appcast.xml")


def validate_security_policy(root: Path, settings: ReleaseSettings) -> None:
    security = (root / "SECURITY.md").read_text(encoding="utf-8")
    release_line = f"{settings.version.rsplit('.', 1)[0]}.x"
    require(
        f"Supported release line: `{release_line}`" in security,
        f"SECURITY.md must declare Supported release line: `{release_line}`",
    )


def child_text(item: ET.Element, local_name: str) -> str:
    child = item.find(f"{{{SPARKLE_NAMESPACE}}}{local_name}")
    return "" if child is None or child.text is None else child.text.strip()


def validate_appcast(root: Path, settings: ReleaseSettings) -> int:
    appcast_path = root / "appcast.xml"
    try:
        document = ET.parse(appcast_path)
    except ET.ParseError as error:
        raise ValueError(f"appcast.xml is not well-formed XML: {error}") from error

    items = document.findall("./channel/item")
    require(items, "appcast.xml has no release items")
    versions: set[str] = set()
    builds: set[int] = set()
    current_build: int | None = None
    previous_build: int | None = None
    for index, item in enumerate(items, start=1):
        short_version = child_text(item, "shortVersionString")
        build_text = child_text(item, "version")
        minimum_system_version = child_text(item, "minimumSystemVersion")
        require(VERSION_PATTERN.fullmatch(short_version) is not None,
                f"appcast item {index} has invalid shortVersionString: {short_version}")
        require(build_text.isdigit() and int(build_text) > 0,
                f"appcast item {short_version} has invalid build: {build_text}")
        build = int(build_text)
        require(short_version not in versions, f"appcast has duplicate version {short_version}")
        require(build not in builds, f"appcast has duplicate build {build}")
        require(previous_build is None or build < previous_build,
                "appcast items must be ordered by strictly decreasing build number")
        versions.add(short_version)
        builds.add(build)
        previous_build = build

        title = (item.findtext("title") or "").strip()
        require(title == f"Version {short_version}",
                f"appcast item {short_version} title does not match its version")
        require(minimum_system_version != "", f"appcast item {short_version} has no minimum OS")
        enclosure = item.find("enclosure")
        require(enclosure is not None, f"appcast item {short_version} has no enclosure")
        attributes = enclosure.attrib
        require(attributes.get(f"{{{SPARKLE_NAMESPACE}}}version") == build_text,
                f"appcast item {short_version} enclosure build does not match")
        require(attributes.get(f"{{{SPARKLE_NAMESPACE}}}shortVersionString") == short_version,
                f"appcast item {short_version} enclosure version does not match")
        require(attributes.get("type") == "application/octet-stream",
                f"appcast item {short_version} enclosure has unexpected content type")
        url = urlparse(attributes.get("url", ""))
        require(url.scheme == "https" and url.netloc and url.path.endswith(f"-{short_version}.dmg"),
                f"appcast item {short_version} enclosure must be an absolute HTTPS versioned DMG URL")
        length = attributes.get("length", "")
        require(length.isdigit() and int(length) > 0,
                f"appcast item {short_version} has invalid enclosure length")
        decoded_base64(
            attributes.get(f"{{{SPARKLE_NAMESPACE}}}edSignature", ""),
            f"appcast item {short_version} EdDSA signature",
            64,
        )
        if short_version == settings.version:
            current_build = build

    if current_build is not None:
        require(current_build == settings.build,
                f"appcast {settings.version} build {current_build} does not match project build {settings.build}")
    else:
        require(max(builds) < settings.build,
                f"project build {settings.build} must exceed every published appcast build")
    return len(items)


def validate(root: Path) -> tuple[ReleaseSettings, int]:
    settings = read_release_settings(root)
    validate_info_plist(root)
    validate_changelog(root, settings)
    validate_security_policy(root, settings)
    item_count = validate_appcast(root, settings)
    return settings, item_count


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path.cwd(), help="repository root")
    arguments = parser.parse_args()
    try:
        settings, item_count = validate(arguments.root.resolve())
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        print(f"release metadata validation failed: {error}", file=sys.stderr)
        return 1
    print(
        "release metadata validation passed: "
        f"{settings.version} ({settings.build}), macOS {settings.minimum_system_version}, "
        f"{item_count} published appcast item(s)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
