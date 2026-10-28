-- Account-owned device removal. Keep a revoked tombstone: login must not undo removal.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';

alter table public.registered_devices
    add column if not exists removal_timestamp timestamptz,
    add column if not exists removed_by_device_id text;

create or replace function public.remove_account_device_v10(
    p_tenant_id uuid, p_user_id uuid,
    p_caller_device_id text, p_caller_signing_algorithm text, p_caller_fingerprint text,
    p_target_device_id text, p_target_signing_algorithm text, p_target_fingerprint text
) returns jsonb
language plpgsql security definer
set search_path = pg_catalog, public, extensions, pg_temp
as $$
declare
    v_caller public.registered_devices%rowtype;
    v_target public.registered_devices%rowtype;
begin
    perform public.assert_service_role_request_v5('remove_account_device_v10');
    if p_tenant_id is null or p_user_id is null
       or p_caller_device_id is null or p_target_device_id is null
       or p_caller_device_id !~ '^[A-Za-z0-9._:-]{16,128}$'
       or p_target_device_id !~ '^[A-Za-z0-9._:-]{16,128}$'
       or p_caller_signing_algorithm is null or p_target_signing_algorithm is null
       or p_caller_signing_algorithm not in ('Ed25519','ML-DSA-65','ML-DSA-87')
       or p_target_signing_algorithm not in ('Ed25519','ML-DSA-65','ML-DSA-87')
       or p_caller_fingerprint is null or p_target_fingerprint is null
       or p_caller_fingerprint !~ '^[a-f0-9]{64}$'
       or p_target_fingerprint !~ '^[a-f0-9]{64}$' then
        raise exception 'bad_device_binding';
    end if;
    -- Same tenant lock as account registration; caller/target races cannot deadlock.
    perform pg_advisory_xact_lock(hashtextextended(p_tenant_id::text || '/account-device-registration', 0));
    select * into v_caller from public.registered_devices
     where tenant_id=p_tenant_id and user_id=p_user_id and device_id=p_caller_device_id
     for update;
    if not found then raise exception 'device_not_registered'; end if;
    if v_caller.protocol_signing_algorithm <> p_caller_signing_algorithm
       or v_caller.protocol_public_key_fingerprint <> p_caller_fingerprint then
        raise exception 'current_identity_mismatch';
    end if;
    if v_caller.status='revoked' then raise exception 'device_revoked'; end if;
    if v_caller.status='frozen' then raise exception 'device_frozen'; end if;
    if v_caller.status<>'active' then raise exception 'device_not_active'; end if;

    select * into v_target from public.registered_devices
     where tenant_id=p_tenant_id and user_id=p_user_id and device_id=p_target_device_id
     for update;
    if not found then raise exception 'target_device_not_found'; end if;
    if v_target.protocol_signing_algorithm <> p_target_signing_algorithm
       or v_target.protocol_public_key_fingerprint <> p_target_fingerprint then
        raise exception 'target_identity_mismatch';
    end if;
    update public.registered_devices
       set status='revoked', removal_timestamp=coalesce(removal_timestamp,now()),
           removed_by_device_id=coalesce(removed_by_device_id,p_caller_device_id)
     where id=v_target.id returning * into v_target;
    -- Retired/grace keys belong to the removed device too; they cannot bypass the tombstone.
    update public.device_identity_history
       set state='revoked', revoked_at=coalesce(revoked_at,now())
     where tenant_id=p_tenant_id and user_id=p_user_id and device_id=p_target_device_id
       and state<>'revoked';
    return to_jsonb(v_target);
end;
$$;
revoke all on function public.remove_account_device_v10(uuid,uuid,text,text,text,text,text,text)
    from public, anon, authenticated;
grant execute on function public.remove_account_device_v10(uuid,uuid,text,text,text,text,text,text)
    to service_role;
do $$
begin
    if has_function_privilege('anon','public.remove_account_device_v10(uuid,uuid,text,text,text,text,text,text)','EXECUTE')
       or has_function_privilege('authenticated','public.remove_account_device_v10(uuid,uuid,text,text,text,text,text,text)','EXECUTE')
       or not has_function_privilege('service_role','public.remove_account_device_v10(uuid,uuid,text,text,text,text,text,text)','EXECUTE') then
        raise exception 'account_removal_privilege_boundary_failed';
    end if;
end;
$$;
notify pgrst,'reload schema';
commit;
