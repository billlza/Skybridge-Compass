#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${REPO_ROOT}/Scripts/validate_macos_release_artifact_run.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/skybridge-release-artifact-run-test.XXXXXX")"
trap 'rm -rf "${TMP_DIR}"' EXIT

mkdir -p "${TMP_DIR}/bin"

cat >"${TMP_DIR}/bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

endpoint=""
for arg in "$@"; do
  case "${arg}" in
    repos/*/actions/runs/*/artifacts*)
      endpoint="${arg}"
      ;;
    repos/*/actions/runs/*)
      endpoint="${arg}"
      ;;
  esac
done

case "${endpoint}" in
  repos/*/actions/runs/*/artifacts*)
    cat "${SKYBRIDGE_FAKE_ARTIFACTS_JSON}"
    ;;
  repos/*/actions/runs/*)
    cat "${SKYBRIDGE_FAKE_RUN_JSON}"
    ;;
  *)
    echo "unexpected gh invocation: $*" >&2
    exit 64
    ;;
esac
SH

chmod +x "${TMP_DIR}/bin/gh"

REPOSITORY="billlza/Skybridge-Compass"
RUN_ID="123456789"
RUN_ATTEMPT="2"
WORKFLOW_PATH=".github/workflows/real-device-release-gate.yml"
EVENT="workflow_dispatch"
HEAD_SHA="0123456789abcdef0123456789abcdef01234567"
HEAD_BRANCH="release/os27"
ARTIFACT_NAMES=(
  "real-device-connectivity-matrix"
  "real-device-p2p-remote-smoke"
  "real-device-file-transfer-smoke"
  "real-device-p2p-security-notice"
  "local-webrtc-security-notice"
  "local-macos-security-notice-panel"
)

write_payloads() {
  local run_json="$1"
  local artifacts_json="$2"

  RUN_ID_VALUE="${RUN_ID_VALUE:-${RUN_ID}}" \
    RUN_ATTEMPT_VALUE="${RUN_ATTEMPT_VALUE:-${RUN_ATTEMPT}}" \
    WORKFLOW_PATH_VALUE="${WORKFLOW_PATH_VALUE:-${WORKFLOW_PATH}}" \
    EVENT_VALUE="${EVENT_VALUE:-${EVENT}}" \
    STATUS_VALUE="${STATUS_VALUE:-completed}" \
    CONCLUSION_VALUE="${CONCLUSION_VALUE:-success}" \
    REPOSITORY_VALUE="${REPOSITORY_VALUE:-${REPOSITORY}}" \
    HEAD_REPOSITORY_VALUE="${HEAD_REPOSITORY_VALUE:-${REPOSITORY}}" \
    HEAD_SHA_VALUE="${HEAD_SHA_VALUE:-${HEAD_SHA}}" \
    HEAD_BRANCH_VALUE="${HEAD_BRANCH_VALUE:-${HEAD_BRANCH}}" \
    ARTIFACT_MODE_VALUE="${ARTIFACT_MODE_VALUE:-valid}" \
    python3 - "${run_json}" "${artifacts_json}" "${ARTIFACT_NAMES[@]}" <<'PY'
import json
import os
import sys

run_path, artifacts_path, *artifact_names = sys.argv[1:]

run_id = int(os.environ["RUN_ID_VALUE"])
run_attempt = int(os.environ["RUN_ATTEMPT_VALUE"])
workflow_path = os.environ["WORKFLOW_PATH_VALUE"]
event = os.environ["EVENT_VALUE"]
status = os.environ["STATUS_VALUE"]
conclusion = os.environ["CONCLUSION_VALUE"]
repository = os.environ["REPOSITORY_VALUE"]
head_repository = os.environ["HEAD_REPOSITORY_VALUE"]
head_sha = os.environ["HEAD_SHA_VALUE"]
head_branch = os.environ["HEAD_BRANCH_VALUE"]
artifact_mode = os.environ["ARTIFACT_MODE_VALUE"]

run = {
    "id": run_id,
    "run_attempt": run_attempt,
    "path": workflow_path,
    "event": event,
    "status": status,
    "conclusion": conclusion,
    "repository": {"full_name": repository},
    "head_repository": {"full_name": head_repository},
    "head_sha": head_sha,
    "head_branch": head_branch,
    "pull_requests": [],
}

artifacts = []
for index, name in enumerate(artifact_names, start=1):
    artifacts.append(
        {
            "id": 9000 + index,
            "node_id": f"artifact-node-{index}",
            "name": name,
            "size_in_bytes": 1024 + index,
            "expired": False,
            "digest": "sha256:" + f"{index:064x}"[-64:],
            "created_at": "2026-06-12T00:00:00Z",
            "updated_at": "2026-06-12T00:01:00Z",
            "workflow_run": {
                "id": run_id,
                "head_sha": head_sha,
                "head_branch": head_branch,
            },
        }
    )

if artifact_mode == "missing":
    artifacts = artifacts[:-1]
elif artifact_mode == "expired":
    artifacts[0]["expired"] = True
elif artifact_mode == "duplicate":
    artifacts.append(dict(artifacts[0]))
elif artifact_mode == "artifact-sha-mismatch":
    artifacts[0]["workflow_run"]["head_sha"] = "abcdefabcdefabcdefabcdefabcdefabcdefabcd"
elif artifact_mode == "missing-digest":
    artifacts[0].pop("digest", None)

payload = [{"total_count": len(artifacts), "artifacts": artifacts}]

with open(run_path, "w", encoding="utf-8") as handle:
    json.dump(run, handle)
with open(artifacts_path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle)
PY
}

run_target() {
  local output_path="$1"
  shift

  PATH="${TMP_DIR}/bin:${PATH}" \
    SKYBRIDGE_FAKE_RUN_JSON="${TMP_DIR}/run.json" \
    SKYBRIDGE_FAKE_ARTIFACTS_JSON="${TMP_DIR}/artifacts.json" \
    "${TARGET}" \
      --repository "${REPOSITORY}" \
      --run-id "${RUN_ID}" \
      --expected-run-attempt "${RUN_ATTEMPT}" \
      --expected-workflow-path "${WORKFLOW_PATH}" \
      --expected-event "${EVENT}" \
      --expected-head-sha "${HEAD_SHA}" \
      --expected-head-branch "${HEAD_BRANCH}" \
      --artifact "${ARTIFACT_NAMES[0]}" \
      --artifact "${ARTIFACT_NAMES[1]}" \
      --artifact "${ARTIFACT_NAMES[2]}" \
      --artifact "${ARTIFACT_NAMES[3]}" \
      --artifact "${ARTIFACT_NAMES[4]}" \
      --artifact "${ARTIFACT_NAMES[5]}" \
      --provenance-output "${output_path}" \
      "$@"
}

expect_success() {
  local description="$1"
  local output_path="${TMP_DIR}/provenance-${description//[^A-Za-z0-9]/-}.json"
  write_payloads "${TMP_DIR}/run.json" "${TMP_DIR}/artifacts.json"
  run_target "${output_path}" >/dev/null
  [[ -s "${output_path}" ]] || {
    echo "${description}: expected provenance output" >&2
    exit 1
  }
  grep -q '"run_attempt": 2' "${output_path}" || {
    echo "${description}: expected run_attempt in provenance output" >&2
    exit 1
  }
}

expect_failure_contains() {
  local description="$1"
  local expected_fragment="$2"
  shift 2

  local output=""
  local status=0
  set +e
  output="$("$@" 2>&1)"
  status=$?
  set -e

  if [[ "${status}" -eq 0 ]]; then
    echo "${description}: expected failure but command succeeded" >&2
    exit 1
  fi
  if [[ "${output}" != *"${expected_fragment}"* ]]; then
    printf '%s\n' "${output}" >&2
    echo "${description}: expected output to contain '${expected_fragment}'" >&2
    exit 1
  fi
}

expect_success "valid provenance"

write_payloads "${TMP_DIR}/run.json" "${TMP_DIR}/artifacts.json"
expect_failure_contains \
  "invalid run id" \
  "run id must be a positive integer" \
  env PATH="${TMP_DIR}/bin:${PATH}" \
    SKYBRIDGE_FAKE_RUN_JSON="${TMP_DIR}/run.json" \
    SKYBRIDGE_FAKE_ARTIFACTS_JSON="${TMP_DIR}/artifacts.json" \
    "${TARGET}" \
      --repository "${REPOSITORY}" \
      --run-id "123 456" \
      --expected-run-attempt "${RUN_ATTEMPT}" \
      --expected-workflow-path "${WORKFLOW_PATH}" \
      --expected-event "${EVENT}" \
      --expected-head-sha "${HEAD_SHA}" \
      --expected-head-branch "${HEAD_BRANCH}" \
      --artifact "${ARTIFACT_NAMES[0]}"

RUN_ATTEMPT_VALUE=3 write_payloads "${TMP_DIR}/run.json" "${TMP_DIR}/artifacts.json"
expect_failure_contains "run attempt mismatch" "run attempt mismatch" run_target "${TMP_DIR}/attempt.json"

WORKFLOW_PATH_VALUE=".github/workflows/other.yml" write_payloads "${TMP_DIR}/run.json" "${TMP_DIR}/artifacts.json"
expect_failure_contains "workflow path mismatch" "workflow path mismatch" run_target "${TMP_DIR}/workflow.json"

STATUS_VALUE="in_progress" write_payloads "${TMP_DIR}/run.json" "${TMP_DIR}/artifacts.json"
expect_failure_contains "status mismatch" "status mismatch" run_target "${TMP_DIR}/status.json"

CONCLUSION_VALUE="failure" write_payloads "${TMP_DIR}/run.json" "${TMP_DIR}/artifacts.json"
expect_failure_contains "conclusion mismatch" "conclusion mismatch" run_target "${TMP_DIR}/conclusion.json"

HEAD_SHA_VALUE="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" write_payloads "${TMP_DIR}/run.json" "${TMP_DIR}/artifacts.json"
expect_failure_contains "head sha mismatch" "head sha mismatch" run_target "${TMP_DIR}/sha.json"

HEAD_REPOSITORY_VALUE="attacker/fork" write_payloads "${TMP_DIR}/run.json" "${TMP_DIR}/artifacts.json"
expect_failure_contains "fork repository mismatch" "head repository mismatch" run_target "${TMP_DIR}/repo.json"

ARTIFACT_MODE_VALUE="missing" write_payloads "${TMP_DIR}/run.json" "${TMP_DIR}/artifacts.json"
expect_failure_contains "missing artifact" "must exist exactly once" run_target "${TMP_DIR}/missing.json"

ARTIFACT_MODE_VALUE="expired" write_payloads "${TMP_DIR}/run.json" "${TMP_DIR}/artifacts.json"
expect_failure_contains "expired artifact" "is expired" run_target "${TMP_DIR}/expired.json"

ARTIFACT_MODE_VALUE="duplicate" write_payloads "${TMP_DIR}/run.json" "${TMP_DIR}/artifacts.json"
expect_failure_contains "duplicate artifact" "must exist exactly once" run_target "${TMP_DIR}/duplicate.json"

ARTIFACT_MODE_VALUE="artifact-sha-mismatch" write_payloads "${TMP_DIR}/run.json" "${TMP_DIR}/artifacts.json"
expect_failure_contains "artifact workflow sha mismatch" "workflow_run.head_sha mismatch" run_target "${TMP_DIR}/artifact-sha.json"

ARTIFACT_MODE_VALUE="missing-digest" write_payloads "${TMP_DIR}/run.json" "${TMP_DIR}/artifacts.json"
expect_failure_contains "artifact missing digest" "missing a sha256 digest" run_target "${TMP_DIR}/digest.json"

printf '{not-json' >"${TMP_DIR}/run.json"
write_payloads "${TMP_DIR}/valid-run.json" "${TMP_DIR}/artifacts.json"
expect_failure_contains "invalid run json" "invalid JSON from GitHub API" run_target "${TMP_DIR}/invalid-json.json"

echo "[test-validate-release-artifact-run] passed"
