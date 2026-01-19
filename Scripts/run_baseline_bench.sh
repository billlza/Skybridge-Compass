#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root_dir"

mkdir -p Artifacts

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

filter="host 127.0.0.1 and (port ${TLS_PORT} or port ${QUIC_PORT} or port ${DTLS_PORT} or port ${NOISE_PORT} or port ${SKYBRIDGE_PORT})"

tcpdump_pid=""
if sudo -n true 2>/dev/null; then
  echo "[BASELINE] Capturing loopback traffic to ${pcap}"
  sudo tcpdump -i lo0 -w "${pcap}" ${filter} >/dev/null 2>&1 &
  tcpdump_pid=$!
  trap 'if [[ -n "${tcpdump_pid:-}" ]]; then kill ${tcpdump_pid} >/dev/null 2>&1 || true; fi' EXIT
else
  echo "[BASELINE] Warning: sudo not available; skipping tcpdump capture"
fi

swift_flags=()
if [[ "${BASELINE_FORCE_APPLE_PQC:-}" == "1" ]]; then
  swift_flags=("-Xswiftc" "-DHAS_APPLE_PQC_SDK")
  export HAS_APPLE_PQC_SDK=1
elif command -v xcrun >/dev/null 2>&1; then
  sdk_path="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
  if [[ -n "${sdk_path}" ]]; then
    module_dir="$sdk_path/System/Library/Frameworks/CryptoKit.framework/Versions/A/Modules/CryptoKit.swiftmodule"
    has_pqc="0"
    if command -v rg >/dev/null 2>&1; then
      if rg -a -q "MLKEM768" "${module_dir}" 2>/dev/null; then
        has_pqc="1"
      fi
    else
      if grep -q "MLKEM768" "${module_dir}"/* 2>/dev/null; then
        has_pqc="1"
      fi
    fi
    if [[ "${has_pqc}" == "1" ]]; then
      swift_flags=("-Xswiftc" "-DHAS_APPLE_PQC_SDK")
      export HAS_APPLE_PQC_SDK=1
    fi
  fi
fi

export SKYBRIDGE_KEYCHAIN_IN_MEMORY=1
export BASELINE_OUTPUT="${timings}"
export BASELINE_KICKOFF_BYTES="${BASELINE_KICKOFF_BYTES:-1}"

echo "[BASELINE] Building BaselineBenchRunner (release)"
bin_path="$(swift build "${swift_flags[@]}" --configuration release --product BaselineBenchRunner --show-bin-path)"
if [[ ! -x "${bin_path}/BaselineBenchRunner" ]]; then
  swift build "${swift_flags[@]}" --configuration release --product BaselineBenchRunner
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
