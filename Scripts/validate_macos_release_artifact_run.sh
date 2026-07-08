#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="validate-macos-release-artifact-run"

usage() {
  cat <<'EOF'
Usage:
  validate_macos_release_artifact_run.sh \
    --repository <owner/repo> \
    --run-id <workflow-run-id> \
    --expected-run-attempt <attempt> \
    --expected-workflow-path <.github/workflows/file.yml> \
    --expected-event <event> \
    --expected-head-sha <sha> \
    --expected-head-branch <branch> \
    --artifact <artifact-name> [--artifact <artifact-name> ...] \
    [--require-public-redacted-artifacts] \
    [--provenance-output <path>]

Validates the GitHub Actions run and artifact metadata used by the macOS release
readiness workflow before any release-gate artifact is downloaded.
EOF
}

fail() {
  echo "::error::[${SCRIPT_NAME}] $1" >&2
  exit 1
}

repository=""
run_id=""
expected_run_attempt=""
expected_workflow_path=""
expected_event=""
expected_head_sha=""
expected_head_branch=""
provenance_output=""
require_public_redacted_artifacts=0
required_artifacts=()

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --repository)
      [[ "$#" -ge 2 ]] || fail "missing value for --repository"
      repository="$2"
      shift 2
      ;;
    --run-id)
      [[ "$#" -ge 2 ]] || fail "missing value for --run-id"
      run_id="$2"
      shift 2
      ;;
    --expected-run-attempt)
      [[ "$#" -ge 2 ]] || fail "missing value for --expected-run-attempt"
      expected_run_attempt="$2"
      shift 2
      ;;
    --expected-workflow-path)
      [[ "$#" -ge 2 ]] || fail "missing value for --expected-workflow-path"
      expected_workflow_path="$2"
      shift 2
      ;;
    --expected-event)
      [[ "$#" -ge 2 ]] || fail "missing value for --expected-event"
      expected_event="$2"
      shift 2
      ;;
    --expected-head-sha)
      [[ "$#" -ge 2 ]] || fail "missing value for --expected-head-sha"
      expected_head_sha="$2"
      shift 2
      ;;
    --expected-head-branch)
      [[ "$#" -ge 2 ]] || fail "missing value for --expected-head-branch"
      expected_head_branch="$2"
      shift 2
      ;;
    --artifact)
      [[ "$#" -ge 2 ]] || fail "missing value for --artifact"
      required_artifacts+=("$2")
      shift 2
      ;;
    --require-public-redacted-artifacts)
      require_public_redacted_artifacts=1
      shift
      ;;
    --provenance-output)
      [[ "$#" -ge 2 ]] || fail "missing value for --provenance-output"
      provenance_output="$2"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

[[ -n "${repository}" ]] || fail "missing --repository"
[[ -n "${run_id}" ]] || fail "missing --run-id"
[[ -n "${expected_run_attempt}" ]] || fail "missing --expected-run-attempt"
[[ -n "${expected_workflow_path}" ]] || fail "missing --expected-workflow-path"
[[ -n "${expected_event}" ]] || fail "missing --expected-event"
[[ -n "${expected_head_sha}" ]] || fail "missing --expected-head-sha"
[[ -n "${expected_head_branch}" ]] || fail "missing --expected-head-branch"
[[ "${#required_artifacts[@]}" -gt 0 ]] || fail "at least one --artifact is required"

