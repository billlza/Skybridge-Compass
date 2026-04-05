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
