create or replace function public.assert_service_role_request_v5(
    p_function_name text default null
)
returns void
language plpgsql
set search_path = pg_catalog, public
as $$
declare
    v_request_role text;
    v_request_claims text;
begin
    v_request_role := nullif(current_setting('request.jwt.claim.role', true), '');

    if v_request_role is null then
        v_request_claims := nullif(current_setting('request.jwt.claims', true), '');
        if v_request_claims is not null then
            v_request_role := nullif((v_request_claims::jsonb ->> 'role'), '');
        end if;
    end if;

    if v_request_role = 'service_role' then
        return;
    end if;

    if v_request_role is null and session_user in ('postgres', 'supabase_admin', 'supabase_auth_admin') then
        return;
    end if;

    raise exception using
        errcode = '42501',
        message = 'service_role_required',
        detail = coalesce(p_function_name, 'This function') || ' may only be invoked by service_role or trusted internal callers.';
end;
$$;

create or replace function public.bootstrap_register_device_v5(
    p_tenant_id uuid,
    p_user_id uuid,
    p_device_id text,
    p_protocol_signing_algorithm text,
    p_protocol_public_key_fingerprint text,
    p_device_name text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_existing public.registered_devices%rowtype;
    v_existing_count integer;
begin
    perform public.assert_service_role_request_v5('bootstrap_register_device_v5');

    select *
      into v_existing
      from public.registered_devices
     where tenant_id = p_tenant_id
       and user_id = p_user_id
       and device_id = p_device_id
       and protocol_signing_algorithm = p_protocol_signing_algorithm
       and protocol_public_key_fingerprint = lower(p_protocol_public_key_fingerprint)
     for update;

    if found then
        if v_existing.status = 'revoked' then
            raise exception 'device_revoked';
        end if;

        if v_existing.status = 'frozen' then
            raise exception 'device_frozen';
        end if;

        if v_existing.status <> 'active' then
            update public.registered_devices
               set status = 'active',
                   device_name = coalesce(nullif(p_device_name, ''), device_name),
                   approved_by = coalesce(approved_by, p_user_id),
                   approval_timestamp = coalesce(approval_timestamp, now()),
                   last_seen_at = now()
             where id = v_existing.id
             returning * into v_existing;
        end if;

        return to_jsonb(v_existing);
    end if;

    select count(*)
      into v_existing_count
      from public.registered_devices
     where tenant_id = p_tenant_id
       and user_id = p_user_id
       and status in ('pending', 'active', 'frozen');

    if v_existing_count > 0 then
        raise exception 'bootstrap_activation_not_allowed';
    end if;

    insert into public.registered_devices (
        tenant_id,
        user_id,
        device_id,
        protocol_signing_algorithm,
        protocol_public_key_fingerprint,
        device_name,
        status,
        approved_by,
        approval_timestamp,
        registered_at,
        last_seen_at
    )
    values (
        p_tenant_id,
        p_user_id,
        p_device_id,
        p_protocol_signing_algorithm,
        lower(p_protocol_public_key_fingerprint),
        coalesce(nullif(p_device_name, ''), 'Trusted Device'),
        'active',
        p_user_id,
        now(),
        now(),
        now()
    )
    returning * into v_existing;

    return to_jsonb(v_existing);
end;
$$;

revoke execute on function public.assert_service_role_request_v5(text) from public, anon, authenticated;
revoke execute on function public.bootstrap_register_device_v5(uuid, uuid, text, text, text, text) from public, anon, authenticated;
grant execute on function public.bootstrap_register_device_v5(uuid, uuid, text, text, text, text) to service_role;
