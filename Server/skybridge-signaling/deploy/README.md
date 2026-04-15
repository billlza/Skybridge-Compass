# SkyBridge Signaling Deployment Guide

This folder provides a production-ready deployment baseline for the signaling service,
with explicit support for dynamic TURN credentials (`/api/turn/credentials`) and
WebSocket signaling (`/ws`).

It now includes two deployment tracks:
- `deploy/nginx/skybridge-signaling.conf`: single-instance baseline
- `deploy/nginx/skybridge-signaling-multi-instance-sticky.conf`: low-risk multi-instance sticky/session-shard rollout

Auth email/SMS production runbook:
- `Docs/ops/auth-email-and-sms-production.md`

## 1. Prepare the server

1. Install Node.js 20+ and npm.
2. Create runtime config:
   - `sudo mkdir -p /opt/skybridge-signaling/shared/config`
   - `sudo cp production.env.example /opt/skybridge-signaling/shared/config/production.env`
   - Fill real values in `production.env`.
3. Ensure Nginx reverse proxy is configured using `deploy/nginx/skybridge-signaling.conf`
   for single-instance deployments, or `deploy/nginx/skybridge-signaling-multi-instance-sticky.conf`
   for low-risk multi-instance sticky deployments.

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

For a real PNVS hook probe in staging:

```bash
SUPABASE_SEND_SMS_HOOK_SECRET='<staging hook secret>' \
bash Server/skybridge-signaling/deploy/scripts/probe_supabase_send_sms_hook.sh \
  https://<staging-host> \
  <mainland-test-phone>
```

Expected behavior:
- `GET /` returns JSON with advertised endpoints.
- `GET /health` returns `200`.
- `GET /health` includes an `sms` readiness block.
- `GET /readyz` returns `200` only when the signaling backend and required SMS OTP dependencies are ready.
- `probe_supabase_send_sms_hook.sh` returns `200`, then PNVS control panel shows a matching sending record.
- `GET /api/turn/credentials` is not `404`.
- `GET /api/turn/credentials` returns short-lived mode (`mode=shared_secret_hmac`) in production.
- `POST /api/webrtc/register-code` returns a short-lived `code + initiatorToken`.
- `POST /api/webrtc/register-session` returns a server-issued `sessionId + signalingToken`.

If `REQUIRE_SMS_AUTH_READY=true`, production readiness now fails closed until:
- `SUPABASE_SEND_SMS_HOOK_SECRET` is configured
- the selected Aliyun provider is fully configured
- `/readyz` reports `smsReady=true`

Recommended pre-release regression:

```bash
bash Scripts/check_turn_tls_regression.sh https://api.nebula-technologies.net
```

## 3.1 Low-risk multi-instance sticky/session-shard rollout

Recommended order:

1. Keep `SIGNALING_STATE_BACKEND=memory`
2. Enable `ENABLE_STICKY_HINT_COOKIE=true`
3. Deploy 2+ Node instances with unique `INSTANCE_ID`
4. Give each instance a non-overlapping `INSTANCE_CODE_PREFIXES`
   - Example A: `ABCDEFGHJKLMNPQ`
   - Example B: `RSTUVWXYZ23456789`
5. Put Nginx in front using `deploy/nginx/skybridge-signaling-multi-instance-sticky.conf`
6. Verify:
   - `GET /health` returns `instanceId`
   - responses include `X-SkyBridge-Instance`
   - responses from sharded nodes include `X-SkyBridge-Code-Prefixes`
   - `/api/lookup/:code` / `/api/webrtc/lookup/:code` / `/api/answer/:code` / `/api/ice/:sessionId` are routed by the first code/session character
   - `/ws?shard=<sessionId>` lands on the same backend instance for both peers

Why this is low-risk:

