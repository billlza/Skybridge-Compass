-- SkyBridge device presence metadata (v7).
-- Canonical deployment path:
-- supabase/migrations/20260905120000_device_presence_metadata_v7.sql
-- The copy under Server/skybridge-signaling/sql is a byte-for-byte operational
-- mirror; Server tests reject any drift between the two files.
--
-- What this migration does:
--   1) Closes the PostgREST client-role exposure of public.registered_devices.
--      The table never had row level security or client-role revokes, so the
--      shipped anon key could read every tenant's device ids and fingerprints.
--      From v7 the table also stores LAN/public addresses, so the boundary is
--      mandatory. Only service_role (the signaling server) reads or writes the
--      table; every existing RPC is SECURITY DEFINER and is unaffected.
--   2) Adds nullable presence metadata columns (platform, model, OS/app
--      version, last LAN addresses, last server-observed public address,
--      last capabilities, last_presence_at).
--   3) Adds touch_registered_device_presence_v7: a service_role-only RPC that
--      updates the metadata of exactly one ACTIVE row matching the full
--      verified identity (tenant, user, device id, algorithm, fingerprint).
--      It never inserts. It also bumps last_seen_at, whose meaning becomes
--      "last time the signaling server saw this device" (before v7 only
--      bootstrap / enrollment / rotation wrote it and nothing read it).
--
-- Idempotent: safe to re-run.

begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';

-- 1) registry table boundary ---------------------------------------------------

alter table public.registered_devices enable row level security;

revoke all privileges on table public.registered_devices
    from public, anon, authenticated;

grant select, insert, update, delete
    on table public.registered_devices
    to service_role;

grant usage, select on sequence public.registered_devices_id_seq to service_role;

-- 刻意不建任何 policy：service_role 绕过 RLS，其余角色应当一行都读不到。

-- 2) presence metadata columns -----------------------------------------------------

alter table public.registered_devices
    add column if not exists platform text,
    add column if not exists device_model text,
    add column if not exists os_version text,
    add column if not exists app_version text,
    add column if not exists last_lan_addresses text[],
    add column if not exists last_public_address text,
    add column if not exists last_capabilities text[],
    add column if not exists last_presence_at timestamptz;

do $$
begin
    if not exists (
        select 1
          from pg_constraint
         where conname = 'registered_devices_presence_metadata_bounds_v7'
           and conrelid = 'public.registered_devices'::regclass
    ) then
        alter table public.registered_devices
            add constraint registered_devices_presence_metadata_bounds_v7 check (
                (platform is null or (char_length(platform) <= 32 and platform ~ '^[a-z0-9_]+$'))
                and (device_model is null or octet_length(device_model) <= 64)
                and (os_version is null or octet_length(os_version) <= 64)
                and (app_version is null or octet_length(app_version) <= 64)
                and (last_lan_addresses is null or cardinality(last_lan_addresses) <= 8)
                and (last_public_address is null or octet_length(last_public_address) <= 64)
                and (last_capabilities is null or cardinality(last_capabilities) <= 16)
            );
    end if;
end;
$$;

-- 3) touch RPC ---------------------------------------------------------------------

create or replace function public.touch_registered_device_presence_v7(
    p_tenant_id uuid,
    p_user_id uuid,
    p_device_id text,
    p_protocol_signing_algorithm text,
    p_protocol_public_key_fingerprint text,
    p_device_name text default null,
    p_platform text default null,
    p_device_model text default null,
    p_os_version text default null,
    p_app_version text default null,
    p_lan_addresses text[] default null,
    p_public_address text default null,
    p_capabilities text[] default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
    v_rows integer := 0;
    v_now timestamptz := now();
    v_address text;
    v_capability text;
begin
    perform public.assert_service_role_request_v5('touch_registered_device_presence_v7');

    if p_lan_addresses is not null then
        if cardinality(p_lan_addresses) > 8 then
            raise exception 'presence_lan_addresses_too_many';
        end if;
        foreach v_address in array p_lan_addresses loop
            -- raises on anything that is not an IP literal
            perform v_address::inet;
        end loop;
    end if;

    if p_public_address is not null then
        perform p_public_address::inet;
    end if;

    if p_capabilities is not null then
        if cardinality(p_capabilities) > 16 then
            raise exception 'presence_capabilities_too_many';
        end if;
        foreach v_capability in array p_capabilities loop
            if v_capability !~ '^[a-z0-9_]{1,32}$' then
                raise exception 'presence_capability_invalid';
            end if;
        end loop;
    end if;

    update public.registered_devices
       set device_name = coalesce(nullif(p_device_name, ''), device_name),
           platform = p_platform,
           device_model = p_device_model,
           os_version = p_os_version,
           app_version = p_app_version,
           last_lan_addresses = p_lan_addresses,
           last_public_address = p_public_address,
           last_capabilities = p_capabilities,
           last_presence_at = v_now,
           last_seen_at = v_now
     where tenant_id = p_tenant_id
       and user_id = p_user_id
       and device_id = p_device_id
       and protocol_signing_algorithm = p_protocol_signing_algorithm
       and protocol_public_key_fingerprint = lower(p_protocol_public_key_fingerprint)
       and status = 'active';

    get diagnostics v_rows = row_count;

    return jsonb_build_object(
        'updated', v_rows = 1,
        'touched_at', v_now
    );
end;
$$;

revoke execute on function public.touch_registered_device_presence_v7(
    uuid, uuid, text, text, text, text, text, text, text, text, text[], text, text[]
) from public, anon, authenticated;
grant execute on function public.touch_registered_device_presence_v7(
    uuid, uuid, text, text, text, text, text, text, text, text, text[], text, text[]
) to service_role;

-- 4) fail-closed self check --------------------------------------------------------

do $$
declare
    v_signature text := 'public.touch_registered_device_presence_v7(uuid,uuid,text,text,text,text,text,text,text,text,text[],text,text[])';
begin
    if not exists (
        select 1
          from pg_class c
          join pg_namespace n on n.oid = c.relnamespace
         where n.nspname = 'public'
           and c.relname = 'registered_devices'
           and c.relrowsecurity
    ) then
        raise exception 'security_v7_registered_devices_rls_disabled';
    end if;
    if has_table_privilege('anon', 'public.registered_devices', 'SELECT')
       or has_table_privilege('authenticated', 'public.registered_devices', 'SELECT') then
        raise exception 'security_v7_registered_devices_exposed_to_client_roles';
    end if;
    if to_regprocedure(v_signature) is null then
        raise exception 'security_v7_touch_rpc_missing';
    end if;
    if has_function_privilege('anon', v_signature, 'EXECUTE') then
        raise exception 'security_v7_touch_rpc_exposed_to_anon';
    end if;
    if not has_function_privilege('service_role', v_signature, 'EXECUTE') then
        raise exception 'security_v7_touch_rpc_missing_service_role_grant';
    end if;
end;
$$;

commit;
