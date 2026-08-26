#!/usr/bin/env bash
#
# release.sh — Build, sign, notarize, package, and Sparkle-sign a release of
# Aagedal Photo Agent, then write the matching <item> into appcast.xml.
#
# It does NOT publish anything: the final step prints a checklist for uploading
# the DMG and synchronizing the GitHub and legacy Codeberg appcasts, because
# those steps need your accounts and are safer to keep explicit.
#
# No private or account-specific data is baked in. Anything machine-specific is
# either auto-detected from the project / keychain, or prompted for at runtime
# with an explanation of why it's needed. You can also preset any of them as
# environment variables to run unattended (see the CONFIG block).
#
# Usage:
#   scripts/release.sh
#   NOTARY_PROFILE=AC_NOTARY scripts/release.sh          # skip the prompt
#   RELEASE_BUILD_MODE=rebuild scripts/release.sh        # ignore saved builds
#
# A normal release requires a clean worktree and a successful macOS CI run for
# the exact HEAD revision. See README.md for the recorded emergency procedure.
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
# upload the DMG.
RELEASE_URL_BASE="${RELEASE_URL_BASE:-https://aagedal.me/apps/photoagent}"
# What to do when a matching archive or exported app already exists:
#   ask (default, interactive), reuse (best valid artifact), or rebuild.
RELEASE_BUILD_MODE="${RELEASE_BUILD_MODE:-ask}"

# Move to repo root (this script lives in scripts/).
cd "$(dirname "$0")/.."

