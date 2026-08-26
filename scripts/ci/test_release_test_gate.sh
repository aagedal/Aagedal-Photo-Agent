#!/usr/bin/env bash

set -euo pipefail

source_root="$(git rev-parse --show-toplevel)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/photo-agent-release-gate.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT

repo="$test_root/repository"
mock_bin="$test_root/bin"
mkdir -p "$repo/scripts/ci" "$mock_bin"
cp "$source_root/scripts/ci/verify_release_test_gate.sh" "$repo/scripts/ci/"
printf 'release gate fixture\n' > "$repo/tracked.txt"

cat > "$mock_bin/gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "auth" ] && [ "${2:-}" = "status" ]; then
  exit 0
fi
if [ "${1:-}" = "run" ] && [ "${2:-}" = "list" ]; then
  printf '[{"databaseId":42,"headSha":"%s","conclusion":"success","url":"https://example.invalid/actions/runs/42","workflowName":"macOS CI","event":"%s","createdAt":"2026-08-25T12:00:00Z"}]\n' \
    "${MOCK_HEAD_SHA:?}" "${MOCK_EVENT:-push}"
  exit 0
fi
printf 'unexpected mock gh arguments: %s\n' "$*" >&2
exit 2
MOCK
chmod +x "$mock_bin/gh"

git init -q "$repo"
git -C "$repo" add scripts/ci/verify_release_test_gate.sh tracked.txt
git -C "$repo" -c user.name='Release Gate Test' -c user.email='release-gate@example.invalid' \
  commit -qm 'release gate fixture'
revision="$(git -C "$repo" rev-parse HEAD)"

(
  cd "$repo"
  PATH="$mock_bin:$PATH" MOCK_HEAD_SHA="$revision" \
    scripts/ci/verify_release_test_gate.sh .git/exact-result.json >/dev/null
)
python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["sourceRevision"] == sys.argv[2]' \
  "$repo/.git/exact-result.json" "$revision"

if (
  cd "$repo"
  PATH="$mock_bin:$PATH" MOCK_HEAD_SHA=0000000000000000000000000000000000000000 \
    scripts/ci/verify_release_test_gate.sh .git/stale-result.json >/dev/null 2>&1
); then
  printf 'stale successful result was incorrectly accepted\n' >&2
  exit 1
fi

if (
  cd "$repo"
  PATH="$mock_bin:$PATH" MOCK_HEAD_SHA="$revision" MOCK_EVENT=pull_request \
    scripts/ci/verify_release_test_gate.sh .git/pull-request-result.json >/dev/null 2>&1
); then
  printf 'pull-request result was incorrectly accepted as a trusted release run\n' >&2
  exit 1
fi

printf 'dirty\n' >> "$repo/tracked.txt"
if (
  cd "$repo"
  PATH="$mock_bin:$PATH" MOCK_HEAD_SHA="$revision" \
    scripts/ci/verify_release_test_gate.sh .git/dirty-result.json >/dev/null 2>&1
); then
  printf 'dirty source tree was incorrectly accepted\n' >&2
  exit 1
fi
git -C "$repo" restore tracked.txt

if (
  cd "$repo"
  RELEASE_TEST_GATE_OVERRIDE=EMERGENCY \
  RELEASE_TEST_GATE_OVERRIDE_REASON='too short' \
  RELEASE_TEST_GATE_OVERRIDE_CONFIRM="$revision" \
    scripts/ci/verify_release_test_gate.sh .git/short-reason-result.json >/dev/null 2>&1
); then
  printf 'under-documented emergency override was incorrectly accepted\n' >&2
  exit 1
fi

(
  cd "$repo"
  RELEASE_TEST_GATE_OVERRIDE=EMERGENCY \
  RELEASE_TEST_GATE_OVERRIDE_REASON='Production recovery requires an audited bypass' \
  RELEASE_TEST_GATE_OVERRIDE_CONFIRM="$revision" \
    scripts/ci/verify_release_test_gate.sh .git/override-result.json >/dev/null 2>&1
)
python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["status"] == "emergency-override"' \
  "$repo/.git/override-result.json"
test "$(wc -l < "$repo/.git/release-test-gate-audit.jsonl" | tr -d ' ')" = 2

printf 'release test-gate harness passed (exact, stale, pull-request, dirty, override controls)\n'
