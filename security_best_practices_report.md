# SkyBridge Official Website — Security Best Practices Report

Date: 2026-02-22  
Scope:
- `frontend/` (Next.js App Router)
- `backend/` (Axum API)

This report is **repo-grounded** (evidence references file + line numbers). Infrastructure controls (CDN/WAF/TLS/PQC, platform headers) are **not** visible here and must be verified at runtime.

## Executive summary

Security posture was strengthened in the areas most likely to be exploited on a public website:

- Added a **strict CSP with per-request nonce** and ensured Next.js receives the nonce during render (XSS blast-radius reduction).
- Enabled the Next.js **proxy/middleware layer** to enforce rate limiting, body size checks, suspicious-request blocking, CSP propagation, and request IDs.
- Hardened baseline **security headers** and prevented caching of sensitive auth callback/reset routes.
- Hardened Supabase auth configuration (PKCE, env-only configuration; reduced token persistence lifetime).
- Upgraded **JavaScript and Rust dependencies** and removed `npm audit` vulnerabilities (via safe dependency override).

## Findings

### [High] (1) Missing/weak XSS defense-in-depth without CSP nonce

Impact: If any XSS is introduced (now or later), attacker JS can exfiltrate auth tokens/session and fully take over accounts.

Status: **Fixed in this branch** by adding a nonce-based CSP and propagating it correctly into Next.js render.

Evidence:
- CSP nonce generation + CSP construction: `frontend/src/proxy.ts:58` – `frontend/src/proxy.ts:107`
- CSP forwarded to **request** headers (required for Next.js to pick up the nonce) + CSP set on response: `frontend/src/proxy.ts:139` – `frontend/src/proxy.ts:152`

Notes:
- CSP is intentionally strict: no `unsafe-inline`, and attribute-based script execution is blocked via `script-src-attr 'none'`. See `frontend/src/proxy.ts:92` – `frontend/src/proxy.ts:104`.

### [High] (2) Edge request filtering / rate limiting must actually execute

Impact: Without an executing request gate, basic DoS (oversized bodies / high-rate traffic) and noisy probing reach the app unchecked.

Status: **Fixed in this branch** by implementing the gate as a Next.js **proxy** entrypoint and applying it broadly.

Evidence:
- Rate limiting + bounded map (anti-memory-DoS): `frontend/src/proxy.ts:28` – `frontend/src/proxy.ts:52`
- Body size guard (1MB) based on `content-length`: `frontend/src/proxy.ts:123` – `frontend/src/proxy.ts:128`
- Proxy matcher excluding static assets: `frontend/src/proxy.ts:158` – `frontend/src/proxy.ts:162`

Operational note:
- This limiter is **best-effort** and per-instance. For production, also enable platform rate limiting/WAF (Cloudflare/Vercel/NGINX) so it remains effective across multiple instances.

### [Medium] (3) Security headers baseline + safe caching rules

Impact: Clickjacking, MIME-sniffing, and overly-permissive browser capabilities can increase exploitability of other bugs.

Status: **Fixed in this branch** by setting secure-by-default headers; and marking auth routes as `no-store`.

Evidence:
- Header baseline + disabling `X-Powered-By`: `frontend/next.config.ts:3` – `frontend/next.config.ts:23`
- Auth routes `Cache-Control: no-store`: `frontend/next.config.ts:38` – `frontend/next.config.ts:42`

HSTS caution:
- HSTS is **opt-in** only via `SKYBRIDGE_ENABLE_HSTS` to avoid “sticky” misconfiguration outages. `frontend/next.config.ts:25` – `frontend/next.config.ts:31`

### [Medium] (4) Supabase client configuration must be environment-driven and token persistence should be minimized

Impact: Misconfiguration can silently point production traffic at the wrong Supabase project; long-lived browser tokens increase risk if XSS occurs.

Status: **Fixed in this branch** by requiring env vars and using PKCE + sessionStorage.

Evidence:
- Env-only Supabase config (no hardcoded URL/keys): `frontend/src/lib/supabase.ts:10` – `frontend/src/lib/supabase.ts:15`
- PKCE flow + `sessionStorage` persistence: `frontend/src/lib/supabase.ts:21` – `frontend/src/lib/supabase.ts:29`

Recommendation for “maximum” security:
- For highest assurance, move to **server-side session cookies** (httpOnly) so access tokens are not readable by JS. This typically involves a BFF/SSR auth layer (e.g., Supabase SSR helpers) and CSRF-aware patterns for state-changing requests.

### [Low] (5) CSP compatibility: remove inline styles to avoid `unsafe-inline`

Impact: Allowing `unsafe-inline` significantly weakens CSP and undermines XSS mitigations.

Status: **Fixed in this branch** by removing an inline `style={...}` usage.

Evidence:
- Replaced inline styles with Tailwind utilities: `frontend/src/components/dashboard/WeatherWidget.tsx:8`

### [Info] (6) Dependency hygiene / supply-chain posture

Status:
- JS deps upgraded; remaining `npm audit` findings eliminated by safe override.
- Rust deps upgraded; build verified.

Evidence:
- `npm` override that removes audit findings (minimatch ReDoS advisory): `frontend/package.json:36` – `frontend/package.json:38`
- Rust deps updated: `backend/Cargo.toml`

## Post-quantum (PQC) considerations (website)

Browser PQC is primarily a **TLS/edge** capability, not something the app can reliably enforce from JavaScript. Practical steps:

1. Enable **hybrid-PQC TLS** at your CDN/edge (provider feature; verify via runtime TLS fingerprints).
2. If you need end-to-end confidentiality against “store now, decrypt later” for specific payloads, consider **application-layer encryption** (WASM crypto + key management). This is non-trivial and should be scoped to specific data flows.

## Verification checklist (runtime)

After deployment, verify at runtime (example commands):

- Check headers/CSP:
  - `curl -I https://YOUR_DOMAIN/`
  - `curl -I https://YOUR_DOMAIN/auth/callback`
  - Ensure `Content-Security-Policy` is present and includes a `'nonce-...'`.
- Confirm proxy executes:
  - Ensure responses include `X-Request-ID` (from `frontend/src/proxy.ts`).
- Confirm Supabase envs:
  - Ensure `NEXT_PUBLIC_SUPABASE_URL` and `NEXT_PUBLIC_SUPABASE_ANON_KEY` are set in the deployment environment.