- No signaling payload change
- No Redis dependency introduced into the hot path
- Existing in-memory semantics remain valid because `/api/register`, `/api/webrtc/register-code`, and `/api/webrtc/register-session` emit only ids owned by the current instance
- Later HTTP + WebSocket traffic deterministically returns to that same instance by code/session prefix

Operational note:

- `/api/register`, `/api/webrtc/register-code`, and `/api/webrtc/register-session` can hit any instance; that instance becomes the owner by generating only codes/session ids from its configured prefix bucket.
- `/api/lookup/:code`, `/api/webrtc/lookup/:code`, `/api/answer/:code`, and `/api/ice/:sessionId` should be routed by code/session prefix extracted from the path.
- `/ws` should route by `?shard=<sessionId>` (first character) to the same backend.
- The sticky hint cookie is a supplemental fallback for browser/cookie-aware clients, but current Apple `NWWebSocket` clients should not rely on it.
- Do **not** use `$request_uri` for prefix extraction because query strings will break the match; use `$uri` for REST path extraction.

Example 2-node split:

- `signaling-a`: `INSTANCE_CODE_PREFIXES=ABCDEFGHJKLMNPQ`
- `signaling-b`: `INSTANCE_CODE_PREFIXES=RSTUVWXYZ23456789`

## 3.2 Preparing for future Redis without breaking today

Before enabling Redis in production, keep these invariants:

- Treat current mode as `SIGNALING_STATE_BACKEND=memory`
- Keep the sticky/session-shard topology even after Redis is introduced
- Expose `INSTANCE_ID` in logs/headers so cross-instance routing can be debugged

Recommended Redis mode for first rollout:

- Use a **single-primary Redis/Valkey deployment (cluster mode disabled)**
- Keep one same-region replica for failover/backup if desired
- Keep sticky/session-shard routing enabled during Redis rollout
- Store only short-lived signaling state; do not move media/data payloads into Redis

When moving to Redis later, the minimum shared state scope is:

1. `connectionCodes`
2. `iceCandidates`
3. room membership metadata (`sessionId -> instanceId/deviceId`)
4. inter-instance message fan-out for `/ws`

Important:

- Do **not** move only `rooms` to Redis while leaving `connectionCodes` / `iceCandidates` in memory.
- Do **not** remove sticky routing on day one of Redis migration; keep it until Redis pub/sub and cleanup semantics are proven.
- Do **not** use plain URI hashing for memory mode unless `register` can deterministically produce codes that map back to the same backend.
- When Redis is ready, you can stop caring about `INSTANCE_CODE_PREFIXES` ownership for correctness, but keeping it during rollout still reduces cross-instance fan-out and simplifies debugging.
- The server now supports `SIGNALING_STATE_BACKEND=redis` with:
  - `SIGNALING_REDIS_URL`
  - `SIGNALING_REDIS_KEY_PREFIX`
  - `SIGNALING_REDIS_CHANNEL_PREFIX`
  - `ROOM_MEMBERSHIP_TTL_MS`
  - `LEGACY_BINDING_TTL_MS`

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
- Must configure `TURN_SHARED_SECRET` for short-lived TURN REST credentials.
- Keep `TURN_ALLOW_STATIC_FALLBACK=false` in production (enable only for temporary rollback).
- Keep `TURN_URIS` dual-stack (`turns:...:5349?transport=tcp` first, `turn:...:3478?transport=udp` fallback).
- Keep `TURN_ENFORCE_API_KEY=true` and use a deployment-specific `TURN_CLIENT_API_KEY` aligned with app-side `SKYBRIDGE_CLIENT_API_KEY` (do not reuse a repo-wide constant).
- Keep Node bound to localhost (`HOST=127.0.0.1`) and expose through Nginx TLS only.
- In multi-instance mode, keep `ENABLE_STICKY_HINT_COOKIE=true` and `STICKY_HINT_COOKIE_SECURE=true`.
- In memory-mode multi-instance deployments, `INSTANCE_CODE_PREFIXES` must be configured and must not overlap across instances.
