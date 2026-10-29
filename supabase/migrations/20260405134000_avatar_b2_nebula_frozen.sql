begin;

create extension if not exists pgcrypto;

insert into storage.buckets (
    id,
    name,
    public,
    file_size_limit,
    allowed_mime_types
)
values (
    'avatars',
    'avatars',
    true,
    5242880,
    array['image/jpeg', 'image/png', 'image/webp']::text[]
)
on conflict (id) do update
set public = excluded.public,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

alter table public.universal_users
    add column if not exists auth_user_id uuid;

do $$
begin
    if not exists (
        select 1
        from pg_constraint
        where conname = 'universal_users_auth_user_id_fkey'
    ) then
        alter table public.universal_users
            add constraint universal_users_auth_user_id_fkey
            foreign key (auth_user_id)
            references auth.users(id)
            on delete cascade;
    end if;
end $$;

create unique index if not exists universal_users_auth_user_id_uidx
    on public.universal_users(auth_user_id)
    where auth_user_id is not null;

create unique index if not exists user_avatars_active_per_user_uidx
    on public.user_avatars(user_id)
    where is_active;

create index if not exists user_avatars_user_created_idx
    on public.user_avatars(user_id, created_at desc);

do $$
begin
    if not exists (
        select 1
        from pg_policies
        where schemaname = 'storage'
          and tablename = 'objects'
          and policyname = 'avatars_insert_own'
    ) then
        execute $policy$
            create policy avatars_insert_own
            on storage.objects
            for insert
            to authenticated
            with check (
                bucket_id = 'avatars'
                and split_part(name, '/', 1) = auth.uid()::text
            )
        $policy$;
    end if;
end $$;

do $$
begin
    if not exists (
        select 1
        from pg_policies
        where schemaname = 'storage'
          and tablename = 'objects'
          and policyname = 'avatars_update_own'
    ) then
        execute $policy$
            create policy avatars_update_own
            on storage.objects
            for update
            to authenticated
            using (
                bucket_id = 'avatars'
                and split_part(name, '/', 1) = auth.uid()::text
            )
            with check (
                bucket_id = 'avatars'
                and split_part(name, '/', 1) = auth.uid()::text
            )
        $policy$;
    end if;
end $$;

do $$
begin
    if not exists (
        select 1
        from pg_policies
        where schemaname = 'storage'
          and tablename = 'objects'
          and policyname = 'avatars_delete_own'
    ) then
        execute $policy$
            create policy avatars_delete_own
            on storage.objects
            for delete
            to authenticated
            using (
                bucket_id = 'avatars'
                and split_part(name, '/', 1) = auth.uid()::text
            )
        $policy$;
    end if;
end $$;

do $$
begin
    if to_regclass('public.user_profiles') is not null
       and not exists (
           select 1
           from pg_policies
           where schemaname = 'public'
             and tablename = 'user_profiles'
             and policyname = 'user_profiles_select_own'
       ) then
        execute $policy$
            create policy user_profiles_select_own
            on public.user_profiles
            for select
            to authenticated
            using (id = auth.uid())
        $policy$;
    end if;
end $$;

do $$
begin
    if to_regclass('public.profiles') is not null
       and not exists (
           select 1
           from pg_policies
           where schemaname = 'public'
             and tablename = 'profiles'
             and policyname = 'profiles_select_own'
       ) then
        execute $policy$
            create policy profiles_select_own
            on public.profiles
            for select
            to authenticated
            using (id = auth.uid())
        $policy$;
    end if;
end $$;

with unique_auth_users as (
    select
        lower(email) as email_key,
        min(id::text)::uuid as auth_user_id,
        count(*) as auth_count
    from auth.users
    where email is not null
    group by lower(email)
)
update public.universal_users uu
set auth_user_id = ua.auth_user_id
from unique_auth_users ua
where uu.auth_user_id is null
  and uu.primary_email is not null
  and lower(uu.primary_email) = ua.email_key
  and ua.auth_count = 1;

insert into public.user_profiles (
    id,
    email,
    full_name,
    custom_user_id,
    avatar_url,
    created_at,
    updated_at
)
select
    u.id,
    u.email,
    nullif(coalesce(u.raw_user_meta_data ->> 'full_name', u.raw_user_meta_data ->> 'display_name'), ''),
    nullif(u.raw_user_meta_data ->> 'custom_user_id', ''),
    nullif(u.raw_user_meta_data ->> 'avatar_url', ''),
    coalesce(u.created_at, now()),
    now()
from auth.users u
left join public.user_profiles up
    on up.id = u.id
where up.id is null;

insert into public.universal_users (
    universal_id,
    primary_email,
    display_name,
    avatar_url,
    user_type,
    account_status,
    auth_user_id,
    created_at,
    updated_at
)
select
    'auth:' || u.id::text,
    u.email,
    coalesce(
        nullif(u.raw_user_meta_data ->> 'display_name', ''),
        nullif(u.raw_user_meta_data ->> 'full_name', ''),
        u.email,
        '用户'
    ),
    coalesce(
        nullif(up.avatar_url, ''),
        nullif(u.raw_user_meta_data ->> 'avatar_url', '')
    ),
    'standard',
    'active',
    u.id,
    coalesce(u.created_at, now()),
    now()
