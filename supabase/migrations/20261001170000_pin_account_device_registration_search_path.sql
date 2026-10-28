begin;
set local lock_timeout = '5s';
set local statement_timeout = '30s';

alter function public.register_account_device_v9(uuid, uuid, text, text, text, text)
    set search_path = pg_catalog, public, extensions, pg_temp;

do $$
begin
    if not exists (
        select 1 from pg_proc p
         where p.oid = 'public.register_account_device_v9(uuid,uuid,text,text,text,text)'::regprocedure
           and 'search_path=pg_catalog, public, extensions, pg_temp' = any(p.proconfig)
           and p.prosecdef
    ) or has_function_privilege('anon', 'public.register_account_device_v9(uuid,uuid,text,text,text,text)', 'EXECUTE')
      or has_function_privilege('authenticated', 'public.register_account_device_v9(uuid,uuid,text,text,text,text)', 'EXECUTE')
      or not has_function_privilege('service_role', 'public.register_account_device_v9(uuid,uuid,text,text,text,text)', 'EXECUTE') then
        raise exception 'account_registration_routine_boundary_failed';
    end if;
end;
$$;

notify pgrst, 'reload schema';
commit;
