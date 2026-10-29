# Nebula Auth Reference

This folder provides a reference OAuth 2.1 authorization server for native public clients using PKCE.

It exists because the real Nebula backend repository is not present in this workspace. The code here is intended to be copied into the actual Nebula auth service or used as a contract fixture while migrating the real backend.

## What it demonstrates

- Public native clients with no `client_secret`
- `authorization_code` grant with mandatory `code_verifier`
- `S256` PKCE only
- Exact redirect URI validation against registered public clients
- Short-lived authorization codes
- Refresh token rotation
- `userinfo` endpoint
- OpenID discovery document

## Run locally

```bash
cd "Server/nebula-auth-reference"
node server.js
```

Default issuer: `http://127.0.0.1:8788`

Demo login:

- username: `demo`
- password: `demo-pass`

## Smoke test

In another terminal:

```bash
cd "Server/nebula-auth-reference"
bash ./smoke_pkce.sh
```

## Environment

- `PORT`
- `NEBULA_ISSUER`
- `NEBULA_DEMO_USERNAME`
- `NEBULA_DEMO_PASSWORD`
- `NEBULA_DEMO_DISPLAY_NAME`
- `NEBULA_DEMO_EMAIL`
- `NEBULA_PUBLIC_CLIENTS_JSON`
- `NEBULA_ALLOW_DEV_HEADLESS_AUTHORIZE`

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
- Replace the demo user check with real login + MFA inside the authorization session.
- Persist auth codes, refresh tokens, and client registrations in durable storage.
- Enforce exact redirect URI registration and one-time refresh token rotation.
