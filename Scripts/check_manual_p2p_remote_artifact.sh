#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE' >&2
Usage:
  Scripts/check_manual_p2p_remote_artifact.sh <artifact-dir> [extra skybridge check performance args]

Environment overrides:
  SKYBRIDGE_MANUAL_P2P_MIN_FPS      default: 59
  SKYBRIDGE_MANUAL_P2P_MIN_WIDTH    default: 2056
  SKYBRIDGE_MANUAL_P2P_MIN_HEIGHT   default: 1329
  SKYBRIDGE_MANUAL_P2P_WINDOW_SECS  default: 10
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -lt 1 ]]; then
  usage
  exit 2
fi

artifact_dir="$1"
shift

if [[ ! -d "${artifact_dir}" ]]; then
  echo "manual P2P artifact directory does not exist: ${artifact_dir}" >&2
  exit 2
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
artifact_dir="$(cd "$(dirname "${artifact_dir}")" && pwd)/$(basename "${artifact_dir}")"

min_fps="${SKYBRIDGE_MANUAL_P2P_MIN_FPS:-59}"
min_width="${SKYBRIDGE_MANUAL_P2P_MIN_WIDTH:-2056}"
min_height="${SKYBRIDGE_MANUAL_P2P_MIN_HEIGHT:-1329}"
window_seconds="${SKYBRIDGE_MANUAL_P2P_WINDOW_SECS:-10}"

cd "${repo_root}/rust"

cargo run -p skybridge -- check performance \
  --kind p2p-remote \
  --artifact-dir "${artifact_dir}" \
  --min-fps "${min_fps}" \
  --min-width "${min_width}" \
  --min-height "${min_height}" \
  --exact-video-size \
  --min-pass-window-seconds "${window_seconds}" \
  --manual-artifact \
  --json \
  "$@"
