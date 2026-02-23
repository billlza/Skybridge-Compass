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

## Runtime verification (recommended)

- Check headers/CSP:
  - `curl -I https://YOUR_DOMAIN/`
  - Ensure `Content-Security-Policy` exists and contains a `nonce-...`
- Confirm proxy executes:
  - Ensure responses include `X-Request-ID`

