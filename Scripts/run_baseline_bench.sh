#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root_dir"

mkdir -p Artifacts

if [[ -n "${BASELINE_FORCE_APPLE_PQC:-}" && "${BASELINE_FORCE_APPLE_PQC}" != "0" ]]; then
  echo "[BASELINE] Error: BASELINE_FORCE_APPLE_PQC is deprecated because it can fabricate Apple PQC benchmark evidence; use the canonical Apple PQC symbol probe instead." >&2
  exit 2
fi

# shellcheck source=Scripts/apple_pqc_sdk_probe.sh
source "${root_dir}/Scripts/apple_pqc_sdk_probe.sh"
skybridge_configure_optional_apple_pqc_sdk_compile_gate macosx
if skybridge_apple_pqc_sdk_probe_succeeded; then
  echo "[BASELINE] Apple PQC SDK symbol probe passed; enabling Package.swift HAS_APPLE_PQC_SDK gate"
else
  echo "[BASELINE] Apple PQC SDK symbol probe failed; baseline will run without HAS_APPLE_PQC_SDK"
  if [[ -n "${SKYBRIDGE_PQC_PROBE_ERROR:-}" ]]; then
    echo "[BASELINE] Apple PQC probe detail: $(skybridge_sanitize_pqc_probe_log_value "${SKYBRIDGE_PQC_PROBE_ERROR}")"
  fi
fi

echo "[BASELINE] Caching sudo credentials for tcpdump"
if ! sudo -v; then
  echo "[BASELINE] Warning: sudo authentication failed; capture will be skipped"
fi

date_str="$(date +%Y-%m-%d_%H%M%S)"
timings="Artifacts/baseline_timings_${date_str}.csv"
pcap="Artifacts/baseline_capture_${date_str}.pcap"
wire="Artifacts/baseline_wire_${date_str}.csv"
summary="Artifacts/baseline_summary_${date_str}.csv"

TLS_PORT="${BASELINE_TLS_PORT:-9443}"
QUIC_PORT="${BASELINE_QUIC_PORT:-9444}"
DTLS_PORT="${BASELINE_DTLS_PORT:-9445}"
NOISE_PORT="${BASELINE_NOISE_PORT:-9446}"
SKYBRIDGE_PORT="${BASELINE_SKYBRIDGE_PORT:-9447}"

validate_port() {
  local name="$1"
  local value="$2"
  if ! [[ "${value}" =~ ^[0-9]+$ ]] || (( value < 1 || value > 65535 )); then
    echo "[BASELINE] Error: ${name} must be a TCP/UDP port in 1...65535, got '${value}'" >&2
    exit 2
  fi
}

validate_port BASELINE_TLS_PORT "${TLS_PORT}"
validate_port BASELINE_QUIC_PORT "${QUIC_PORT}"
validate_port BASELINE_DTLS_PORT "${DTLS_PORT}"
validate_port BASELINE_NOISE_PORT "${NOISE_PORT}"
validate_port BASELINE_SKYBRIDGE_PORT "${SKYBRIDGE_PORT}"

filter_args=(
  host 127.0.0.1
  and
  \( port "${TLS_PORT}" or port "${QUIC_PORT}" or port "${DTLS_PORT}" or port "${NOISE_PORT}" or port "${SKYBRIDGE_PORT}" \)
)

tcpdump_pid=""
if sudo -n true 2>/dev/null; then
  echo "[BASELINE] Capturing loopback traffic to ${pcap}"
  sudo tcpdump -i lo0 -w "${pcap}" "${filter_args[@]}" >/dev/null 2>&1 &
  tcpdump_pid=$!
  trap 'if [[ -n "${tcpdump_pid:-}" ]]; then kill ${tcpdump_pid} >/dev/null 2>&1 || true; fi' EXIT
else
  echo "[BASELINE] Warning: sudo not available; skipping tcpdump capture"
fi

export SKYBRIDGE_KEYCHAIN_IN_MEMORY=1
export BASELINE_OUTPUT="${timings}"
export BASELINE_KICKOFF_BYTES="${BASELINE_KICKOFF_BYTES:-1}"

echo "[BASELINE] Building BaselineBenchRunner (release)"
bin_path="$(swift build --configuration release --product BaselineBenchRunner --show-bin-path)"
if [[ ! -x "${bin_path}/BaselineBenchRunner" ]]; then
  swift build --configuration release --product BaselineBenchRunner
fi
echo "[BASELINE] Running BaselineBenchRunner (release)"
"${bin_path}/BaselineBenchRunner"

if [[ -n "${tcpdump_pid:-}" ]]; then
  kill -2 "${tcpdump_pid}" >/dev/null 2>&1 || true
  wait "${tcpdump_pid}" >/dev/null 2>&1 || true
  trap - EXIT
  if [[ -f "${pcap}" ]]; then
    sudo chown "${USER}" "${pcap}" >/dev/null 2>&1 || true
    sudo chmod 644 "${pcap}" >/dev/null 2>&1 || true
  fi
fi

if [[ -s "${pcap}" ]]; then
  python3 Scripts/parse_baseline_capture.py \
    --pcap "${pcap}" \
    --timings "${timings}" \
    --output "${wire}" \
    --summary-output "${summary}"
else
  echo "[BASELINE] Warning: capture missing; skipping wire-size parse"
fi

printf "\n[BASELINE] Timings: %s\n" "${timings}"
if [[ -s "${pcap}" ]]; then
  printf "[BASELINE] Wire: %s\n" "${wire}"
  printf "[BASELINE] Summary: %s\n" "${summary}"
  printf "[BASELINE] Capture: %s\n" "${pcap}"
fi
