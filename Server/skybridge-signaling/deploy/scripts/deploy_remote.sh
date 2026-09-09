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
  --identity-file <path>   SSH private key for remote login (optional)
  --port <port>            SSH port (default: 22)
  --app-dir <path>         Remote app root (default: /opt/skybridge-signaling)
  --service <name>         systemd service name (default: skybridge-signaling)
  --node-runtime-dir <dir> Reviewed remote Node distribution directory (required)
  --health-url <url>       Readiness endpoint checked on remote host
                           (default: http://127.0.0.1:8443/readyz)
  --skip-systemd           Prepare and verify the candidate only; do not change current or systemd
  -h, --help               Show this help
USAGE
}

HOST=""
USER_NAME=""
IDENTITY_FILE=""
PORT="22"
APP_DIR="/opt/skybridge-signaling"
SERVICE_NAME="skybridge-signaling"
NODE_RUNTIME_DIR=""
HEALTH_URL="http://127.0.0.1:8443/readyz"
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
        --node-runtime-dir)
            NODE_RUNTIME_DIR="${2:-}"
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

if [[ -z "$HOST" || -z "$USER_NAME" || -z "$NODE_RUNTIME_DIR" ]]; then
    echo "--host, --user and --node-runtime-dir are required" >&2
    usage
    exit 1
fi

if [[ -n "$IDENTITY_FILE" && ! -f "$IDENTITY_FILE" ]]; then
    echo "identity file does not exist: $IDENTITY_FILE" >&2
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
node -e "const [major, minor] = process.versions.node.split('.').map(Number); if (major < 24 || (major === 24 && minor < 6)) { console.error('Node.js 24.6.0 or newer is required'); process.exit(1); }"

HEALTH_ORIGIN="$(node - "$HEALTH_URL" "$HOST" "$USER_NAME" "$PORT" "$APP_DIR" "$SERVICE_NAME" <<'VALIDATE_INPUT'
const [healthURL, host, user, port, appDir, service] = process.argv.slice(2);
function fail(message) { console.error(message); process.exit(1); }
let url;
try { url = new URL(healthURL); } catch { fail('Invalid --health-url'); }
if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password || url.search || url.hash
    || /[\u0000-\u0020\u007f]/.test(healthURL)) {
  fail('--health-url must be HTTP(S) without credentials, query, fragment or whitespace');
}
if (!/^[A-Za-z0-9[\]:._%\-]+$/.test(host) || host.startsWith('-')) fail('Invalid --host');
if (!/^[A-Za-z_][A-Za-z0-9_\-]*$/.test(user)) fail('Invalid --user');
if (!/^\d+$/.test(port) || Number(port) < 1 || Number(port) > 65535) fail('Invalid --port');
if (!appDir.startsWith('/') || appDir === '/' || appDir.split('/').includes('..')
    || /[\u0000-\u001f\u007f]/.test(appDir)) fail('--app-dir must be an absolute non-root path without parent traversal');
if (!/^[A-Za-z0-9_][A-Za-z0-9_.@\-]*$/.test(service)) fail('Invalid --service');
console.log(url.origin);
VALIDATE_INPUT
)"

# SSH executes its command through a remote shell. Quote every environment
# assignment as one POSIX shell word, including paths containing apostrophes.
remote_environment() {
    node - "$@" <<'QUOTE_ENVIRONMENT'
const words = ['env', ...process.argv.slice(2), 'bash', '-s'];
console.log(words.map((word) => `'${word.replace(/'/g, "'\\''")}'`).join(' '));
QUOTE_ENVIRONMENT
}

pushd "$SERVER_DIR" >/dev/null
node --check server.js
popd >/dev/null

GIT_SHA="$(git -C "$PROJECT_ROOT" rev-parse --short HEAD 2>/dev/null || echo nogit)"
STAMP="$(date -u +%Y%m%d%H%M%S)"
RELEASE_NAME="${STAMP}-${GIT_SHA}"
BUILD_FINGERPRINT="skybridge-signaling/${RELEASE_NAME}"
ARCHIVE_PATH="$(mktemp -t "skybridge-signaling-${RELEASE_NAME}.XXXXXX.tgz")"
REMOTE_ARCHIVE="/tmp/skybridge-signaling-${RELEASE_NAME}.tgz"
REMOTE_RELEASE_DIR="$APP_DIR/releases/$RELEASE_NAME"
REMOTE_ENV="$APP_DIR/shared/config/production.env"
REMOTE_CURRENT="$APP_DIR/current"
REMOTE_TARGET="${USER_NAME}@${HOST}"

