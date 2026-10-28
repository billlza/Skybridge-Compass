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
  --release <name>         Recorded release directory (default: current release's recorded predecessor)
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

node - "$HOST" "$USER_NAME" "$PORT" "$APP_DIR" "$SERVICE_NAME" "$TARGET_RELEASE" "$HEALTH_URL" <<'VALIDATE_INPUT'
const [host, user, port, appDir, service, release, healthURL] = process.argv.slice(2);
function fail(message) { console.error(message); process.exit(1); }
if (!/^[A-Za-z0-9[\]:._%\-]+$/.test(host) || host.startsWith('-')) fail('Invalid --host');
if (!/^[A-Za-z_][A-Za-z0-9_\-]*$/.test(user)) fail('Invalid --user');
if (!/^\d+$/.test(port) || Number(port) < 1 || Number(port) > 65535) fail('Invalid --port');
if (!appDir.startsWith('/') || appDir === '/' || appDir.split('/').includes('..')
    || /[\u0000-\u001f\u007f]/.test(appDir)) fail('Invalid --app-dir');
if (!/^[A-Za-z0-9_][A-Za-z0-9_.@\-]*$/.test(service)) fail('Invalid --service');
if (release && !/^[A-Za-z0-9_][A-Za-z0-9_.\-]*$/.test(release)) fail('Invalid --release');
let url;
try { url = new URL(healthURL); } catch { fail('Invalid --health-url'); }
if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password || url.search || url.hash
    || /[\u0000-\u0020\u007f]/.test(healthURL)) fail('Invalid --health-url');
VALIDATE_INPUT

remote_environment() {
    node - "$@" <<'QUOTE_ENVIRONMENT'
const words = ['env', ...process.argv.slice(2), 'bash', '-s'];
console.log(words.map((word) => `'${word.replace(/'/g, "'\\''")}'`).join(' '));
QUOTE_ENVIRONMENT
}

REMOTE_TARGET="${USER_NAME}@${HOST}"
SSH_CMD=(ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10
  -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -p "$PORT")
if [[ -n "$IDENTITY_FILE" ]]; then
    SSH_CMD+=( -i "$IDENTITY_FILE" -o IdentitiesOnly=yes )
fi

"${SSH_CMD[@]}" "$REMOTE_TARGET" \
  "$(remote_environment "APP_DIR=$APP_DIR" "SERVICE_NAME=$SERVICE_NAME" "TARGET_RELEASE=$TARGET_RELEASE" "HEALTH_URL=$HEALTH_URL")" <<'REMOTE_ROLLBACK'
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
source_release="$(readlink -f "$current_link")"
if [[ ! -f "$source_release/deploy/scripts/release_runtime_journal.sh" ]]; then
  echo "Current release has no runtime journal helper; reconcile its runtime before rollback" >&2
  exit 1
fi
source "$source_release/deploy/scripts/release_runtime_journal.sh"

if [[ -n "$TARGET_RELEASE" ]]; then
  target_path="$releases_dir/$TARGET_RELEASE"
  if [[ ! -d "$target_path" ]]; then
    echo "Target release does not exist: $target_path" >&2
    exit 1
  fi
else
  if [[ ! -f "$source_release/.previous-current-target" ]]; then
    echo "Current release has no recorded predecessor" >&2
    exit 1
  fi
  target_path="$(cat "$source_release/.previous-current-target")"
fi
if [[ -z "$target_path" || ! -d "$target_path" ]]; then
  echo "Recorded rollback target does not exist" >&2
  exit 1
fi
target_path="$(readlink -f "$target_path")"
releases_root="$(readlink -f "$releases_dir")"
case "$target_path" in
  "$releases_root"/*) ;;
  *) echo "Rollback target is outside the release directory" >&2; exit 1 ;;
esac
if [[ "$target_path" == "$source_release" ]]; then
  echo "Rollback target is already current" >&2
  exit 1
fi

echo "Rolling back to: $target_path"
switch_to_recorded_release "$source_release" "$target_path" "$SERVICE_NAME" "$current_link"
sleep 2

verify_rollback_build "$source_release" "$target_path" "$HEALTH_URL"
sudo systemctl --no-pager --full status "$SERVICE_NAME" | sed -n '1,25p'
REMOTE_ROLLBACK

echo "Rollback completed"
