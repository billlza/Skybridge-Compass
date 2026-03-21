# Nebula Auth Reference

This folder provides a Nebula auth gateway for native public clients using OAuth 2.1 + PKCE.

It can run in two modes:

- `demo` mode: in-memory reference issuer for local smoke tests
- `supabase_gateway` mode: real login/signup/phone OTP/OIDC bridge backed by Supabase Auth

It exists because the real Nebula backend repository is not present in this workspace. The code here is intended to be deployed as the shortest path to a working issuer or copied into the actual Nebula auth service later.

## What it demonstrates

- Public native clients with no `client_secret`
- `authorization_code` grant with mandatory `code_verifier`
- `S256` PKCE only
- Exact redirect URI validation against registered public clients
- Loopback redirect templates for CLI (`http://127.0.0.1/auth/callback`)
- Short-lived authorization codes
- Supabase-backed refresh token proxying
- `userinfo` endpoint backed by Supabase `/auth/v1/user`
- OpenID discovery document
- Compatibility endpoints for existing Apple/Linux clients:
  - `/auth/login`
  - `/auth/refresh`
  - `/auth/register`
  - `/auth/email/login`
  - `/auth/email/reset-password`
  - `/auth/phone/send-code`
  - `/auth/phone/login`
  - `/auth/apple/exchange`

## Run locally

```bash
cd "Server/nebula-auth-reference"
node server.js
```

Default issuer: `http://127.0.0.1:8788`

Demo login in `demo` mode:

- username: `demo`
- password: `demo-pass`

To run against real Supabase:

```bash
export SUPABASE_URL="https://YOUR_PROJECT.supabase.co"
export SUPABASE_ANON_KEY="..."
export SUPABASE_SERVICE_ROLE_KEY="..."   # optional, only for username checks
export NEBULA_ISSUER="https://auth.nebula-technologies.net"
node server.js
```

## Smoke test

In another terminal:

```bash
cd "Server/nebula-auth-reference"
bash ./smoke_pkce.sh
```

For real Supabase-backed smoke, export:

```bash
export NEBULA_SMOKE_IDENTIFIER="you@example.com"
export NEBULA_SMOKE_PASSWORD="your-password"
bash ./smoke_pkce.sh https://auth.nebula-technologies.net
```

## Environment

- `PORT`
- `NEBULA_ISSUER`
- `NEBULA_PUBLIC_CLIENTS_JSON`
- `NEBULA_ALLOW_DEV_HEADLESS_AUTHORIZE`
- `SUPABASE_URL`
- `SUPABASE_ANON_KEY`
- `SUPABASE_SERVICE_ROLE_KEY`
- `NEBULA_DEMO_USERNAME`
- `NEBULA_DEMO_PASSWORD`
- `NEBULA_DEMO_DISPLAY_NAME`
- `NEBULA_DEMO_EMAIL`

Example `NEBULA_PUBLIC_CLIENTS_JSON`:

```json
{
  "skybridge_compass_pro": {
    "redirectUris": ["skybridge://auth/nebula"],
    "scopes": ["openid", "profile", "email", "offline_access"]
  },
  "skybridge_compass_ios": {
    "redirectUris": ["skybridge://auth/nebula"],
    "scopes": ["openid", "profile", "email", "offline_access"]
  }
}
```

## Production notes

- Disable `NEBULA_ALLOW_DEV_HEADLESS_AUTHORIZE`.
- Bind a dedicated issuer hostname such as `auth.nebula-technologies.net`; do not point the issuer at the frontend site or signaling service.
- Keep `api.nebula-technologies.net` for signaling and TURN, and point the auth hostname at this service.
- If phone OTP is enabled in Supabase, configure Supabase `send_sms` hooks to call the signaling service endpoint `/api/hooks/supabase/send-sms`, which already supports Alibaba Cloud personal SMS.
- For transactional email, prefer configuring Supabase/Auth mail delivery with a provider such as Resend, SES, or MailerSend instead of sending from clients directly.
- Persist auth codes and browser sessions in durable storage before treating this as the final long-term auth backend.
