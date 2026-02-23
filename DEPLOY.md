# Deployment

This repo contains:
- `frontend/` (Next.js)
- `backend/` (Axum)

## Option A — Vercel (frontend)

1. Import the repo into Vercel.
2. Set **Root Directory** to `frontend/`.
3. Configure environment variables (Production + Preview as needed):
   - `NEXT_PUBLIC_SUPABASE_URL`
   - `NEXT_PUBLIC_SUPABASE_ANON_KEY`
4. Deploy.

Notes:
- The proxy layer runs automatically in Next.js and is used for CSP + request gating (`frontend/src/proxy.ts`).
- Script CSP uses a per-request nonce (XSS defense-in-depth), so routes are rendered **on-demand** (SSR) to let Next attach the nonce during render.
- Supabase env vars are required for auth features. If they are missing, the site still renders but auth flows (`/auth/*`) will show a configuration error.
- If you self-host, put a reverse proxy/CDN in front and ensure it forwards a real client IP (`cf-connecting-ip`, `x-real-ip`, or `x-forwarded-for`) so IP-based rate limiting can work. Control trust via `SKYBRIDGE_TRUST_PROXY_HEADERS` (defaults to `true` in production).
- If you want to enable HSTS, set `SKYBRIDGE_ENABLE_HSTS=true` **only after** confirming the site is permanently HTTPS.

## Option B — Docker Compose (frontend + backend)

1. Create a `.env` file at repo root:
   - `cp .env.example .env`
   - Fill `NEXT_PUBLIC_SUPABASE_URL` and `NEXT_PUBLIC_SUPABASE_ANON_KEY`
2. Build and run:
   - `docker compose up -d --build`
3. Verify:
   - Frontend: `http://localhost:3000`
   - Backend: `http://localhost:8080/api/status`

## Option C — Render (backend)

This repo includes a Render Blueprint at `render.yaml` (targets branch `official-website`).

1. Push the latest code to GitHub (Render deploys from Git).
2. In Render Dashboard: **New** → **Blueprint**.
3. Select repo `billlza/Skybridge-Compass` and branch `official-website`.
4. Set/confirm env vars:
   - `SKYBRIDGE_WEB_ORIGIN` = your frontend origin (e.g. `https://YOUR_DOMAIN` or your Vercel URL)
5. Apply and monitor deploy logs.

## Runtime verification (recommended)

- Check headers/CSP:
  - `curl -I https://YOUR_DOMAIN/`
  - `curl -I https://YOUR_DOMAIN/auth/callback`
  - Ensure `Content-Security-Policy` exists and contains a `nonce-...`
- Confirm HTML scripts actually have a nonce:
  - `curl -s https://YOUR_DOMAIN/ | grep -Eo 'nonce=\"[^\"]+\"' | head`
- Confirm proxy executes:
  - Ensure responses include `X-Request-ID`