SSH_CMD=(ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10
    -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -p "$PORT")
SCP_CMD=(scp -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10
    -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -P "$PORT")
if [[ -n "$IDENTITY_FILE" ]]; then
    SSH_CMD+=( -i "$IDENTITY_FILE" -o IdentitiesOnly=yes )
    SCP_CMD+=( -i "$IDENTITY_FILE" -o IdentitiesOnly=yes )
fi

cleanup() {
    rm -f "$ARCHIVE_PATH"
}
trap cleanup EXIT

echo "[deploy] Packaging release $RELEASE_NAME"
COPYFILE_DISABLE=1 tar --no-xattrs \
  --exclude='node_modules' \
  --exclude='.DS_Store' \
  --exclude='*.log' \
  -C "$SERVER_DIR" \
  -czf "$ARCHIVE_PATH" \
  .

echo "[deploy] Uploading archive to $REMOTE_TARGET"
"${SCP_CMD[@]}" "$ARCHIVE_PATH" "$REMOTE_TARGET:$REMOTE_ARCHIVE"

echo "[deploy] Provisioning release directory and dependencies"
"${SSH_CMD[@]}" "$REMOTE_TARGET" \
  "$(remote_environment "APP_DIR=$APP_DIR" "REMOTE_ARCHIVE=$REMOTE_ARCHIVE" "REMOTE_RELEASE_DIR=$REMOTE_RELEASE_DIR" "REMOTE_ENV=$REMOTE_ENV" "REMOTE_CURRENT=$REMOTE_CURRENT" "HEALTH_URL=$HEALTH_URL" "BUILD_FINGERPRINT=$BUILD_FINGERPRINT" "NODE_RUNTIME_DIR=$NODE_RUNTIME_DIR")" <<'REMOTE_PREP'
set -euo pipefail

if [[ ! -x "$NODE_RUNTIME_DIR/bin/node" ]]; then
  echo "Selected Node runtime is not executable" >&2
  exit 1
fi
if ! command -v curl >/dev/null 2>&1; then
  echo "curl is not installed on remote host" >&2
  exit 1
fi

if ! id -u skybridge >/dev/null 2>&1; then
  sudo useradd --system --home "$APP_DIR" --shell /usr/sbin/nologin skybridge
fi

sudo mkdir -p "$APP_DIR/releases" "$APP_DIR/shared/config"
for managed_directory in "$APP_DIR" "$APP_DIR/releases"; do
  service_access="$(sudo -u skybridge bash -c 'if [[ -w "$1" ]]; then printf writable; else printf read_only; fi' -- "$managed_directory")"
  if [[ "$service_access" != "read_only" ]]; then
    echo "Deployment management directory is writable by the service account: $managed_directory" >&2
    exit 1
  fi
done

if [[ ! -f "$REMOTE_ENV" ]]; then
  echo "Missing env file: $REMOTE_ENV" >&2
  echo "Create it from production.env.example before deploying." >&2
  exit 2
fi

sudo mkdir -m 0755 "$REMOTE_RELEASE_DIR"
sudo tar --no-same-owner -xzf "$REMOTE_ARCHIVE" -C "$REMOTE_RELEASE_DIR"
sudo rm -f "$REMOTE_ARCHIVE"
source "$REMOTE_RELEASE_DIR/deploy/scripts/release_runtime_journal.sh"
validate_selected_node_runtime "$NODE_RUNTIME_DIR"
printf '%s\n' "$BUILD_FINGERPRINT" | sudo tee "$REMOTE_RELEASE_DIR/.skybridge-build-fingerprint" >/dev/null
printf '%s\n' "$NODE_RUNTIME_DIR" | sudo tee "$REMOTE_RELEASE_DIR/.node-runtime-dir" >/dev/null
sudo chmod -R go-w "$REMOTE_RELEASE_DIR"
sudo mkdir "$REMOTE_RELEASE_DIR/node_modules" "$REMOTE_RELEASE_DIR/.npm-cache"
sudo chown skybridge:skybridge "$REMOTE_RELEASE_DIR/node_modules" "$REMOTE_RELEASE_DIR/.npm-cache"

