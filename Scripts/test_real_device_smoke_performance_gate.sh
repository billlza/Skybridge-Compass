#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="${ROOT_DIR}/Scripts/real_device_smoke_performance_gate.sh"
P2P_SCRIPT="${ROOT_DIR}/Scripts/run_real_device_p2p_remote_smoke.sh"
FILE_SCRIPT="${ROOT_DIR}/Scripts/run_real_device_file_transfer_smoke.sh"
WEBRTC_SCRIPT="${ROOT_DIR}/Scripts/run_real_device_webrtc_smoke.sh"

fail() {
  echo "[test-real-device-smoke-performance-gate] $1" >&2
  exit 1
}

line_number() {
  local pattern="$1"
  local path="$2"
  grep -nF -- "$pattern" "$path" | head -n 1 | cut -d: -f1
}

require_literal() {
  local pattern="$1"
  local path="$2"
  grep -Fq -- "$pattern" "$path" || fail "missing required literal in ${path}: ${pattern}"
}

require_literal 'source "$ROOT_DIR/Scripts/real_device_smoke_performance_gate.sh"' "$P2P_SCRIPT"
require_literal 'source "$ROOT_DIR/Scripts/real_device_smoke_performance_gate.sh"' "$FILE_SCRIPT"
require_literal 'skybridge_smoke_check_performance_gate "$ROOT_DIR" p2p-remote "$ARTIFACT_DIR"' "$P2P_SCRIPT"
require_literal 'skybridge_smoke_check_performance_gate "$ROOT_DIR" file-transfer "$ARTIFACT_DIR"' "$FILE_SCRIPT"
require_literal 'skybridge_smoke_check_public_artifacts "$PUBLIC_ARTIFACT_DIR" "$IOS_DEVICE_ID"' "$P2P_SCRIPT"
require_literal 'skybridge_smoke_check_public_artifacts "$PUBLIC_ARTIFACT_DIR" "$IOS_DEVICE_ID"' "$FILE_SCRIPT"
require_literal 'skybridge_smoke_check_public_artifacts "$PUBLIC_ARTIFACT_DIR" "$IOS_DEVICE_ID" "$MAC_DEVICE_ID" "$IOS_LOGICAL_DEVICE_ID" "$MAC_PQC_DEVICE_ID"' "$WEBRTC_SCRIPT"
require_literal 'cargo run --quiet --manifest-path "${root_dir}/rust/Cargo.toml" -p skybridge -- "$@"' "$HELPER"
require_literal 'SKYBRIDGE_CLI_BIN is not executable' "$HELPER"
require_literal 'real-device smoke artifact directory does not exist' "$HELPER"

p2p_gate_line="$(line_number 'skybridge_smoke_check_performance_gate "$ROOT_DIR" p2p-remote "$ARTIFACT_DIR"' "$P2P_SCRIPT")"
p2p_public_gate_line="$(line_number 'skybridge_smoke_check_public_artifacts "$PUBLIC_ARTIFACT_DIR" "$IOS_DEVICE_ID"' "$P2P_SCRIPT")"
p2p_success_line="$(line_number 'Real-device P2P remote desktop smoke succeeded' "$P2P_SCRIPT")"
p2p_final_line="$(line_number 'append_ios_status "smoke-final result=success' "$P2P_SCRIPT")"
[[ -n "$p2p_gate_line" && -n "$p2p_public_gate_line" && -n "$p2p_success_line" && -n "$p2p_final_line" ]] \
  || fail "P2P script must contain final sentinels, Rust performance gate, and success output"
(( p2p_final_line < p2p_gate_line && p2p_gate_line < p2p_public_gate_line && p2p_public_gate_line < p2p_success_line )) \
  || fail "P2P Rust performance and public artifact gates must run after final sentinels and before success output"

