#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/lib/repository_layout.sh"
RELEASE_REPO_ROOT="$(skybridge_canonical_release_root "$ROOT_DIR")"
DEFAULT_MAC_PACKAGE_PATH="$RELEASE_REPO_ROOT"
MAC_PACKAGE_PATH="$DEFAULT_MAC_PACKAGE_PATH"
RUN_DIR=""

usage() {
  cat <<'EOF'
Usage:
  scripts/run_mac_lan_interop_host.sh \
    [--mac-package-path <path>] \
    [--run-dir <path>]
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mac-package-path)
      MAC_PACKAGE_PATH="${2:-}"
      shift 2
      ;;
    --run-dir)
      RUN_DIR="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if ! command -v swift >/dev/null 2>&1; then
  echo "swift not found in PATH" >&2
  exit 1
fi

MAC_PACKAGE_PATH="$(skybridge_require_release_repo_root "$MAC_PACKAGE_PATH")"

if [[ -z "$RUN_DIR" ]]; then
  RUN_DIR="$ROOT_DIR/build/interop/mac-lan-host/$(date +%Y%m%d-%H%M%S)"
fi
mkdir -p "$RUN_DIR"
chmod 700 "$RUN_DIR"

LOG_FILE="$RUN_DIR/local-lan-host.log"
ENV_FILE="$RUN_DIR/environment.txt"
README_FILE="$RUN_DIR/readme.txt"
SWIFT_SCRATCH_PATH="$RUN_DIR/swiftpm"

{
  echo "date=$(date '+%Y-%m-%d %H:%M:%S %z')"
  echo "swift=$(swift --version 2>/dev/null | head -n 1)"
  echo "mac_package_path=$MAC_PACKAGE_PATH"
  echo "swift_scratch_path=$SWIFT_SCRATCH_PATH"
  echo "run_dir=$RUN_DIR"
} >"$ENV_FILE"
skybridge_append_git_source_binding "$ENV_FILE" android "$RELEASE_REPO_ROOT"
skybridge_append_git_source_binding "$ENV_FILE" apple "$MAC_PACKAGE_PATH"

cat >"$README_FILE" <<EOF
Expected host signals:
- Bonjour service for Android discovery
- Remote desktop TCP listener on port 5901
- File listener path and inbound directory printed by LocalLanInteropHost

Primary log:
- $LOG_FILE
EOF

echo "Launching LocalLanInteropHost..."
echo "Log file: $LOG_FILE"
echo "Environment file: $ENV_FILE"
echo "Press Ctrl+C to stop."

swift run \
  --package-path "$MAC_PACKAGE_PATH" \
  --scratch-path "$SWIFT_SCRATCH_PATH" \
  --disable-automatic-resolution \
  LocalLanInteropHost 2>&1 | tee "$LOG_FILE"
