-- SkyBridge client-role lock-down for tenant policy and enrollment invites (v8).
-- Canonical deployment path:
-- supabase/migrations/20260905130000_lock_down_tenant_policy_and_enrollment_invites_v8.sql
-- The copy under Server/skybridge-signaling/sql is a byte-for-byte operational
-- mirror; Server tests reject any drift between the two files.
--
-- Why:
--   public.tenant_security_policy and public.device_enrollment_invites were
--   created by security_v5 without row level security and without revoking the
--   default Supabase client-role grants. With the shipped anon key a client
--   could therefore read every tenant's policy row, flip
--   public_signaling_enabled / allowlist_only, or insert an enrollment invite
--   whose token hash it chose itself and then redeem it, bypassing the
--   admin-issued enrollment flow.
--
--   Every legitimate access path is either the signaling server (service_role,
--   direct PostgREST read of tenant_security_policy in lib/registry_store.js)
--   or a SECURITY DEFINER RPC (ensure_tenant_security_policy_v5,
--   enroll_first_device_v5, confirm_device_enrollment_v5,
--   bootstrap_register_device_v5). None of them depends on client-role table
--   privileges, so nothing shipped in this repository loses access.
--
--   v8 does for these two tables exactly what v6 did for the identity-rotation
--   tables and v7 did for registered_devices: enable RLS, revoke the client
--   roles, grant service_role, and fail closed if the boundary is not in
--   place afterwards. No policies are created on purpose: service_role
--   bypasses RLS and every other role must see zero rows.
--
-- Operational note: an external admin tool that reached these tables through
-- the anon or authenticated role would stop working after v8. That is the
-- intended outcome; such a tool must use service_role or a SECURITY DEFINER
-- RPC instead.
--
-- Idempotent: safe to re-run. Touches privileges only; no data is modified.

begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';

-- 1) tenant_security_policy ---------------------------------------------------------

alter table public.tenant_security_policy enable row level security;

revoke all privileges on table public.tenant_security_policy
    from public, anon, authenticated;

grant select, insert, update, delete
    on table public.tenant_security_policy
    to service_role;

-- 2) device_enrollment_invites --------------------------------------------------------

alter table public.device_enrollment_invites enable row level security;

revoke all privileges on table public.device_enrollment_invites
    from public, anon, authenticated;

grant select, insert, update, delete
    on table public.device_enrollment_invites
    to service_role;

grant usage, select on sequence public.device_enrollment_invites_id_seq to service_role;

-- 3) fail-closed self check --------------------------------------------------------

do $$
begin
    if not exists (
        select 1
          from pg_class c
          join pg_namespace n on n.oid = c.relnamespace
         where n.nspname = 'public'
           and c.relname = 'tenant_security_policy'
           and c.relrowsecurity
    ) then
        raise exception 'security_v8_tenant_security_policy_rls_disabled';
    end if;
    if has_table_privilege('anon', 'public.tenant_security_policy', 'SELECT')
       or has_table_privilege('anon', 'public.tenant_security_policy', 'INSERT')
       or has_table_privilege('anon', 'public.tenant_security_policy', 'UPDATE')
       or has_table_privilege('authenticated', 'public.tenant_security_policy', 'SELECT')
       or has_table_privilege('authenticated', 'public.tenant_security_policy', 'INSERT')
       or has_table_privilege('authenticated', 'public.tenant_security_policy', 'UPDATE') then
        raise exception 'security_v8_tenant_security_policy_exposed_to_client_roles';
    end if;
    if not has_table_privilege('service_role', 'public.tenant_security_policy', 'SELECT') then
        raise exception 'security_v8_tenant_security_policy_missing_service_role_grant';
    end if;

    if not exists (
        select 1
          from pg_class c
          join pg_namespace n on n.oid = c.relnamespace
         where n.nspname = 'public'
           and c.relname = 'device_enrollment_invites'
           and c.relrowsecurity
    ) then
        raise exception 'security_v8_device_enrollment_invites_rls_disabled';
    end if;
    if has_table_privilege('anon', 'public.device_enrollment_invites', 'SELECT')
       or has_table_privilege('anon', 'public.device_enrollment_invites', 'INSERT')
       or has_table_privilege('anon', 'public.device_enrollment_invites', 'UPDATE')
       or has_table_privilege('authenticated', 'public.device_enrollment_invites', 'SELECT')
       or has_table_privilege('authenticated', 'public.device_enrollment_invites', 'INSERT')
       or has_table_privilege('authenticated', 'public.device_enrollment_invites', 'UPDATE') then
        raise exception 'security_v8_device_enrollment_invites_exposed_to_client_roles';
    end if;
    if not has_table_privilege('service_role', 'public.device_enrollment_invites', 'SELECT') then
        raise exception 'security_v8_device_enrollment_invites_missing_service_role_grant';
    end if;
end;
$$;

commit;
