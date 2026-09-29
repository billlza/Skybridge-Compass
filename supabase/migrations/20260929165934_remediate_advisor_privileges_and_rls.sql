-- Apply after the two retained, previously unapplied hardening migrations.
-- Schema-only changes: no user rows are modified or deleted.
BEGIN;
SET LOCAL lock_timeout = '3s';
SET LOCAL statement_timeout = '45s';

-- Make exposure an explicit choice for future application objects. PostgreSQL's
-- built-in PUBLIC function grant is global and cannot be revoked per schema.
ALTER DEFAULT PRIVILEGES FOR ROLE postgres REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
    REVOKE ALL ON FUNCTIONS FROM anon, authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
    REVOKE ALL ON TABLES FROM anon, authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
    REVOKE ALL ON SEQUENCES FROM anon, authenticated;

-- public and extensions must be trusted before including them in search_path.
DO $trusted_schemas$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_namespace n
        WHERE n.nspname IN ('public', 'extensions')
          AND (has_schema_privilege('anon', n.oid, 'CREATE')
               OR has_schema_privilege('authenticated', n.oid, 'CREATE'))
    ) THEN
        RAISE EXCEPTION 'An untrusted client can create objects in a routine search_path';
    END IF;
END
$trusted_schemas$;


-- Pin invoker functions too; the previous migration covered only definers.

ALTER FUNCTION public.assert_avatar_backend_ready() SET search_path = pg_catalog, public, extensions, pg_temp;

ALTER FUNCTION public.assert_service_role_request_v5(text) SET search_path = pg_catalog, public, extensions, pg_temp;

ALTER FUNCTION public.audit_changes() SET search_path = pg_catalog, public, extensions, pg_temp;

ALTER FUNCTION public.avatar_finalize_upload(text,text,text,bigint,integer,integer,jsonb,text) SET search_path = pg_catalog, public, extensions, pg_temp;

ALTER FUNCTION public.bind_contact_method(text,text,text,inet,text) SET search_path = pg_catalog, public, extensions, pg_temp;

ALTER FUNCTION public.bootstrap_register_device_v5(uuid,uuid,text,text,text,text) SET search_path = pg_catalog, public, extensions, pg_temp;

ALTER FUNCTION public.check_auth_attempt_allowed_v1(text,text,text,text,text) SET search_path = pg_catalog, public, extensions, pg_temp;

ALTER FUNCTION public.check_device_send_limit(text,integer) SET search_path = pg_catalog, public, extensions, pg_temp;

ALTER FUNCTION public.check_phone_send_limit(text,integer) SET search_path = pg_catalog, public, extensions, pg_temp;

ALTER FUNCTION public.check_registration_allowed(text,text,text,text) SET search_path = pg_catalog, public, extensions, pg_temp;

ALTER FUNCTION public.check_user_profile_access(text) SET search_path = pg_catalog, public, extensions, pg_temp;

ALTER FUNCTION public.cleanup_expired_blacklist() SET search_path = pg_catalog, public, extensions, pg_temp;

ALTER FUNCTION public.cleanup_expired_rate_limits() SET search_path = pg_catalog, public, extensions, pg_temp;

ALTER FUNCTION public.cleanup_expired_vcode_records() SET search_path = pg_catalog, public, extensions, pg_temp;

ALTER FUNCTION public.cleanup_old_attempts() SET search_path = pg_catalog, public, extensions, pg_temp;

ALTER FUNCTION public.cleanup_old_idempotent_requests() SET search_path = pg_catalog, public, extensions, pg_temp;

ALTER FUNCTION public.commit_device_identity_rotation_v6(uuid,uuid,uuid,text,bigint,text,text,text,timestamp with time zone) SET search_path = pg_catalog, public, extensions, pg_temp;

ALTER FUNCTION public.confirm_device_enrollment_v5(uuid,uuid,text,text,text,text,text,text,text) SET search_path = pg_catalog, public, extensions, pg_temp;

ALTER FUNCTION public.count_recent_device_attempts(text,integer) SET search_path = pg_catalog, public, extensions, pg_temp;

ALTER FUNCTION public.count_recent_ip_attempts(text,integer) SET search_path = pg_catalog, public, extensions, pg_temp;

