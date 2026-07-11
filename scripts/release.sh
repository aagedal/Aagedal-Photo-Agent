#!/usr/bin/env bash
#
# release.sh — Build, sign, notarize, package, and Sparkle-sign a release of
# Aagedal Photo Agent, then write the matching <item> into appcast.xml.
#
# It does NOT publish anything: the final step prints a checklist for uploading
# the DMG + appcast to Codeberg, because that needs your account and is the one
# truly irreversible step.
#
# No private or account-specific data is baked in. Anything machine-specific is
# either auto-detected from the project / keychain, or prompted for at runtime
# with an explanation of why it's needed. You can also preset any of them as
# environment variables to run unattended (see the CONFIG block).
#
# Usage:
#   scripts/release.sh
#   NOTARY_PROFILE=AC_NOTARY scripts/release.sh          # skip the prompt
#
set -euo pipefail

# ─── CONFIG (override via env) ────────────────────────────────────────────────
SCHEME="${SCHEME:-Aagedal Photo Agent}"
DMG_STEM="${DMG_STEM:-Aagedal-Photo-Agent}"   # -> Aagedal-Photo-Agent-<version>.dmg
VOL_NAME="${VOL_NAME:-Aagedal Photo Agent}"   # mounted DMG volume name
APPCAST="${APPCAST:-appcast.xml}"
CHANGELOG="${CHANGELOG:-CHANGELOG.md}"
OUTPUT_DIR="${OUTPUT_DIR:-build/release}"
# Base URL the published DMG will live under. The enclosure URL becomes
# "$RELEASE_URL_BASE/<stem>-<version>.dmg" — must match where you actually
# upload the DMG. The DMG is too large for Codeberg release assets, so it is
# self-hosted at this flat path (no per-version subfolder).
RELEASE_URL_BASE="${RELEASE_URL_BASE:-https://aagedal.me/apps}"

# Move to repo root (this script lives in scripts/).
cd "$(dirname "$0")/.."