say()  { printf '\n\033[1;34m▶ %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m✓ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m! %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

# Recheck the artifacts in this checkout immediately before any signing or
# packaging work. Remote CI validates committed declarations, but it cannot
# prove that a required local binary is still present and unmodified here.
say "Verifying bundled release artifacts"
python3 -B scripts/ci/validate_bundled_components.py \
  || die "Bundled component validation failed; restore or rebuild the declared artifacts before releasing."
ok "Bundled release artifacts match their pinned manifest"

# Catch version/build, changelog, security-policy, Sparkle, and appcast drift
# before consulting CI, credentials, or the keychain.
say "Verifying release metadata"
python3 -B scripts/ci/validate_release_metadata.py \
  || die "Release metadata validation failed; reconcile the project, changelog, security policy, Info.plist, and appcast."
ok "Release metadata is internally consistent"

# Verify this exact committed source before doing any keychain, signing,
# notarization, archive, or appcast work. The verifier also records the accepted
# workflow run (or the explicit emergency override) in OUTPUT_DIR.
say "Verifying exact-revision release test gate"
scripts/ci/verify_release_test_gate.sh "$OUTPUT_DIR/release-test-gate.json"
ok "Release test gate accepted and recorded"
SOURCE_REVISION="$(git rev-parse HEAD)"

artifact_matches_source_revision() {
  local marker="$1.source-revision"
  [ -f "$marker" ] && [ "$(tr -d '\r\n' < "$marker")" = "$SOURCE_REVISION" ]
}

record_artifact_source_revision() {
  printf '%s\n' "$SOURCE_REVISION" > "$1.source-revision"
}

artifact_app_version() {
  /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$1/Contents/Info.plist" 2>/dev/null || true
}

artifact_app_build() {
  /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$1/Contents/Info.plist" 2>/dev/null || true
}

app_matches_release() {
  [ -d "$1" ] \
    && [ "$(artifact_app_version "$1")" = "$VERSION" ] \
    && [ "$(artifact_app_build "$1")" = "$BUILD" ]
}

archive_app_path() {
  /usr/bin/find "$1/Products/Applications" -maxdepth 1 -name '*.app' -type d 2>/dev/null | head -1
}

archive_matches_release() {
  local archived_app
  [ -d "$1" ] || return 1
  archived_app="$(archive_app_path "$1")"
  [ -n "$archived_app" ] \
    && app_matches_release "$archived_app" \
    && artifact_matches_source_revision "$1"
}

choose_build_source() {
  local existing_app="$1" existing_archive="$2"
  local app_usable=0 archive_usable=0 choice default_choice
  local -a labels=() values=()

  if app_matches_release "$existing_app" \
    && artifact_matches_source_revision "$existing_app" \
    && codesign --verify --deep --strict "$existing_app" >/dev/null 2>&1; then
    app_usable=1
  elif [ -d "$existing_app" ]; then
    warn "Existing exported app does not match $VERSION ($BUILD) and exact source $SOURCE_REVISION, or its Developer ID signature is invalid; it will not be reused."
  fi

  if archive_matches_release "$existing_archive"; then
    archive_usable=1
  elif [ -d "$existing_archive" ]; then
    warn "Existing archive does not match $VERSION ($BUILD) and exact source $SOURCE_REVISION; it will not be reused."
  fi

  case "$RELEASE_BUILD_MODE" in
    rebuild)
      BUILD_CHOICE="rebuild"
      return
      ;;
    reuse)
      if [ "$app_usable" -eq 1 ]; then
        BUILD_CHOICE="app"
      elif [ "$archive_usable" -eq 1 ]; then
        BUILD_CHOICE="archive"
      else
        die "RELEASE_BUILD_MODE=reuse was requested, but no valid $VERSION ($BUILD) artifact exists."
      fi
      return
      ;;
    ask) ;;
    *) die "RELEASE_BUILD_MODE must be ask, reuse, or rebuild (got '$RELEASE_BUILD_MODE')." ;;
  esac

  if [ "$app_usable" -eq 0 ] && [ "$archive_usable" -eq 0 ]; then
    BUILD_CHOICE="rebuild"
    return
  fi

  # A non-interactive invocation cannot answer the menu safely.
  if [ ! -t 0 ] || [ ! -t 1 ]; then
    warn "Matching release artifacts exist, but no terminal is attached; rebuilding. Set RELEASE_BUILD_MODE=reuse to resume."
    BUILD_CHOICE="rebuild"
    return
  fi

  say "Resume release $VERSION (build $BUILD)"
  if [ "$app_usable" -eq 1 ]; then
    labels+=("Continue with the existing Developer ID app (skip archive and export)")
    values+=("app")
  fi
  if [ "$archive_usable" -eq 1 ]; then
    labels+=("Export/sign the existing archive (skip the Xcode rebuild)")
    values+=("archive")
  fi
  labels+=("Rebuild everything from source")
  values+=("rebuild")
  default_choice=1

  printf 'Reusable artifacts were found:\n'
  local index
  for ((index = 0; index < ${#labels[@]}; index++)); do
    printf '  %d) %s\n' "$((index + 1))" "${labels[$index]}"
  done
  while true; do
    read -r -p "Choose [${default_choice}]: " choice
    choice="${choice:-$default_choice}"
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#values[@]}" ]; then
      BUILD_CHOICE="${values[$((choice - 1))]}"
      return
    fi
    warn "Enter a number from 1 to ${#values[@]}."
  done
}

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
  say "Notarizing ${label}…"
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

# Keep the public support promise tied to the release being produced. A stale
# policy is a release-blocking documentation defect because it can tell users of
# the current build that they are ineligible for security fixes.
RELEASE_LINE="${VERSION%.*}.x"
if ! grep -Fq "Supported release line: \`$RELEASE_LINE\`" SECURITY.md; then
  die "SECURITY.md must declare 'Supported release line: \`$RELEASE_LINE\`' before releasing $VERSION."
fi
ok "Security policy covers release line $RELEASE_LINE"

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
set +e
NOTARY_CHECK="$(xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" 2>&1)"
NOTARY_CHECK_STATUS=$?
set -e
if [ "$NOTARY_CHECK_STATUS" -ne 0 ] || grep -Eqi '(^Error:|No Keychain password item|could not be found in the keychain|invalid credentials|authentication failed)' <<<"$NOTARY_CHECK"; then
  printf '%s\n' "$NOTARY_CHECK" >&2
  die "Notary profile '$NOTARY_PROFILE' could not authenticate. Recreate it with:
  xcrun notarytool store-credentials '$NOTARY_PROFILE' --apple-id '<your-apple-id>' --team-id '$TEAM_ID'"
fi
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

# ─── 6. Choose a fresh build or a safe resume point ───────────────────────────
# Archives are versioned so a failed notarization run can be resumed later
# without accidentally exporting a build from another release.
mkdir -p "$OUTPUT_DIR"
ARCHIVE="$OUTPUT_DIR/$DMG_STEM-$VERSION.xcarchive"
LEGACY_ARCHIVE="$OUTPUT_DIR/$DMG_STEM.xcarchive"
EXISTING_ARCHIVE="$ARCHIVE"
if [ ! -d "$EXISTING_ARCHIVE" ] && archive_matches_release "$LEGACY_ARCHIVE"; then
  EXISTING_ARCHIVE="$LEGACY_ARCHIVE"
fi
EXISTING_APP="$(/usr/bin/find "$OUTPUT_DIR/export" -maxdepth 1 -name '*.app' -type d 2>/dev/null | head -1)"
BUILD_CHOICE=""
choose_build_source "$EXISTING_APP" "$EXISTING_ARCHIVE"
ok "Release path: $BUILD_CHOICE"

if [ "$BUILD_CHOICE" = "rebuild" ]; then
  rm -rf "$ARCHIVE" "$LEGACY_ARCHIVE" "$OUTPUT_DIR/export"
  rm -f "$ARCHIVE.source-revision" "$LEGACY_ARCHIVE.source-revision"
  say "Archiving (Release)…"
  run_with_progress "Archiving" "$OUTPUT_DIR/archive.log" \
    xcodebuild -scheme "$SCHEME" -configuration Release -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE" archive \
    || die "Archive failed — see $OUTPUT_DIR/archive.log"
  record_artifact_source_revision "$ARCHIVE"
  ok "Archived: $ARCHIVE"
elif [ "$BUILD_CHOICE" = "archive" ]; then
  ARCHIVE="$EXISTING_ARCHIVE"
  ok "Reusing archive: $ARCHIVE"
fi

# ─── 7. Export with Developer ID ──────────────────────────────────────────────
# -allowProvisioningUpdates lets Xcode fetch/create the Developer ID provisioning
# profile the iCloud entitlement requires. If this fails with "PLA Update
# available", accept the updated agreement at developer.apple.com and re-run.
if [ "$BUILD_CHOICE" = "app" ]; then
  APP="$EXISTING_APP"
  ok "Reusing verified Developer ID app: $APP"
else
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
  rm -rf "$OUTPUT_DIR/export"
  say "Exporting (Developer ID)…"
  xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$EXPORT_OPTS" \
    -exportPath "$OUTPUT_DIR/export" -allowProvisioningUpdates >"$OUTPUT_DIR/export.log" 2>&1 \
    || die "Export failed — see $OUTPUT_DIR/export.log (if 'PLA Update available', accept the agreement at developer.apple.com and re-run)"
  APP="$(/usr/bin/find "$OUTPUT_DIR/export" -maxdepth 1 -name '*.app' -type d | head -1)"
  [ -n "$APP" ] || die "Exported .app not found."
  app_matches_release "$APP" || die "Exported app version/build does not match $VERSION ($BUILD)."
  codesign --verify --deep --strict "$APP" || die "Exported app failed signature verification."
  record_artifact_source_revision "$APP"
  ok "Exported & verified: $APP"
fi

# ─── 8. Notarize the app, then staple ─────────────────────────────────────────
if xcrun stapler validate "$APP" >/dev/null 2>&1; then
  ok "App already notarized & stapled"
else
  say "Checking for an accepted notarization ticket from an earlier run…"
  if xcrun stapler staple "$APP" >"$OUTPUT_DIR/staple-app-resume.log" 2>&1 \
    && xcrun stapler validate "$APP" >/dev/null 2>&1; then
    ok "Recovered the accepted notarization ticket; no resubmission needed"
  else
    ZIP="$OUTPUT_DIR/$DMG_STEM-$VERSION-app.zip"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    notarize "$ZIP" "App" "$OUTPUT_DIR/notarize-app.log"
    xcrun stapler staple "$APP" && xcrun stapler validate "$APP"
    ok "App notarized & stapled"
  fi
fi

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
[ -n "$NOTES" ] \
  || die "$CHANGELOG needs a '## $VERSION' section with at least one bullet under '### Highlights'."
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

ACTIVE_VERSION_COUNT="$(xmllint --xpath \
  "count(//*[local-name()='item']/*[local-name()='shortVersionString' and text()='$VERSION'])" \
  "$APPCAST" 2>/dev/null)" || die "Could not inspect active releases in $APPCAST."
if [ "$ACTIVE_VERSION_COUNT" != "0" ]; then
  printf '%s\n' "$ITEM" >"$OUTPUT_DIR/appcast-item.xml"
  ok "$VERSION already in $APPCAST — wrote the regenerated item to $OUTPUT_DIR/appcast-item.xml instead"
else
  ITEM_FILE="$OUTPUT_DIR/appcast-item.xml"
  printf '%s\n' "$ITEM" >"$ITEM_FILE"
  awk -v item_file="$ITEM_FILE" '
    /New release items are inserted here by scripts\/release\.sh/ && !d {
      print
      print ""
      while ((getline line < item_file) > 0) print line
      close(item_file)
      d=1
      next
    }
    { print }
  ' "$APPCAST" >"$APPCAST.tmp" && mv "$APPCAST.tmp" "$APPCAST"
  xmllint --noout "$APPCAST" || die "appcast.xml is no longer well-formed."
  ACTIVE_VERSION_COUNT="$(xmllint --xpath \
    "count(//*[local-name()='item']/*[local-name()='shortVersionString' and text()='$VERSION'])" \
    "$APPCAST" 2>/dev/null)"
  [ "$ACTIVE_VERSION_COUNT" = "1" ] \
    || die "$VERSION was not inserted as exactly one active appcast item."
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
