-- Preserve the queue/result contract while moving extension registration out of
-- public. All objects stay in net. No CASCADE and no pg_catalog modifications.
BEGIN;
SET LOCAL lock_timeout = '3s';
SET LOCAL statement_timeout = '45s';

LOCK TABLE net.http_request_queue, net._http_response IN ACCESS EXCLUSIVE MODE;
DO $queue_guard$
BEGIN
    IF EXISTS (SELECT 1 FROM net.http_request_queue) THEN
        RAISE EXCEPTION 'pg_net queue must drain before extension maintenance';
    END IF;
END
$queue_guard$;

CREATE TEMP TABLE preserved_net_responses ON COMMIT DROP AS
    SELECT * FROM net._http_response;
CREATE TEMP TABLE preserved_net_sequence ON COMMIT DROP AS
    SELECT last_value, is_called FROM net.http_request_queue_id_seq;

DROP EXTENSION pg_net;
CREATE EXTENSION pg_net WITH SCHEMA extensions;

INSERT INTO net._http_response(id,status_code,content_type,headers,content,timed_out,error_msg,created)
    SELECT id,status_code,content_type,headers,content,timed_out,error_msg,created
    FROM preserved_net_responses;
SELECT pg_catalog.setval('net.http_request_queue_id_seq', last_value, is_called)
    FROM preserved_net_sequence;

-- Hosted Supabase owns net as supabase_admin. That owner cannot be impersonated
-- by postgres, and REVOKE by postgres is a warning-only no-op. Apply object ACLs
-- only where we own them (e.g. self-hosted/local PostgreSQL). On hosted projects,
-- the enforced boundary is NOLOGIN client roles plus an unexposed Data API schema;
-- the live gate checks /postgrest and rejects exposed net RPC bridges.
DO $net_privileges$
DECLARE owner_oid oid;
BEGIN
    SELECT nspowner INTO STRICT owner_oid FROM pg_namespace WHERE nspname='net';
    IF pg_has_role(current_user, owner_oid, 'MEMBER') THEN
        REVOKE ALL ON SCHEMA net FROM PUBLIC, anon, authenticated;
        REVOKE ALL ON ALL FUNCTIONS IN SCHEMA net FROM PUBLIC, anon, authenticated;
        REVOKE ALL ON ALL TABLES IN SCHEMA net FROM PUBLIC, anon, authenticated;
        REVOKE ALL ON ALL SEQUENCES IN SCHEMA net FROM PUBLIC, anon, authenticated;
        GRANT USAGE ON SCHEMA net TO service_role;
        GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA net TO service_role;
    ELSIF (SELECT count(*) FROM pg_roles WHERE rolname IN ('anon','authenticated') AND NOT rolcanlogin) <> 2 THEN
        RAISE EXCEPTION 'Managed net boundary requires NOLOGIN client roles';
    END IF;
END
$net_privileges$;

CREATE OR REPLACE PROCEDURE public.scheduled_maintenance_4ea8045d()
LANGUAGE plpgsql
SET search_path = pg_catalog, public, extensions, pg_temp
AS $procedure$
DECLARE
    maintenance_token text;
BEGIN
    SELECT decrypted_secret INTO STRICT maintenance_token
      FROM vault.decrypted_secrets WHERE name='skybridge_scheduled_maintenance_token';
    IF maintenance_token IS NULL OR maintenance_token !~ '^[0-9a-f]{64}$' THEN
        RAISE EXCEPTION 'maintenance credential is missing or invalid';
    END IF;
    PERFORM net.http_post(
        url := 'https://hloqytmhjludmuhwyyzb.supabase.co/functions/v1/scheduled-maintenance',
        headers := jsonb_build_object('Content-Type','application/json','Authorization','Bearer ' || maintenance_token),
        body := '{"edge_function_name":"scheduled-maintenance"}'::jsonb,
        timeout_milliseconds := 70000
    );
END
$procedure$;
REVOKE ALL ON PROCEDURE public.scheduled_maintenance_4ea8045d() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON PROCEDURE public.scheduled_maintenance_4ea8045d() TO service_role;

DO $verification$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname='pg_net' AND extnamespace='extensions'::regnamespace)
       OR (SELECT count(*) FROM net._http_response) <> (SELECT count(*) FROM preserved_net_responses) THEN
        RAISE EXCEPTION 'pg_net extension relocation did not preserve its contract';
    END IF;
END
$verification$;
NOTIFY pgrst, 'reload schema';
COMMIT;
