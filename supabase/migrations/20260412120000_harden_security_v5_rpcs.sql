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

create or replace function public.ensure_tenant_security_policy_v5(
    p_tenant_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
    perform public.assert_service_role_request_v5('ensure_tenant_security_policy_v5');

    insert into public.tenant_security_policy (
        tenant_id,
        public_signaling_enabled,
        allowlist_only,
        min_supported_client_version,
        min_supported_protocol_version
    )
    values (
        p_tenant_id,
        true,
        false,
        '1.0.0',
        '1'
    )
    on conflict (tenant_id) do update
        set public_signaling_enabled = excluded.public_signaling_enabled,
            min_supported_client_version = excluded.min_supported_client_version,
            min_supported_protocol_version = excluded.min_supported_protocol_version,
            updated_at = now();
end;
$$;

create or replace function public.enroll_first_device_v5(
    p_invite_token_hash text,
    p_tenant_id uuid,
    p_target_user_id uuid,
    p_device_id text,
    p_protocol_signing_algorithm text,
    p_protocol_public_key_fingerprint text,
    p_device_name text,
    p_approved_by uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_invite public.device_enrollment_invites%rowtype;
    v_existing_count integer;
    v_result public.registered_devices%rowtype;
begin
    perform public.assert_service_role_request_v5('enroll_first_device_v5');

    select *
      into v_invite
      from public.device_enrollment_invites
     where invite_token_hash = p_invite_token_hash
       and tenant_id = p_tenant_id
       and target_user_id = p_target_user_id
     for update;

    if not found then
        raise exception 'invite_not_found';
    end if;

    if v_invite.state <> 'issued' then
        raise exception 'invite_not_issuable';
    end if;

    if v_invite.expires_at <= now() then
        update public.device_enrollment_invites
           set state = 'expired'
         where id = v_invite.id;
        raise exception 'invite_expired';
    end if;

    select count(*)
      into v_existing_count
      from public.registered_devices
     where tenant_id = p_tenant_id
       and user_id = p_target_user_id
       and status in ('pending', 'active', 'frozen');

    if v_existing_count > 0 then
        raise exception 'first_device_already_exists';
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
        approval_method,
        approval_timestamp,
        registered_at,
        last_seen_at
    )
    values (
        p_tenant_id,
        p_target_user_id,
        p_device_id,
        p_protocol_signing_algorithm,
        lower(p_protocol_public_key_fingerprint),
        coalesce(nullif(p_device_name, ''), 'Trusted Device'),
        'active',
        coalesce(p_approved_by, v_invite.issued_by),
        'invite_token',
        now(),
        now(),
        now()
    )
    returning * into v_result;

    update public.device_enrollment_invites
       set state = 'consumed',
           consumed_at = now()
     where id = v_invite.id;

    return to_jsonb(v_result);
end;
$$;

create or replace function public.confirm_device_enrollment_v5(
    p_tenant_id uuid,
    p_user_id uuid,
    p_approver_device_id text,
    p_approver_protocol_signing_algorithm text,
    p_approver_protocol_public_key_fingerprint text,
    p_pending_device_id text,
    p_pending_protocol_signing_algorithm text,
    p_pending_protocol_public_key_fingerprint text,
    p_device_name text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_approver public.registered_devices%rowtype;
    v_pending public.registered_devices%rowtype;
begin
    perform public.assert_service_role_request_v5('confirm_device_enrollment_v5');

    select *
      into v_approver
      from public.registered_devices
     where tenant_id = p_tenant_id
       and user_id = p_user_id
       and device_id = p_approver_device_id
       and protocol_signing_algorithm = p_approver_protocol_signing_algorithm
       and protocol_public_key_fingerprint = lower(p_approver_protocol_public_key_fingerprint)
       and status = 'active'
     for update;

    if not found then
        raise exception 'approver_not_active';
    end if;

    insert into public.registered_devices (
        tenant_id,
        user_id,
        device_id,
        protocol_signing_algorithm,
        protocol_public_key_fingerprint,
        device_name,
        status,
        registered_at
    )
    values (
        p_tenant_id,
        p_user_id,
        p_pending_device_id,
        p_pending_protocol_signing_algorithm,
        lower(p_pending_protocol_public_key_fingerprint),
        coalesce(nullif(p_device_name, ''), 'Pending Device'),
        'pending',
        now()
    )
    on conflict (tenant_id, protocol_signing_algorithm, protocol_public_key_fingerprint) do nothing;

    select *
      into v_pending
      from public.registered_devices
     where tenant_id = p_tenant_id
       and user_id = p_user_id
       and device_id = p_pending_device_id
       and protocol_signing_algorithm = p_pending_protocol_signing_algorithm
       and protocol_public_key_fingerprint = lower(p_pending_protocol_public_key_fingerprint)
     for update;

    if not found then
        raise exception 'pending_device_not_found';
    end if;

    if v_pending.status = 'revoked' then
        raise exception 'pending_device_revoked';
    end if;

    if v_pending.status = 'frozen' then
        raise exception 'pending_device_frozen';
    end if;

    update public.registered_devices
       set status = 'active',
           device_name = coalesce(nullif(p_device_name, ''), device_name),
           approved_by = p_user_id,
           approval_method = 'trusted_device_confirmation',
           approval_timestamp = now(),
           last_seen_at = now()
     where id = v_pending.id
     returning * into v_pending;

    return to_jsonb(v_pending);
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
revoke execute on function public.ensure_tenant_security_policy_v5(uuid) from public, anon, authenticated;
grant execute on function public.ensure_tenant_security_policy_v5(uuid) to service_role;
revoke execute on function public.enroll_first_device_v5(text, uuid, uuid, text, text, text, text, uuid) from public, anon, authenticated;
grant execute on function public.enroll_first_device_v5(text, uuid, uuid, text, text, text, text, uuid) to service_role;
revoke execute on function public.confirm_device_enrollment_v5(uuid, uuid, text, text, text, text, text, text, text) from public, anon, authenticated;
grant execute on function public.confirm_device_enrollment_v5(uuid, uuid, text, text, text, text, text, text, text) to service_role;
revoke execute on function public.bootstrap_register_device_v5(uuid, uuid, text, text, text, text) from public, anon, authenticated;
grant execute on function public.bootstrap_register_device_v5(uuid, uuid, text, text, text, text) to service_role;