ALTER FUNCTION public.create_universal_user(text,text,text,text,text,text) SET search_path = pg_catalog, public, extensions, pg_temp;

ALTER FUNCTION public.create_user_session(uuid,uuid,jsonb,integer) SET search_path = pg_catalog, public, extensions, pg_temp;

ALTER FUNCTION public.detect_suspicious_behavior(text,integer,integer) SET search_path = pg_catalog, public, extensions, pg_temp;

ALTER FUNCTION public.enroll_first_device_v5(text,uuid,uuid,text,text,text,text,uuid) SET search_path = pg_catalog, public, extensions, pg_temp;

ALTER FUNCTION public.ensure_avatar_universal_user(uuid) SET search_path = pg_catalog, public, extensions, pg_temp;

ALTER FUNCTION public.ensure_tenant_security_policy_v5(uuid) SET search_path = pg_catalog, public, extensions, pg_temp;

ALTER FUNCTION public.expire_device_identity_grace_v6(integer) SET search_path = pg_catalog, public, extensions, pg_temp;

ALTER FUNCTION public.generate_unique_nebula_id() SET search_path = pg_catalog, public, extensions, pg_temp;

ALTER FUNCTION public.generate_universal_id(text,text) SET search_path = pg_catalog, public, extensions, pg_temp;

ALTER FUNCTION public.get_best_channel(text) SET search_path = pg_catalog, public, extensions, pg_temp;

ALTER FUNCTION public.get_email_by_nebula_id(text) SET search_path = pg_catalog, public, extensions, pg_temp;

ALTER FUNCTION public.get_user_binding_status(uuid) SET search_path = pg_catalog, public, extensions, pg_temp;

ALTER FUNCTION public.guard_registration_attempt_v1(text,text,text,text,text,text) SET search_path = pg_catalog, public, extensions, pg_temp;

ALTER FUNCTION public.handle_new_user() SET search_path = pg_catalog, public, extensions, pg_temp;

ALTER FUNCTION public.hook_skybridge_before_user_created_v1(jsonb) SET search_path = pg_catalog, public, extensions, pg_temp;

ALTER FUNCTION public.is_device_blacklisted(text) SET search_path = pg_catalog, public, extensions, pg_temp;

ALTER FUNCTION public.is_disposable_email(text) SET search_path = pg_catalog, public, extensions, pg_temp;

ALTER FUNCTION public.is_ip_blacklisted(text) SET search_path = pg_catalog, public, extensions, pg_temp;

ALTER FUNCTION public.is_valid_protocol_identity_key_v6(text,text) SET search_path = pg_catalog, public, extensions, pg_temp;

ALTER FUNCTION public.issue_device_identity_rotation_v6(uuid,uuid,uuid,uuid,text,bigint,text,text,text,text,text,text,text,text,timestamp with time zone) SET search_path = pg_catalog, public, extensions, pg_temp;

ALTER FUNCTION public.link_accounts(uuid,text,text,text) SET search_path = pg_catalog, public, extensions, pg_temp;

ALTER FUNCTION public.nextval(text) SET search_path = pg_catalog, public, extensions, pg_temp;

ALTER FUNCTION public.record_registration_attempt_v1(text,text,text,text,boolean,text,boolean,boolean,text,jsonb) SET search_path = pg_catalog, public, extensions, pg_temp;

ALTER FUNCTION public.reject_device_identity_rotation_audit_mutation_v6() SET search_path = pg_catalog, public, extensions, pg_temp;

ALTER FUNCTION public.resolve_registration_request_ip_v1() SET search_path = pg_catalog, public, extensions, pg_temp;

ALTER FUNCTION public.sync_tenant_security_policy_for_auth_user_v5() SET search_path = pg_catalog, public, extensions, pg_temp;

ALTER FUNCTION public.touch_registered_device_presence_v7(uuid,uuid,text,text,text,text,text,text,text,text,text[],text,text[]) SET search_path = pg_catalog, public, extensions, pg_temp;

ALTER FUNCTION public.unbind_contact_method(text,text,inet,text) SET search_path = pg_catalog, public, extensions, pg_temp;

ALTER FUNCTION public.update_channel_stats(text,boolean,integer) SET search_path = pg_catalog, public, extensions, pg_temp;

