-- Auth login guard acceptance checks.
--
-- Run in Supabase SQL editor after applying:
--   20260424173000_scope_auth_risk_by_attempt_type.sql
--   20260424190000_decouple_login_from_registration_guard.sql

DELETE FROM public.registration_attempts
WHERE device_fingerprint = 'sql-probe-device'
   OR metadata ->> 'probe' = 'auth_login_guard_acceptance';

DELETE FROM public.registration_attempt_tickets
WHERE device_fingerprint = 'sql-probe-device';

SELECT
  p.proname,
  pg_catalog.oidvectortypes(p.proargtypes) AS args
FROM pg_catalog.pg_proc p
JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname IN (
    'check_auth_attempt_allowed_v1',
    'guard_registration_attempt_v1',
    'record_registration_attempt_v1'
  )
ORDER BY p.proname, args;

SELECT
  COUNT(*) AS login_attempt_rows_before_probe
FROM public.registration_attempts
WHERE metadata ->> 'probe' = 'auth_login_guard_acceptance'
  AND attempt_type = 'login';

SELECT
  COUNT(*) AS login_tickets_before_probe
FROM public.registration_attempt_tickets
WHERE device_fingerprint = 'sql-probe-device'
  AND attempt_type = 'login';

WITH decision AS (
  SELECT *
    FROM public.guard_registration_attempt_v1(
      encode(extensions.digest('login-guard-sql-probe@example.invalid', 'sha256'), 'hex'),
      'email',
      'login-guard-sql-probe@example.invalid',
      'sql-probe-device',
      'login',
      'login'
    )
)
SELECT
  allowed,
  requires_captcha,
  audit_ticket IS NOT NULL AS issued_login_audit_ticket
FROM decision;

WITH decision AS (
  SELECT *
    FROM public.guard_registration_attempt_v1(
      encode(extensions.digest('login-guard-sql-probe@example.invalid', 'sha256'), 'hex'),
      'email',
      'login-guard-sql-probe@example.invalid',
      'sql-probe-device',
      'login',
      'login'
    )
)
SELECT public.record_registration_attempt_v1(
  'login-guard-sql-probe@example.invalid',
  'email',
  'sql-probe-device',
  'login',
  FALSE,
  'probe failed login',
  FALSE,
  FALSE,
  audit_ticket,
  '{"probe":"auth_login_guard_acceptance","attempt_type":"login"}'::jsonb
)
FROM decision
WHERE allowed = TRUE
  AND audit_ticket IS NOT NULL;

SELECT
  COUNT(*) AS login_attempt_rows_after_probe
FROM public.registration_attempts
WHERE metadata ->> 'probe' = 'auth_login_guard_acceptance'
  AND attempt_type = 'login';
