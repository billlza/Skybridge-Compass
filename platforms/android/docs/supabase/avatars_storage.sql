-- SkyBridge Compass: Supabase Storage policies for cross-platform avatar visibility
--
-- Symptom:
-- - macOS uploads avatar successfully, but iOS/Android can't see it.
--
-- Root cause (most common):
-- - `avatars` bucket is NOT public, or Storage RLS has no SELECT policy.
-- - Pro release constructs a public URL:
--     /storage/v1/object/public/avatars/{userId}.jpg
--   and iOS/macOS fetch it WITHOUT auth headers, so it must be publicly readable.

-- 1) Ensure bucket exists and is public
insert into storage.buckets (id, name, public)
values ('avatars', 'avatars', true)
on conflict (id) do update set public = true;

-- 2) Public read policy for avatars
-- NOTE: If you don't want public read, you must switch clients to signed URLs or authenticated fetch.
drop policy if exists "avatars_public_read" on storage.objects;
create policy "avatars_public_read"
on storage.objects
for select
to public
using (bucket_id = 'avatars');

-- 3) Allow authenticated users to upload/overwrite ONLY their own avatar file
-- Matches Pro release naming: {userId}.jpg
drop policy if exists "avatars_user_write_own" on storage.objects;
create policy "avatars_user_write_own"
on storage.objects
for all
to authenticated
using (
  bucket_id = 'avatars'
  and name = (auth.uid()::text || '.jpg')
)
with check (
  bucket_id = 'avatars'
  and name = (auth.uid()::text || '.jpg')
);