ALTER FUNCTION public.update_profile_version() SET search_path = pg_catalog, public, extensions, pg_temp;

ALTER FUNCTION public.update_updated_at_column() SET search_path = pg_catalog, public, extensions, pg_temp;

ALTER FUNCTION public.verify_verification_code(text,text,text,text) SET search_path = pg_catalog, public, extensions, pg_temp;

-- pg_cron owns the CALL transaction; keep the HTTP request in that transaction.

CREATE OR REPLACE PROCEDURE public.scheduled_maintenance_4ea8045d()
 LANGUAGE plpgsql
 SET search_path = pg_catalog, public, extensions, pg_temp
AS $procedure$
            BEGIN
            PERFORM net.http_post(
            url:='https://hloqytmhjludmuhwyyzb.supabase.co/functions/v1/scheduled-maintenance',
            headers:=jsonb_build_object('Content-Type', 'application/json'),
            body:='{"edge_function_name":"scheduled-maintenance"}',
            timeout_milliseconds:=10000
            );
            END;
            $procedure$;

REVOKE ALL ON PROCEDURE public.scheduled_maintenance_4ea8045d() FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON PROCEDURE public.scheduled_maintenance_4ea8045d() TO service_role;

-- A user-controlled nebula_ prefix is not proof of ownership. Standard
-- clients retain their UUID-owned settings/notifications; server clients retain
-- service_role access. No privileges are needed to evaluate this predicate.
CREATE OR REPLACE FUNCTION public.check_user_profile_access(target_user_id text)
RETURNS boolean LANGUAGE sql STABLE SECURITY INVOKER
SET search_path = pg_catalog, public, extensions, pg_temp
AS $body$
    SELECT current_user = 'service_role'
        OR coalesce((SELECT auth.uid())::text = target_user_id, false);
$body$;


CREATE OR REPLACE FUNCTION public.get_user_binding_status(target_user_id uuid)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = pg_catalog, public, extensions, pg_temp
AS $function$
DECLARE
    result JSON;
    user_profile RECORD;
BEGIN
    -- 检查权限：只能查询自己的状态
    IF auth.uid() IS NULL OR auth.uid() IS DISTINCT FROM target_user_id THEN
        RAISE EXCEPTION 'Access denied: Cannot access other user data';
    END IF;

    -- 获取用户资料
    SELECT * INTO user_profile
    FROM user_profiles
    WHERE id = target_user_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'User profile not found';
    END IF;

    -- 构建返回结果
    SELECT json_build_object(
        'user_id', user_profile.id,
        'nebula_id', user_profile.nebula_id,
        'email', CASE
            WHEN user_profile.email IS NOT NULL THEN
                json_build_object(
                    'value', user_profile.email,
                    'masked', CASE
                        WHEN length(user_profile.email) > 6 THEN
                            substring(user_profile.email from 1 for 2) || '***@' ||
                            substring(user_profile.email from position('@' in user_profile.email) + 1)
                        ELSE user_profile.email
                    END,
                    'is_bound', true
                )
            ELSE json_build_object('is_bound', false)
        END,
        'phone', CASE
            WHEN user_profile.phone IS NOT NULL THEN
                json_build_object(
                    'value', user_profile.phone,
                    'masked', CASE
                        WHEN length(user_profile.phone) = 11 THEN
                            substring(user_profile.phone from 1 for 3) || '****' ||
                            substring(user_profile.phone from 8 for 4)
                        ELSE user_profile.phone
                    END,
                    'is_bound', true
                )
            ELSE json_build_object('is_bound', false)
        END,
        'account_type', user_profile.account_type,
        'created_at', user_profile.created_at,
        'updated_at', user_profile.updated_at
    ) INTO result;

    RETURN result;
END;
$function$;

-- Revoke inherited PUBLIC execution as well as direct client grants.

REVOKE ALL ON FUNCTION public.assert_avatar_backend_ready() FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.assert_avatar_backend_ready() TO service_role;

REVOKE ALL ON FUNCTION public.audit_changes() FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.audit_changes() TO service_role;

REVOKE ALL ON FUNCTION public.avatar_finalize_upload(text,text,text,bigint,integer,integer,jsonb,text) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.avatar_finalize_upload(text,text,text,bigint,integer,integer,jsonb,text) TO service_role, authenticated;

