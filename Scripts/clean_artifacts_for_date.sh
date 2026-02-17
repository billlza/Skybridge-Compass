#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ARTIFACTS_DIR="$ROOT_DIR/Artifacts"
EXPECTED_ARTIFACT_DATE="2026-01-23"

timestamp() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

log() {
  printf '[ARTIFACT-CLEAN][%s] %s\n' "$(timestamp)" "$*"
}

artifact_date="${ARTIFACT_DATE:-${1:-}}"

if [[ -z "${artifact_date}" ]]; then
  echo "ARTIFACT_DATE is required (expected ${EXPECTED_ARTIFACT_DATE})." >&2
  exit 2
fi

if [[ "${artifact_date}" != "${EXPECTED_ARTIFACT_DATE}" ]]; then
  echo "ARTIFACT_DATE must be ${EXPECTED_ARTIFACT_DATE}, got ${artifact_date}." >&2
  exit 2
fi

mkdir -p "${ARTIFACTS_DIR}"

manifest="${ARTIFACTS_DIR}/cleanup_manifest_${artifact_date}.txt"

{
  echo "# SkyBridge artifact cleanup manifest"
  echo "# timestamp_utc sha256 path"
} >"${manifest}"

prefixes=(
  handshake_bench
  handshake_rtt
  handshake_wire
  message_sizes
  fault_injection
  policy_downgrade
  migration_coverage
  traffic_padding
  traffic_padding_sensitivity
  system_impact
  network_emulation_kernel
  realnet_microstudy
  realnet
)

extra_globs=(
  "realnet_*_${artifact_date}*.csv"
)

deleted=0

record_delete() {
  local target="$1"
  local hash
  hash="$(shasum -a 256 "${target}" | awk '{print $1}')"
  printf '%s %s %s\n' "$(timestamp)" "${hash}" "${target}" >>"${manifest}"
  rm -f -- "${target}"
  deleted=$(( deleted + 1 ))
}

for prefix in "${prefixes[@]}"; do
  target="${ARTIFACTS_DIR}/${prefix}_${artifact_date}.csv"
  if [[ -f "${target}" ]]; then
    record_delete "${target}"
  fi
done

for pattern in "${extra_globs[@]}"; do
  while IFS= read -r target; do
    [[ -n "${target}" ]] || continue
    [[ -f "${target}" ]] || continue
    record_delete "${target}"
  done < <(find "${ARTIFACTS_DIR}" -maxdepth 1 -type f -name "${pattern}" -print)
done

log "Deleted ${deleted} artifact file(s) for ${artifact_date}"
log "Cleanup manifest: ${manifest}"

leftovers=()
for prefix in "${prefixes[@]}"; do
  target="${ARTIFACTS_DIR}/${prefix}_${artifact_date}.csv"
  if [[ -f "${target}" ]]; then
    leftovers+=("${target}")
  fi
done
while IFS= read -r target; do
  [[ -n "${target}" ]] || continue
  leftovers+=("${target}")
done < <(find "${ARTIFACTS_DIR}" -maxdepth 1 -type f -name "realnet_*_${artifact_date}*.csv" -print)

if (( ${#leftovers[@]} > 0 )); then
  echo "Artifact cleanup incomplete; leftovers detected:" >&2
  printf '%s\n' "${leftovers[@]}" >&2
  exit 1
fi

log "Post-clean empty-set check passed for ${artifact_date}"