file_gate_line="$(line_number 'skybridge_smoke_check_performance_gate "$ROOT_DIR" file-transfer "$ARTIFACT_DIR"' "$FILE_SCRIPT")"
file_public_gate_line="$(line_number 'skybridge_smoke_check_public_artifacts "$PUBLIC_ARTIFACT_DIR" "$IOS_DEVICE_ID"' "$FILE_SCRIPT")"
file_success_line="$(line_number 'Real-device bidirectional file transfer smoke succeeded' "$FILE_SCRIPT")"
file_marker_line="$(line_number 'Waiting for smoke success markers' "$FILE_SCRIPT")"
[[ -n "$file_gate_line" && -n "$file_public_gate_line" && -n "$file_success_line" && -n "$file_marker_line" ]] \
  || fail "file-transfer script must contain success markers, Rust performance gate, and success output"
(( file_marker_line < file_gate_line && file_gate_line < file_public_gate_line && file_public_gate_line < file_success_line )) \
  || fail "file-transfer Rust performance and public artifact gates must run after success markers and before success output"

webrtc_doctor_line="$(line_number 'run_webrtc_media_doctor "$SESSION_ID"' "$WEBRTC_SCRIPT")"
webrtc_public_gate_line="$(line_number 'skybridge_smoke_check_public_artifacts "$PUBLIC_ARTIFACT_DIR" "$IOS_DEVICE_ID" "$MAC_DEVICE_ID" "$IOS_LOGICAL_DEVICE_ID" "$MAC_PQC_DEVICE_ID"' "$WEBRTC_SCRIPT")"
webrtc_success_line="$(line_number 'Real-device WebRTC smoke succeeded' "$WEBRTC_SCRIPT")"
[[ -n "$webrtc_doctor_line" && -n "$webrtc_public_gate_line" && -n "$webrtc_success_line" ]] \
  || fail "WebRTC script must contain media doctor, public artifact gate, and success output"
(( webrtc_doctor_line < webrtc_public_gate_line && webrtc_public_gate_line < webrtc_success_line )) \
  || fail "WebRTC public artifact gate must run after media doctor and before success output"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/skybridge-smoke-performance-gate-test.XXXXXX")"
trap 'rm -rf "${TMP_DIR}"' EXIT
ARTIFACT_DIR="${TMP_DIR}/artifact"
FAKE_CLI="${TMP_DIR}/skybridge"
ARGS_FILE="${TMP_DIR}/args.txt"
mkdir -p "$ARTIFACT_DIR"
cat >"$FAKE_CLI" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" >"${SKYBRIDGE_FAKE_CLI_ARGS_FILE:?missing args file}"
SH
chmod +x "$FAKE_CLI"

source "$HELPER"

SKYBRIDGE_CLI_BIN="$FAKE_CLI" \
SKYBRIDGE_FAKE_CLI_ARGS_FILE="$ARGS_FILE" \
  skybridge_smoke_check_performance_gate "$ROOT_DIR" p2p-remote "$ARTIFACT_DIR" --min-fps 59 --exact-video-size

expected_args="${TMP_DIR}/expected-args.txt"
cat >"$expected_args" <<EOF
check
performance
--kind
p2p-remote
--artifact-dir
$ARTIFACT_DIR
--min-fps
59
--exact-video-size
EOF
cmp "$expected_args" "$ARGS_FILE" \
  || fail "helper should invoke the selected SkyBridge CLI with canonical performance arguments"

if SKYBRIDGE_CLI_BIN="${TMP_DIR}/missing-cli" skybridge_smoke_check_performance_gate "$ROOT_DIR" file-transfer "$ARTIFACT_DIR" >/dev/null 2>&1; then
  fail "helper must fail when SKYBRIDGE_CLI_BIN is not executable"
fi

if SKYBRIDGE_CLI_BIN="$FAKE_CLI" skybridge_smoke_check_performance_gate "$ROOT_DIR" file-transfer "${TMP_DIR}/missing-artifact" >/dev/null 2>&1; then
  fail "helper must fail when artifact directory is missing"
fi

echo "real-device smoke performance gate contract passed"