pushd "$REMOTE_RELEASE_DIR" >/dev/null
npm_exit_code=0
sudo -u skybridge env PATH="$NODE_RUNTIME_DIR/bin:$PATH" NPM_CONFIG_CACHE="$REMOTE_RELEASE_DIR/.npm-cache" NPM_CONFIG_UPDATE_NOTIFIER=false NO_UPDATE_NOTIFIER=1 \
  "$NODE_RUNTIME_DIR/bin/node" "$NODE_RUNTIME_DIR/lib/node_modules/npm/bin/npm-cli.js" \
  ci --omit=dev --ignore-scripts --no-audit --no-fund || npm_exit_code=$?
popd >/dev/null
sudo chown -R root:root "$REMOTE_RELEASE_DIR/node_modules" "$REMOTE_RELEASE_DIR/.npm-cache"
sudo chmod -R go-w "$REMOTE_RELEASE_DIR/node_modules" "$REMOTE_RELEASE_DIR/.npm-cache"
if [[ "$npm_exit_code" != "0" ]]; then exit "$npm_exit_code"; fi

PREVIOUS_CURRENT_TARGET=""
if [[ -L "$REMOTE_CURRENT" || -e "$REMOTE_CURRENT" ]]; then
  PREVIOUS_CURRENT_TARGET="$(readlink -f "$REMOTE_CURRENT" || true)"
fi
printf '%s\n' "$PREVIOUS_CURRENT_TARGET" | sudo tee "$REMOTE_RELEASE_DIR/.previous-current-target" >/dev/null
sudo chmod 0644 "$REMOTE_RELEASE_DIR/.previous-current-target"

CANDIDATE_PORT="$("$NODE_RUNTIME_DIR/bin/node" -e "const net = require('node:net'); const server = net.createServer(); server.listen(0, '127.0.0.1', () => { console.log(server.address().port); server.close(); });")"
CANDIDATE_READY_URL="$(HEALTH_URL="$HEALTH_URL" CANDIDATE_PORT="$CANDIDATE_PORT" "$NODE_RUNTIME_DIR/bin/node" -e "const url = new URL(process.env.HEALTH_URL); url.hostname = '127.0.0.1'; url.port = process.env.CANDIDATE_PORT; console.log(url.toString());")"
CANDIDATE_BASE_URL="$(CANDIDATE_READY_URL="$CANDIDATE_READY_URL" "$NODE_RUNTIME_DIR/bin/node" -e "console.log(new URL(process.env.CANDIDATE_READY_URL).origin)")"

echo "[deploy] Preflight booting candidate release on $CANDIDATE_READY_URL"
sudo -u skybridge env \
  REMOTE_ENV="$REMOTE_ENV" \
  REMOTE_RELEASE_DIR="$REMOTE_RELEASE_DIR" \
  CANDIDATE_PORT="$CANDIDATE_PORT" \
  CANDIDATE_READY_URL="$CANDIDATE_READY_URL" \
  CANDIDATE_BASE_URL="$CANDIDATE_BASE_URL" \
  EXPECTED_BUILD_FINGERPRINT="$BUILD_FINGERPRINT" \
  NODE_RUNTIME_DIR="$NODE_RUNTIME_DIR" \
  bash -s <<'REMOTE_CANDIDATE'
set -euo pipefail

CANDIDATE_LOG="$REMOTE_RELEASE_DIR/.candidate-boot.log"
set -a
source "$REMOTE_ENV"
set +a
export PATH="$NODE_RUNTIME_DIR/bin:$PATH"

HOST=127.0.0.1 PORT="$CANDIDATE_PORT" NODE_ENV=production "$NODE_RUNTIME_DIR/bin/node" "$REMOTE_RELEASE_DIR/server.js" >"$CANDIDATE_LOG" 2>&1 &
candidate_pid=$!

