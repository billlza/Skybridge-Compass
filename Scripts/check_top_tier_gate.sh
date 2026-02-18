#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

EXPECTED_ARTIFACT_DATE="2026-01-23"
ARTIFACT_DATE_VALUE="${ARTIFACT_DATE:-}"
GATE_REPORT_PATH="${SKYBRIDGE_GATE_REPORT:-}"

GATE_ITEMS=()

timestamp() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

log() {
  printf '[TOP-GATE][%s] %s\n' "$(timestamp)" "$*"
}

pass_item() {
  local text="$1"
  GATE_ITEMS+=("- [x] ${text}")
  log "PASS ${text}"
}

fail_item() {
  local text="$1"
  GATE_ITEMS+=("- [ ] ${text}")
  log "FAIL ${text}"
  return 1
}

require_file() {
  local file_path="$1"
  [[ -f "$file_path" ]] || fail_item "missing file: ${file_path}"
}

require_command() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || fail_item "missing command: ${cmd}"
}

write_gate_report() {
  [[ -z "$GATE_REPORT_PATH" ]] && return 0
  mkdir -p "$(dirname "$GATE_REPORT_PATH")"
  {
    echo "# Top-Tier Gate Report"
    echo
    echo "- Timestamp: $(timestamp)"
    echo "- Artifact date: ${ARTIFACT_DATE_VALUE}"
    echo
    echo "## Gate Checks"
    for item in "${GATE_ITEMS[@]}"; do
      echo "$item"
    done
  } >"$GATE_REPORT_PATH"
  log "Gate report written to ${GATE_REPORT_PATH}"
}

trap 'write_gate_report' EXIT

log "Starting top-tier academic gate"

if [[ -z "$ARTIFACT_DATE_VALUE" ]]; then
  fail_item "ARTIFACT_DATE must be set (required: ${EXPECTED_ARTIFACT_DATE})"
fi
if [[ "$ARTIFACT_DATE_VALUE" != "$EXPECTED_ARTIFACT_DATE" ]]; then
  fail_item "ARTIFACT_DATE must be ${EXPECTED_ARTIFACT_DATE}, got ${ARTIFACT_DATE_VALUE}"
fi
pass_item "artifact date pinned to ${EXPECTED_ARTIFACT_DATE}"

for dep in tamarin-prover swift python3 pdflatex pdffonts pdftotext; do
  require_command "$dep"
done
pass_item "runtime dependencies available"

TAMARIN_PROOF="Artifacts/tamarin_skybridge_v2_proof_${ARTIFACT_DATE_VALUE}.txt"
TAMARIN_SUMMARY="Artifacts/tamarin_skybridge_v2_summary_${ARTIFACT_DATE_VALUE}.txt"
TAMARIN_PNG="Artifacts/tamarin_skybridge_v2_summary_${ARTIFACT_DATE_VALUE}.png"
TAMARIN_REPORT="Artifacts/tamarin_skybridge_v2_report_${ARTIFACT_DATE_VALUE}.md"

require_file "$TAMARIN_PROOF"
require_file "$TAMARIN_SUMMARY"
require_file "$TAMARIN_PNG"
require_file "$TAMARIN_REPORT"

exists_verified_count="$(grep -c '(exists-trace): verified' "$TAMARIN_SUMMARY" || true)"
all_verified_count="$(grep -c '(all-traces): verified' "$TAMARIN_SUMMARY" || true)"
if [[ "$exists_verified_count" -lt 2 ]]; then
  fail_item "Tamarin exists-trace verified count must be >=2 (got ${exists_verified_count})"
fi
if [[ "$all_verified_count" -lt 6 ]]; then
  fail_item "Tamarin all-traces verified count must be >=6 (got ${all_verified_count})"
fi
if grep -Eq '(falsified|not verified|attack found|unknown)' "$TAMARIN_SUMMARY"; then
  fail_item "Tamarin summary contains non-verified outcomes"
fi
pass_item "formal gate passed (exists=${exists_verified_count}, all=${all_verified_count})"