from auth.users u
left join public.universal_users uu
    on uu.auth_user_id = u.id
left join public.user_profiles up
    on up.id = u.id
where uu.id is null;

with legacy_avatar_sources as (
    select
        uu.id as universal_user_id,
        u.id as auth_user_id,
        coalesce(
            nullif(up.avatar_url, ''),
            nullif(u.raw_user_meta_data ->> 'avatar_url', ''),
            nullif(p.avatar_url, '')
        ) as avatar_url,
        case
            when nullif(up.avatar_url, '') is not null then 'user_profiles'
            when nullif(u.raw_user_meta_data ->> 'avatar_url', '') is not null then 'auth_metadata'
            when nullif(p.avatar_url, '') is not null then 'profiles'
            else null
        end as backfill_source
    from auth.users u
    join public.universal_users uu
        on uu.auth_user_id = u.id
    left join public.user_profiles up
        on up.id = u.id
    left join public.profiles p
        on p.id = u.id
),
eligible_legacy_avatars as (
    select *
    from legacy_avatar_sources las
    where las.avatar_url is not null
      and not exists (
          select 1
          from public.user_avatars ua
          where ua.user_id = las.universal_user_id
            and ua.is_active
      )
)
insert into public.user_avatars (
    user_id,
    avatar_url,
    avatar_type,
    file_name,
    mime_type,
    is_active,
    is_approved,
    metadata
)
select
    ela.universal_user_id,
    ela.avatar_url,
    case
        when ela.avatar_url like '%/storage/v1/object/public/avatars/%' then 'migration'
        else 'external_migration'
    end,
    regexp_replace(ela.avatar_url, '^.*/', ''),
    null,
    true,
    true,
    jsonb_build_object(
        'backfill_source', ela.backfill_source,
        'auth_user_id', ela.auth_user_id
    )
from eligible_legacy_avatars ela;

update public.user_profiles up
set avatar_url = ua.avatar_url,
    updated_at = now()
from public.universal_users uu
join public.user_avatars ua
    on ua.user_id = uu.id
   and ua.is_active
where up.id = uu.auth_user_id
  and up.avatar_url is distinct from ua.avatar_url;

update public.universal_users uu
set avatar_url = ua.avatar_url,
    updated_at = now()
from public.user_avatars ua
where ua.user_id = uu.id
  and ua.is_active
  and uu.avatar_url is distinct from ua.avatar_url;

create or replace function public.assert_avatar_backend_ready()
returns void
language plpgsql
security definer
set search_path = public, auth
as $$
begin
    if to_regclass('public.universal_users') is null then
        raise exception 'avatar backend misconfigured: public.universal_users is missing';
    end if;

    if to_regclass('public.user_avatars') is null then
        raise exception 'avatar backend misconfigured: public.user_avatars is missing';
    end if;

    if to_regclass('public.user_profiles') is null then
        raise exception 'avatar backend misconfigured: public.user_profiles is missing';
    end if;

    if not exists (
        select 1
        from information_schema.columns
        where table_schema = 'public'
          and table_name = 'universal_users'
          and column_name = 'auth_user_id'
    ) then
        raise exception 'avatar backend misconfigured: public.universal_users.auth_user_id is missing';
    end if;

    if not exists (
        select 1
        from information_schema.columns
        where table_schema = 'public'
          and table_name = 'user_profiles'
          and column_name = 'avatar_url'
    ) then
        raise exception 'avatar backend misconfigured: public.user_profiles.avatar_url is missing';
    end if;

    if not exists (
        select 1
        from information_schema.columns
        where table_schema = 'public'
          and table_name = 'user_avatars'
          and column_name in ('user_id', 'avatar_url', 'is_active')
        group by table_schema, table_name
        having count(*) = 3
    ) then
        raise exception 'avatar backend misconfigured: public.user_avatars is missing required columns';
    end if;

    if not exists (
        select 1
        from storage.buckets
        where id = 'avatars'
    ) then
        raise exception 'avatar backend misconfigured: storage bucket avatars is missing';
    end if;
end;
$$;

create or replace function public.ensure_avatar_universal_user(
    p_auth_user_id uuid
) returns uuid
language plpgsql
security definer
set search_path = public, auth
as $$
declare
    v_universal_user_id uuid;
