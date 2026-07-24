-- SkyBridge device protocol-identity rotation.
-- Canonical deployment path:
-- supabase/migrations/20260722041138_device_identity_rotation_v6.sql
-- The copy under Server/skybridge-signaling/sql is a byte-for-byte operational
-- mirror; Server tests reject any drift between the two files.
-- Apply only after the canonical v5 migration chain (or standalone
-- security_v5.sql). This migration deliberately does not change bootstrap
-- registration semantics: a rotation starts from an exact, active v5
-- registered-device binding and commits through one atomic RPC.

begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';

alter table public.registered_devices
    add column if not exists identity_generation bigint not null default 1
        check (identity_generation > 0);

alter table public.registered_devices
    add column if not exists protocol_public_key_base64 text;

create or replace function public.is_valid_protocol_identity_key_v6(
    p_algorithm text,
    p_public_key_base64 text
)
returns boolean
language sql
immutable
set search_path = pg_catalog
as $$
    select case p_algorithm
        when 'Ed25519' then
            length(p_public_key_base64) = 44
            and p_public_key_base64 ~ '^([A-Za-z0-9+/]{4}){10}[A-Za-z0-9+/]{3}=$'
        when 'ML-DSA-65' then
            length(p_public_key_base64) = 2604
            and p_public_key_base64 ~ '^([A-Za-z0-9+/]{4}){650}[A-Za-z0-9+/]{3}=$'
        when 'ML-DSA-87' then
            length(p_public_key_base64) = 3456
            and p_public_key_base64 ~ '^([A-Za-z0-9+/]{4}){864}$'
        else false
    end;
$$;

create table if not exists public.device_identity_rotations (
    rotation_id uuid primary key,
    request_id uuid not null,
    tenant_id uuid not null,
    user_id uuid not null,
    device_id text not null,
    old_generation bigint not null check (old_generation > 0),
    old_protocol_signing_algorithm text not null
        check (old_protocol_signing_algorithm in ('Ed25519', 'ML-DSA-65', 'ML-DSA-87')),
    old_protocol_public_key_fingerprint text not null
        check (old_protocol_public_key_fingerprint ~ '^[0-9a-f]{64}$'),
    old_protocol_public_key_base64 text not null,
    new_protocol_signing_algorithm text not null
        check (new_protocol_signing_algorithm in ('Ed25519', 'ML-DSA-65', 'ML-DSA-87')),
    new_protocol_public_key_fingerprint text not null
        check (new_protocol_public_key_fingerprint ~ '^[0-9a-f]{64}$'),
    new_protocol_public_key_base64 text not null,
    nonce text not null check (nonce ~ '^[A-Za-z0-9_-]{43}$'),
    transcript_hash text not null check (transcript_hash ~ '^[0-9a-f]{64}$'),
    state text not null check (state in ('issued', 'committed', 'expired', 'cancelled')),
    issued_at timestamptz not null,
    expires_at timestamptz not null,
    committed_at timestamptz,
    committed_generation bigint check (committed_generation is null or committed_generation > 0),
    grace_expires_at timestamptz,
    result jsonb,
    check (expires_at > issued_at),
    check (public.is_valid_protocol_identity_key_v6(
        old_protocol_signing_algorithm,
        old_protocol_public_key_base64
    )),
    check (public.is_valid_protocol_identity_key_v6(
        new_protocol_signing_algorithm,
        new_protocol_public_key_base64
    ))
);

create unique index if not exists device_identity_rotations_request_id_idx
    on public.device_identity_rotations (tenant_id, user_id, device_id, request_id);

create unique index if not exists device_identity_rotations_one_issued_per_device_idx
    on public.device_identity_rotations (tenant_id, user_id, device_id)
    where state = 'issued';

create unique index if not exists device_identity_rotations_one_issued_per_new_key_idx
    on public.device_identity_rotations (
        tenant_id,
        new_protocol_signing_algorithm,
        new_protocol_public_key_fingerprint
    ) where state = 'issued';

