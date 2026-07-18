#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
EXPECTED_ARTIFACT_DATE="2026-01-23"
ARTIFACT_DATE="${ARTIFACT_DATE:-${SKYBRIDGE_ARTIFACT_DATE:-$EXPECTED_ARTIFACT_DATE}}"
if [[ "${ARTIFACT_DATE}" != "${EXPECTED_ARTIFACT_DATE}" ]]; then
  echo "ARTIFACT_DATE must be ${EXPECTED_ARTIFACT_DATE}, got ${ARTIFACT_DATE}" >&2
  exit 2
fi

GATES_DIR="${ROOT_DIR}/Artifacts/gates"
GATE_LOG_DIR="${GATES_DIR}/logs"
mkdir -p "${GATE_LOG_DIR}"

if [[ -z "${GATE_NAME:-}" ]]; then
  echo "GATE_NAME must be set by the caller script." >&2
  exit 2
fi
if [[ -z "${GATE_DOMAIN:-}" ]]; then
  echo "GATE_DOMAIN must be set by the caller script." >&2
  exit 2
fi

GATE_START_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
CHECK_ROWS_FILE="$(mktemp)"

cleanup_gate_tmp() {
  rm -f "${CHECK_ROWS_FILE}"
}
trap cleanup_gate_tmp EXIT

count_pattern_hits() {
  local pattern="$1"
  local file_path="$2"
  local matches=""
  local scan_status=0

  if matches="$(/usr/bin/grep -En "${pattern}" "${file_path}")"; then
    printf '%s\n' "${matches}" | wc -l | tr -d ' '
  else
    scan_status=$?
    if [[ "${scan_status}" -eq 1 ]]; then
      printf '0\n'
      return 0
    fi
    echo "gate log scan failed for ${file_path} with status ${scan_status}" >&2
    return "${scan_status}"
  fi
}

sanitize_field() {
  printf '%s' "$1" | tr '\t\r\n' ' ' | sed 's/  */ /g'
}

_run_gate_check() {
  local check_id="$1"
  local check_domain="$2"
  local owner_hint="$3"
  local enforce_zero_warnings="$4"
  shift 4

  local started_at ended_at
  started_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  local log_path="${GATE_LOG_DIR}/${GATE_NAME}_${check_id}_${ARTIFACT_DATE}.log"
  local exit_code=0

  if (cd "${ROOT_DIR}" && "$@") >"${log_path}" 2>&1; then
    exit_code=0
  else
    exit_code=$?
  fi

  local warning_count error_count status message
  warning_count="$(count_pattern_hits '(^|[^[:alpha:]])(warning:|WARNING:)' "${log_path}")"
  error_count="$(count_pattern_hits '(^|[^[:alpha:]])(error:|ERROR:)' "${log_path}")"

  status="pass"
  message="ok"
  if [[ "${exit_code}" -ne 0 ]]; then
    status="fail"
    message="command exited with ${exit_code}"
  elif [[ "${enforce_zero_warnings}" == "1" && ( "${warning_count}" -gt 0 || "${error_count}" -gt 0 ) ]]; then
    status="fail"
    message="zero-warning gate violated (warnings=${warning_count}, errors=${error_count})"
  fi

  ended_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(sanitize_field "${check_id}")" \
    "$(sanitize_field "${check_domain}")" \
    "$(sanitize_field "${owner_hint}")" \
    "$(sanitize_field "${status}")" \
    "${exit_code}" \
    "${warning_count}" \
    "${error_count}" \
    "$(sanitize_field "${log_path}")" \
    "${started_at}" \
    "${ended_at}" \
    "$(sanitize_field "${message}")" \
    >>"${CHECK_ROWS_FILE}"
}

