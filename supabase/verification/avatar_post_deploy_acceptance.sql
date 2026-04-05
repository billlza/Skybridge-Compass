-- Avatar B post-deploy acceptance checklist
-- Run in the Supabase SQL editor after deploying:
--   1. supabase/migrations/20260405134000_avatar_b2_nebula_frozen.sql
--   2. supabase/functions/avatar-finalize/index.ts
--
-- Replace the placeholder below with the auth.users.id of the real test account.

-- ============================================================================
-- Test account input
-- ============================================================================

with params as (
    select 'REPLACE_AUTH_USER_ID'::uuid as auth_user_id
)
select *
from params;

-- ============================================================================
-- Contract checks
-- ============================================================================

select
    b.id,
    b.public,
    b.file_size_limit,
    b.allowed_mime_types
from storage.buckets b
where b.id = 'avatars';

select
    n.nspname as schema_name,
    c.relname as object_name,
    c.relkind as object_kind
from pg_class c
join pg_namespace n
    on n.oid = c.relnamespace
where (n.nspname, c.relname) in (
    ('public', 'universal_users'),
    ('public', 'user_avatars'),
    ('public', 'user_profiles')
)
order by n.nspname, c.relname;

select
    table_schema,
    table_name,
    column_name,
    data_type,
    is_nullable
from information_schema.columns
where (table_schema, table_name, column_name) in (
    ('public', 'universal_users', 'auth_user_id'),
    ('public', 'user_profiles', 'avatar_url'),
    ('public', 'user_avatars', 'user_id'),
    ('public', 'user_avatars', 'avatar_url'),
    ('public', 'user_avatars', 'is_active')
)
order by table_schema, table_name, column_name;

select
    schemaname,
    tablename,
    indexname,
    indexdef
from pg_indexes
where schemaname = 'public'
  and indexname in (
      'universal_users_auth_user_id_uidx',
      'user_avatars_active_per_user_uidx',
      'user_avatars_user_created_idx'
  )
order by indexname;

select
    schemaname,
    tablename,
    policyname,
    cmd,
    roles
from pg_policies
where (schemaname, tablename, policyname) in (
    ('storage', 'objects', 'avatars_insert_own'),
    ('storage', 'objects', 'avatars_update_own'),
    ('storage', 'objects', 'avatars_delete_own'),
    ('public', 'user_profiles', 'user_profiles_select_own'),
    ('public', 'profiles', 'profiles_select_own')
)
order by schemaname, tablename, policyname;

select
    n.nspname as schema_name,
    p.proname as function_name,
    pg_get_function_identity_arguments(p.oid) as args
from pg_proc p
join pg_namespace n
    on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
      'assert_avatar_backend_ready',
      'ensure_avatar_universal_user',
      'avatar_finalize_upload'
  )
order by p.proname;

-- ============================================================================
-- Baseline before first live upload
-- Capture this output before uploading a new avatar.
-- ============================================================================

with params as (
    select 'REPLACE_AUTH_USER_ID'::uuid as auth_user_id
)
select
    u.id as auth_user_id,
    u.email,
    nullif(u.raw_user_meta_data ->> 'nebula_id', '') as auth_nebula_id,
    nullif(u.raw_user_meta_data ->> 'avatar_url', '') as auth_avatar_url
from auth.users u
join params p
    on p.auth_user_id = u.id;

-- ============================================================================
-- Post-upload verification
-- Run this after uploading a new avatar from macOS.
-- ============================================================================

with params as (
    select 'REPLACE_AUTH_USER_ID'::uuid as auth_user_id
),
resolved_user as (
    select
        uu.id as universal_user_id,
        uu.auth_user_id,
        uu.avatar_url as universal_avatar_url,
        uu.universal_id
    from public.universal_users uu
    join params p
        on p.auth_user_id = uu.auth_user_id
),
active_avatar as (
    select
        ua.*
    from public.user_avatars ua
    join resolved_user ru
        on ru.universal_user_id = ua.user_id
    where ua.is_active
),
active_avatar_count as (
    select count(*)::int as active_count
    from active_avatar
)
select
    u.id as auth_user_id,
    u.email,
    nullif(u.raw_user_meta_data ->> 'nebula_id', '') as auth_nebula_id,
    nullif(u.raw_user_meta_data ->> 'avatar_url', '') as auth_avatar_url,
    ru.universal_user_id,
    ru.universal_id,
    ru.universal_avatar_url,
    up.avatar_url as user_profiles_avatar_url,
    aac.active_count,
    aa.id as active_avatar_id,
    aa.avatar_url as active_avatar_url,
    aa.avatar_type,
    aa.metadata ->> 'storage_path' as active_storage_path,
    case
        when aac.active_count = 1
         and aa.avatar_url is not null
         and aa.avatar_url = up.avatar_url
         and aa.avatar_url = ru.universal_avatar_url
        then 'PASS'
        else 'FAIL'
    end as projection_status
from auth.users u
join params p
    on p.auth_user_id = u.id
left join resolved_user ru
    on ru.auth_user_id = u.id
left join public.user_profiles up
    on up.id = u.id
left join active_avatar aa
    on true
left join active_avatar_count aac
    on true;

-- ============================================================================
-- Inspect all avatar rows for the test account
-- ============================================================================

with params as (
    select 'REPLACE_AUTH_USER_ID'::uuid as auth_user_id
)
select
    ua.id,
    ua.created_at,
    ua.is_active,
    ua.avatar_type,
    ua.avatar_url,
    ua.metadata ->> 'storage_path' as storage_path
from public.user_avatars ua
join public.universal_users uu
    on uu.id = ua.user_id
join params p
    on p.auth_user_id = uu.auth_user_id
order by ua.created_at desc;

-- ============================================================================
-- Verify the backing object exists in storage.objects
-- ============================================================================

with params as (
    select 'REPLACE_AUTH_USER_ID'::uuid as auth_user_id
)
select
    so.bucket_id,
    so.name,
    so.metadata,
    so.created_at,
    so.updated_at
from storage.objects so
join params p
    on so.bucket_id = 'avatars'
   and split_part(so.name, '/', 1) = p.auth_user_id::text
order by so.created_at desc;

-- ============================================================================
-- Final PASS/FAIL summary
-- nebula_id must remain unchanged before and after upload.
-- Compare the value printed here with the baseline query output above.
-- ============================================================================

with params as (
    select 'REPLACE_AUTH_USER_ID'::uuid as auth_user_id
),
resolved_user as (
    select uu.*
    from public.universal_users uu
    join params p
        on p.auth_user_id = uu.auth_user_id
),
active_avatar_count as (
    select count(*)::int as active_count
    from public.user_avatars ua
    join resolved_user ru
        on ru.id = ua.user_id
    where ua.is_active
)
select
    p.auth_user_id,
    nullif(u.raw_user_meta_data ->> 'nebula_id', '') as current_nebula_id,
    up.avatar_url as projected_avatar_url,
    ru.avatar_url as universal_avatar_url,
    aac.active_count,
    case when ru.auth_user_id is not null then 'PASS' else 'FAIL' end as auth_bridge_ready,
    case when aac.active_count = 1 then 'PASS' else 'FAIL' end as single_active_avatar,
    case when up.avatar_url is not null and up.avatar_url = ru.avatar_url then 'PASS' else 'FAIL' end as projection_consistent
from params p
join auth.users u
    on u.id = p.auth_user_id
left join public.user_profiles up
    on up.id = p.auth_user_id
left join resolved_user ru
    on ru.auth_user_id = p.auth_user_id
left join active_avatar_count aac
    on true;