create index if not exists device_identity_rotations_new_key_idx
    on public.device_identity_rotations (
        tenant_id,
        new_protocol_signing_algorithm,
        new_protocol_public_key_fingerprint,
        state
    );

create index if not exists device_identity_rotations_device_issued_at_idx
    on public.device_identity_rotations (tenant_id, user_id, device_id, issued_at desc);

create index if not exists device_identity_rotations_user_issued_at_idx
    on public.device_identity_rotations (tenant_id, user_id, issued_at desc);

create table if not exists public.device_identity_history (
    id bigint generated always as identity primary key,
    tenant_id uuid not null,
    user_id uuid not null,
    device_id text not null,
    generation bigint not null check (generation > 0),
    protocol_signing_algorithm text not null
        check (protocol_signing_algorithm in ('Ed25519', 'ML-DSA-65', 'ML-DSA-87')),
    protocol_public_key_fingerprint text not null
        check (protocol_public_key_fingerprint ~ '^[0-9a-f]{64}$'),
    protocol_public_key_base64 text not null,
    state text not null check (state in ('active', 'grace', 'revoked')),
    activated_at timestamptz not null,
    grace_started_at timestamptz,
    grace_expires_at timestamptz,
    revoked_at timestamptz,
    source_rotation_id uuid references public.device_identity_rotations(rotation_id),
    created_at timestamptz not null default now(),
    unique (tenant_id, user_id, device_id, generation),
    unique (tenant_id, protocol_signing_algorithm, protocol_public_key_fingerprint),
    check (public.is_valid_protocol_identity_key_v6(
        protocol_signing_algorithm,
        protocol_public_key_base64
    )),
    check (
        (state = 'active' and grace_started_at is null and grace_expires_at is null and revoked_at is null)
        or (state = 'grace' and grace_started_at is not null and grace_expires_at is not null and revoked_at is null)
        or (state = 'revoked' and revoked_at is not null)
    )
);

-- "grace" is retention/audit metadata for already-issued, authority-frozen
-- sessions. Admission never reads this table and only the registered_devices
-- active binding may obtain a new admission or session authority.
create unique index if not exists device_identity_history_one_active_per_device_idx
    on public.device_identity_history (tenant_id, user_id, device_id)
    where state = 'active';

create index if not exists device_identity_history_device_generation_idx
    on public.device_identity_history (tenant_id, user_id, device_id, generation desc);

create table if not exists public.device_identity_rotation_audit (
    id bigint generated always as identity primary key,
    rotation_id uuid not null references public.device_identity_rotations(rotation_id),
    tenant_id uuid not null,
    user_id uuid not null,
    device_id text not null,
    event_type text not null check (event_type in ('challenged', 'committed', 'expired', 'cancelled')),
    transcript_hash text not null check (transcript_hash ~ '^[0-9a-f]{64}$'),
    details jsonb not null default '{}'::jsonb,
    occurred_at timestamptz not null default now(),
    unique (rotation_id, event_type)
);

create or replace function public.reject_device_identity_rotation_audit_mutation_v6()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
begin
    raise exception 'identity_rotation_audit_is_immutable';
end;
$$;

drop trigger if exists device_identity_rotation_audit_immutable_v6
    on public.device_identity_rotation_audit;
create trigger device_identity_rotation_audit_immutable_v6
    before update or delete on public.device_identity_rotation_audit
    for each row execute function public.reject_device_identity_rotation_audit_mutation_v6();

alter table public.device_identity_rotations enable row level security;
alter table public.device_identity_history enable row level security;
alter table public.device_identity_rotation_audit enable row level security;