HANDSHAKE_BENCH="Artifacts/handshake_bench_${ARTIFACT_DATE_VALUE}.csv"
HANDSHAKE_RTT="Artifacts/handshake_rtt_${ARTIFACT_DATE_VALUE}.csv"
MESSAGE_SIZES="Artifacts/message_sizes_${ARTIFACT_DATE_VALUE}.csv"
FAULT_INJECTION="Artifacts/fault_injection_${ARTIFACT_DATE_VALUE}.csv"
POLICY_DOWNGRADE="Artifacts/policy_downgrade_${ARTIFACT_DATE_VALUE}.csv"
MIGRATION_COVERAGE="Artifacts/migration_coverage_${ARTIFACT_DATE_VALUE}.csv"
TRAFFIC_PADDING="Artifacts/traffic_padding_${ARTIFACT_DATE_VALUE}.csv"
TRAFFIC_PADDING_SENS="Artifacts/traffic_padding_sensitivity_${ARTIFACT_DATE_VALUE}.csv"
SYSTEM_IMPACT="Artifacts/system_impact_${ARTIFACT_DATE_VALUE}.csv"
REALNET_MICROSTUDY="Artifacts/realnet_microstudy_${ARTIFACT_DATE_VALUE}.csv"
KERNEL_EMULATION="Artifacts/network_emulation_kernel_${ARTIFACT_DATE_VALUE}.csv"

for file_path in \
  "$HANDSHAKE_BENCH" \
  "$HANDSHAKE_RTT" \
  "$MESSAGE_SIZES" \
  "$FAULT_INJECTION" \
  "$POLICY_DOWNGRADE" \
  "$MIGRATION_COVERAGE" \
  "$TRAFFIC_PADDING" \
  "$TRAFFIC_PADDING_SENS" \
  "$SYSTEM_IMPACT" \
  "$REALNET_MICROSTUDY" \
  "$KERNEL_EMULATION"; do
  require_file "$file_path"
done
pass_item "key artifact CSV files present for ${ARTIFACT_DATE_VALUE}"

python3 - "$HANDSHAKE_BENCH" "$HANDSHAKE_RTT" "$MESSAGE_SIZES" "$TRAFFIC_PADDING_SENS" "$ARTIFACT_DATE_VALUE" <<'PY'
import csv
import sys
from pathlib import Path

bench_path, rtt_path, msg_path, sens_path, expected_date = sys.argv[1:]

required_v2_config = "liboqs PQC v2 FS (ML-KEM-768-FS + ML-DSA-65)"
required_msg_rows = {"MessageA.PQC-liboqs-v2fs", "MessageB.PQC-liboqs-v2fs"}
required_core_configs = {
    "Classic (X25519 + Ed25519)",
    "liboqs PQC (ML-KEM-768 + ML-DSA-65)",
    "CryptoKit PQC (ML-KEM-768 + ML-DSA-65)",
    "liboqs PQC v2 FS (ML-KEM-768-FS + ML-DSA-65)",
}


def load(path: str):
    with open(path, newline="") as fh:
        return list(csv.DictReader(fh))


def check_single_header(path: str):
    lines = Path(path).read_text(encoding="utf-8").splitlines()
    if not lines:
        raise SystemExit(f"empty csv: {path}")
    header = lines[0].strip()
    if sum(1 for ln in lines if ln.strip() == header) != 1:
        raise SystemExit(f"duplicate header rows detected: {path}")


def complete_batch_count(rows, required_configs):
    batches = []
    current = {}
    for row in rows:
        config = row.get("configuration", "")
        if config in current:
            batches.append(current)
            current = {}
        current[config] = row
    if current:
        batches.append(current)
    required = set(required_configs)
    return sum(1 for b in batches if required.issubset(set(b.keys())))


for csv_path in (bench_path, rtt_path, msg_path, sens_path):
    check_single_header(csv_path)

bench_rows = load(bench_path)
rtt_rows = load(rtt_path)
msg_rows = load(msg_path)
sens_rows = load(sens_path)

bench_configs = {r.get("configuration", "") for r in bench_rows}
rtt_configs = {r.get("configuration", "") for r in rtt_rows}
msg_names = {r.get("message", "") for r in msg_rows}

