# Security Policy

## Supported versions

Security fixes are provided for the latest 2.0 release. Older releases (1.x and
2.0 betas) are not maintained — please update before reporting.

| Version | Supported |
|---------|-----------|
| 2.0.x   | ✅        |
| < 2.0   | ❌        |

## Reporting a vulnerability

Report security issues through the project's Codeberg issue tracker:

**<https://codeberg.org/taagedal/Aagedal-Photo-Agent/issues/new>**

Start the issue title with **`[security]`** so it can be triaged and labelled
quickly. Aagedal Photo Agent is a local, single-user desktop app — it runs no
servers, so coordinated public disclosure here is appropriate for most findings.

To avoid handing out a working exploit before a fix is available, please:

- In the **initial** report, describe the issue and its impact at a level that
  lets it be assessed, but **hold back a full working exploit or a ready-to-run
  malicious sample** if the flaw looks exploitable and unpatched. A maintainer
  will reply in the thread to arrange the remaining details.
- Include the app version (Settings → Licenses shows the build) and your macOS
  version.
- Attach a minimal reproduction (a sample file or configuration) once asked, or
  from the start if the issue is low-risk.

> Codeberg does not yet support confidential/private issues. If you believe a
> finding is too sensitive to describe in public at all, open a minimal issue
> titled `[security] request private contact` with no technical detail, and a
> maintainer will arrange a channel.

You can expect an acknowledgement within **7 days** and a status update within
**30 days**. Once a fix ships, credit is given in the changelog unless you prefer
to remain anonymous. As this is a small open-source project there is no
bug-bounty program.

## Scope

Aagedal Photo Agent is a local, single-user macOS application. The most relevant
areas to look at:

- **Untrusted file parsing.** The app reads images, EXIF/IPTC/XMP metadata, and
  `.xmp` / JSON / face-data sidecars that may originate from untrusted sources.
  Parsing is handled in-process (SwiftExif → libexif/libiptcdata, Apple ImageIO,
  and the app's own XMP code). Memory-safety or injection issues triggered by a
  malicious file are in scope.
- **Path traversal.** Imports that read paths from files — e.g. keyword-list and
  Known People / Teams database (ZIP) import — must stay within their intended
  directories.
- **Credential and key storage.** FTP/SFTP passwords and C2PA signing private
  keys are stored in the macOS Keychain and must never be written to logs,
  sidecars, exported metadata, or synced via iCloud.
- **Content credentials (C2PA).** Signing certificate/key handling and manifest
  generation.
- **Network paths.** FTP/SFTP upload and the Sparkle auto-update channel
  (appcast over HTTPS, releases verified with an EdDSA signature).
- **iCloud sync.** Synced categories must never include passwords, signing keys,
  certificates, or machine-specific paths.

### Generally out of scope

- Attacks requiring a compromised local account or physical access to an
  unlocked Mac.
- Denial of service from intentionally malformed files that does not lead to
  code execution or data disclosure (please still report crashes — they are
  fixed as ordinary bugs).
- Findings in third-party dependencies that are already public and fixed
  upstream; please report those upstream and reference them here.

## A note on warranty

This software is distributed under the GPL-3.0 **with no warranty** (see
[LICENSE](LICENSE), sections 15–16). The security process above is a good-faith
effort, not a contractual guarantee.
