# Avatar B Supabase Rollout

Last updated: 2026-04-05

## Goal

Roll out the avatar B migration without touching the frozen `nebula_id` standard.

Stable rules:

- `nebula_id` remains the only cross-platform business identifier.
- `user_avatars` is the avatar source of truth.
- `universal_users.auth_user_id` is the technical bridge to `auth.users.id`.
- `user_profiles.avatar_url` is the client-facing projection.
- `auth.user_metadata.avatar_url` is best-effort mirror only.

## What this rollout deploys

- SQL migration: [20260405134000_avatar_b2_nebula_frozen.sql](/Users/bill/Desktop/SkyBridge%20Compass%20Pro%20release/supabase/migrations/20260405134000_avatar_b2_nebula_frozen.sql)
- Edge Function: [index.ts](/Users/bill/Desktop/SkyBridge%20Compass%20Pro%20release/supabase/functions/avatar-finalize/index.ts)

Important backend changes:

- creates or repairs the `avatars` bucket
- adds `universal_users.auth_user_id`
- backfills `user_profiles` and `universal_users`
- seeds `user_avatars` from existing avatar projections when needed
- adds `assert_avatar_backend_ready()` hard checks
- hardens `avatar_finalize_upload(...)` so finalize fails if bucket/schema/object checks fail
- adds authenticated select policies for `user_profiles` and legacy `profiles`

## Preflight

Run:

```bash
./Scripts/prepare_supabase_avatar_rollout.sh
```

Expected preflight state before deploy:

- linked project ref is present
- remote migration history does not yet contain `20260405134000`
- local function entrypoint exists at `supabase/functions/avatar-finalize/index.ts`
- remote function `avatar-finalize` may be absent; that is acceptable for first deploy

Network note:

- `supabase db push` may time out against the remote Postgres host on unstable IPv6 routes.
- If that happens, keep VPN enabled and retry with `--dns-resolver https`.

## Deploy order

1. Push the SQL migration first.

```bash
supabase db push --linked --dns-resolver https
```

2. Deploy the Edge Function second.

```bash
supabase functions deploy avatar-finalize --project-ref "$(cat supabase/.temp/project-ref)" --use-api
```

Do not reverse the order. The function depends on the new SQL contract.

## Post-deploy acceptance

Use the SQL checklist in [avatar_post_deploy_acceptance.sql](/Users/bill/Desktop/SkyBridge%20Compass%20Pro%20release/supabase/verification/avatar_post_deploy_acceptance.sql).

Execution order:

1. Before first live upload, capture the baseline `nebula_id` for the test account.
2. Upload a new avatar from macOS.
3. Run the post-upload verification block.
4. Log into iOS with the same account and confirm avatar appears from cloud projection.

The acceptance result is good only if all are true:

- `avatars` bucket exists
- `universal_users.auth_user_id` is populated for the test account
- exactly one `user_avatars` row is active for the test account
- the active `user_avatars.avatar_url` matches `user_profiles.avatar_url`
- `storage.objects` contains the uploaded object under `avatars/<auth_user_id>/...`
- `auth.user_metadata.avatar_url` may succeed or fail, but projection must remain correct
- `nebula_id` is unchanged before and after upload

## Rollback

If deploy partially succeeds:

1. Stop client rollout immediately.
2. If the function deploy introduced bad behavior, redeploy the previous function revision first.
3. Do not attempt destructive schema rollback while live user data is in mixed state.
4. Keep legacy `profiles` fallback in clients until cloud projection is proven stable.

## Not in scope for this rollout

- changing `nebula_id` generation, lookup, or synchronization
- removing legacy `profiles` fallback from all clients
- Android avatar migration
- direct client writes into `user_avatars`
