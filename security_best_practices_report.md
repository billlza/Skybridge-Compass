# Security Best Practices Report

## Executive Summary

This scan covered the Vercel frontend, the Rust backend, the Supabase Edge Functions currently used by the frontend, and a follow-up review of active remote-only Supabase functions in the same project.

As of March 13, 2026, there are no open `P0-P3` findings in the website production chain. The highest-risk live issue found during the follow-up audit was a public, `SECURITY DEFINER` database RPC that allowed anonymous `nebula_id -> email` enumeration; that exposure has been removed and the frontend login flow was migrated to a server-side edge-function path.

Separate from the website production chain, a small set of remote-only Supabase functions still look risky and unattributed to this repo. They are documented below as cross-project follow-up items, not blockers for the website deployment that is now live.

Validation completed:

- `pnpm audit --audit-level=moderate`: no known vulnerabilities
- `pnpm build:prod`: success
- `cargo check`: success
- `supabase functions deploy --use-api`: updated security-related functions deployed, including `nebula-login`
- Supabase Management API SQL review: RLS and function ACLs inspected on March 13, 2026
- `vercel deploy --prod`: production updated

## P0

No open P0 findings.

## P1

No open P1 findings in the website production chain.

## P2

No open P2 findings in the website production chain.

## P3

No open P3 security findings in the website production chain.

## Resolved Items

1. Removed permissive wildcard CORS from the Rust backend and Supabase Edge Functions, replacing it with an explicit allowlist.
2. Removed the production use of the `test-update-user-id` function and deleted the deployed test function from Supabase.
3. Stopped logging raw verification codes and raw contact targets in server-side verification flows.
4. Switched public `nebula_id` generation to stronger random identifiers instead of short, enumerable values.
5. Tightened backend request handling with explicit CORS methods/headers, response security headers, request body limits, and outbound client timeouts.
6. Updated frontend dependencies to remediate React Router and build-chain advisories.
7. Added Vercel SPA rewrites and security headers so deep links no longer 404 and the production site has stricter browser-side protections.
8. Added a new `nebula-login` edge function so frontend `nebula_id` login no longer exposes the backing email mapping to the browser.
9. Revoked public execution on `public.get_email_by_nebula_id(text)` and removed anonymous execution on the security-definer RPCs used for binding status changes.
10. Deleted three remote-only Supabase functions that were high-risk and unused by this repo: `create-admin-user`, `create-test-user`, and `send-contact-notification`.

## Database / RLS Review

- `user_profiles`, `verification_codes`, and `account_bindings` all have `rowsecurity = true`.
- Direct anonymous reads against `user_profiles` returned no rows, while service-role reads confirmed live data exists, which is consistent with RLS being enforced.
- Anonymous insert probes against `verification_codes` and `account_bindings` were rejected with RLS errors.
- The main database issue found was function-level privilege exposure, not a table-level anonymous read/write leak.

## Cross-Project Follow-up

These items are still live in the same Supabase project but were not found to be referenced anywhere under `/Users/bill/Desktop*`. They were not auto-deleted because they may belong to another deployed product surface.

1. `phone-auth`
   Uses wildcard CORS, `Math.random()` for verification code generation, and returns `debug_code` in the response body. This should be either hardened or removed.
2. `upload-apk`
   Uses wildcard CORS and performs service-role-backed APK uploads. If still needed, it should be authenticated and origin-restricted before further use.
3. `scheduled-maintenance`
   Still has `verify_jwt = false` in the deployed function metadata and performs broad maintenance mutations with the service role key. This should be protected by a signed scheduler secret or replaced with a safer job trigger.

## Scope Notes

- The `bind-account-v2` and `unbind-account-v2` Supabase functions delegate verification to database RPC procedures. Those stored procedure bodies were inspected live through the Supabase Management API even though they are not present in this repo.
- Remaining frontend lint warnings are React hook hygiene warnings, not active security findings.
- The remaining large frontend entry chunk is a performance concern, not a security issue.
