-- Auth privilege-boundary post-deploy acceptance.
--
-- This script is read-only and repeatable. It raises on the first missing object,
-- leaked privilege, unsafe policy, or lost guarded-RPC grant.

do $acceptance$
declare
    target_table_name text;
    target_table_oid regclass;
    target_function_signature text;
    target_function_oid regprocedure;
    client_role_name text;
    privilege_name text;
    guarded_rpc_signature text;
begin
    foreach target_table_name in array array[
        'public.registration_blacklist',
        'public.rate_limit_config'
    ] loop
        target_table_oid := to_regclass(target_table_name);
        if target_table_oid is null then
            raise exception 'auth privilege acceptance: required table % is missing',
                target_table_name;
        end if;

        if not exists (
            select 1
              from pg_class c
             where c.oid = target_table_oid
               and c.relrowsecurity
        ) then
            raise exception 'auth privilege acceptance: RLS is disabled on %',
                target_table_name;
        end if;

        foreach client_role_name in array array['anon', 'authenticated'] loop
            foreach privilege_name in array array[
                'SELECT', 'INSERT', 'UPDATE', 'DELETE',
                'TRUNCATE', 'REFERENCES', 'TRIGGER'
            ] loop
                if has_table_privilege(
                    client_role_name,
                    target_table_oid,
                    privilege_name
                ) then
                    raise exception
                        'auth privilege acceptance: role % retains % on table %',
                        client_role_name,
                        privilege_name,
                        target_table_name;
                end if;
            end loop;
        end loop;

        if exists (
            select 1
              from pg_class c
              cross join lateral aclexplode(
                  coalesce(c.relacl, acldefault('r', c.relowner))
              ) acl
             where c.oid = target_table_oid
               and acl.grantee = 0
        ) then
            raise exception 'auth privilege acceptance: PUBLIC retains a privilege on table %',
                target_table_name;
        end if;

        foreach privilege_name in array array['SELECT', 'INSERT', 'UPDATE', 'DELETE'] loop
            if not has_table_privilege(
                'service_role',
                target_table_oid,
                privilege_name
            ) then
                raise exception
                    'auth privilege acceptance: service_role is missing % on table %',
                    privilege_name,
                    target_table_name;
            end if;
        end loop;
    end loop;

    if exists (
        select 1
          from pg_policies p
         where p.schemaname = 'public'
           and p.tablename in ('registration_blacklist', 'rate_limit_config')
           and p.policyname in (
               'Admin can manage blacklist',
               'Admin can manage rate_limit_config'
           )
    ) then
        raise exception 'auth privilege acceptance: a legacy user-metadata admin policy remains';
    end if;

    if exists (
        select 1
          from pg_policies p
         where p.schemaname = 'public'
           and p.tablename in ('registration_blacklist', 'rate_limit_config')
           and (
               coalesce(p.qual, '') ilike '%raw_user_meta_data%'
               or coalesce(p.with_check, '') ilike '%raw_user_meta_data%'
           )
    ) then
        raise exception 'auth privilege acceptance: an admin policy trusts raw_user_meta_data';
    end if;

    if exists (
        select 1
          from pg_policies p
         where p.schemaname = 'public'
           and p.tablename in ('registration_blacklist', 'rate_limit_config')
           and p.roles && array['public', 'anon', 'authenticated']::name[]
    ) then
        raise exception 'auth privilege acceptance: an internal table still has a client-role policy';
    end if;

    foreach target_function_signature in array array[
        'public.is_ip_blacklisted(text)',
        'public.is_device_blacklisted(text)',
        'public.is_disposable_email(text)',
        'public.count_recent_ip_attempts(text,integer)',
        'public.count_recent_device_attempts(text,integer)',
        'public.check_registration_allowed(text,text,text,text)',
        'public.cleanup_old_attempts()',
        'public.check_phone_send_limit(text,integer)',
        'public.check_device_send_limit(text,integer)',
        'public.detect_suspicious_behavior(text,integer,integer)',
        'public.get_best_channel(text)',
        'public.update_channel_stats(text,boolean,integer)',
        'public.cleanup_expired_vcode_records()',
        'public.cleanup_expired_rate_limits()',
        'public.check_auth_attempt_allowed_v1(text,text,text,text,text)',
        'public.assert_avatar_backend_ready()',
        'public.ensure_avatar_universal_user(uuid)'
    ] loop
        target_function_oid := to_regprocedure(target_function_signature);
        if target_function_oid is null then
            raise exception 'auth privilege acceptance: required function % is missing',
                target_function_signature;
        end if;

        foreach client_role_name in array array['anon', 'authenticated'] loop
            if has_function_privilege(
                client_role_name,
                target_function_oid,
                'EXECUTE'
            ) then
                raise exception
                    'auth privilege acceptance: role % can execute internal function %',
                    client_role_name,
                    target_function_signature;
            end if;
        end loop;

        if exists (
            select 1
              from pg_proc p
              cross join lateral aclexplode(
                  coalesce(p.proacl, acldefault('f', p.proowner))
              ) acl
             where p.oid = target_function_oid
               and acl.grantee = 0
               and acl.privilege_type = 'EXECUTE'
        ) then
            raise exception 'auth privilege acceptance: PUBLIC can execute internal function %',
                target_function_signature;
        end if;

        if not has_function_privilege(
            'service_role',
            target_function_oid,
            'EXECUTE'
        ) then
            raise exception
                'auth privilege acceptance: service_role cannot execute internal function %',
                target_function_signature;
        end if;
    end loop;

    foreach guarded_rpc_signature in array array[
        'public.guard_registration_attempt_v1(text,text,text,text,text,text)',
        'public.record_registration_attempt_v1(text,text,text,text,boolean,text,boolean,boolean,text,jsonb)'
    ] loop
        target_function_oid := to_regprocedure(guarded_rpc_signature);
        if target_function_oid is null then
            raise exception 'auth privilege acceptance: guarded RPC % is missing',
                guarded_rpc_signature;
        end if;

        if exists (
            select 1
              from pg_proc p
              cross join lateral aclexplode(
                  coalesce(p.proacl, acldefault('f', p.proowner))
              ) acl
             where p.oid = target_function_oid
               and acl.grantee = 0
               and acl.privilege_type = 'EXECUTE'
        ) then
            raise exception 'auth privilege acceptance: guarded RPC % is granted to PUBLIC',
                guarded_rpc_signature;
        end if;

        foreach client_role_name in array array['anon', 'authenticated', 'service_role'] loop
            if not has_function_privilege(
                client_role_name,
                target_function_oid,
                'EXECUTE'
            ) then
                raise exception
                    'auth privilege acceptance: role % lost guarded RPC %',
                    client_role_name,
                    guarded_rpc_signature;
            end if;
        end loop;
    end loop;
end
$acceptance$;

select 'PASS'::text as auth_privilege_boundaries_acceptance;