if required_v2_config not in bench_configs:
    raise SystemExit(f"missing v2 config in {bench_path}")
if required_v2_config not in rtt_configs:
    raise SystemExit(f"missing v2 config in {rtt_path}")
if not required_msg_rows.issubset(msg_names):
    missing = sorted(required_msg_rows - msg_names)
    raise SystemExit(f"missing v2 message-size rows in {msg_path}: {missing}")

if len(bench_rows) < len(required_core_configs):
    raise SystemExit(f"insufficient bench rows in {bench_path}: {len(bench_rows)}")
if len(rtt_rows) < len(required_core_configs):
    raise SystemExit(f"insufficient rtt rows in {rtt_path}: {len(rtt_rows)}")

if any(r.get("configuration") == "configuration" for r in bench_rows):
    raise SystemExit(f"embedded header row found in {bench_path}")
if any(r.get("configuration") == "configuration" for r in rtt_rows):
    raise SystemExit(f"embedded header row found in {rtt_path}")
if any(r.get("message") == "message" for r in msg_rows):
    raise SystemExit(f"embedded header row found in {msg_path}")

if complete_batch_count(bench_rows, required_core_configs) < 1:
    raise SystemExit(f"no complete core benchmark batch in {bench_path}")
if complete_batch_count(rtt_rows, required_core_configs) < 1:
    raise SystemExit(f"no complete core rtt batch in {rtt_path}")

if sens_rows:
    dates = {r.get("artifact_date", "") for r in sens_rows}
    if dates != {expected_date}:
        raise SystemExit(f"artifact_date column mismatch in {sens_path}: {sorted(dates)}")

print("csv_checks_ok")
PY
pass_item "v1/v2 CSV gate passed (bench/rtt/message-size/date consistency)"

CLAIMS_JSON="Artifacts/claims_${ARTIFACT_DATE_VALUE}.json"
CLAIMS_MACROS="Docs/generated/claims_macros.tex"
require_file "$CLAIMS_JSON"
require_file "$CLAIMS_MACROS"
pass_item "claims artifacts present (json + macros)"

BENCH_STABILITY_JSON="Artifacts/bench_stability_window_${ARTIFACT_DATE_VALUE}.json"
require_file "$BENCH_STABILITY_JSON"
if ! python3 - "$BENCH_STABILITY_JSON" <<'PY'
import json
import sys

path = sys.argv[1]
data = json.load(open(path, "r", encoding="utf-8"))
if not data.get("overall_stable", False):
    raise SystemExit(f"benchmark stability window not converged: {path}")
print("bench_stability_ok")
PY
then
  fail_item "benchmark stability window did not converge (${BENCH_STABILITY_JSON})"
fi
pass_item "benchmark stability window converged (3→5 adaptive gate)"

V2_TABLE="Docs/supp_tables/s12_v2_v1_compare.tex"
require_file "$V2_TABLE"
if ! grep -q 'liboqs v1' "$V2_TABLE"; then
  fail_item "v2 comparison table missing 'liboqs v1' row"
fi
if ! grep -q 'liboqs v2 FS' "$V2_TABLE"; then
  fail_item "v2 comparison table missing 'liboqs v2 FS' row"
fi
pass_item "v1/v2 supplementary table present and populated"

CONSISTENCY_SCRIPT="Scripts/check_paper_consistency.sh"
require_file "$CONSISTENCY_SCRIPT"

log "Running paper consistency gate"
bash "$CONSISTENCY_SCRIPT"
pass_item "paper consistency gate passed"

NUMERIC_CONSISTENCY_SCRIPT="Scripts/check_numeric_consistency.py"
require_file "$NUMERIC_CONSISTENCY_SCRIPT"
log "Running numeric consistency gate"
ARTIFACT_DATE="$ARTIFACT_DATE_VALUE" python3 "$NUMERIC_CONSISTENCY_SCRIPT"
pass_item "numeric consistency gate passed"

