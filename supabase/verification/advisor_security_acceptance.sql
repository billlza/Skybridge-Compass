-- Read-only invariants. Run after every migration, against the database actually deployed.
DO $acceptance$
DECLARE
    problem text;
BEGIN
    SELECT string_agg(c.relname, ', ') INTO problem
    FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
    WHERE n.nspname='public' AND c.relkind IN ('r','p') AND NOT c.relrowsecurity;
    IF problem IS NOT NULL THEN RAISE EXCEPTION 'RLS disabled: %', problem; END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname='pg_net' AND extnamespace='extensions'::regnamespace) THEN
        RAISE EXCEPTION 'pg_net is absent or registered in an exposed schema';
    END IF;
    IF (SELECT count(*) FROM pg_roles WHERE rolname IN ('anon','authenticated') AND NOT rolcanlogin)<>2 THEN
        RAISE EXCEPTION 'Client roles must not have direct database login';
    END IF;
    IF EXISTS (
        SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
        WHERE n.nspname IN ('public','graphql_public') AND p.prokind IN ('f','p')
          AND p.prosrc ~* 'net\s*\.'
          AND (has_function_privilege('anon',p.oid,'EXECUTE') OR has_function_privilege('authenticated',p.oid,'EXECUTE'))
    ) THEN
        RAISE EXCEPTION 'A client RPC exposes the private HTTP facility';
    END IF;

    SELECT string_agg(p.oid::regprocedure::text, ', ') INTO problem
    FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.prokind IN ('f','p')
      AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid='pg_proc'::regclass
                      AND d.objid=p.oid AND d.deptype='e')
      AND NOT EXISTS (SELECT 1 FROM unnest(p.proconfig) cfg
                      WHERE cfg = 'search_path=pg_catalog, public, extensions, pg_temp');
    IF problem IS NOT NULL THEN RAISE EXCEPTION 'Unpinned routine search_path: %', problem; END IF;

    SELECT string_agg(c.relname || ':' || a.privilege_type, ', ') INTO problem
    FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
    CROSS JOIN LATERAL aclexplode(coalesce(c.relacl, acldefault('r',c.relowner))) a
    LEFT JOIN pg_roles r ON r.oid=a.grantee
    WHERE n.nspname='public' AND c.relkind IN ('r','p')
      AND (a.grantee=0 OR (r.rolname='anon' AND NOT
          (c.relname IN ('constellations','disposable_email_domains') AND a.privilege_type='SELECT'))
          OR (r.rolname='authenticated' AND a.privilege_type IN ('TRUNCATE','REFERENCES','TRIGGER')));
    IF problem IS NOT NULL THEN RAISE EXCEPTION 'Unsafe table grant: %', problem; END IF;

    SELECT string_agg(c.relname, ', ') INTO problem
    FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
    WHERE n.nspname='public' AND c.relkind IN ('r','p')
      AND c.relname NOT IN (
        'account_bindings','account_links','activity_logs','auth_methods','constellations',
        'disposable_email_domains','idempotent_requests','nebula_accounts','notifications',
        'oauth_accounts','phone_auth','profiles','sync_status','universal_users','user_activity',
        'user_avatars','user_profiles','user_sessions','user_settings','username_change_limits','username_history')
      AND (has_table_privilege('authenticated', c.oid, 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
           OR has_table_privilege('anon', c.oid, 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER'));
    IF problem IS NOT NULL THEN RAISE EXCEPTION 'Internal table exposed: %', problem; END IF;

    SELECT string_agg(p.oid::regprocedure::text, ', ') INTO problem
    FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.prosecdef
      AND ((has_function_privilege('anon',p.oid,'EXECUTE') AND p.oid::regprocedure::text NOT IN (
          'guard_registration_attempt_v1(text,text,text,text,text,text)',
          'record_registration_attempt_v1(text,text,text,text,boolean,text,boolean,boolean,text,jsonb)'))
       OR (has_function_privilege('authenticated',p.oid,'EXECUTE') AND p.oid::regprocedure::text NOT IN (
          'guard_registration_attempt_v1(text,text,text,text,text,text)',
          'record_registration_attempt_v1(text,text,text,text,boolean,text,boolean,boolean,text,jsonb)',
          'avatar_finalize_upload(text,text,text,bigint,integer,integer,jsonb,text)',
          'bind_contact_method(text,text,text,inet,text)',
          'unbind_contact_method(text,text,inet,text)', 'get_user_binding_status(uuid)'))
       OR EXISTS (SELECT 1 FROM aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a
                   WHERE a.grantee=0 AND a.privilege_type='EXECUTE'));
    IF problem IS NOT NULL THEN RAISE EXCEPTION 'Internal SECURITY DEFINER executable: %', problem; END IF;

    IF NOT has_function_privilege('supabase_auth_admin',
        'public.hook_skybridge_before_user_created_v1(jsonb)','EXECUTE') THEN
        RAISE EXCEPTION 'Auth hook execution grant lost';
    END IF;
    IF has_function_privilege('anon','public.scheduled_maintenance_4ea8045d()','EXECUTE')
       OR has_function_privilege('authenticated','public.scheduled_maintenance_4ea8045d()','EXECUTE') THEN
        RAISE EXCEPTION 'Maintenance procedure is client-executable';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_proc WHERE oid='public.scheduled_maintenance_4ea8045d()'::regprocedure
               AND prosrc ~* '\mCOMMIT\M') THEN
        RAISE EXCEPTION 'Pinned maintenance procedure must leave transaction control to its caller';
    END IF;

    IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public'
               AND (coalesce(qual,'') || coalesce(with_check,'')) ILIKE '%raw_user_meta_data%') THEN
        RAISE EXCEPTION 'RLS trusts user-editable authorization metadata';
    END IF;
    -- The Management API's read-only auditor has catalog access but deliberately
    -- cannot execute application RPCs. Check the reviewed predicate here; the
    -- isolated regression suite exercises it under real client roles.
    IF NOT EXISTS (
        SELECT 1 FROM pg_proc WHERE oid='public.check_user_profile_access(text)'::regprocedure
          AND NOT prosecdef
          AND regexp_replace(prosrc, '\s+', '', 'g') = regexp_replace(
            $predicate$SELECT current_user = 'service_role'
                OR coalesce((SELECT auth.uid())::text = target_user_id, false);$predicate$,
            '\s+', '', 'g')
    ) THEN
        RAISE EXCEPTION 'User ownership predicate differs from the reviewed contract';
    END IF;
    SELECT string_agg(tablename || ':' || policyname, ', ') INTO problem
    FROM pg_policies WHERE schemaname='public'
      AND ((qual LIKE '%auth.uid()%' AND qual NOT LIKE '%SELECT auth.uid()%')
        OR (with_check LIKE '%auth.uid()%' AND with_check NOT LIKE '%SELECT auth.uid()%'));
    IF problem IS NOT NULL THEN RAISE EXCEPTION 'Per-row auth lookup: %', problem; END IF;

    SELECT string_agg(overlap.description, ', ') INTO problem FROM (
        SELECT c.relname || ':' || client.rolname || ':' || command.name AS description
        FROM pg_policy p JOIN pg_class c ON c.oid=p.polrelid
        JOIN pg_namespace n ON n.oid=c.relnamespace
        CROSS JOIN (SELECT oid,rolname FROM pg_roles WHERE rolname IN ('anon','authenticated')) client
        CROSS JOIN (VALUES ('r','SELECT'),('a','INSERT'),('w','UPDATE'),('d','DELETE')) command(code,name)
        WHERE n.nspname='public' AND p.polpermissive
          AND (0=ANY(p.polroles) OR client.oid=ANY(p.polroles))
          AND (p.polcmd='*' OR p.polcmd::text=command.code)
        GROUP BY c.relname,client.rolname,command.name HAVING count(*)>1
    ) overlap;
    IF problem IS NOT NULL THEN RAISE EXCEPTION 'Overlapping permissive client policies: %', problem; END IF;

    IF EXISTS (
        SELECT 1 FROM pg_default_acl d
        CROSS JOIN LATERAL aclexplode(d.defaclacl) a
        LEFT JOIN pg_roles r ON r.oid=a.grantee
        WHERE d.defaclrole='postgres'::regrole
          AND d.defaclnamespace IN (0, 'public'::regnamespace)
          AND (a.grantee=0 OR r.rolname IN ('anon','authenticated'))
    ) OR NOT EXISTS (
        SELECT 1 FROM pg_default_acl WHERE defaclrole='postgres'::regrole
          AND defaclnamespace=0 AND defaclobjtype='f'
    ) THEN
        RAISE EXCEPTION 'Future objects inherit client access';
    END IF;

    SELECT string_agg(c.conname, ', ') INTO problem
    FROM pg_constraint c JOIN pg_class t ON t.oid=c.conrelid
    JOIN pg_namespace n ON n.oid=t.relnamespace
    WHERE n.nspname='public' AND c.contype='f' AND NOT EXISTS (
        SELECT 1 FROM pg_index i WHERE i.indrelid=c.conrelid AND i.indisvalid
          AND i.indisready AND i.indexprs IS NULL
          -- FK equality probes imply IS NOT NULL; the existing unique auth-user
          -- index intentionally excludes NULLs. Other partial indexes need review.
          AND (i.indpred IS NULL OR (cardinality(c.conkey)=1 AND
               pg_get_expr(i.indpred,i.indrelid) =
               (SELECT format('(%I IS NOT NULL)',a.attname) FROM pg_attribute a
                WHERE a.attrelid=c.conrelid AND a.attnum=c.conkey[1])))
          AND i.indnkeyatts >= cardinality(c.conkey)
          AND (i.indkey::smallint[])[0:cardinality(c.conkey)-1] @> c.conkey
    );
    IF problem IS NOT NULL THEN RAISE EXCEPTION 'Foreign key lacks a usable leading index: %', problem; END IF;
END
$acceptance$;
