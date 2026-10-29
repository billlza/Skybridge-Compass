begin;

-- User metadata is writable by the owning Auth user and therefore cannot be an
-- administrative authority. These tables are internal control-plane state; remove
-- the legacy client-facing policies and deny every client database role at the
-- table-privilege boundary as well as at RLS.
drop policy if exists "Admin can manage blacklist"
    on public.registration_blacklist;
drop policy if exists "Admin can manage rate_limit_config"
    on public.rate_limit_config;

revoke all privileges on table public.registration_blacklist
    from public, anon, authenticated;
revoke all privileges on table public.rate_limit_config
    from public, anon, authenticated;

grant select, insert, update, delete
    on table public.registration_blacklist
    to service_role;
grant select, insert, update, delete
    on table public.rate_limit_config
    to service_role;

-- The registration and SMS helpers below execute with their owner privileges and
-- expose control-plane state or mutations. They are implementation details of the
-- guarded RPC/server paths, not client RPCs.
revoke all privileges on function public.is_ip_blacklisted(text)
    from public, anon, authenticated;
revoke all privileges on function public.is_device_blacklisted(text)
    from public, anon, authenticated;
revoke all privileges on function public.is_disposable_email(text)
    from public, anon, authenticated;
revoke all privileges on function public.count_recent_ip_attempts(text, integer)
    from public, anon, authenticated;
revoke all privileges on function public.count_recent_device_attempts(text, integer)
    from public, anon, authenticated;
revoke all privileges on function public.check_registration_allowed(text, text, text, text)
    from public, anon, authenticated;
revoke all privileges on function public.cleanup_old_attempts()
    from public, anon, authenticated;

grant execute on function public.is_ip_blacklisted(text) to service_role;
grant execute on function public.is_device_blacklisted(text) to service_role;
grant execute on function public.is_disposable_email(text) to service_role;
grant execute on function public.count_recent_ip_attempts(text, integer) to service_role;
grant execute on function public.count_recent_device_attempts(text, integer) to service_role;
grant execute on function public.check_registration_allowed(text, text, text, text) to service_role;
grant execute on function public.cleanup_old_attempts() to service_role;

revoke all privileges on function public.check_phone_send_limit(text, integer)
    from public, anon, authenticated;
revoke all privileges on function public.check_device_send_limit(text, integer)
    from public, anon, authenticated;
revoke all privileges on function public.detect_suspicious_behavior(text, integer, integer)
    from public, anon, authenticated;
revoke all privileges on function public.get_best_channel(text)
    from public, anon, authenticated;
revoke all privileges on function public.update_channel_stats(text, boolean, integer)
    from public, anon, authenticated;
revoke all privileges on function public.cleanup_expired_vcode_records()
    from public, anon, authenticated;
revoke all privileges on function public.cleanup_expired_rate_limits()
    from public, anon, authenticated;

grant execute on function public.check_phone_send_limit(text, integer) to service_role;
grant execute on function public.check_device_send_limit(text, integer) to service_role;
grant execute on function public.detect_suspicious_behavior(text, integer, integer) to service_role;
grant execute on function public.get_best_channel(text) to service_role;
grant execute on function public.update_channel_stats(text, boolean, integer) to service_role;
grant execute on function public.cleanup_expired_vcode_records() to service_role;
grant execute on function public.cleanup_expired_rate_limits() to service_role;

-- This evaluator is called through the guarded registration RPC and is intended to
-- remain server-only. CREATE FUNCTION grants EXECUTE to PUBLIC by default, so make
-- the intended service-only boundary explicit.
revoke all privileges on function public.check_auth_attempt_allowed_v1(text, text, text, text, text)
    from public, anon, authenticated;
grant execute on function public.check_auth_attempt_allowed_v1(text, text, text, text, text)
    to service_role;

-- avatar_finalize_upload invokes both functions as their SECURITY DEFINER owner.
-- Neither helper is a supported direct client RPC.
revoke all privileges on function public.assert_avatar_backend_ready()
    from public, anon, authenticated;
revoke all privileges on function public.ensure_avatar_universal_user(uuid)
    from public, anon, authenticated;
grant execute on function public.assert_avatar_backend_ready() to service_role;
grant execute on function public.ensure_avatar_universal_user(uuid) to service_role;

-- Preserve the deliberate client surface while removing the broader implicit PUBLIC
-- grant that is recreated whenever these functions are dropped and recreated.
revoke all privileges on function public.guard_registration_attempt_v1(
    text, text, text, text, text, text
) from public;
revoke all privileges on function public.record_registration_attempt_v1(
    text, text, text, text, boolean, text, boolean, boolean, text, jsonb
) from public;

grant execute on function public.guard_registration_attempt_v1(
    text, text, text, text, text, text
) to anon, authenticated, service_role;
grant execute on function public.record_registration_attempt_v1(
    text, text, text, text, boolean, text, boolean, boolean, text, jsonb
) to anon, authenticated, service_role;

commit;