CLAIM_GUARDRAIL_SCRIPT="Scripts/check_claim_guardrails.py"
require_file "$CLAIM_GUARDRAIL_SCRIPT"
log "Running claim guardrail gate"
if ! python3 "$CLAIM_GUARDRAIL_SCRIPT" \
  --artifact-date "$ARTIFACT_DATE_VALUE" \
  --out-json "Artifacts/claim_guardrails_${ARTIFACT_DATE_VALUE}.json" \
  --out-md "Artifacts/claim_guardrails_${ARTIFACT_DATE_VALUE}.md"; then
  fail_item "claim guardrail gate failed"
fi
pass_item "claim guardrail gate passed"

IOS_MINOR_MATRIX_SCRIPT="Scripts/check_ios_minor_matrix.py"
require_file "$IOS_MINOR_MATRIX_SCRIPT"
log "Running iOS minor-version matrix gate"
if ! ARTIFACT_DATE="$ARTIFACT_DATE_VALUE" \
python3 "$IOS_MINOR_MATRIX_SCRIPT" --output "Artifacts/ios_minor_matrix_${ARTIFACT_DATE_VALUE}.md"; then
  fail_item "iOS minor-version matrix gate failed"
fi
pass_item "iOS minor-version matrix gate passed"

INTEROP_CHECK_SCRIPT="Scripts/check_cross_platform_interop.py"
INTEROP_AGGREGATE_SCRIPT="Scripts/aggregate_interop_matrix.py"
require_file "$INTEROP_CHECK_SCRIPT"
require_file "$INTEROP_AGGREGATE_SCRIPT"
log "Running cross-platform consistency gate"
if ! python3 "$INTEROP_CHECK_SCRIPT" \
  --artifact-date "$ARTIFACT_DATE_VALUE" \
  --out-json "Artifacts/interop_consistency_${ARTIFACT_DATE_VALUE}.json" \
  --out-md "Artifacts/interop_consistency_${ARTIFACT_DATE_VALUE}.md"; then
  fail_item "cross-platform consistency gate failed"
fi
pass_item "cross-platform consistency gate passed"

log "Running interop matrix aggregation gate"
python3 "$INTEROP_AGGREGATE_SCRIPT" --artifact-date "$ARTIFACT_DATE_VALUE"

INTEROP_MATRIX_CSV="Artifacts/interop_cross_platform_${ARTIFACT_DATE_VALUE}.csv"
INTEROP_MATRIX_TEX="Docs/supp_tables/s13_interop_matrix.tex"
require_file "$INTEROP_MATRIX_CSV"
require_file "$INTEROP_MATRIX_TEX"
if ! python3 - "$INTEROP_MATRIX_CSV" <<'PY'
import csv
import sys

path = sys.argv[1]
with open(path, newline="", encoding="utf-8") as fh:
    rows = list(csv.DictReader(fh))
if len(rows) < 3:
    raise SystemExit(f"insufficient interop rows: {len(rows)}")
pairs = {(r.get("initiator_platform", ""), r.get("responder_platform", "")) for r in rows}
if len(pairs) < 3:
    raise SystemExit(f"insufficient platform-pair coverage: {len(pairs)}")
measured = [r for r in rows if r.get("evidence_class") == "measured"]
if not measured:
    raise SystemExit("missing measured interop rows")
print("interop_matrix_ok")
PY
then
  fail_item "interop matrix coverage gate failed"
fi
pass_item "interop matrix coverage gate passed"

if [[ "${SKYBRIDGE_GATE_SKIP_COMPILE:-0}" == "1" ]]; then
  log "Skipping compile_paper.sh (SKYBRIDGE_GATE_SKIP_COMPILE=1); verifying PDFs exist"
else
  log "Running paper compile gate (--skip-figures)"
  bash compile_paper.sh --skip-figures
fi

require_file "Docs/TDSC-2026-01-0318_IEEE_Paper_SkyBridge_Compass_patched.pdf"
require_file "Docs/TDSC-2026-01-0318_supplementary.pdf"
pass_item "paper compile gate passed (main + supplementary PDF present)"

log "Top-tier gate completed successfully"