REVOKE ALL ON FUNCTION public.bind_contact_method(text,text,text,inet,text) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.bind_contact_method(text,text,text,inet,text) TO service_role, authenticated;

REVOKE ALL ON FUNCTION public.bootstrap_register_device_v5(uuid,uuid,text,text,text,text) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.bootstrap_register_device_v5(uuid,uuid,text,text,text,text) TO service_role;

REVOKE ALL ON FUNCTION public.check_auth_attempt_allowed_v1(text,text,text,text,text) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.check_auth_attempt_allowed_v1(text,text,text,text,text) TO service_role;

REVOKE ALL ON FUNCTION public.check_device_send_limit(text,integer) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.check_device_send_limit(text,integer) TO service_role;

REVOKE ALL ON FUNCTION public.check_phone_send_limit(text,integer) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.check_phone_send_limit(text,integer) TO service_role;

REVOKE ALL ON FUNCTION public.check_registration_allowed(text,text,text,text) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.check_registration_allowed(text,text,text,text) TO service_role;

REVOKE ALL ON FUNCTION public.check_user_profile_access(text) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.check_user_profile_access(text) TO service_role, authenticated;

REVOKE ALL ON FUNCTION public.cleanup_expired_rate_limits() FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.cleanup_expired_rate_limits() TO service_role;

REVOKE ALL ON FUNCTION public.cleanup_expired_vcode_records() FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.cleanup_expired_vcode_records() TO service_role;

REVOKE ALL ON FUNCTION public.cleanup_old_attempts() FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.cleanup_old_attempts() TO service_role;

REVOKE ALL ON FUNCTION public.cleanup_old_idempotent_requests() FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.cleanup_old_idempotent_requests() TO service_role;

REVOKE ALL ON FUNCTION public.commit_device_identity_rotation_v6(uuid,uuid,uuid,text,bigint,text,text,text,timestamp with time zone) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.commit_device_identity_rotation_v6(uuid,uuid,uuid,text,bigint,text,text,text,timestamp with time zone) TO service_role;

REVOKE ALL ON FUNCTION public.confirm_device_enrollment_v5(uuid,uuid,text,text,text,text,text,text,text) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.confirm_device_enrollment_v5(uuid,uuid,text,text,text,text,text,text,text) TO service_role;

REVOKE ALL ON FUNCTION public.count_recent_device_attempts(text,integer) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.count_recent_device_attempts(text,integer) TO service_role;

REVOKE ALL ON FUNCTION public.count_recent_ip_attempts(text,integer) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.count_recent_ip_attempts(text,integer) TO service_role;

REVOKE ALL ON FUNCTION public.detect_suspicious_behavior(text,integer,integer) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.detect_suspicious_behavior(text,integer,integer) TO service_role;

REVOKE ALL ON FUNCTION public.enroll_first_device_v5(text,uuid,uuid,text,text,text,text,uuid) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.enroll_first_device_v5(text,uuid,uuid,text,text,text,text,uuid) TO service_role;

REVOKE ALL ON FUNCTION public.ensure_avatar_universal_user(uuid) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.ensure_avatar_universal_user(uuid) TO service_role;

REVOKE ALL ON FUNCTION public.ensure_tenant_security_policy_v5(uuid) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.ensure_tenant_security_policy_v5(uuid) TO service_role;

REVOKE ALL ON FUNCTION public.expire_device_identity_grace_v6(integer) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.expire_device_identity_grace_v6(integer) TO service_role;

REVOKE ALL ON FUNCTION public.generate_unique_nebula_id() FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.generate_unique_nebula_id() TO service_role;

REVOKE ALL ON FUNCTION public.get_best_channel(text) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.get_best_channel(text) TO service_role;

REVOKE ALL ON FUNCTION public.get_email_by_nebula_id(text) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.get_email_by_nebula_id(text) TO service_role;

REVOKE ALL ON FUNCTION public.get_user_binding_status(uuid) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.get_user_binding_status(uuid) TO service_role, authenticated;

REVOKE ALL ON FUNCTION public.guard_registration_attempt_v1(text,text,text,text,text,text) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.guard_registration_attempt_v1(text,text,text,text,text,text) TO service_role, authenticated, anon;