say()  { printf '\n\033[1;34m▶ %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m✓ %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

# Run a normally-silent command with a small terminal spinner while keeping its complete output in
# a log. On failure, print the useful tail immediately so the user does not have to hunt for it.
run_with_progress() {
  local label="$1" log="$2"
  shift 2
  "$@" >"$log" 2>&1 &
  local pid=$! start=$SECONDS frame=0
  local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  while kill -0 "$pid" 2>/dev/null; do
    printf '\r\033[2K  %s %s… %ds' "${frames[$frame]}" "$label" "$((SECONDS - start))"
    frame=$(((frame + 1) % ${#frames[@]}))
    sleep 0.2
  done
  set +e
  wait "$pid"
  local status=$?
  set -e
  if [ "$status" -eq 0 ]; then
    printf '\r\033[2K'
    return 0
  fi
  printf '\r\033[2K' >&2
  printf '\033[1;31mLast 60 lines of %s:\033[0m\n' "$log" >&2
  tail -60 "$log" >&2
  return "$status"
}

# Submit an artifact and, if Apple rejects it, automatically fetch the detailed issue log using the
# submission ID. Full notarytool output remains visible and is also retained in OUTPUT_DIR.
notarize() {
  local artifact="$1" label="$2" log="$3" submit_status
  say "Notarizing $label…"
  set +e
  xcrun notarytool submit "$artifact" --keychain-profile "$NOTARY_PROFILE" --wait --verbose 2>&1 | tee "$log"
  submit_status=${PIPESTATUS[0]}
  set -e

  local submission_id
  submission_id="$(sed -n 's/^[[:space:]]*id:[[:space:]]*//p' "$log" | head -1)"
  if [ "$submit_status" -eq 0 ] && grep -Eq '^[[:space:]]*status:[[:space:]]*Accepted[[:space:]]*$' "$log"; then
    ok "$label notarization accepted${submission_id:+ (submission $submission_id)}"
    return 0
  fi

  printf '\033[1;31m✗ %s notarization was not accepted (notarytool exit %s).\033[0m\n' "$label" "$submit_status" >&2
  if [ -n "$submission_id" ]; then
    local issue_log="$OUTPUT_DIR/notarize-$label-issues.json"
    printf 'Current Apple submission state:\n' >&2
    xcrun notarytool info --keychain-profile "$NOTARY_PROFILE" "$submission_id" 2>&1 | tee "$OUTPUT_DIR/notarize-$label-info.log" >&2 || true
    printf 'Fetching Apple diagnostic log for submission %s…\n' "$submission_id" >&2
    if xcrun notarytool log --keychain-profile "$NOTARY_PROFILE" "$submission_id" "$issue_log"; then
      printf '\n\033[1;31mApple notarization diagnostics:\033[0m\n' >&2
      cat "$issue_log" >&2
    else
      printf 'Could not download the diagnostic log; inspect submission %s manually.\n' "$submission_id" >&2
    fi
  else
    printf 'No submission ID was returned. Check credentials/network output in %s.\n' "$log" >&2
  fi
  die "$label notarization failed — full submit output: $log"
}

# ─── 1. Toolchain: full Xcode (not just Command Line Tools) ───────────────────
# WHY: archiving/exporting a .app needs the full Xcode toolchain. The CLT-only
# path that `xcode-select` often points at cannot build app targets.
if [ -z "${DEVELOPER_DIR:-}" ]; then
  sel="$(xcode-select -p 2>/dev/null || true)"
  if [[ "$sel" == *"/Xcode.app/"* ]]; then
    DEVELOPER_DIR="$sel"
  elif [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
    DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
  else
    die "Full Xcode not found. Install Xcode and set DEVELOPER_DIR, or run: sudo xcode-select -s /Applications/Xcode.app"
  fi
fi
export DEVELOPER_DIR
ok "Xcode: $DEVELOPER_DIR"

# ─── 2. Read version / build / team / min-OS straight from the project ────────
# WHY: keeps the DMG name, appcast version, and minimumSystemVersion in lockstep
# with whatever is set in the Xcode project — no hand-editing here.
SETTINGS="$(xcodebuild -scheme "$SCHEME" -configuration Release -showBuildSettings 2>/dev/null)"
get() { awk -F' = ' -v k="$1" '$0 ~ "^[[:space:]]*"k" = "{gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2; exit}' <<<"$SETTINGS"; }
VERSION="$(get MARKETING_VERSION)"
BUILD="$(get CURRENT_PROJECT_VERSION)"
TEAM_ID="$(get DEVELOPMENT_TEAM)"
MIN_OS="$(get MACOSX_DEPLOYMENT_TARGET)"
[ -n "$VERSION" ] && [ -n "$BUILD" ] && [ -n "$TEAM_ID" ] || die "Could not read version/build/team from the project."
ok "Version $VERSION (build $BUILD), team $TEAM_ID, min macOS $MIN_OS"

# ─── 3. Signing identity (Developer ID Application) ───────────────────────────
# WHY: distribution outside the App Store must be signed with a "Developer ID
# Application" certificate (Apple Development certs can't be notarized). This is
# read from your login keychain; nothing secret is printed or stored.
SIGN_ID="$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/{print $2; exit}')"
[ -n "$SIGN_ID" ] || die "No 'Developer ID Application' certificate in your keychain. Create one at developer.apple.com → Certificates."
ok "Signing identity: $SIGN_ID"

# ─── 4. Notarization credential (keychain profile) ────────────────────────────
# WHY: notarytool uploads the build to Apple to be scanned. We use a stored
# *keychain profile* so no Apple ID / app-specific password is ever typed here
# or written to disk by this script.
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
if [ -z "$NOTARY_PROFILE" ]; then
  cat <<EOF
Notarization uses a one-time keychain profile so no password lives in this
script or the repo. If you haven't created one yet, run (once):

  xcrun notarytool store-credentials "AC_NOTARY" \\
      --apple-id "<your-apple-id>" --team-id $TEAM_ID

It prompts for an app-specific password from appleid.apple.com
(Sign-In & Security → App-Specific Passwords).
EOF
  read -r -p "notarytool keychain profile name: " NOTARY_PROFILE
  [ -n "$NOTARY_PROFILE" ] || die "A notarytool profile name is required."
fi
ok "Notary profile: $NOTARY_PROFILE"
say "Validating notarization credentials…"
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null \
  || die "Notary profile '$NOTARY_PROFILE' could not authenticate. Recreate it with 'xcrun notarytool store-credentials'."
ok "Notarization credentials accepted"

# ─── 5. Sparkle tools + key sanity ────────────────────────────────────────────
# WHY: the appcast enclosure needs an EdDSA signature from Sparkle's sign_update.
# We also confirm the private key in your keychain matches the SUPublicEDKey the
# app ships with — a mismatch would make every client silently reject the update.
SPARKLE_BIN_DIR="${SPARKLE_BIN_DIR:-$(dirname "$(find "$HOME/Library/Developer/Xcode/DerivedData" -path '*artifacts/sparkle/Sparkle/bin/sign_update' -type f 2>/dev/null | head -1)")}"
SIGN_UPDATE="$SPARKLE_BIN_DIR/sign_update"
GENERATE_KEYS="$SPARKLE_BIN_DIR/generate_keys"
[ -x "$SIGN_UPDATE" ] || die "Sparkle sign_update not found. Build the app once (resolves the Sparkle SwiftPM artifact) or set SPARKLE_BIN_DIR."
INFO_PLIST="$(/usr/bin/find . -name Info.plist -path '*/Aagedal Photo Agent/*' | head -1)"
PUB_PLIST="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$INFO_PLIST" 2>/dev/null || true)"
if [ -x "$GENERATE_KEYS" ] && [ -n "$PUB_PLIST" ]; then
  PUB_KC="$("$GENERATE_KEYS" -p 2>/dev/null || true)"
  [ "$PUB_KC" = "$PUB_PLIST" ] || die "Sparkle key mismatch: keychain public key != app's SUPublicEDKey. Updates would be rejected."
  ok "Sparkle signing key matches the app's embedded public key"
fi

# ─── 6. Archive (Release) ─────────────────────────────────────────────────────
rm -rf "$OUTPUT_DIR" && mkdir -p "$OUTPUT_DIR"
ARCHIVE="$OUTPUT_DIR/$DMG_STEM.xcarchive"
say "Archiving (Release)…"
run_with_progress "Archiving" "$OUTPUT_DIR/archive.log" \
  xcodebuild -scheme "$SCHEME" -configuration Release -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE" archive \
  || die "Archive failed — see $OUTPUT_DIR/archive.log"
ok "Archived"

# ─── 7. Export with Developer ID ──────────────────────────────────────────────
# -allowProvisioningUpdates lets Xcode fetch/create the Developer ID provisioning
# profile the iCloud entitlement requires. If this fails with "PLA Update
# available", accept the updated agreement at developer.apple.com and re-run.
EXPORT_OPTS="$OUTPUT_DIR/ExportOptions.plist"
cat >"$EXPORT_OPTS" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>automatic</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
</dict></plist>
EOF
say "Exporting (Developer ID)…"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$EXPORT_OPTS" \
  -exportPath "$OUTPUT_DIR/export" -allowProvisioningUpdates >"$OUTPUT_DIR/export.log" 2>&1 \
  || die "Export failed — see $OUTPUT_DIR/export.log (if 'PLA Update available', accept the agreement at developer.apple.com and re-run)"
APP="$(/usr/bin/find "$OUTPUT_DIR/export" -maxdepth 1 -name '*.app' | head -1)"
[ -n "$APP" ] || die "Exported .app not found."
codesign --verify --deep --strict "$APP" || die "Exported app failed signature verification."
ok "Exported & verified: $APP"

# ─── 8. Notarize the app, then staple ─────────────────────────────────────────
ZIP="$OUTPUT_DIR/$DMG_STEM-app.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
notarize "$ZIP" "App" "$OUTPUT_DIR/notarize-app.log"
xcrun stapler staple "$APP" && xcrun stapler validate "$APP"
ok "App notarized & stapled"

# ─── 9. Build, sign, notarize, staple the DMG ─────────────────────────────────
DMG="$OUTPUT_DIR/$DMG_STEM-$VERSION.dmg"
say "Building DMG…"
STAGE="$OUTPUT_DIR/dmg-staging"
rm -rf "$STAGE" && mkdir -p "$STAGE"
ditto "$APP" "$STAGE/$(basename "$APP")"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$VOL_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
codesign --force --sign "$SIGN_ID" --timestamp "$DMG"
notarize "$DMG" "DMG" "$OUTPUT_DIR/notarize-dmg.log"
xcrun stapler staple "$DMG" && xcrun stapler validate "$DMG"
spctl -a -t open --context context:primary-signature "$DMG" >/dev/null 2>&1 && ok "Gatekeeper accepts the DMG"
ok "DMG ready: $DMG"

# ─── 10. Sparkle EdDSA signature ──────────────────────────────────────────────
say "Signing for Sparkle…"
SIG_LINE="$("$SIGN_UPDATE" "$DMG")"   # -> sparkle:edSignature="…" length="…"
ED_SIG="$(sed -n 's/.*edSignature="\([^"]*\)".*/\1/p' <<<"$SIG_LINE")"
LENGTH="$(sed -n 's/.*length="\([0-9]*\)".*/\1/p' <<<"$SIG_LINE")"
[ -n "$ED_SIG" ] && [ -n "$LENGTH" ] || die "Could not parse Sparkle signature output: $SIG_LINE"
ok "EdDSA signature obtained (length $LENGTH)"

# ─── 11. Build the appcast <item> (release notes pulled from CHANGELOG) ───────
# Highlights come from the "### Highlights" bullets under "## <version>" in the
# changelog, so user-facing notes stay in sync with what you already wrote there.
NOTES="$(awk -v ver="$VERSION" '
  $0 ~ "^## "ver { inver=1; next }
  inver && /^## /  { exit }
  inver && /^### Highlights/ { inh=1; next }
  inh && /^### / { inh=0 }
  inh && /^- / { sub(/^- /,""); print "                    <li>" $0 "</li>" }
' "$CHANGELOG")"
[ -n "$NOTES" ] || NOTES="                    <li>See the changelog for details.</li>"
PUBDATE="$(date '+%a, %d %b %Y %H:%M:%S %z')"
DMG_URL="$RELEASE_URL_BASE/$DMG_STEM-$VERSION.dmg"
ITEM="        <item>
            <title>Version $VERSION</title>
            <pubDate>$PUBDATE</pubDate>
            <sparkle:version>$BUILD</sparkle:version>
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
            <description><![CDATA[
                <ul>
$NOTES
                </ul>
            ]]></description>
            <enclosure
                url=\"$DMG_URL\"
                sparkle:version=\"$BUILD\"
                sparkle:shortVersionString=\"$VERSION\"
                sparkle:edSignature=\"$ED_SIG\"
                length=\"$LENGTH\"
                type=\"application/octet-stream\" />
        </item>"

if grep -q "<sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>" "$APPCAST"; then
  printf '%s\n' "$ITEM" >"$OUTPUT_DIR/appcast-item.xml"
  ok "$VERSION already in $APPCAST — wrote the regenerated item to $OUTPUT_DIR/appcast-item.xml instead"
else
  awk -v item="$ITEM" '/^[[:space:]]*<item>/ && !d { print item; print ""; d=1 } { print }' "$APPCAST" >"$APPCAST.tmp" && mv "$APPCAST.tmp" "$APPCAST"
  xmllint --noout "$APPCAST" || die "appcast.xml is no longer well-formed."
  ok "Inserted the $VERSION item into $APPCAST"
fi

# ─── 12. What's left (publishing — your call, not automated) ──────────────────
cat <<EOF

$(printf '\033[1;32m━━━ Release build complete ━━━\033[0m')

  DMG:     $DMG
  SHA-256: $(shasum -a 256 "$DMG" | awk '{print $1}')
  Size:    $LENGTH bytes

Publish steps (manual — outward-facing, not automated):
  1. Upload the DMG to your web host so it is reachable at exactly:
        $DMG_URL
  2. Update the Sparkle appcast feed (SUFeedURL:
        $(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$INFO_PLIST" 2>/dev/null))
     with the now-updated $APPCAST.
  3. Commit + push the $APPCAST change, and tag the release ($VERSION).
EOF
