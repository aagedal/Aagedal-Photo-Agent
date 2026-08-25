#!/usr/bin/env bash

set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

say() { printf '\n==> %s\n' "$*"; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

say "Checking generated metadata support documentation"
python3 scripts/generate_metadata_field_support.py --check

say "Validating tracked JSON documents"
json_count=0
while IFS= read -r -d '' path; do
  python3 -m json.tool "$path" >/dev/null
  json_count=$((json_count + 1))
done < <(git ls-files -z -- '*.json')
printf 'validated %d JSON documents\n' "$json_count"

say "Validating tracked property lists and the Xcode project"
plist_count=0
while IFS= read -r -d '' path; do
  plutil -lint -- "$path" >/dev/null
  plist_count=$((plist_count + 1))
done < <(git ls-files -z -- '*.plist' '*.xcprivacy')
plutil -lint -- 'Aagedal Photo Agent.xcodeproj/project.pbxproj' >/dev/null
printf 'validated %d property lists and project.pbxproj\n' "$plist_count"

say "Checking unified-log privacy classifications"
python3 scripts/ci/test_logger_privacy_validator.py
python3 scripts/ci/validate_logger_privacy.py

say "Scanning tracked files for unresolved conflict markers"
conflict_output="$(git grep -n -I -E '^(<<<<<<< |=======$|>>>>>>> )' -- . 2>/dev/null || true)"
if [ -n "$conflict_output" ]; then
  printf '%s\n' "$conflict_output" >&2
  fail "unresolved merge-conflict markers found"
fi
printf 'no unresolved conflict markers found\n'

say "Checking whitespace errors"
git diff --check
if [ -n "${CI_DIFF_BASE:-}" ]; then
  git rev-parse --verify "${CI_DIFF_BASE}^{commit}" >/dev/null \
    || fail "CI_DIFF_BASE does not resolve to a commit: $CI_DIFF_BASE"
  git diff --check "${CI_DIFF_BASE}...HEAD"
fi
printf 'git diff --check passed\n'