REVOKE ALL ON FUNCTION public.handle_new_user() FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.handle_new_user() TO service_role;

REVOKE ALL ON FUNCTION public.hook_skybridge_before_user_created_v1(jsonb) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.hook_skybridge_before_user_created_v1(jsonb) TO service_role, supabase_auth_admin;

REVOKE ALL ON FUNCTION public.is_device_blacklisted(text) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.is_device_blacklisted(text) TO service_role;

REVOKE ALL ON FUNCTION public.is_disposable_email(text) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.is_disposable_email(text) TO service_role;

REVOKE ALL ON FUNCTION public.is_ip_blacklisted(text) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.is_ip_blacklisted(text) TO service_role;

REVOKE ALL ON FUNCTION public.issue_device_identity_rotation_v6(uuid,uuid,uuid,uuid,text,bigint,text,text,text,text,text,text,text,text,timestamp with time zone) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.issue_device_identity_rotation_v6(uuid,uuid,uuid,uuid,text,bigint,text,text,text,text,text,text,text,text,timestamp with time zone) TO service_role;

REVOKE ALL ON FUNCTION public.nextval(text) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.nextval(text) TO service_role;

REVOKE ALL ON FUNCTION public.record_registration_attempt_v1(text,text,text,text,boolean,text,boolean,boolean,text,jsonb) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.record_registration_attempt_v1(text,text,text,text,boolean,text,boolean,boolean,text,jsonb) TO service_role, authenticated, anon;

REVOKE ALL ON FUNCTION public.resolve_registration_request_ip_v1() FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.resolve_registration_request_ip_v1() TO service_role;

REVOKE ALL ON FUNCTION public.sync_tenant_security_policy_for_auth_user_v5() FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.sync_tenant_security_policy_for_auth_user_v5() TO service_role;

REVOKE ALL ON FUNCTION public.touch_registered_device_presence_v7(uuid,uuid,text,text,text,text,text,text,text,text,text[],text,text[]) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.touch_registered_device_presence_v7(uuid,uuid,text,text,text,text,text,text,text,text,text[],text,text[]) TO service_role;

REVOKE ALL ON FUNCTION public.unbind_contact_method(text,text,inet,text) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.unbind_contact_method(text,text,inet,text) TO service_role, authenticated;

REVOKE ALL ON FUNCTION public.update_channel_stats(text,boolean,integer) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.update_channel_stats(text,boolean,integer) TO service_role;

REVOKE ALL ON FUNCTION public.verify_verification_code(text,text,text,text) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.verify_verification_code(text,text,text,text) TO service_role;

-- RLS does not protect TRUNCATE. Rebuild table grants from the reviewed
-- policy contract, preserving service access and only intended client commands.
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM PUBLIC, anon, authenticated;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.constellations, public.disposable_email_domains TO anon, authenticated;

-- Code issuance/verification and binding audit writes belong to trusted servers.
DROP POLICY "System can manage verification codes" ON public.verification_codes;
DROP POLICY "Users can view own verification codes" ON public.verification_codes;
CREATE POLICY verification_codes_service_only ON public.verification_codes
    FOR ALL TO service_role USING (true) WITH CHECK (true);
ALTER POLICY "System can insert binding records" ON public.account_bindings TO service_role;
DROP POLICY profiles_select_own ON public.profiles;
DROP POLICY user_profiles_select_own ON public.user_profiles;


ALTER POLICY "Users can view own binding history" ON public."account_bindings" TO authenticated USING (((SELECT auth.uid()) = user_id));

ALTER POLICY "用户只能访问相关的账户关联" ON public."account_links" TO authenticated USING ((((primary_user_id)::text = ((SELECT auth.uid()))::text) OR ((linked_user_id)::text = ((SELECT auth.uid()))::text))) WITH CHECK ((((primary_user_id)::text = ((SELECT auth.uid()))::text) OR ((linked_user_id)::text = ((SELECT auth.uid()))::text)));

ALTER POLICY "用户只能查看自己的活动日志" ON public."activity_logs" TO authenticated USING ((user_id = (SELECT auth.uid())));

