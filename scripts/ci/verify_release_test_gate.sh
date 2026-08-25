#!/usr/bin/env bash

set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

audit_file="${1:-build/release/release-test-gate.json}"
audit_log="${RELEASE_TEST_GATE_AUDIT_LOG:-$(dirname "$audit_file")/release-test-gate-audit.jsonl}"
workflow="${RELEASE_TEST_GATE_WORKFLOW:-ci.yml}"
repository="${RELEASE_GITHUB_REPOSITORY:-aagedal/Aagedal-Photo-Agent}"
revision="$(git rev-parse HEAD)"
timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
operator="${USER:-unknown}"

die() { printf 'release test gate: %s\n' "$*" >&2; exit 1; }
write_record() {
  local status="$1" reason="$2" run_json="${3:-}"
  mkdir -p "$(dirname "$audit_file")" "$(dirname "$audit_log")"
  GATE_STATUS="$status" GATE_REASON="$reason" GATE_RUN_JSON="$run_json" \
    GATE_REVISION="$revision" GATE_TIMESTAMP="$timestamp" GATE_OPERATOR="$operator" \
    GATE_WORKFLOW="$workflow" GATE_REPOSITORY="$repository" GATE_AUDIT_FILE="$audit_file" \
    python3 - <<'PY'
import json
import os
from pathlib import Path

run = json.loads(os.environ["GATE_RUN_JSON"]) if os.environ["GATE_RUN_JSON"] else None
record = {
    "schemaVersion": 1,
    "status": os.environ["GATE_STATUS"],
    "sourceRevision": os.environ["GATE_REVISION"],
    "recordedAt": os.environ["GATE_TIMESTAMP"],
    "operator": os.environ["GATE_OPERATOR"],
    "repository": os.environ["GATE_REPOSITORY"],
    "workflow": os.environ["GATE_WORKFLOW"],
}
if os.environ["GATE_REASON"]:
    record["reason"] = os.environ["GATE_REASON"]
if run is not None:
    record["workflowRun"] = run
Path(os.environ["GATE_AUDIT_FILE"]).write_text(
    json.dumps(record, indent=2, sort_keys=True) + "\n", encoding="utf-8"
)
PY
  python3 -c 'import json,sys; json.load(open(sys.argv[1], encoding="utf-8"))' "$audit_file"
  printf '%s\n' "$(python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1], encoding="utf-8")), separators=(",", ":"), sort_keys=True))' "$audit_file")" >> "$audit_log"
}

dirty="$(git status --porcelain --untracked-files=all)"
if [ -n "$dirty" ]; then
  printf '%s\n' "$dirty" >&2
  die "the source tree is not clean; commit the exact release source before testing and releasing"
fi

if [ "${RELEASE_TEST_GATE_OVERRIDE:-}" = "EMERGENCY" ]; then
  reason="${RELEASE_TEST_GATE_OVERRIDE_REASON:-}"
  [ "${#reason}" -ge 20 ] \
    || die "an emergency override requires RELEASE_TEST_GATE_OVERRIDE_REASON (at least 20 characters)"
  if [ "${RELEASE_TEST_GATE_OVERRIDE_CONFIRM:-}" != "$revision" ]; then
    if [ ! -t 0 ]; then
      die "set RELEASE_TEST_GATE_OVERRIDE_CONFIRM=$revision to confirm the non-interactive override"
    fi
    printf '\n*** EMERGENCY RELEASE TEST-GATE OVERRIDE ***\n' >&2
    printf 'Source revision: %s\nReason: %s\n' "$revision" "$reason" >&2
    read -r -p "Type the full source revision to continue: " confirmation
    [ "$confirmation" = "$revision" ] || die "override confirmation did not match the source revision"
  fi
  printf '\n!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n' >&2
  printf 'EMERGENCY OVERRIDE: RELEASE HAS NO VERIFIED PASSING CI RUN\n' >&2
  printf 'Revision: %s\nReason: %s\n' "$revision" "$reason" >&2
  printf '!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n\n' >&2
  write_record "emergency-override" "$reason"
  printf 'Emergency override recorded in %s and %s\n' "$audit_file" "$audit_log" >&2
  exit 0
fi

[ -z "${RELEASE_TEST_GATE_OVERRIDE:-}" ] \
  || die "RELEASE_TEST_GATE_OVERRIDE must be unset or exactly EMERGENCY"
command -v gh >/dev/null 2>&1 \
  || die "GitHub CLI is required to verify the exact-revision CI result"
gh auth status >/dev/null 2>&1 \
  || die "GitHub CLI is not authenticated; run 'gh auth login'"

run_list="$(gh run list \
  --repo "$repository" \
  --workflow "$workflow" \
  --commit "$revision" \
  --status success \
  --limit 20 \
  --json databaseId,headSha,conclusion,url,workflowName,event,createdAt)" \
  || die "could not query GitHub Actions for $revision"

run_json="$(GATE_RUN_LIST="$run_list" GATE_REVISION="$revision" python3 - <<'PY'
import json
import os

runs = json.loads(os.environ["GATE_RUN_LIST"])
revision = os.environ["GATE_REVISION"]
trusted = [
    run for run in runs
    if run.get("headSha") == revision
    and run.get("conclusion") == "success"
    and run.get("event") == "push"
]
if trusted:
    print(json.dumps(trusted[0], separators=(",", ":"), sort_keys=True))
PY
)"
[ -n "$run_json" ] \
  || die "no successful push run of $workflow is tied to exact revision $revision"

write_record "passed" "" "$run_json"
run_url="$(GATE_RUN_JSON="$run_json" python3 -c 'import json,os; print(json.loads(os.environ["GATE_RUN_JSON"])["url"])')"
printf 'Verified passing CI for exact source revision %s\n%s\n' "$revision" "$run_url"