revoke all on table public.device_identity_rotations from public, anon, authenticated;
revoke all on table public.device_identity_history from public, anon, authenticated;
revoke all on table public.device_identity_rotation_audit from public, anon, authenticated;
grant select, insert, update on table public.device_identity_rotations to service_role;
grant select, insert, update on table public.device_identity_history to service_role;
grant select, insert on table public.device_identity_rotation_audit to service_role;
grant usage, select on sequence public.device_identity_history_id_seq to service_role;
grant usage, select on sequence public.device_identity_rotation_audit_id_seq to service_role;

create or replace function public.issue_device_identity_rotation_v6(
    p_request_id uuid,
    p_rotation_id uuid,
    p_tenant_id uuid,
    p_user_id uuid,
    p_device_id text,
    p_old_generation bigint,
    p_old_protocol_signing_algorithm text,
    p_old_protocol_public_key_fingerprint text,
    p_old_protocol_public_key_base64 text,
    p_new_protocol_signing_algorithm text,
    p_new_protocol_public_key_fingerprint text,
    p_new_protocol_public_key_base64 text,
    p_nonce text,
    p_transcript_hash text,
    p_expires_at timestamptz
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_now timestamptz := clock_timestamp();
    v_device public.registered_devices%rowtype;
    v_active_history public.device_identity_history%rowtype;
    v_pending public.device_identity_rotations%rowtype;
    v_request public.device_identity_rotations%rowtype;
begin
    perform public.assert_service_role_request_v5('issue_device_identity_rotation_v6');

    if p_device_id is null or p_device_id !~ '^[A-Za-z0-9._:-]{16,128}$' then
        raise exception 'invalid_rotation_device_id';
    end if;
    if p_old_generation is null or p_old_generation <= 0 then
        raise exception 'invalid_rotation_generation';
    end if;
    if p_old_protocol_public_key_fingerprint !~ '^[0-9a-f]{64}$'
       or p_new_protocol_public_key_fingerprint !~ '^[0-9a-f]{64}$'
       or p_transcript_hash !~ '^[0-9a-f]{64}$'
       or p_nonce !~ '^[A-Za-z0-9_-]{43}$'
       or not public.is_valid_protocol_identity_key_v6(
            p_old_protocol_signing_algorithm,
            p_old_protocol_public_key_base64
       )
       or not public.is_valid_protocol_identity_key_v6(
            p_new_protocol_signing_algorithm,
            p_new_protocol_public_key_base64
       ) then
        raise exception 'invalid_rotation_payload';
    end if;
    if p_expires_at <= v_now or p_expires_at > v_now + interval '10 minutes' then
        raise exception 'invalid_rotation_expiry';
    end if;
    if p_old_protocol_signing_algorithm = p_new_protocol_signing_algorithm
       and p_old_protocol_public_key_fingerprint = p_new_protocol_public_key_fingerprint then
        raise exception 'identity_unchanged';
    end if;

    -- Every issue/commit operation takes the per-device lock first. Keeping a
    -- common lock order prevents a challenge retry (device then rotation rows)
    -- from deadlocking with commit (rotation then device rows).
    perform pg_catalog.pg_advisory_xact_lock(
        pg_catalog.hashtextextended(
            p_tenant_id::text || ':' || p_user_id::text || ':' || p_device_id,
            6001
        )
    );

    -- Serialize ownership decisions for a candidate key across devices. The
    -- partial unique index is the final constraint; this lock keeps the RPC's
    -- public error deterministic instead of surfacing a raw unique violation.
    perform pg_catalog.pg_advisory_xact_lock(
        pg_catalog.hashtextextended(
            p_tenant_id::text || ':' || p_new_protocol_signing_algorithm || ':' ||
            p_new_protocol_public_key_fingerprint,
            6002
        )
    );

    -- A partial unique index cannot distinguish elapsed rows until their state
    -- changes. Retire every elapsed issued claim for this candidate while the
    -- candidate advisory lock is held, including claims from other devices.
    with expired_candidate as (
        update public.device_identity_rotations
           set state = 'expired'
         where tenant_id = p_tenant_id
           and new_protocol_signing_algorithm = p_new_protocol_signing_algorithm
           and new_protocol_public_key_fingerprint = p_new_protocol_public_key_fingerprint
           and state = 'issued'
           and expires_at <= v_now
        returning rotation_id, tenant_id, user_id, device_id, transcript_hash
    )
    insert into public.device_identity_rotation_audit (
        rotation_id, tenant_id, user_id, device_id, event_type,
        transcript_hash, details, occurred_at
    )
    select
        rotation_id, tenant_id, user_id, device_id, 'expired',
        transcript_hash, jsonb_build_object('reason', 'candidate_claim_expired'), v_now
      from expired_candidate
    on conflict (rotation_id, event_type) do nothing;

    select *
      into v_device
      from public.registered_devices
     where tenant_id = p_tenant_id
       and user_id = p_user_id
       and device_id = p_device_id
     for update;

    if not found then
        raise exception 'device_not_registered';
    end if;
    if v_device.status = 'revoked' then
        raise exception 'device_revoked';
    end if;
    if v_device.status = 'frozen' then
        raise exception 'device_frozen';
    end if;
    if v_device.status <> 'active' then
        raise exception 'device_not_active';
    end if;
    if v_device.identity_generation <> p_old_generation then
        raise exception 'identity_generation_conflict';
    end if;
    if v_device.protocol_signing_algorithm <> p_old_protocol_signing_algorithm
       or v_device.protocol_public_key_fingerprint <> p_old_protocol_public_key_fingerprint then
        raise exception 'current_identity_mismatch';
    end if;
    if v_device.protocol_public_key_base64 is not null
       and v_device.protocol_public_key_base64 <> p_old_protocol_public_key_base64 then
        raise exception 'old_public_key_conflict';
    end if;

    select *
      into v_request
      from public.device_identity_rotations
     where tenant_id = p_tenant_id
       and user_id = p_user_id
       and device_id = p_device_id
       and request_id = p_request_id
     for update;

    if found then
        if v_request.old_generation <> p_old_generation
           or v_request.old_protocol_signing_algorithm <> p_old_protocol_signing_algorithm
           or v_request.old_protocol_public_key_fingerprint <> p_old_protocol_public_key_fingerprint
           or v_request.old_protocol_public_key_base64 <> p_old_protocol_public_key_base64
           or v_request.new_protocol_signing_algorithm <> p_new_protocol_signing_algorithm
           or v_request.new_protocol_public_key_fingerprint <> p_new_protocol_public_key_fingerprint
           or v_request.new_protocol_public_key_base64 <> p_new_protocol_public_key_base64 then
            raise exception 'rotation_payload_conflict';
        end if;
        if v_request.state = 'expired' or v_request.expires_at <= v_now then
            raise exception 'rotation_expired';
        end if;
        if v_request.state <> 'issued' then
            raise exception 'rotation_state_conflict';
        end if;
        return to_jsonb(v_request);
    end if;

    if (
        select count(*)
          from public.device_identity_rotations
         where tenant_id = p_tenant_id
           and user_id = p_user_id
           and device_id = p_device_id
           and issued_at > v_now - interval '24 hours'
    ) >= 8 then
        raise exception 'identity_rotation_device_daily_limited';
    end if;
    if (
        select count(*)
          from public.device_identity_rotations
         where tenant_id = p_tenant_id
           and user_id = p_user_id
           and issued_at > v_now - interval '24 hours'
    ) >= 64 then
        raise exception 'identity_rotation_user_daily_limited';
    end if;

    select *
      into v_pending
      from public.device_identity_rotations
     where tenant_id = p_tenant_id
       and user_id = p_user_id
       and device_id = p_device_id
       and state = 'issued'
     for update;

    if found and v_pending.expires_at > v_now then
        raise exception 'identity_rotation_already_pending';
    end if;
    if found then
        update public.device_identity_rotations
           set state = 'expired'
         where rotation_id = v_pending.rotation_id;
        insert into public.device_identity_rotation_audit (
            rotation_id, tenant_id, user_id, device_id, event_type,
            transcript_hash, details, occurred_at
        ) values (
            v_pending.rotation_id, v_pending.tenant_id, v_pending.user_id,
            v_pending.device_id, 'expired', v_pending.transcript_hash,
            jsonb_build_object('reason', 'challenge_expired'), v_now
        ) on conflict (rotation_id, event_type) do nothing;
    end if;

    if exists (
        select 1
          from public.registered_devices
         where tenant_id = p_tenant_id
           and protocol_signing_algorithm = p_new_protocol_signing_algorithm
           and protocol_public_key_fingerprint = p_new_protocol_public_key_fingerprint
    ) or exists (
        select 1
          from public.device_identity_history
         where tenant_id = p_tenant_id
           and protocol_signing_algorithm = p_new_protocol_signing_algorithm
           and protocol_public_key_fingerprint = p_new_protocol_public_key_fingerprint
    ) or exists (
        select 1
          from public.device_identity_rotations
         where tenant_id = p_tenant_id
           and new_protocol_signing_algorithm = p_new_protocol_signing_algorithm
           and new_protocol_public_key_fingerprint = p_new_protocol_public_key_fingerprint
           and state = 'issued'
           and expires_at > v_now
    ) then
        raise exception 'new_identity_already_owned';
    end if;

    select *
      into v_active_history
      from public.device_identity_history
     where tenant_id = p_tenant_id
       and user_id = p_user_id
       and device_id = p_device_id
       and state = 'active'
     for update;

    if found then
        if v_active_history.generation <> p_old_generation
           or v_active_history.protocol_signing_algorithm <> p_old_protocol_signing_algorithm
           or v_active_history.protocol_public_key_fingerprint <> p_old_protocol_public_key_fingerprint then
            raise exception 'identity_history_inconsistent';
        end if;
        if v_active_history.protocol_public_key_base64 <> p_old_protocol_public_key_base64 then
            raise exception 'old_public_key_conflict';
        end if;
    else
        if exists (
            select 1
              from public.device_identity_history
             where tenant_id = p_tenant_id
               and user_id = p_user_id
               and device_id = p_device_id
        ) then
            raise exception 'identity_history_inconsistent';
        end if;
        insert into public.device_identity_history (
            tenant_id, user_id, device_id, generation,
            protocol_signing_algorithm, protocol_public_key_fingerprint,
            protocol_public_key_base64, state, activated_at
        ) values (
            p_tenant_id, p_user_id, p_device_id, p_old_generation,
            p_old_protocol_signing_algorithm, p_old_protocol_public_key_fingerprint,
            p_old_protocol_public_key_base64, 'active', v_now
        );
    end if;

    update public.registered_devices
       set protocol_public_key_base64 = coalesce(
           protocol_public_key_base64,
           p_old_protocol_public_key_base64
       )
     where id = v_device.id;

    insert into public.device_identity_rotations (
        rotation_id, request_id, tenant_id, user_id, device_id, old_generation,
        old_protocol_signing_algorithm, old_protocol_public_key_fingerprint,
        old_protocol_public_key_base64, new_protocol_signing_algorithm,
        new_protocol_public_key_fingerprint, new_protocol_public_key_base64,
        nonce, transcript_hash, state, issued_at, expires_at
    ) values (
        p_rotation_id, p_request_id, p_tenant_id, p_user_id, p_device_id, p_old_generation,
        p_old_protocol_signing_algorithm, p_old_protocol_public_key_fingerprint,
        p_old_protocol_public_key_base64, p_new_protocol_signing_algorithm,
        p_new_protocol_public_key_fingerprint, p_new_protocol_public_key_base64,
        p_nonce, p_transcript_hash, 'issued', v_now, p_expires_at
    );

    insert into public.device_identity_rotation_audit (
        rotation_id, tenant_id, user_id, device_id, event_type,
        transcript_hash, details, occurred_at
    ) values (
        p_rotation_id, p_tenant_id, p_user_id, p_device_id, 'challenged',
        p_transcript_hash,
        jsonb_build_object(
            'oldGeneration', p_old_generation,
            'oldFingerprint', p_old_protocol_public_key_fingerprint,
            'newFingerprint', p_new_protocol_public_key_fingerprint
        ),
        v_now
    );

    select *
      into v_request
      from public.device_identity_rotations
     where rotation_id = p_rotation_id;
    return to_jsonb(v_request);
end;
$$;

create or replace function public.expire_device_identity_grace_v6(
    p_limit integer default 1000
)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_updated integer;
begin
    perform public.assert_service_role_request_v5('expire_device_identity_grace_v6');
    if p_limit is null or p_limit < 1 or p_limit > 10000 then
        raise exception 'invalid_identity_grace_expiry_limit';
    end if;

    with expired as (
        select id
          from public.device_identity_history
         where state = 'grace'
           and grace_expires_at <= clock_timestamp()
         order by grace_expires_at, id
         for update skip locked
         limit p_limit
    )
    update public.device_identity_history as history
       set state = 'revoked',
           revoked_at = clock_timestamp()
      from expired
     where history.id = expired.id;
    get diagnostics v_updated = row_count;
    return v_updated;
end;
$$;

create or replace function public.commit_device_identity_rotation_v6(
    p_rotation_id uuid,
    p_tenant_id uuid,
    p_user_id uuid,
    p_device_id text,
    p_old_generation bigint,
    p_old_protocol_signing_algorithm text,
    p_old_protocol_public_key_fingerprint text,
    p_transcript_hash text,
    p_grace_expires_at timestamptz
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_now timestamptz := clock_timestamp();
    v_rotation public.device_identity_rotations%rowtype;
    v_device public.registered_devices%rowtype;
    v_old_history public.device_identity_history%rowtype;
    v_new_generation bigint;
    v_result jsonb;
    v_rows integer;
begin
    perform public.assert_service_role_request_v5('commit_device_identity_rotation_v6');

    perform pg_catalog.pg_advisory_xact_lock(
        pg_catalog.hashtextextended(
            p_tenant_id::text || ':' || p_user_id::text || ':' || p_device_id,
            6001
        )
    );

    select *
      into v_rotation
      from public.device_identity_rotations
     where rotation_id = p_rotation_id
     for update;

    if not found
       or v_rotation.tenant_id <> p_tenant_id
       or v_rotation.user_id <> p_user_id
       or v_rotation.device_id <> p_device_id
       or v_rotation.old_generation <> p_old_generation
       or v_rotation.old_protocol_signing_algorithm <> p_old_protocol_signing_algorithm
       or v_rotation.old_protocol_public_key_fingerprint <> p_old_protocol_public_key_fingerprint then
        raise exception 'rotation_not_found';
    end if;
    if v_rotation.transcript_hash <> p_transcript_hash then
        raise exception 'rotation_payload_conflict';
    end if;
    if v_rotation.state = 'committed' then
        if v_rotation.result is null then
            raise exception 'identity_history_inconsistent';
        end if;
        return v_rotation.result;
    end if;
    if v_rotation.state <> 'issued' then
        raise exception 'rotation_state_conflict';
    end if;
    if v_rotation.expires_at <= v_now then
        raise exception 'rotation_expired';
    end if;
    if p_grace_expires_at <= v_now
       or p_grace_expires_at > v_now + interval '7 days' then
        raise exception 'invalid_rotation_grace_expiry';
    end if;

    perform pg_catalog.pg_advisory_xact_lock(
        pg_catalog.hashtextextended(
            p_tenant_id::text || ':' || v_rotation.new_protocol_signing_algorithm || ':' ||
            v_rotation.new_protocol_public_key_fingerprint,
            6002
        )
    );

    select *
      into v_device
      from public.registered_devices
     where tenant_id = p_tenant_id
       and user_id = p_user_id
       and device_id = p_device_id
     for update;

    if not found then
        raise exception 'device_not_registered';
    end if;
    if v_device.status = 'revoked' then
        raise exception 'device_revoked';
    end if;
    if v_device.status = 'frozen' then
        raise exception 'device_frozen';
    end if;
    if v_device.status <> 'active' then
        raise exception 'device_not_active';
    end if;
    if v_device.identity_generation <> p_old_generation then
        raise exception 'identity_generation_conflict';
    end if;
    if v_device.protocol_signing_algorithm <> v_rotation.old_protocol_signing_algorithm
       or v_device.protocol_public_key_fingerprint <> v_rotation.old_protocol_public_key_fingerprint
       or v_device.protocol_public_key_base64 <> v_rotation.old_protocol_public_key_base64 then
        raise exception 'current_identity_mismatch';
    end if;

    if exists (
        select 1
          from public.registered_devices
         where tenant_id = p_tenant_id
           and protocol_signing_algorithm = v_rotation.new_protocol_signing_algorithm
           and protocol_public_key_fingerprint = v_rotation.new_protocol_public_key_fingerprint
           and id <> v_device.id
    ) or exists (
        select 1
          from public.device_identity_history
         where tenant_id = p_tenant_id
           and protocol_signing_algorithm = v_rotation.new_protocol_signing_algorithm
           and protocol_public_key_fingerprint = v_rotation.new_protocol_public_key_fingerprint
    ) then
        raise exception 'new_identity_already_owned';
    end if;

    select *
      into v_old_history
      from public.device_identity_history
     where tenant_id = p_tenant_id
       and user_id = p_user_id
       and device_id = p_device_id
       and generation = p_old_generation
       and state = 'active'
     for update;

    if not found
       or v_old_history.protocol_signing_algorithm <> v_rotation.old_protocol_signing_algorithm
       or v_old_history.protocol_public_key_fingerprint <> v_rotation.old_protocol_public_key_fingerprint
       or v_old_history.protocol_public_key_base64 <> v_rotation.old_protocol_public_key_base64 then
        raise exception 'identity_history_inconsistent';
    end if;

    v_new_generation := p_old_generation + 1;

    update public.device_identity_history
       set state = 'grace',
           grace_started_at = v_now,
           grace_expires_at = p_grace_expires_at,
           source_rotation_id = p_rotation_id
     where id = v_old_history.id;

    insert into public.device_identity_history (
        tenant_id, user_id, device_id, generation,
        protocol_signing_algorithm, protocol_public_key_fingerprint,
        protocol_public_key_base64, state, activated_at, source_rotation_id
    ) values (
        p_tenant_id, p_user_id, p_device_id, v_new_generation,
        v_rotation.new_protocol_signing_algorithm,
        v_rotation.new_protocol_public_key_fingerprint,
        v_rotation.new_protocol_public_key_base64,
        'active', v_now, p_rotation_id
    );

    update public.registered_devices
       set protocol_signing_algorithm = v_rotation.new_protocol_signing_algorithm,
           protocol_public_key_fingerprint = v_rotation.new_protocol_public_key_fingerprint,
           protocol_public_key_base64 = v_rotation.new_protocol_public_key_base64,
           identity_generation = v_new_generation,
           approved_by = p_user_id,
           approval_method = 'key_rotation_confirmation',
           approval_timestamp = v_now,
           last_seen_at = v_now
     where id = v_device.id
       and status = 'active'
       and identity_generation = p_old_generation
       and protocol_signing_algorithm = v_rotation.old_protocol_signing_algorithm
       and protocol_public_key_fingerprint = v_rotation.old_protocol_public_key_fingerprint;
    get diagnostics v_rows = row_count;
    if v_rows <> 1 then
        raise exception 'identity_generation_conflict';
    end if;

    v_result := jsonb_build_object(
        'rotation_id', p_rotation_id,
        'state', 'committed',
        'committed_at', v_now,
        'generation', v_new_generation,
        'grace_expires_at', p_grace_expires_at
    );

    update public.device_identity_rotations
       set state = 'committed',
           committed_at = v_now,
           committed_generation = v_new_generation,
           grace_expires_at = p_grace_expires_at,
           result = v_result
     where rotation_id = p_rotation_id;

    insert into public.device_identity_rotation_audit (
        rotation_id, tenant_id, user_id, device_id, event_type,
        transcript_hash, details, occurred_at
    ) values (
        p_rotation_id, p_tenant_id, p_user_id, p_device_id, 'committed',
        p_transcript_hash,
        jsonb_build_object(
            'oldGeneration', p_old_generation,
            'newGeneration', v_new_generation,
            'oldFingerprint', v_rotation.old_protocol_public_key_fingerprint,
            'newFingerprint', v_rotation.new_protocol_public_key_fingerprint,
            'graceExpiresAt', p_grace_expires_at
        ),
        v_now
    );

    return v_result;
end;
$$;

revoke execute on function public.is_valid_protocol_identity_key_v6(text, text)
    from public, anon, authenticated;
revoke execute on function public.reject_device_identity_rotation_audit_mutation_v6()
    from public, anon, authenticated;
revoke execute on function public.issue_device_identity_rotation_v6(
    uuid, uuid, uuid, uuid, text, bigint, text, text, text, text, text, text, text, text, timestamptz
) from public, anon, authenticated;
grant execute on function public.issue_device_identity_rotation_v6(
    uuid, uuid, uuid, uuid, text, bigint, text, text, text, text, text, text, text, text, timestamptz
) to service_role;
revoke execute on function public.commit_device_identity_rotation_v6(
    uuid, uuid, uuid, text, bigint, text, text, text, timestamptz
) from public, anon, authenticated;
grant execute on function public.commit_device_identity_rotation_v6(
    uuid, uuid, uuid, text, bigint, text, text, text, timestamptz
) to service_role;
revoke execute on function public.expire_device_identity_grace_v6(integer)
    from public, anon, authenticated;
grant execute on function public.expire_device_identity_grace_v6(integer)
    to service_role;

do $$
begin
    if not exists (
        select 1
          from information_schema.columns
         where table_schema = 'public'
           and table_name = 'registered_devices'
           and column_name = 'identity_generation'
    ) then
        raise exception 'security_v6_identity_generation_missing';
    end if;
    if to_regprocedure(
        'public.issue_device_identity_rotation_v6(uuid,uuid,uuid,uuid,text,bigint,text,text,text,text,text,text,text,text,timestamp with time zone)'
    ) is null then
        raise exception 'security_v6_issue_rpc_missing';
    end if;
    if to_regprocedure(
        'public.commit_device_identity_rotation_v6(uuid,uuid,uuid,text,bigint,text,text,text,timestamp with time zone)'
    ) is null then
        raise exception 'security_v6_commit_rpc_missing';
    end if;
    if has_function_privilege(
        'anon',
        'public.commit_device_identity_rotation_v6(uuid,uuid,uuid,text,bigint,text,text,text,timestamp with time zone)',
        'EXECUTE'
    ) then
        raise exception 'security_v6_commit_rpc_exposed_to_anon';
    end if;
    if not has_function_privilege(
        'service_role',
        'public.commit_device_identity_rotation_v6(uuid,uuid,uuid,text,bigint,text,text,text,timestamp with time zone)',
        'EXECUTE'
    ) then
        raise exception 'security_v6_commit_rpc_missing_service_role_grant';
    end if;
    if not exists (
        select 1
          from pg_trigger
         where tgrelid = 'public.device_identity_rotation_audit'::regclass
           and tgname = 'device_identity_rotation_audit_immutable_v6'
           and not tgisinternal
    ) then
        raise exception 'security_v6_audit_immutability_trigger_missing';
    end if;
end;
$$;

commit;
