#!/usr/bin/env python3
"""Lock reviewed privacy invariants for investigation reports, maps, and temp files."""

from __future__ import annotations

import re
import sys
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Requirement:
    label: str
    path: Path
    pattern: re.Pattern[str]
    minimum_count: int = 1


def required(label: str, path: str, pattern: str, minimum_count: int = 1) -> Requirement:
    return Requirement(label, Path(path), re.compile(pattern, re.DOTALL), minimum_count)


REQUIREMENTS = (
    required(
        "report defaults omit canonical paths in both model and UI",
        "Aagedal Photo Agent/Services/AnalysisPDFReportRenderer.swift",
        r"var\s+includeCanonicalPath\s*=\s*false",
    ),
    required(
        "report model defaults omit camera serial numbers",
        "Aagedal Photo Agent/Services/AnalysisPDFReportRenderer.swift",
        r"var\s+includeCameraSerialNumber\s*=\s*false",
    ),
    required(
        "report model defaults omit exact coordinates",
        "Aagedal Photo Agent/Services/AnalysisPDFReportRenderer.swift",
        r"var\s+includeLocationCoordinates\s*=\s*false",
    ),
    required(
        "report model defaults omit raw metadata",
        "Aagedal Photo Agent/Services/AnalysisPDFReportRenderer.swift",
        r"var\s+includeRawMetadata\s*=\s*false",
    ),
    required(
        "report model defaults to an offline schematic map",
        "Aagedal Photo Agent/Services/AnalysisPDFReportRenderer.swift",
        r"var\s+mapBasemap:\s*AnalysisReportMapBasemap\s*=\s*\.schematic",
    ),
    required(
        "report UI defaults omit exact coordinates",
        "Aagedal Photo Agent/Views/Analysis/AnalysisWorkspaceView.swift",
        r"@State\s+private\s+var\s+includeLocationCoordinates\s*=\s*false",
    ),
    required(
        "report UI defaults omit raw metadata",
        "Aagedal Photo Agent/Views/Analysis/AnalysisWorkspaceView.swift",
        r"@State\s+private\s+var\s+includeRawMetadata\s*=\s*false",
    ),
    required(
        "report UI defaults to an offline schematic map",
        "Aagedal Photo Agent/Views/Analysis/AnalysisWorkspaceView.swift",
        r"@State\s+private\s+var\s+mapBasemap:\s*AnalysisReportMapBasemap\s*=\s*\.schematic",
    ),
    required(
        "report UI discloses the OpenStreetMap request destination and coordinate class",
        "Aagedal Photo Agent/Views/Analysis/AnalysisWorkspaceView.swift",
        r"sends the visible map region as tile coordinates to OpenStreetMap",
    ),
    required(
        "report destination uses an atomic write",
        "Aagedal Photo Agent/Views/Analysis/AnalysisWorkspaceView.swift",
        r"data\.write\(to:\s*outputURL,\s*options:\s*\.atomic\)",
    ),
    required(
        "OpenStreetMap requests use an ephemeral session",
        "Aagedal Photo Agent/Services/AnalysisOpenStreetMapSnapshotter.swift",
        r"URLSessionConfiguration\.ephemeral",
    ),
    required(
        "OpenStreetMap requests disable the URL cache",
        "Aagedal Photo Agent/Services/AnalysisOpenStreetMapSnapshotter.swift",
        r"configuration\.urlCache\s*=\s*nil",
    ),
    required(
        "OpenStreetMap requests do not consult persistent cached data",
        "Aagedal Photo Agent/Services/AnalysisOpenStreetMapSnapshotter.swift",
        r"requestCachePolicy\s*=\s*\.reloadIgnoringLocalCacheData",
    ),
    required(
        "OpenStreetMap requests use the reviewed HTTPS tile origin",
        "Aagedal Photo Agent/Services/AnalysisOpenStreetMapSnapshotter.swift",
        r'"https://tile\.openstreetmap\.org/\\\(zoom\)/\\\(wrappedX\)/\\\(y\)\.png"',
    ),
    required(
        "interactive OpenStreetMap tiles use an ephemeral session",
        "Aagedal Photo Agent/Views/Analysis/AnalysisOpenStreetMapView.swift",
        r"URLSessionConfiguration\.ephemeral",
    ),
    required(
        "interactive OpenStreetMap tiles disable the URL cache",
        "Aagedal Photo Agent/Views/Analysis/AnalysisOpenStreetMapView.swift",
        r"configuration\.urlCache\s*=\s*nil",
    ),
    required(
        "interactive OpenStreetMap tiles use the reviewed HTTPS origin",
        "Aagedal Photo Agent/Views/Analysis/AnalysisOpenStreetMapView.swift",
        r'urlTemplate:\s*"https://tile\.openstreetmap\.org/\{z\}/\{x\}/\{y\}\.png"',
    ),
    required(
        "project export staging has an unpredictable name",
        "Aagedal Photo Agent/Services/ImageAnalysisProjectArchive.swift",
        r'"pint-export-\\\(UUID\(\)\.uuidString\)"',
    ),
    required(
        "project import staging has an unpredictable name",
        "Aagedal Photo Agent/Services/ImageAnalysisProjectArchive.swift",
        r'"pint-import-\\\(UUID\(\)\.uuidString\)"',
    ),
    required(
        "project archive staging is removed on success and failure paths",
        "Aagedal Photo Agent/Services/ImageAnalysisProjectArchive.swift",
        r"defer\s*\{\s*try\?\s*FileManager\.default\.removeItem\(at:\s*(?:stagingRoot|extracted\.stagingRoot)\)\s*\}",
        minimum_count=3,
    ),
    required(
        "temporary FTP credentials are created exclusively with owner-only permissions",
        "Aagedal Photo Agent/Services/FTPService.swift",
        r"open\(url\.path,\s*O_WRONLY\s*\|\s*O_CREAT\s*\|\s*O_EXCL,\s*mode_t\(0o600\)\)",
    ),
    required(
        "temporary FTP credentials are removed after each operation",
        "Aagedal Photo Agent/Services/FTPService.swift",
        r"defer\s*\{\s*try\?\s*FileManager\.default\.removeItem\(at:\s*netrcURL\)\s*\}",
        minimum_count=2,
    ),
)


def validate(root: Path) -> list[str]:
    contents: dict[Path, str] = {}
    failures: list[str] = []
    for requirement in REQUIREMENTS:
        absolute = root / requirement.path
        if requirement.path not in contents:
            try:
                contents[requirement.path] = absolute.read_text(encoding="utf-8")
            except OSError as error:
                failures.append(f"{requirement.path}: cannot read reviewed surface: {error}")
                continue
        count = len(requirement.pattern.findall(contents[requirement.path]))
        if count < requirement.minimum_count:
            failures.append(
                f"{requirement.path}: privacy invariant missing: {requirement.label} "
                f"(found {count}, need {requirement.minimum_count})"
            )
    return failures


def main() -> int:
    root = Path(sys.argv[1]) if len(sys.argv) == 2 else Path.cwd()
    if len(sys.argv) > 2 or not (root / "Aagedal Photo Agent").is_dir():
        print(f"usage: {Path(sys.argv[0]).name} [REPOSITORY_ROOT]", file=sys.stderr)
        return 2

    failures = validate(root)
    if failures:
        print("\n".join(failures), file=sys.stderr)
        print(
            "Investigation privacy behavior changed; review the report, map, and temporary-file "
            "boundary before updating this validator.",
            file=sys.stderr,
        )
        return 1

    print(f"investigation privacy validation passed ({len(REQUIREMENTS)} invariants)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
