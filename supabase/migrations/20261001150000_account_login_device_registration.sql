-- Authenticated account login registers an additional device without an existing-device approval.
-- The server opt-in is required. Bootstrap/enrollment/identity-rotation RPCs keep their contracts.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';

alter table public.registered_devices drop constraint registered_devices_approval_method_check;
alter table public.registered_devices add constraint registered_devices_approval_method_check
    check (approval_method is null or approval_method in (
        'invite_token', 'trusted_device_confirmation', 'key_rotation_confirmation',
        'admin_override', 'account_login'
    ));

create or replace function public.register_account_device_v9(
    p_tenant_id uuid, p_user_id uuid, p_device_id text,
    p_protocol_signing_algorithm text, p_protocol_public_key_fingerprint text,
    p_device_name text default null
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare
    v_device public.registered_devices%rowtype;
    v_fingerprint text := lower(p_protocol_public_key_fingerprint);
begin
    perform public.assert_service_role_request_v5('register_account_device_v9');
    if p_tenant_id is null or p_user_id is null or p_device_id is null
       or char_length(p_device_id) not between 16 and 128
       or p_device_id ~ '[[:cntrl:]]'
       or p_protocol_signing_algorithm is null
       or p_protocol_signing_algorithm not in ('Ed25519', 'ML-DSA-65', 'ML-DSA-87')
       or v_fingerprint is null or v_fingerprint !~ '^[a-f0-9]{64}$'
       or (p_device_name is not null and
           (char_length(p_device_name) > 128 or p_device_name ~ '[[:cntrl:]]')) then
        raise exception 'bad_device_binding';
    end if;

    -- Serialize registrations within the tenant, including equal-key races across accounts.
    -- Row locks below also synchronize with existing identity-rotation transactions.
    perform pg_advisory_xact_lock(hashtextextended(p_tenant_id::text || '/account-device-registration', 0));
    select * into v_device from public.registered_devices
     where tenant_id = p_tenant_id and user_id = p_user_id and device_id = p_device_id
     for update;
    if found then
        if v_device.status = 'revoked' then raise exception 'device_revoked'; end if;
        if v_device.status = 'frozen' then raise exception 'device_frozen'; end if;
        if v_device.protocol_signing_algorithm <> p_protocol_signing_algorithm
           or v_device.protocol_public_key_fingerprint <> v_fingerprint then
            raise exception 'current_identity_mismatch';
        end if;
        update public.registered_devices
           set status = 'active', device_name = coalesce(nullif(p_device_name, ''), device_name),
               approved_by = case when status = 'pending' then p_user_id else coalesce(approved_by, p_user_id) end,
               approval_method = case when status = 'pending' then 'account_login' else coalesce(approval_method, 'account_login') end,
               approval_timestamp = case when status = 'pending' then now() else coalesce(approval_timestamp, now()) end,
               last_seen_at = now()
         where id = v_device.id returning * into v_device;
        return to_jsonb(v_device);
    end if;

    -- A retired rotation key and a key owned by another device cannot acquire a new identity.
    if exists (select 1 from public.device_identity_history
               where tenant_id = p_tenant_id and protocol_signing_algorithm = p_protocol_signing_algorithm
                 and protocol_public_key_fingerprint = v_fingerprint) then
        raise exception 'current_identity_mismatch';
    end if;
    if exists (select 1 from public.registered_devices
               where tenant_id = p_tenant_id and protocol_signing_algorithm = p_protocol_signing_algorithm
                 and protocol_public_key_fingerprint = v_fingerprint) then
        raise exception 'new_identity_already_owned';
    end if;

    insert into public.registered_devices (
        tenant_id, user_id, device_id, protocol_signing_algorithm, protocol_public_key_fingerprint,
        device_name, status, approved_by, approval_method, approval_timestamp, registered_at, last_seen_at
    ) values (
        p_tenant_id, p_user_id, p_device_id, p_protocol_signing_algorithm, v_fingerprint,
        coalesce(nullif(p_device_name, ''), 'Account Device'), 'active', p_user_id, 'account_login', now(), now(), now()
    ) returning * into v_device;
    return to_jsonb(v_device);
end;
$$;

revoke all on function public.register_account_device_v9(uuid, uuid, text, text, text, text)
    from public, anon, authenticated;
grant execute on function public.register_account_device_v9(uuid, uuid, text, text, text, text) to service_role;

do $$
begin
    if has_function_privilege('anon', 'public.register_account_device_v9(uuid,uuid,text,text,text,text)', 'EXECUTE')
       or has_function_privilege('authenticated', 'public.register_account_device_v9(uuid,uuid,text,text,text,text)', 'EXECUTE')
       or not has_function_privilege('service_role', 'public.register_account_device_v9(uuid,uuid,text,text,text,text)', 'EXECUTE') then
        raise exception 'account_registration_privilege_boundary_failed';
    end if;
    if not (select relrowsecurity from pg_class where oid = 'public.registered_devices'::regclass) then
        raise exception 'account_registration_registry_rls_disabled';
    end if;
end;
$$;
notify pgrst, 'reload schema';
commit;