begin
    if p_auth_user_id is null then
        raise exception 'auth user id is required';
    end if;

    select uu.id
      into v_universal_user_id
      from public.universal_users uu
     where uu.auth_user_id = p_auth_user_id
     limit 1;

    if v_universal_user_id is not null then
        return v_universal_user_id;
    end if;

    insert into public.universal_users (
        universal_id,
        primary_email,
        display_name,
        avatar_url,
        user_type,
        account_status,
        auth_user_id,
        created_at,
        updated_at
    )
    select
        'auth:' || u.id::text,
        u.email,
        coalesce(
            nullif(u.raw_user_meta_data ->> 'display_name', ''),
            nullif(u.raw_user_meta_data ->> 'full_name', ''),
            u.email,
            '用户'
        ),
        up.avatar_url,
        'standard',
        'active',
        u.id,
        coalesce(u.created_at, now()),
        now()
    from auth.users u
    left join public.user_profiles up
        on up.id = u.id
    where u.id = p_auth_user_id
    on conflict (auth_user_id) do update
        set primary_email = coalesce(public.universal_users.primary_email, excluded.primary_email),
            display_name = coalesce(public.universal_users.display_name, excluded.display_name),
            avatar_url = coalesce(public.universal_users.avatar_url, excluded.avatar_url),
            updated_at = now()
    returning id into v_universal_user_id;

    if v_universal_user_id is null then
        select uu.id
          into v_universal_user_id
          from public.universal_users uu
         where uu.auth_user_id = p_auth_user_id
         limit 1;
    end if;

    if v_universal_user_id is null then
        raise exception 'failed to resolve universal_users row for auth user %', p_auth_user_id;
    end if;

    return v_universal_user_id;
end;
$$;

create or replace function public.avatar_finalize_upload(
    p_storage_path text,
    p_avatar_url text,
    p_mime_type text default null,
    p_file_size bigint default null,
    p_width integer default null,
    p_height integer default null,
    p_crop_data jsonb default null,
    p_avatar_type text default 'upload'
) returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
    v_auth_user_id uuid := auth.uid();
    v_universal_user_id uuid;
    v_avatar_id uuid;
    v_expected_avatar_suffix text;
begin
    perform public.assert_avatar_backend_ready();

    if v_auth_user_id is null then
        raise exception 'avatar finalize requires an authenticated user';
    end if;

    if p_storage_path is null or btrim(p_storage_path) = '' then
        raise exception 'storage_path is required';
    end if;

    if split_part(p_storage_path, '/', 1) <> v_auth_user_id::text then
        raise exception 'storage_path must begin with the authenticated user id';
    end if;

    if p_avatar_url is null or btrim(p_avatar_url) = '' then
        raise exception 'avatar_url is required';
    end if;

    v_expected_avatar_suffix := '/storage/v1/object/public/avatars/' || p_storage_path;
    if right(p_avatar_url, length(v_expected_avatar_suffix)) <> v_expected_avatar_suffix then
        raise exception 'avatar_url must resolve to avatars/%', p_storage_path;
    end if;

    if not exists (
        select 1
        from storage.objects so
        where so.bucket_id = 'avatars'
          and so.name = p_storage_path
    ) then
        raise exception 'uploaded avatar object does not exist at avatars/%', p_storage_path;
    end if;

    v_universal_user_id := public.ensure_avatar_universal_user(v_auth_user_id);

    insert into public.user_profiles (
        id,
        email,
        full_name,
        custom_user_id,
        avatar_url,
        created_at,
        updated_at
    )
    select
        u.id,
        u.email,
        nullif(coalesce(u.raw_user_meta_data ->> 'full_name', u.raw_user_meta_data ->> 'display_name'), ''),
        nullif(u.raw_user_meta_data ->> 'custom_user_id', ''),
        p_avatar_url,
        coalesce(u.created_at, now()),
        now()
    from auth.users u
    where u.id = v_auth_user_id
    on conflict (id) do update
        set avatar_url = excluded.avatar_url,
            updated_at = now();

    update public.user_avatars
       set is_active = false
     where user_id = v_universal_user_id
       and is_active = true;

    insert into public.user_avatars (
        user_id,
        avatar_url,
        avatar_type,
        file_name,
        file_size,
        mime_type,
        width,
        height,
        crop_data,
        is_active,
        is_approved,
        metadata
    ) values (
        v_universal_user_id,
        p_avatar_url,
        coalesce(nullif(p_avatar_type, ''), 'upload'),
        regexp_replace(p_storage_path, '^.*/', ''),
        p_file_size,
        p_mime_type,
        p_width,
        p_height,
        p_crop_data,
        true,
        true,
        jsonb_build_object(
            'storage_path', p_storage_path,
            'auth_user_id', v_auth_user_id
        )
    )
    returning id into v_avatar_id;

    update public.universal_users
       set avatar_url = p_avatar_url,
           updated_at = now()
     where id = v_universal_user_id;

    return jsonb_build_object(
        'avatar_id', v_avatar_id,
        'avatar_url', p_avatar_url,
        'storage_path', p_storage_path,
        'universal_user_id', v_universal_user_id,
        'auth_user_id', v_auth_user_id,
        'is_active', true,
        'projection_status', 'projected'
    );
end;
$$;

grant execute on function public.assert_avatar_backend_ready() to authenticated;
grant execute on function public.ensure_avatar_universal_user(uuid) to authenticated;
grant execute on function public.avatar_finalize_upload(text, text, text, bigint, integer, integer, jsonb, text) to authenticated;

do $$
begin
    if not exists (
        select 1
        from public.universal_users
        where auth_user_id is null
    ) then
        alter table public.universal_users
            alter column auth_user_id set not null;
    else
        raise notice 'universal_users.auth_user_id still has null rows; leaving column nullable until data is reconciled';
    end if;
end $$;

commit;
