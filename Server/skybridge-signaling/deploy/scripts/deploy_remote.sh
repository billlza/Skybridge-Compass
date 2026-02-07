#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<USAGE
Deploy SkyBridge signaling service to a remote Linux host.

Usage:
  $(basename "$0") --host <host> --user <user> [options]

Options:
  --host <host>            Remote host (required)
  --user <user>            SSH user (required)
  --port <port>            SSH port (default: 22)
  --app-dir <path>         Remote app root (default: /opt/skybridge-signaling)
  --service <name>         systemd service name (default: skybridge-signaling)
  --health-url <url>       Health endpoint checked on remote host
                           (default: http://127.0.0.1:8443/health)
  --skip-systemd           Do not install/reload/restart systemd service
  -h, --help               Show this help
USAGE
}

HOST=""
USER_NAME=""
PORT="22"
APP_DIR="/opt/skybridge-signaling"
SERVICE_NAME="skybridge-signaling"
HEALTH_URL="http://127.0.0.1:8443/health"
SKIP_SYSTEMD="false"

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
        --health-url)
            HEALTH_URL="${2:-}"
            shift 2
            ;;
        --skip-systemd)
            SKIP_SYSTEMD="true"
            shift
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
SERVER_DIR="$PROJECT_ROOT/Server/skybridge-signaling"
SERVICE_TEMPLATE="$SERVER_DIR/deploy/systemd/skybridge-signaling.service"

if [[ ! -f "$SERVER_DIR/server.js" ]]; then
    echo "server.js not found at $SERVER_DIR" >&2
    exit 1
fi

for cmd in ssh scp tar git; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Required command missing: $cmd" >&2
        exit 1
    fi
done

if ! command -v node >/dev/null 2>&1; then
    echo "node is required locally for preflight checks" >&2
    exit 1
fi

pushd "$SERVER_DIR" >/dev/null
node --check server.js
popd >/dev/null

GIT_SHA="$(git -C "$PROJECT_ROOT" rev-parse --short HEAD 2>/dev/null || echo nogit)"
STAMP="$(date -u +%Y%m%d%H%M%S)"
RELEASE_NAME="${STAMP}-${GIT_SHA}"
ARCHIVE_PATH="$(mktemp -t skybridge-signaling-${RELEASE_NAME}.XXXXXX.tgz)"
REMOTE_ARCHIVE="/tmp/skybridge-signaling-${RELEASE_NAME}.tgz"
REMOTE_RELEASE_DIR="$APP_DIR/releases/$RELEASE_NAME"
REMOTE_ENV="$APP_DIR/shared/config/production.env"
REMOTE_CURRENT="$APP_DIR/current"
REMOTE_TARGET="${USER_NAME}@${HOST}"

cleanup() {
    rm -f "$ARCHIVE_PATH"
}
trap cleanup EXIT

echo "[deploy] Packaging release $RELEASE_NAME"
tar \
  --exclude='node_modules' \
  --exclude='.DS_Store' \
  --exclude='*.log' \
  -C "$SERVER_DIR" \
  -czf "$ARCHIVE_PATH" \
  .

echo "[deploy] Uploading archive to $REMOTE_TARGET"
scp -P "$PORT" "$ARCHIVE_PATH" "$REMOTE_TARGET:$REMOTE_ARCHIVE"

echo "[deploy] Provisioning release directory and dependencies"
ssh -p "$PORT" "$REMOTE_TARGET" \
  "APP_DIR='$APP_DIR' REMOTE_ARCHIVE='$REMOTE_ARCHIVE' REMOTE_RELEASE_DIR='$REMOTE_RELEASE_DIR' REMOTE_ENV='$REMOTE_ENV' REMOTE_CURRENT='$REMOTE_CURRENT' bash -s" <<'REMOTE_PREP'
set -euo pipefail

if ! command -v node >/dev/null 2>&1; then
  echo "node is not installed on remote host" >&2
  exit 1
fi
if ! command -v npm >/dev/null 2>&1; then
  echo "npm is not installed on remote host" >&2
  exit 1
fi

if ! id -u skybridge >/dev/null 2>&1; then
  sudo useradd --system --home "$APP_DIR" --shell /usr/sbin/nologin skybridge
fi

sudo mkdir -p "$APP_DIR/releases" "$APP_DIR/shared/config"

if [[ ! -f "$REMOTE_ENV" ]]; then
  echo "Missing env file: $REMOTE_ENV" >&2
  echo "Create it from production.env.example before deploying." >&2
  exit 2
fi

sudo mkdir -p "$REMOTE_RELEASE_DIR"
sudo tar -xzf "$REMOTE_ARCHIVE" -C "$REMOTE_RELEASE_DIR"
sudo rm -f "$REMOTE_ARCHIVE"

pushd "$REMOTE_RELEASE_DIR" >/dev/null
sudo npm ci --omit=dev --no-audit --no-fund
popd >/dev/null

sudo ln -sfn "$REMOTE_RELEASE_DIR" "$REMOTE_CURRENT"
sudo chown -R skybridge:skybridge "$APP_DIR"
REMOTE_PREP

if [[ "$SKIP_SYSTEMD" != "true" ]]; then
    if [[ ! -f "$SERVICE_TEMPLATE" ]]; then
        echo "systemd template not found: $SERVICE_TEMPLATE" >&2
        exit 1
    fi

    echo "[deploy] Installing systemd service: $SERVICE_NAME"
    scp -P "$PORT" "$SERVICE_TEMPLATE" "$REMOTE_TARGET:/tmp/${SERVICE_NAME}.service"

    ssh -p "$PORT" "$REMOTE_TARGET" \
      "SERVICE_NAME='$SERVICE_NAME' HEALTH_URL='$HEALTH_URL' bash -s" <<'REMOTE_SYSTEMD'
set -euo pipefail

sudo install -m 0644 "/tmp/${SERVICE_NAME}.service" "/etc/systemd/system/${SERVICE_NAME}.service"
sudo rm -f "/tmp/${SERVICE_NAME}.service"

sudo systemctl daemon-reload
sudo systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
sudo systemctl restart "$SERVICE_NAME"
sleep 2

curl -fsS "$HEALTH_URL" >/dev/null
sudo systemctl --no-pager --full status "$SERVICE_NAME" | sed -n '1,25p'
REMOTE_SYSTEMD
fi

echo "[deploy] Release $RELEASE_NAME deployed successfully"
echo "[deploy] Remote current symlink: $REMOTE_CURRENT"
echo "[deploy] Health check: $HEALTH_URL"
