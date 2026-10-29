#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: deploy_media_relay_remote.sh --host <host> --user <user> --env-file <path> [options]

Options:
  --identity <path>        SSH identity file
  --port <port>            SSH port (default: 22)
  --app-dir <path>         Remote app directory (default: /opt/skybridge-media-relay)
  --service <name>         systemd service name (default: skybridge-media-relay)
  --release-name <name>    Release name (default: timestamp-gitsha)
  -h, --help               Show this help
USAGE
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOST=""
USER_NAME=""
IDENTITY_FILE=""
PORT=22
APP_DIR="/opt/skybridge-media-relay"
SERVICE_NAME="skybridge-media-relay"
ENV_FILE=""
GIT_SHA="$(git -C "$SERVER_DIR" rev-parse --short HEAD 2>/dev/null || echo nogit)"
RELEASE_NAME="$(date -u +%Y%m%d%H%M%S)-$GIT_SHA"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --host) HOST="$2"; shift 2 ;;
        --user) USER_NAME="$2"; shift 2 ;;
        --identity) IDENTITY_FILE="$2"; shift 2 ;;
        --port) PORT="$2"; shift 2 ;;
        --app-dir) APP_DIR="$2"; shift 2 ;;
        --service) SERVICE_NAME="$2"; shift 2 ;;
        --env-file) ENV_FILE="$2"; shift 2 ;;
        --release-name) RELEASE_NAME="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
    esac
done

if [[ -z "$HOST" || -z "$USER_NAME" || -z "$ENV_FILE" ]]; then
    usage >&2
    exit 1
fi
if [[ ! -f "$ENV_FILE" ]]; then
    echo "Env file not found: $ENV_FILE" >&2
    exit 1
fi

ARCHIVE_PATH="$(mktemp -t skybridge-media-relay-${RELEASE_NAME}.XXXXXX.tgz)"
REMOTE_ARCHIVE="/tmp/skybridge-media-relay-${RELEASE_NAME}.tgz"
REMOTE_ENV_UPLOAD="/tmp/${SERVICE_NAME}.production.env"
REMOTE_SERVICE_UPLOAD="/tmp/${SERVICE_NAME}.service"
REMOTE_RELEASE_DIR="$APP_DIR/releases/$RELEASE_NAME"
REMOTE_ENV="$APP_DIR/shared/config/production.env"
REMOTE_CURRENT="$APP_DIR/current"
REMOTE_TARGET="${USER_NAME}@${HOST}"
SERVICE_TEMPLATE="$SERVER_DIR/deploy/systemd/skybridge-media-relay.service"

SSH_CMD=(ssh -p "$PORT")
SCP_CMD=(scp -P "$PORT")
if [[ -n "$IDENTITY_FILE" ]]; then
    SSH_CMD+=( -i "$IDENTITY_FILE" -o IdentitiesOnly=yes )
    SCP_CMD+=( -i "$IDENTITY_FILE" -o IdentitiesOnly=yes )
fi

cleanup() {
    rm -f "$ARCHIVE_PATH"
}
trap cleanup EXIT

echo "[media-relay] Packaging release $RELEASE_NAME"
tar \
  --exclude='node_modules' \
  --exclude='.DS_Store' \
  --exclude='*.log' \
  -C "$SERVER_DIR" \
  -czf "$ARCHIVE_PATH" \
  media_relay_standalone.js \
  package.json \
  lib/media_relay.js

echo "[media-relay] Uploading release and configuration to $REMOTE_TARGET"
"${SCP_CMD[@]}" "$ARCHIVE_PATH" "$REMOTE_TARGET:$REMOTE_ARCHIVE"
"${SCP_CMD[@]}" "$ENV_FILE" "$REMOTE_TARGET:$REMOTE_ENV_UPLOAD"
"${SCP_CMD[@]}" "$SERVICE_TEMPLATE" "$REMOTE_TARGET:$REMOTE_SERVICE_UPLOAD"

"${SSH_CMD[@]}" "$REMOTE_TARGET" \
  "APP_DIR='$APP_DIR' REMOTE_ARCHIVE='$REMOTE_ARCHIVE' REMOTE_RELEASE_DIR='$REMOTE_RELEASE_DIR' REMOTE_ENV='$REMOTE_ENV' REMOTE_ENV_UPLOAD='$REMOTE_ENV_UPLOAD' REMOTE_CURRENT='$REMOTE_CURRENT' REMOTE_SERVICE_UPLOAD='$REMOTE_SERVICE_UPLOAD' SERVICE_NAME='$SERVICE_NAME' bash -s" <<'REMOTE_DEPLOY'
set -euo pipefail

if ! command -v node >/dev/null 2>&1; then
  echo "node is not installed on remote host" >&2
  exit 1
fi

if ! id -u skybridge >/dev/null 2>&1; then
  useradd --system --home "$APP_DIR" --shell /usr/sbin/nologin skybridge
fi

mkdir -p "$APP_DIR/releases" "$APP_DIR/shared/config" "$REMOTE_RELEASE_DIR"
tar -xzf "$REMOTE_ARCHIVE" -C "$REMOTE_RELEASE_DIR"
rm -f "$REMOTE_ARCHIVE"
install -m 0600 "$REMOTE_ENV_UPLOAD" "$REMOTE_ENV"
rm -f "$REMOTE_ENV_UPLOAD"
install -m 0644 "$REMOTE_SERVICE_UPLOAD" "/etc/systemd/system/${SERVICE_NAME}.service"
rm -f "$REMOTE_SERVICE_UPLOAD"

chown -R skybridge:skybridge "$REMOTE_RELEASE_DIR" "$APP_DIR/shared"
systemctl daemon-reload
systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
ln -sfn "$REMOTE_RELEASE_DIR" "$REMOTE_CURRENT"
chown -h skybridge:skybridge "$REMOTE_CURRENT" || true
systemctl restart "$SERVICE_NAME"
sleep 1
systemctl --no-pager --full status "$SERVICE_NAME" | sed -n '1,25p'
REMOTE_DEPLOY

echo "[media-relay] Release $RELEASE_NAME deployed successfully"