ALTER POLICY "用户只能访问自己的认证方法" ON public."auth_methods" TO authenticated USING (((user_id)::text = ((SELECT auth.uid()))::text)) WITH CHECK (((user_id)::text = ((SELECT auth.uid()))::text));

ALTER POLICY "idempotent_requests_user_access" ON public."idempotent_requests" TO authenticated USING ((((SELECT auth.uid()))::text = user_id)) WITH CHECK ((((SELECT auth.uid()))::text = user_id));

ALTER POLICY "用户只能更新自己的星云账户" ON public."nebula_accounts" TO authenticated USING ((( SELECT auth.uid() AS uid) = id)) WITH CHECK ((( SELECT auth.uid() AS uid) = id));

ALTER POLICY "用户只能读取自己的星云账户" ON public."nebula_accounts" TO authenticated USING ((( SELECT auth.uid() AS uid) = id));

ALTER POLICY "用户插入自己的星云账户" ON public."nebula_accounts" TO authenticated WITH CHECK ((( SELECT auth.uid() AS uid) = id));

ALTER POLICY "enterprise_notifications_user_access" ON public."notifications" TO authenticated USING (check_user_profile_access(user_id)) WITH CHECK (check_user_profile_access(user_id));

ALTER POLICY "用户只能访问自己的OAuth账户" ON public."oauth_accounts" TO authenticated USING (((user_id)::text = ((SELECT auth.uid()))::text)) WITH CHECK (((user_id)::text = ((SELECT auth.uid()))::text));

ALTER POLICY "用户只能访问自己的手机认证" ON public."phone_auth" TO authenticated USING (((user_id)::text = ((SELECT auth.uid()))::text)) WITH CHECK (((user_id)::text = ((SELECT auth.uid()))::text));

ALTER POLICY "Users can insert own profile" ON public."profiles" TO authenticated WITH CHECK (((SELECT auth.uid()) = id));

ALTER POLICY "Users can update own profile" ON public."profiles" TO authenticated USING (((SELECT auth.uid()) = id)) WITH CHECK (((SELECT auth.uid()) = id));

ALTER POLICY "Users can view own profile" ON public."profiles" TO authenticated USING (((SELECT auth.uid()) = id));

ALTER POLICY "用户只能访问自己的同步状态" ON public."sync_status" TO authenticated USING ((user_id = (SELECT auth.uid()))) WITH CHECK ((user_id = (SELECT auth.uid())));

ALTER POLICY "用户只能访问自己的记录" ON public."universal_users" TO authenticated USING ((((SELECT auth.uid()))::text = (id)::text)) WITH CHECK ((((SELECT auth.uid()))::text = (id)::text));

ALTER POLICY "Allow users to insert their own activity" ON public."user_activity" TO authenticated WITH CHECK ((((SELECT auth.uid()))::text = user_id));

ALTER POLICY "Allow users to view their own activity" ON public."user_activity" TO authenticated USING ((((SELECT auth.uid()))::text = user_id));

ALTER POLICY "用户只能访问自己的头像" ON public."user_avatars" TO authenticated USING ((user_id = (SELECT auth.uid()))) WITH CHECK ((user_id = (SELECT auth.uid())));

ALTER POLICY "Users can insert own profile" ON public."user_profiles" TO authenticated WITH CHECK (((SELECT auth.uid()) = id));

ALTER POLICY "Users can update own profile" ON public."user_profiles" TO authenticated USING (((SELECT auth.uid()) = id)) WITH CHECK (((SELECT auth.uid()) = id));

ALTER POLICY "Users can view own profile" ON public."user_profiles" TO authenticated USING (((SELECT auth.uid()) = id));

ALTER POLICY "用户只能访问自己的会话" ON public."user_sessions" TO authenticated USING (((user_id)::text = ((SELECT auth.uid()))::text)) WITH CHECK (((user_id)::text = ((SELECT auth.uid()))::text));

ALTER POLICY "enterprise_settings_user_access" ON public."user_settings" TO authenticated USING (check_user_profile_access(user_id)) WITH CHECK (check_user_profile_access(user_id));

ALTER POLICY "用户只能访问自己的用户名修改限制" ON public."username_change_limits" TO authenticated USING ((user_id = (SELECT auth.uid()))) WITH CHECK ((user_id = (SELECT auth.uid())));

