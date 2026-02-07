# SkyBridge Signaling Deployment Guide

This folder provides a production-ready deployment baseline for the signaling service,
with explicit support for dynamic TURN credentials (`/api/turn/credentials`) and
WebSocket signaling (`/ws`).

## 1. Prepare the server

1. Install Node.js 20+ and npm.
2. Create runtime config:
   - `sudo mkdir -p /opt/skybridge-signaling/shared/config`
   - `sudo cp production.env.example /opt/skybridge-signaling/shared/config/production.env`
   - Fill real values in `production.env`.
3. Ensure Nginx reverse proxy is configured using `deploy/nginx/skybridge-signaling.conf`.

## 2. Deploy from local workspace

```bash
bash Server/skybridge-signaling/deploy/scripts/deploy_remote.sh \
  --host <server-ip-or-dns> \
  --user <ssh-user>
```

Common flags:
- `--service skybridge-signaling`
- `--app-dir /opt/skybridge-signaling`
- `--health-url http://127.0.0.1:8443/health`

## 3. Post-deploy smoke checks

```bash
bash Server/skybridge-signaling/deploy/scripts/smoke_local.sh http://127.0.0.1:8443
```

Expected behavior:
- `GET /` returns JSON with advertised endpoints.
- `GET /health` returns `200`.
- `GET /api/turn/credentials` is not `404`.

## 4. Rollback

```bash
bash Server/skybridge-signaling/deploy/scripts/rollback_remote.sh \
  --host <server-ip-or-dns> \
  --user <ssh-user>
```

Optional explicit release target:

```bash
bash Server/skybridge-signaling/deploy/scripts/rollback_remote.sh \
  --host <server-ip-or-dns> \
  --user <ssh-user> \
  --release <release-name>
```

## Security notes

- Keep `ALLOW_INSECURE=false` in production.
- Prefer `TURN_SHARED_SECRET` short-lived credentials over static TURN password.
- Keep `TURN_ENFORCE_API_KEY=true` and align `TURN_CLIENT_API_KEY` with app-side `SKYBRIDGE_CLIENT_API_KEY`.
- Keep Node bound to localhost (`HOST=127.0.0.1`) and expose through Nginx TLS only.