run_check_strict_no_warnings() {
  local check_id="$1"
  local owner_hint="$2"
  local check_domain="${3:-${GATE_DOMAIN}}"
  if [[ $# -lt 4 ]]; then
    echo "run_check_strict_no_warnings requires command arguments." >&2
    exit 2
  fi
  shift 3
  _run_gate_check "${check_id}" "${check_domain}" "${owner_hint}" "1" "$@"
}

run_check_allow_warnings() {
  local check_id="$1"
  local owner_hint="$2"
  local check_domain="${3:-${GATE_DOMAIN}}"
  if [[ $# -lt 4 ]]; then
    echo "run_check_allow_warnings requires command arguments." >&2
    exit 2
  fi
  shift 3
  _run_gate_check "${check_id}" "${check_domain}" "${owner_hint}" "0" "$@"
}

finalize_gate_report() {
  local gate_finished_at json_out md_out
  gate_finished_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  json_out="${GATES_DIR}/${GATE_NAME}_${ARTIFACT_DATE}.json"
  md_out="${GATES_DIR}/${GATE_NAME}_${ARTIFACT_DATE}.md"

  python3 - "${CHECK_ROWS_FILE}" "${GATE_NAME}" "${GATE_DOMAIN}" "${ARTIFACT_DATE}" "${GATE_START_AT}" "${gate_finished_at}" "${json_out}" "${md_out}" <<'PY'
import csv
import json
import pathlib
import sys

rows_path, gate_name, gate_domain, artifact_date, started_at, finished_at, json_out, md_out = sys.argv[1:]

checks = []
with open(rows_path, "r", encoding="utf-8") as fh:
    reader = csv.reader(fh, delimiter="\t")
    for row in reader:
        if len(row) != 11:
            continue
        (
            check_id,
            check_domain,
            owner_hint,
            status,
            exit_code,
            warning_count,
            error_count,
            log_path,
            check_started_at,
            check_finished_at,
            message,
        ) = row
        checks.append(
            {
                "id": check_id,
                "domain": check_domain,
                "owner_hint": owner_hint,
                "status": status,
                "exit_code": int(exit_code),
                "warning_count": int(warning_count),
                "error_count": int(error_count),
                "log_path": log_path,
                "started_at": check_started_at,
                "finished_at": check_finished_at,
                "message": message,
            }
        )

failed = next((c for c in checks if c["status"] != "pass"), None)
status = "pass" if failed is None else "fail"
report = {
    "schema_version": 1,
    "gate_name": gate_name,
    "artifact_date": artifact_date,
    "domain": gate_domain,
    "status": status,
    "failed_domain": None if failed is None else failed["domain"],
    "failed_check_id": None if failed is None else failed["id"],
    "owner_hint": "none" if failed is None else failed["owner_hint"],
    "started_at": started_at,
    "finished_at": finished_at,
    "checks": checks,
}

json_path = pathlib.Path(json_out)
json_path.parent.mkdir(parents=True, exist_ok=True)
json_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

md_lines = [
    f"# {gate_name} report",
    "",
    f"- Schema version: `1`",
    f"- Artifact date: `{artifact_date}`",
    f"- Domain: `{gate_domain}`",
    f"- Status: **{status.upper()}**",
    f"- Failed domain: `{report['failed_domain']}`",
    f"- Failed check: `{report['failed_check_id']}`",
    f"- Owner hint: `{report['owner_hint']}`",
    "",
    "## Checks",
    "",
    "| Check ID | Domain | Status | Owner | Exit | Warnings | Errors | Log |",
    "|---|---|---|---|---:|---:|---:|---|",
]

for check in checks:
    md_lines.append(
        "| {id} | {domain} | {status} | {owner} | {exit} | {warnings} | {errors} | `{log}` |".format(
            id=check["id"],
            domain=check["domain"],
            status=check["status"],
            owner=check["owner_hint"],
            exit=check["exit_code"],
            warnings=check["warning_count"],
            errors=check["error_count"],
            log=check["log_path"],
        )
    )

md_path = pathlib.Path(md_out)
md_path.write_text("\n".join(md_lines) + "\n", encoding="utf-8")

print(f"gate_json={json_out}")
print(f"gate_md={md_out}")
print(f"gate_status={status}")
print(f"gate_failed_domain={report['failed_domain'] if report['failed_domain'] is not None else 'null'}")
print(f"gate_failed_check_id={report['failed_check_id'] if report['failed_check_id'] is not None else 'null'}")
print(f"gate_owner_hint={report['owner_hint']}")
PY

  local gate_status
  gate_status="$(python3 - "${json_out}" <<'PY'
import json,sys
data=json.load(open(sys.argv[1],encoding='utf-8'))
print(data["status"])
PY
)"

  if [[ "${gate_status}" != "pass" ]]; then
    return 1
  fi
  return 0
}
