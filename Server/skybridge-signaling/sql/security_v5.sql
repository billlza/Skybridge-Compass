create table if not exists public.tenant_security_policy (
    tenant_id uuid primary key,
    public_signaling_enabled boolean not null default false,
    allowlist_only boolean not null default false,
    min_supported_client_version text,
    min_supported_protocol_version text,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create table if not exists public.registered_devices (
    id bigint generated always as identity primary key,
    tenant_id uuid not null,
    user_id uuid not null,
    device_id text not null,
    protocol_signing_algorithm text not null,
    protocol_public_key_fingerprint text not null,
    device_name text not null default 'Unknown Device',
    status text not null check (status in ('pending', 'active', 'frozen', 'revoked')),
    approved_by uuid,
    approval_method text check (
        approval_method is null
        or approval_method in (
            'invite_token',
            'trusted_device_confirmation',
            'key_rotation_confirmation',
            'admin_override'
        )
    ),
    approval_timestamp timestamptz,
    registered_at timestamptz not null default now(),
    last_seen_at timestamptz,
    unique (tenant_id, user_id, device_id),
    unique (tenant_id, protocol_signing_algorithm, protocol_public_key_fingerprint)
);

create index if not exists registered_devices_tenant_user_status_idx
    on public.registered_devices (tenant_id, user_id, status);

create table if not exists public.device_enrollment_invites (
    id bigint generated always as identity primary key,
    invite_token_hash text not null unique,
    tenant_id uuid not null,
    target_user_id uuid not null,
    state text not null check (state in ('issued', 'consumed', 'revoked', 'expired')),
    issued_by uuid,
    issued_channel text not null check (issued_channel in ('admin_console', 'email', 'manual')),
    delivered_at timestamptz,
    viewed_at timestamptz,
    consumed_at timestamptz,
    resent_count integer not null default 0,
    revoked_at timestamptz,
    expires_at timestamptz not null,
    created_at timestamptz not null default now()
);

create index if not exists device_enrollment_invites_target_idx
    on public.device_enrollment_invites (tenant_id, target_user_id, state);

create or replace function public.ensure_tenant_security_policy_v5(
    p_tenant_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
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

create or replace function public.sync_tenant_security_policy_for_auth_user_v5()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
    perform public.ensure_tenant_security_policy_v5(new.id);
    return new;
end;
$$;

drop trigger if exists sync_tenant_security_policy_for_auth_user_v5 on auth.users;
create trigger sync_tenant_security_policy_for_auth_user_v5
after insert on auth.users
for each row
execute function public.sync_tenant_security_policy_for_auth_user_v5();

insert into public.tenant_security_policy (
    tenant_id,
    public_signaling_enabled,
    allowlist_only,
    min_supported_client_version,
    min_supported_protocol_version
)
select
    id,
    true,
    false,
    '1.0.0',
    '1'
from auth.users
on conflict (tenant_id) do update
    set public_signaling_enabled = excluded.public_signaling_enabled,
        min_supported_client_version = excluded.min_supported_client_version,
        min_supported_protocol_version = excluded.min_supported_protocol_version,
        updated_at = now();

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
