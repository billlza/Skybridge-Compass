# Nebula Public Client + PKCE Migration

## Scope

This document defines the target backend contract for migrating Nebula native apps from confidential-client style requests toward OAuth 2.1 public clients with PKCE.

The real Nebula backend repository is not available in this workspace, so this document and `Server/nebula-auth-reference/` are the migration source of truth produced from the app repository side.

## Why change

Current native-app auth assumptions are not ideal:

- Native apps should not rely on embedded long-lived `client_secret`.
- Username/password exchange from the app to a bespoke `/auth/login` endpoint keeps credentials inside the client UI and bypasses system-browser protections.
- PKCE is the standard defense against authorization code interception for public clients.

Target state:

- macOS and iOS are registered as public clients
- `client_secret` is not required for native clients
- authorization code flow uses PKCE with `S256`
- login and MFA happen inside the server-controlled authorization session

## Required server endpoints

- `GET /.well-known/openid-configuration`
- `GET /oauth/authorize`
- `POST /oauth/token`
- `GET /oauth/userinfo`
- `POST /oauth/revoke`

## Required discovery fields

- `issuer`
- `authorization_endpoint`
- `token_endpoint`
- `userinfo_endpoint`
- `revocation_endpoint`
- `response_types_supported = ["code"]`
- `grant_types_supported = ["authorization_code", "refresh_token"]`
- `token_endpoint_auth_methods_supported = ["none"]`
- `code_challenge_methods_supported = ["S256"]`

## Authorize request requirements

- `response_type=code`
- `client_id`
- `redirect_uri`
- `scope`
- `state`
- `code_challenge`
- `code_challenge_method=S256`

Rules:

- exact-match registered redirect URIs
- reject missing `state`
- reject missing `code_challenge`
- reject any PKCE method other than `S256`
- never require `client_secret` for registered native public clients

## Token request requirements

Authorization-code exchange must require:

- `grant_type=authorization_code`
- `client_id`
- `code`
- `redirect_uri`
- `code_verifier`

Rules:

- authorization code must be one-time use
- authorization code lifetime should be short, for example 5 minutes
- `sha256(code_verifier)` must match the stored `code_challenge`
- reject mismatched `client_id` or `redirect_uri`

Refresh flow:

- `grant_type=refresh_token`
- `client_id`
- `refresh_token`

Rules:

- rotate refresh tokens on every successful use
- revoke the previous refresh token once rotated
- bind refresh tokens to the same `client_id`

## Userinfo contract

At minimum return:

- `sub`
- `preferred_username`
- `name`
- `email`

## MFA handling

MFA should no longer be a separate app-driven `/auth/mfa/verify` step for public clients.

Instead:

- primary login happens on the authorization page
- if MFA is needed, the authorization session continues server-side
- the client only sees the final authorization code after the full auth session is satisfied

This removes the need for the native app to directly orchestrate password + MFA secrets against raw API endpoints.

## Client registration

Recommended native public clients:

- `skybridge_compass_pro`
- `skybridge_compass_ios`

Recommended redirect URI:

- `skybridge://auth/nebula`

If platform-specific redirects are needed later, register them explicitly and keep exact matching.

## Rollout plan

1. Deploy discovery + PKCE endpoints in Nebula backend.
2. Register macOS and iOS as public clients.
3. Keep old `/auth/login` and `/auth/register` temporarily for backward compatibility.
4. Update macOS/iOS UI to use system-browser PKCE login.
5. Once all supported clients migrate, remove confidential native-client behavior and delete native `client_secret` usage entirely.

## Compatibility note

Current app code in this repo already treats `NEBULA_CLIENT_SECRET` as optional and adds a public-client PKCE helper in `Sources/SkyBridgeCore/Services/NebulaPublicClientOAuth.swift`.

That means the backend can move first, and the client UI migration can follow without reintroducing embedded secrets.