[[ "${repository}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
  || fail "repository must be owner/repo, got: ${repository}"
[[ "${run_id}" =~ ^[1-9][0-9]*$ ]] \
  || fail "run id must be a positive integer, got: ${run_id}"
[[ "${expected_run_attempt}" =~ ^[1-9][0-9]*$ ]] \
  || fail "expected run attempt must be a positive integer, got: ${expected_run_attempt}"
[[ "${expected_workflow_path}" =~ ^\.github/workflows/[A-Za-z0-9_.-]+\.ya?ml$ ]] \
  || fail "expected workflow path must be a repository workflow path, got: ${expected_workflow_path}"
[[ "${expected_head_sha}" =~ ^[0-9a-fA-F]{40}$ ]] \
  || fail "expected head sha must be a 40-character git SHA, got: ${expected_head_sha}"

command -v gh >/dev/null 2>&1 || fail "GitHub CLI (gh) is required"
command -v python3 >/dev/null 2>&1 || fail "python3 is required"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/skybridge-release-artifact-run.XXXXXX")"
trap 'rm -rf "${tmp_dir}"' EXIT

run_json="${tmp_dir}/run.json"
artifacts_json="${tmp_dir}/artifacts.json"
required_json="${tmp_dir}/required-artifacts.json"

python3 - "${required_json}" "${required_artifacts[@]}" <<'PY'
import json
import sys

with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(sys.argv[2:], handle)
PY

api_headers=(
  -H "Accept: application/vnd.github+json"
  -H "X-GitHub-Api-Version: 2022-11-28"
)

if ! gh api "${api_headers[@]}" "repos/${repository}/actions/runs/${run_id}" >"${run_json}"; then
  fail "GitHub API run lookup failed for ${repository}/actions/runs/${run_id}"
fi

if ! gh api --paginate --slurp "${api_headers[@]}" "repos/${repository}/actions/runs/${run_id}/artifacts?per_page=100" >"${artifacts_json}"; then
  fail "GitHub API artifact lookup failed for ${repository}/actions/runs/${run_id}"
fi

python3 - \
  "${run_json}" \
  "${artifacts_json}" \
  "${required_json}" \
  "${provenance_output}" \
  "${repository}" \
  "${run_id}" \
  "${expected_run_attempt}" \
  "${expected_workflow_path}" \
  "${expected_event}" \
  "${expected_head_sha}" \
  "${expected_head_branch}" \
  "${require_public_redacted_artifacts}" <<'PY'
import collections
import json
import os
import re
import sys

(
    run_json_path,
    artifacts_json_path,
    required_json_path,
    provenance_output,
    expected_repository,
    expected_run_id,
    expected_run_attempt,
    expected_workflow_path,
    expected_event,
    expected_head_sha,
    expected_head_branch,
    require_public_redacted_artifacts,
) = sys.argv[1:]

PREFIX = "::error::[validate-macos-release-artifact-run]"


def load_json(path):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return json.load(handle)
    except FileNotFoundError:
        print(f"{PREFIX} missing JSON file: {path}", file=sys.stderr)
        raise SystemExit(1)
    except json.JSONDecodeError as exc:
        print(f"{PREFIX} invalid JSON from GitHub API: {path}: {exc}", file=sys.stderr)
        raise SystemExit(1)


run = load_json(run_json_path)
artifact_payload = load_json(artifacts_json_path)
required_artifacts = load_json(required_json_path)
errors = []

if not isinstance(run, dict):
    errors.append("workflow run response must be a JSON object")
if not isinstance(required_artifacts, list) or not all(isinstance(name, str) for name in required_artifacts):
    errors.append("required artifact list must be an array of strings")

for name, count in collections.Counter(required_artifacts).items():
    if not name:
        errors.append("required artifact name must not be empty")
    if count != 1:
        errors.append(f"required artifact name must be unique: {name}")
    if require_public_redacted_artifacts == "1" and (
        "public-redacted" not in name and "redacted-public" not in name
    ):
        errors.append(
            f"required artifact name must declare the public-redaction contract: {name}"
        )

if errors:
    for error in errors:
        print(f"{PREFIX} {error}", file=sys.stderr)
    raise SystemExit(1)


def nested(mapping, *keys):
    value = mapping
    for key in keys:
        if not isinstance(value, dict):
            return None
        value = value.get(key)
    return value


def string(value):
    return "" if value is None else str(value)


run_checks = [
    ("run id", string(run.get("id")), expected_run_id),
    ("run attempt", string(run.get("run_attempt")), expected_run_attempt),
    ("workflow path", string(run.get("path")), expected_workflow_path),
    ("event", string(run.get("event")), expected_event),
    ("status", string(run.get("status")), "completed"),
    ("conclusion", string(run.get("conclusion")), "success"),
    ("repository", string(nested(run, "repository", "full_name")), expected_repository),
    ("head repository", string(nested(run, "head_repository", "full_name")), expected_repository),
    ("head sha", string(run.get("head_sha")), expected_head_sha),
    ("head branch", string(run.get("head_branch")), expected_head_branch),
]

for label, actual, expected in run_checks:
    if actual != expected:
        errors.append(f"{label} mismatch: expected {expected}, actual {actual or 'missing'}")

if string(run.get("pull_requests")) not in ("", "[]"):
    errors.append("producer run must not be pull_request-scoped")


def artifact_pages(payload):
    if isinstance(payload, dict):
        return [payload]
    if isinstance(payload, list):
        return payload
    errors.append("artifact response must be a JSON object or an array of paginated objects")
    return []


artifacts = []
for page in artifact_pages(artifact_payload):
    if not isinstance(page, dict):
        errors.append("artifact response page must be a JSON object")
        continue
    page_artifacts = page.get("artifacts")
    if not isinstance(page_artifacts, list):
        errors.append("artifact response page is missing artifacts array")
        continue
    artifacts.extend(page_artifacts)

artifacts_by_name = collections.defaultdict(list)
for artifact in artifacts:
    if not isinstance(artifact, dict):
        errors.append("artifact entry must be a JSON object")
        continue
    artifacts_by_name[string(artifact.get("name"))].append(artifact)

verified_artifacts = []
digest_pattern = re.compile(r"^sha256:[0-9a-f]{64}$")

for artifact_name in required_artifacts:
    matches = artifacts_by_name.get(artifact_name, [])
    if len(matches) != 1:
        errors.append(f"artifact {artifact_name} must exist exactly once, found {len(matches)}")
        continue

    artifact = matches[0]
    if artifact.get("expired") is not False:
        errors.append(f"artifact {artifact_name} is expired or missing expired=false")
    size = artifact.get("size_in_bytes")
    if not isinstance(size, int) or size <= 0:
        errors.append(f"artifact {artifact_name} must have a positive size_in_bytes")
    digest = string(artifact.get("digest"))
    if not digest_pattern.match(digest):
        errors.append(f"artifact {artifact_name} is missing a sha256 digest")

    workflow_run = artifact.get("workflow_run")
    if not isinstance(workflow_run, dict):
        errors.append(f"artifact {artifact_name} is missing workflow_run metadata")
    else:
        artifact_checks = [
            ("workflow_run.id", string(workflow_run.get("id")), expected_run_id),
            ("workflow_run.head_sha", string(workflow_run.get("head_sha")), expected_head_sha),
            ("workflow_run.head_branch", string(workflow_run.get("head_branch")), expected_head_branch),
        ]
        for label, actual, expected in artifact_checks:
            if actual != expected:
                errors.append(
                    f"artifact {artifact_name} {label} mismatch: expected {expected}, actual {actual or 'missing'}"
                )

    verified_artifacts.append(
        {
            "name": artifact_name,
            "id": artifact.get("id"),
            "node_id": artifact.get("node_id"),
            "size_in_bytes": size,
            "digest": digest,
            "expired": artifact.get("expired"),
            "created_at": artifact.get("created_at"),
            "updated_at": artifact.get("updated_at"),
        }
    )

if errors:
    for error in errors:
        print(f"{PREFIX} {error}", file=sys.stderr)
    raise SystemExit(1)

provenance = {
    "schema_version": 1,
    "repository": expected_repository,
    "run_id": int(expected_run_id),
    "run_attempt": int(expected_run_attempt),
    "workflow_path": expected_workflow_path,
    "event": expected_event,
    "status": "completed",
    "conclusion": "success",
    "head_sha": expected_head_sha,
    "head_branch": expected_head_branch,
    "artifacts": verified_artifacts,
}

if provenance_output:
    output_dir = os.path.dirname(provenance_output)
    if output_dir:
        os.makedirs(output_dir, exist_ok=True)
    with open(provenance_output, "w", encoding="utf-8") as handle:
        json.dump(provenance, handle, indent=2, sort_keys=True)
        handle.write("\n")

print(
    "[validate-macos-release-artifact-run] "
    f"verified run_id={expected_run_id} attempt={expected_run_attempt} "
    f"workflow={expected_workflow_path} sha={expected_head_sha} "
    f"artifacts={len(verified_artifacts)}"
)
PY
