#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<USAGE
Rollback SkyBridge signaling service to a previous release.

Usage:
  $(basename "$0") --host <host> --user <user> [options]

Options:
  --host <host>            Remote host (required)
  --user <user>            SSH user (required)
  --identity-file <path>   SSH private key for remote login (optional)
  --port <port>            SSH port (default: 22)
  --app-dir <path>         Remote app root (default: /opt/skybridge-signaling)
  --service <name>         systemd service name (default: skybridge-signaling)
  --release <name>         Explicit release directory name to rollback to
  --health-url <url>       Health endpoint checked on remote host
                           (default: http://127.0.0.1:8443/health)
  -h, --help               Show this help
USAGE
}

HOST=""
USER_NAME=""
IDENTITY_FILE=""
PORT="22"
APP_DIR="/opt/skybridge-signaling"
SERVICE_NAME="skybridge-signaling"
TARGET_RELEASE=""
HEALTH_URL="http://127.0.0.1:8443/health"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --host)
            HOST="${2:-}"
            shift 2
            ;;
        --user)
            USER_NAME="${2:-}"
            shift 2
            ;;
        --identity-file)
            IDENTITY_FILE="${2:-}"
            shift 2
            ;;
        --port)
            PORT="${2:-}"
            shift 2
            ;;
        --app-dir)
            APP_DIR="${2:-}"
            shift 2
            ;;
        --service)
            SERVICE_NAME="${2:-}"
            shift 2
            ;;
        --release)
            TARGET_RELEASE="${2:-}"
            shift 2
            ;;
        --health-url)
            HEALTH_URL="${2:-}"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage
            exit 1
            ;;
    esac
done

if [[ -z "$HOST" || -z "$USER_NAME" ]]; then
    echo "--host and --user are required" >&2
    usage
    exit 1
fi

if [[ -n "$IDENTITY_FILE" && ! -f "$IDENTITY_FILE" ]]; then
    echo "identity file does not exist: $IDENTITY_FILE" >&2
    exit 1
fi

REMOTE_TARGET="${USER_NAME}@${HOST}"
SSH_CMD=(ssh -p "$PORT")
if [[ -n "$IDENTITY_FILE" ]]; then
    SSH_CMD+=( -i "$IDENTITY_FILE" -o IdentitiesOnly=yes )
fi

"${SSH_CMD[@]}" "$REMOTE_TARGET" \
  "APP_DIR='$APP_DIR' SERVICE_NAME='$SERVICE_NAME' TARGET_RELEASE='$TARGET_RELEASE' HEALTH_URL='$HEALTH_URL' bash -s" <<'REMOTE_ROLLBACK'
set -euo pipefail

releases_dir="$APP_DIR/releases"
current_link="$APP_DIR/current"

if [[ ! -d "$releases_dir" ]]; then
  echo "No releases directory at $releases_dir" >&2
  exit 1
fi

if [[ ! -L "$current_link" ]]; then
  echo "Current symlink missing at $current_link" >&2
  exit 1
fi

if [[ -n "$TARGET_RELEASE" ]]; then
  target_path="$releases_dir/$TARGET_RELEASE"
  if [[ ! -d "$target_path" ]]; then
    echo "Target release does not exist: $target_path" >&2
    exit 1
  fi
else
  current_target="$(readlink "$current_link")"
  mapfile -t all_releases < <(ls -1dt "$releases_dir"/* 2>/dev/null || true)
  target_path=""
  for release in "${all_releases[@]}"; do
    if [[ "$release" != "$current_target" ]]; then
      target_path="$release"
      break
    fi
  done
  if [[ -z "$target_path" ]]; then
    echo "No previous release found to rollback to" >&2
    exit 1
  fi
fi

echo "Rolling back to: $target_path"
sudo ln -sfn "$target_path" "$current_link"
sudo chown -h skybridge:skybridge "$current_link" || true

sudo systemctl restart "$SERVICE_NAME"
sleep 2

curl -fsS "$HEALTH_URL" >/dev/null
sudo systemctl --no-pager --full status "$SERVICE_NAME" | sed -n '1,25p'
REMOTE_ROLLBACK

echo "Rollback completed"