cleanup() {
  if kill -0 "$candidate_pid" >/dev/null 2>&1; then
    kill "$candidate_pid" >/dev/null 2>&1 || true
    wait "$candidate_pid" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

for attempt in $(seq 1 30); do
  if curl --disable --silent --show-error --fail --connect-timeout 5 --max-time 15 "$CANDIDATE_READY_URL" >/dev/null; then
    bash "$REMOTE_RELEASE_DIR/deploy/scripts/smoke_local.sh" \
      "$CANDIDATE_BASE_URL" "" "$EXPECTED_BUILD_FINGERPRINT"
    exit 0
  fi
  if ! kill -0 "$candidate_pid" >/dev/null 2>&1; then
    wait "$candidate_pid" || true
    break
  fi
  sleep 1
done

echo "Candidate release failed readiness: $CANDIDATE_READY_URL" >&2
tail -n 50 "$CANDIDATE_LOG" >&2 || true
exit 1
REMOTE_CANDIDATE

REMOTE_PREP

if [[ "$SKIP_SYSTEMD" != "true" ]]; then
    if [[ ! -f "$SERVICE_TEMPLATE" ]]; then
        echo "systemd template not found: $SERVICE_TEMPLATE" >&2
        exit 1
    fi

    "${SSH_CMD[@]}" "$REMOTE_TARGET" \
      "$(remote_environment "SERVICE_NAME=$SERVICE_NAME" "REMOTE_CURRENT=$REMOTE_CURRENT" "REMOTE_RELEASE_DIR=$REMOTE_RELEASE_DIR" "PROBE_BASE_URL=$HEALTH_ORIGIN" "EXPECTED_BUILD_FINGERPRINT=$BUILD_FINGERPRINT" "NODE_RUNTIME_DIR=$NODE_RUNTIME_DIR")" <<'REMOTE_SYSTEMD'
set -euo pipefail

source "$REMOTE_RELEASE_DIR/deploy/scripts/release_runtime_journal.sh"

PREVIOUS_CURRENT_TARGET=""
if [[ -f "$REMOTE_RELEASE_DIR/.previous-current-target" ]]; then
  PREVIOUS_CURRENT_TARGET="$(cat "$REMOTE_RELEASE_DIR/.previous-current-target")"
fi

rollback_current() {
  if [[ -z "$PREVIOUS_CURRENT_TARGET" || ! -d "$PREVIOUS_CURRENT_TARGET" ]]; then
    return 1
  fi
  echo "[deploy] Rolling back current symlink to $PREVIOUS_CURRENT_TARGET" >&2
  switch_to_recorded_release "$REMOTE_RELEASE_DIR" "$PREVIOUS_CURRENT_TARGET" "$SERVICE_NAME" "$REMOTE_CURRENT" || return
  verify_rollback_build "$REMOTE_RELEASE_DIR" "$PREVIOUS_CURRENT_TARGET" "$PROBE_BASE_URL/health"
}

capture_service_runtime_journal "$REMOTE_RELEASE_DIR" "$SERVICE_NAME"
if [[ -n "$PREVIOUS_CURRENT_TARGET" ]]; then
  capture_previous_health_build "$REMOTE_RELEASE_DIR" "$PREVIOUS_CURRENT_TARGET" "$PROBE_BASE_URL/health"
fi
if ! switch_to_recorded_release "$PREVIOUS_CURRENT_TARGET" "$REMOTE_RELEASE_DIR" "$SERVICE_NAME" "$REMOTE_CURRENT" promote; then
  if ! rollback_current; then echo "[deploy] Rollback failed; preserved runtime journal requires reconciliation" >&2; fi
  exit 1
fi
if ! sudo systemctl enable "$SERVICE_NAME" >/dev/null; then
  if ! rollback_current; then echo "[deploy] Rollback failed; preserved runtime journal requires reconciliation" >&2; fi
  exit 1
fi
sleep 2

if ! env PATH="$NODE_RUNTIME_DIR/bin:$PATH" bash "$REMOTE_RELEASE_DIR/deploy/scripts/smoke_local.sh" \
  "$PROBE_BASE_URL" "" "$EXPECTED_BUILD_FINGERPRINT"; then
  if ! rollback_current; then echo "[deploy] Rollback failed; preserved runtime journal requires reconciliation" >&2; fi
  exit 1
fi

sudo systemctl --no-pager --full status "$SERVICE_NAME" | sed -n '1,25p'
printf '%s\n' "$EXPECTED_BUILD_FINGERPRINT" | sudo tee "$REMOTE_RELEASE_DIR/.deployment-verified" >/dev/null
sudo chmod 0644 "$REMOTE_RELEASE_DIR/.deployment-verified"
REMOTE_SYSTEMD
else
    echo "[deploy] Candidate prepared and verified: $REMOTE_RELEASE_DIR"
    echo "[deploy] Prepared only: current and the running service were not changed"
    exit 0
fi

echo "[deploy] Release $RELEASE_NAME deployed and verified successfully"
echo "[deploy] Remote current symlink: $REMOTE_CURRENT"
echo "[deploy] Health check: $HEALTH_URL"