ALTER POLICY "用户只能查看自己的用户名历史" ON public."username_history" TO authenticated USING ((user_id = (SELECT auth.uid())));

GRANT SELECT ON public."account_bindings" TO authenticated;

GRANT DELETE, INSERT, SELECT, UPDATE ON public."account_links" TO authenticated;

GRANT SELECT ON public."activity_logs" TO authenticated;

GRANT DELETE, INSERT, SELECT, UPDATE ON public."auth_methods" TO authenticated;

GRANT DELETE, INSERT, SELECT, UPDATE ON public."idempotent_requests" TO authenticated;

GRANT INSERT, SELECT, UPDATE ON public."nebula_accounts" TO authenticated;

GRANT DELETE, INSERT, SELECT, UPDATE ON public."notifications" TO authenticated;

GRANT DELETE, INSERT, SELECT, UPDATE ON public."oauth_accounts" TO authenticated;

GRANT DELETE, INSERT, SELECT, UPDATE ON public."phone_auth" TO authenticated;

GRANT INSERT, SELECT, UPDATE ON public."profiles" TO authenticated;

GRANT DELETE, INSERT, SELECT, UPDATE ON public."sync_status" TO authenticated;

GRANT DELETE, INSERT, SELECT, UPDATE ON public."universal_users" TO authenticated;

GRANT INSERT, SELECT ON public."user_activity" TO authenticated;

GRANT DELETE, INSERT, SELECT, UPDATE ON public."user_avatars" TO authenticated;

GRANT INSERT, SELECT, UPDATE ON public."user_profiles" TO authenticated;

GRANT DELETE, INSERT, SELECT, UPDATE ON public."user_sessions" TO authenticated;

GRANT DELETE, INSERT, SELECT, UPDATE ON public."user_settings" TO authenticated;

GRANT DELETE, INSERT, SELECT, UPDATE ON public."username_change_limits" TO authenticated;

GRANT SELECT ON public."username_history" TO authenticated;

GRANT USAGE ON SEQUENCE public.user_settings_id_seq TO authenticated;

-- Tables are under 128 KiB in the inspected snapshot. Bound locking and
-- refuse to do blocking index builds if the data has grown substantially.
DO $size_guard$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
               WHERE n.nspname='public' AND c.relkind='r'
                 AND pg_total_relation_size(c.oid) > 67108864) THEN
        RAISE EXCEPTION 'Review table growth and use a separate concurrent index rollout';
    END IF;
END
$size_guard$;


CREATE INDEX IF NOT EXISTS "account_links_linked_user_id_idx" ON public."account_links" (linked_user_id);

CREATE INDEX IF NOT EXISTS "device_groups_owner_id_idx" ON public."device_groups" (owner_id);

CREATE INDEX IF NOT EXISTS "device_identity_history_source_rotation_id_idx" ON public."device_identity_history" (source_rotation_id);

CREATE INDEX IF NOT EXISTS "nebula_accounts_user_id_idx" ON public."nebula_accounts" (user_id);

CREATE INDEX IF NOT EXISTS "nebula_privileges_nebula_id_idx" ON public."nebula_privileges" (nebula_id);

CREATE INDEX IF NOT EXISTS "nebula_security_logs_nebula_id_idx" ON public."nebula_security_logs" (nebula_id);

CREATE INDEX IF NOT EXISTS "nebula_sessions_nebula_id_idx" ON public."nebula_sessions" (nebula_id);

CREATE INDEX IF NOT EXISTS "oauth_accounts_user_id_idx" ON public."oauth_accounts" (user_id);

CREATE INDEX IF NOT EXISTS "phone_auth_user_id_idx" ON public."phone_auth" (user_id);

CREATE INDEX IF NOT EXISTS "registration_blacklist_created_by_idx" ON public."registration_blacklist" (created_by);

CREATE INDEX IF NOT EXISTS "user_preferences_user_id_idx" ON public."user_preferences" (user_id);

CREATE INDEX IF NOT EXISTS "user_sessions_auth_method_id_idx" ON public."user_sessions" (auth_method_id);

CREATE INDEX IF NOT EXISTS "username_history_changed_by_user_id_idx" ON public."username_history" (changed_by_user_id);

NOTIFY pgrst, 'reload schema';
COMMIT;
