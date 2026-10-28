-- Schema-only regression fixture captured from the hosted project on 2026-09-29.;

-- Contains no user rows, credentials, or production sequence positions.;

-- The minimal auth/storage schemas below model the managed dependencies used by these tests.;

DO $$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='anon') THEN CREATE ROLE anon NOLOGIN; END IF; END $$;

DO $$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated NOLOGIN; END IF; END $$;

DO $$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='service_role') THEN CREATE ROLE service_role NOLOGIN BYPASSRLS; END IF; END $$;

DO $$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='supabase_auth_admin') THEN CREATE ROLE supabase_auth_admin NOLOGIN; END IF; END $$;

CREATE SCHEMA auth;

CREATE SCHEMA storage;

CREATE SCHEMA extensions;

GRANT USAGE ON SCHEMA public, auth, extensions TO anon, authenticated, service_role, supabase_auth_admin;

REVOKE CREATE ON SCHEMA public FROM PUBLIC;

CREATE EXTENSION pgcrypto WITH SCHEMA extensions;

CREATE EXTENSION "uuid-ossp" WITH SCHEMA extensions;

SET search_path = public, extensions;

CREATE TABLE auth.users (id uuid PRIMARY KEY, email text, created_at timestamptz DEFAULT now(), raw_user_meta_data jsonb DEFAULT '{}'::jsonb, raw_app_meta_data jsonb DEFAULT '{}'::jsonb);

CREATE TABLE storage.buckets (id text PRIMARY KEY, public boolean DEFAULT false);

CREATE TABLE storage.objects (id uuid DEFAULT gen_random_uuid() PRIMARY KEY, bucket_id text REFERENCES storage.buckets(id), name text, metadata jsonb);

CREATE OR REPLACE FUNCTION auth.uid()
 RETURNS uuid
 LANGUAGE sql
 STABLE
AS $function$
  select
  coalesce(
    nullif(current_setting('request.jwt.claim.sub', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
  )::uuid
$function$;

CREATE OR REPLACE FUNCTION auth.role()
 RETURNS text
 LANGUAGE sql
 STABLE
AS $function$
  select
  coalesce(
    nullif(current_setting('request.jwt.claim.role', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role')
  )::text
$function$;

CREATE OR REPLACE FUNCTION auth.jwt()
 RETURNS jsonb
 LANGUAGE sql
 STABLE
AS $function$
  select
    coalesce(
        nullif(current_setting('request.jwt.claim', true), ''),
        nullif(current_setting('request.jwt.claims', true), '')
    )::jsonb
$function$;

CREATE SEQUENCE public."constellation_data_id_seq" AS integer START WITH 1;

CREATE SEQUENCE public."nebula_id_seq" AS bigint START WITH 100000;

CREATE SEQUENCE public."nebula_id_sequence_id_seq" AS integer START WITH 1;

CREATE SEQUENCE public."user_settings_id_seq" AS integer START WITH 1;

CREATE TABLE public."account_bindings" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "user_id" uuid NOT NULL,
  "contact_type" character varying(10) NOT NULL,
  "contact_value" character varying(255) NOT NULL,
  "action" character varying(10) NOT NULL,
  "verification_code" character varying(6),
  "verified_at" timestamp with time zone,
  "ip_address" inet,
  "user_agent" text,
  "created_at" timestamp with time zone DEFAULT now()
);

ALTER TABLE public."account_bindings" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."account_links" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "primary_user_id" uuid NOT NULL,
  "linked_user_id" uuid NOT NULL,
  "link_type" text NOT NULL,
  "link_status" text DEFAULT 'active'::text NOT NULL,
  "linked_by_auth_method" text NOT NULL,
  "linked_at" timestamp with time zone DEFAULT now(),
  "metadata" jsonb DEFAULT '{}'::jsonb
);

ALTER TABLE public."account_links" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."activity_logs" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "user_id" uuid NOT NULL,
  "activity_type" text NOT NULL,
  "activity_description" text NOT NULL,
  "activity_data" jsonb DEFAULT '{}'::jsonb,
  "ip_address" inet,
  "user_agent" text,
  "device_id" uuid,
  "risk_level" text DEFAULT 'low'::text,
  "requires_action" boolean DEFAULT false,
  "created_at" timestamp with time zone DEFAULT now()
);

ALTER TABLE public."activity_logs" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."api_keys" (
  "id" uuid DEFAULT uuid_generate_v4() NOT NULL,
  "user_id" uuid,
  "api_key" character varying(100) NOT NULL,
  "api_key_name" character varying(100),
  "permissions" jsonb,
  "last_used_at" timestamp with time zone,
  "expires_at" timestamp with time zone,
  "is_active" boolean DEFAULT true,
  "created_at" timestamp with time zone DEFAULT now()
);

ALTER TABLE public."api_keys" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."audit_logs" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "table_name" text NOT NULL,
  "operation_type" text NOT NULL,
  "user_id" text,
  "old_values" jsonb,
  "new_values" jsonb,
  "timestamp" timestamp with time zone DEFAULT now(),
  "ip_address" inet,
  "user_agent" text,
  "session_id" text
);

ALTER TABLE public."audit_logs" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."auth_methods" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "user_id" uuid NOT NULL,
  "auth_type" text NOT NULL,
  "auth_provider" text,
  "identifier" text NOT NULL,
  "is_primary" boolean DEFAULT false,
  "is_verified" boolean DEFAULT false,
  "verification_token" text,
  "verification_expires_at" timestamp with time zone,
  "last_used_at" timestamp with time zone,
  "created_at" timestamp with time zone DEFAULT now(),
  "metadata" jsonb DEFAULT '{}'::jsonb
);

ALTER TABLE public."auth_methods" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."cli_login_sessions" (
  "session_id" uuid NOT NULL,
  "client_id" text NOT NULL,
  "code_challenge" text NOT NULL,
  "redirect_uri" text NOT NULL,
  "state" text NOT NULL,
  "status" text NOT NULL,
  "auth_code_hash" text,
  "auth_user_id" uuid,
  "encrypted_access_token" text,
  "encrypted_refresh_token" text,
  "user_identifier" text,
  "display_name" text,
  "approved_at" timestamp with time zone,
  "consumed_at" timestamp with time zone,
  "expires_at" timestamp with time zone NOT NULL,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "cli_metadata" jsonb DEFAULT '{}'::jsonb NOT NULL
);

CREATE TABLE public."constellation_data" (
  "id" integer DEFAULT nextval('constellation_data_id_seq'::regclass) NOT NULL,
  "code" character varying(3) NOT NULL,
  "name_zh" character varying(20) NOT NULL,
  "name_en" character varying(20) NOT NULL,
  "symbol" character varying(10) NOT NULL,
  "color_primary" character varying(7) NOT NULL,
  "color_secondary" character varying(7) NOT NULL,
  "star_pattern" jsonb DEFAULT '{}'::jsonb,
  "description" text,
  "is_active" boolean DEFAULT true
);

ALTER TABLE public."constellation_data" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."constellations" (
  "id" bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
  "name" text NOT NULL,
  "code" character varying(3) NOT NULL,
  "description" text,
  "color_primary" character varying(7) DEFAULT '#4F46E5'::character varying,
  "color_secondary" character varying(7) DEFAULT '#7C3AED'::character varying,
  "created_at" timestamp with time zone DEFAULT now()
);

ALTER TABLE public."constellations" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."contact_submissions" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "user_id" uuid,
  "full_name" text NOT NULL,
  "email" text NOT NULL,
  "phone" text,
  "company_name" text,
  "message" text NOT NULL,
  "status" text DEFAULT 'pending'::text,
  "created_at" timestamp with time zone DEFAULT timezone('utc'::text, now()) NOT NULL,
  "updated_at" timestamp with time zone DEFAULT timezone('utc'::text, now()) NOT NULL,
  "message_type" text DEFAULT 'other'::text
);

ALTER TABLE public."contact_submissions" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."device_connections" (
  "id" uuid DEFAULT uuid_generate_v4() NOT NULL,
  "controller_device_id" uuid NOT NULL,
  "target_device_id" uuid NOT NULL,
  "connection_type" character varying(20) NOT NULL,
  "connection_status" character varying(20) DEFAULT 'pending'::character varying,
  "connection_data" jsonb,
  "established_at" timestamp with time zone,
  "disconnected_at" timestamp with time zone,
  "created_at" timestamp with time zone DEFAULT now()
);

ALTER TABLE public."device_connections" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."device_enrollment_invites" (
  "id" bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
  "invite_token_hash" text NOT NULL,
  "tenant_id" uuid NOT NULL,
  "target_user_id" uuid NOT NULL,
  "state" text NOT NULL,
  "issued_by" uuid,
  "issued_channel" text NOT NULL,
  "delivered_at" timestamp with time zone,
  "viewed_at" timestamp with time zone,
  "consumed_at" timestamp with time zone,
  "resent_count" integer DEFAULT 0 NOT NULL,
  "revoked_at" timestamp with time zone,
  "expires_at" timestamp with time zone NOT NULL,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL
);

ALTER TABLE public."device_enrollment_invites" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."device_group_members" (
  "id" uuid DEFAULT uuid_generate_v4() NOT NULL,
  "group_id" uuid NOT NULL,
  "device_id" uuid NOT NULL,
  "added_at" timestamp with time zone DEFAULT now()
);

ALTER TABLE public."device_group_members" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."device_groups" (
  "id" uuid DEFAULT uuid_generate_v4() NOT NULL,
  "owner_id" uuid,
  "group_name" character varying(100) NOT NULL,
  "description" text,
  "group_icon" character varying(50),
  "created_at" timestamp with time zone DEFAULT now(),
  "updated_at" timestamp with time zone DEFAULT now()
);

ALTER TABLE public."device_groups" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."device_identity_history" (
  "id" bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
  "tenant_id" uuid NOT NULL,
  "user_id" uuid NOT NULL,
  "device_id" text NOT NULL,
  "generation" bigint NOT NULL,
  "protocol_signing_algorithm" text NOT NULL,
  "protocol_public_key_fingerprint" text NOT NULL,
  "protocol_public_key_base64" text,
  "state" text NOT NULL,
  "activated_at" timestamp with time zone NOT NULL,
  "grace_started_at" timestamp with time zone,
  "grace_expires_at" timestamp with time zone,
  "revoked_at" timestamp with time zone,
  "source_rotation_id" uuid,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL
);

ALTER TABLE public."device_identity_history" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."device_identity_rotation_audit" (
  "id" bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
  "rotation_id" uuid NOT NULL,
  "tenant_id" uuid NOT NULL,
  "user_id" uuid NOT NULL,
  "device_id" text NOT NULL,
  "event_type" text NOT NULL,
  "transcript_hash" text NOT NULL,
  "details" jsonb DEFAULT '{}'::jsonb NOT NULL,
  "occurred_at" timestamp with time zone DEFAULT now() NOT NULL
);

ALTER TABLE public."device_identity_rotation_audit" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."device_identity_rotations" (
  "rotation_id" uuid NOT NULL,
  "request_id" uuid NOT NULL,
  "tenant_id" uuid NOT NULL,
  "user_id" uuid NOT NULL,
  "device_id" text NOT NULL,
  "old_generation" bigint NOT NULL,
  "old_protocol_signing_algorithm" text NOT NULL,
  "old_protocol_public_key_fingerprint" text NOT NULL,
  "old_protocol_public_key_base64" text NOT NULL,
  "new_protocol_signing_algorithm" text NOT NULL,
  "new_protocol_public_key_fingerprint" text NOT NULL,
  "new_protocol_public_key_base64" text NOT NULL,
  "nonce" text NOT NULL,
  "transcript_hash" text NOT NULL,
  "state" text NOT NULL,
  "issued_at" timestamp with time zone NOT NULL,
  "expires_at" timestamp with time zone NOT NULL,
  "committed_at" timestamp with time zone,
  "committed_generation" bigint,
  "grace_expires_at" timestamp with time zone,
  "result" jsonb
);

ALTER TABLE public."device_identity_rotations" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."device_pairings" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "initiator_user_id" uuid NOT NULL,
  "target_user_id" uuid NOT NULL,
  "target_device_id" uuid NOT NULL,
  "pairing_code" character varying(20) NOT NULL,
  "status" character varying(20) DEFAULT 'pending'::character varying,
  "expires_at" timestamp with time zone DEFAULT (now() + '00:10:00'::interval),
  "completed_at" timestamp with time zone,
  "permissions" jsonb DEFAULT '{}'::jsonb,
  "created_at" timestamp with time zone DEFAULT now(),
  "updated_at" timestamp with time zone DEFAULT now()
);

ALTER TABLE public."device_pairings" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."device_permissions" (
  "id" uuid DEFAULT uuid_generate_v4() NOT NULL,
  "controller_device_id" uuid NOT NULL,
  "target_device_id" uuid NOT NULL,
  "permission_type" character varying(50) NOT NULL,
  "granted_by" uuid,
  "expires_at" timestamp with time zone,
  "is_active" boolean DEFAULT true,
  "created_at" timestamp with time zone DEFAULT now()
);

ALTER TABLE public."device_permissions" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."devices" (
  "id" uuid DEFAULT uuid_generate_v4() NOT NULL,
  "owner_id" uuid,
  "device_name" character varying(100) NOT NULL,
  "device_type" character varying(50) NOT NULL,
  "platform" character varying(20) NOT NULL,
  "model" character varying(100),
  "os_version" character varying(50),
  "app_version" character varying(20),
  "device_token" text,
  "last_ip_address" inet,
  "last_location" jsonb,
  "is_online" boolean DEFAULT false,
  "last_seen_at" timestamp with time zone,
  "created_at" timestamp with time zone DEFAULT now(),
  "updated_at" timestamp with time zone DEFAULT now()
);

ALTER TABLE public."devices" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."disposable_email_domains" (
  "domain" text NOT NULL,
  "added_at" timestamp with time zone DEFAULT now(),
  "source" text DEFAULT 'manual'::text
);

ALTER TABLE public."disposable_email_domains" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."file_transfers" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "session_id" uuid NOT NULL,
  "file_name" character varying(255) NOT NULL,
  "file_size" bigint NOT NULL,
  "file_type" character varying(100),
  "file_path" text,
  "transfer_direction" character varying(20) NOT NULL,
  "progress_percentage" integer DEFAULT 0,
  "status" character varying(20) DEFAULT 'pending'::character varying,
  "started_at" timestamp with time zone DEFAULT now(),
  "completed_at" timestamp with time zone,
  "created_at" timestamp with time zone DEFAULT now(),
  "updated_at" timestamp with time zone DEFAULT now()
);

ALTER TABLE public."file_transfers" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."idempotent_requests" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "key" text NOT NULL,
  "user_id" text NOT NULL,
  "response_data" jsonb NOT NULL,
  "created_at" timestamp with time zone DEFAULT now()
);

ALTER TABLE public."idempotent_requests" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."mfa_settings" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "user_id" uuid NOT NULL,
  "is_enabled" boolean DEFAULT false,
  "totp_secret" text,
  "backup_codes" text[],
  "sms_phone" character varying(50),
  "preferred_method" character varying(20) DEFAULT 'totp'::character varying,
  "biometric_enabled" boolean DEFAULT false,
  "created_at" timestamp with time zone DEFAULT now(),
  "updated_at" timestamp with time zone DEFAULT now()
);

ALTER TABLE public."mfa_settings" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."nebula_accounts" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "nebula_id" character varying(20) NOT NULL,
  "constellation_code" character varying(3) NOT NULL,
  "constellation_name" character varying(20) NOT NULL,
  "created_at" timestamp with time zone DEFAULT now(),
  "updated_at" timestamp with time zone DEFAULT now(),
  "user_id" uuid,
  "display_name" character varying(100),
  "avatar_url" text,
  "cosmic_salt" character varying(64) NOT NULL,
  "is_active" boolean DEFAULT true,
  "last_login_at" timestamp with time zone,
  "metadata" jsonb DEFAULT '{}'::jsonb,
  "constellation_id" bigint NOT NULL,
  "hashed_key" text NOT NULL
);

ALTER TABLE public."nebula_accounts" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."nebula_id_sequence" (
  "id" integer DEFAULT nextval('nebula_id_sequence_id_seq'::regclass) NOT NULL,
  "current_value" bigint DEFAULT 100000 NOT NULL,
  "max_value" bigint DEFAULT 9999999 NOT NULL,
  "created_at" timestamp with time zone DEFAULT now(),
  "updated_at" timestamp with time zone DEFAULT now()
);

ALTER TABLE public."nebula_id_sequence" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."nebula_privileges" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "nebula_id" character varying(20),
  "privilege_type" character varying(50) NOT NULL,
  "privilege_value" text,
  "granted_at" timestamp with time zone DEFAULT now(),
  "expires_at" timestamp with time zone,
  "is_active" boolean DEFAULT true,
  "metadata" jsonb DEFAULT '{}'::jsonb
);

ALTER TABLE public."nebula_privileges" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."nebula_security_logs" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "nebula_id" character varying(20),
  "action_type" character varying(50) NOT NULL,
  "action_details" jsonb DEFAULT '{}'::jsonb,
  "ip_address" inet,
  "user_agent" text,
  "success" boolean NOT NULL,
  "created_at" timestamp with time zone DEFAULT now(),
  "risk_level" character varying(20) DEFAULT 'low'::character varying
);

ALTER TABLE public."nebula_security_logs" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."nebula_sessions" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "nebula_id" character varying(20),
  "session_token" character varying(255) NOT NULL,
  "device_info" jsonb DEFAULT '{}'::jsonb,
  "ip_address" inet,
  "created_at" timestamp with time zone DEFAULT now(),
  "last_active_at" timestamp with time zone DEFAULT now(),
  "expires_at" timestamp with time zone NOT NULL,
  "is_active" boolean DEFAULT true
);

ALTER TABLE public."nebula_sessions" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."notifications" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "user_id" text NOT NULL,
  "notification_type" character varying(100) NOT NULL,
  "title" character varying(255) NOT NULL,
  "message" text NOT NULL,
  "data" jsonb DEFAULT '{}'::jsonb,
  "is_read" boolean DEFAULT false,
  "priority" character varying(20) DEFAULT 'normal'::character varying,
  "expires_at" timestamp with time zone,
  "created_at" timestamp with time zone DEFAULT now(),
  "updated_at" timestamp with time zone DEFAULT now()
);

ALTER TABLE public."notifications" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."oauth_accounts" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "user_id" uuid NOT NULL,
  "provider" text NOT NULL,
  "provider_user_id" text NOT NULL,
  "provider_email" text,
  "provider_name" text,
  "provider_avatar_url" text,
  "access_token_encrypted" text,
  "refresh_token_encrypted" text,
  "token_expires_at" timestamp with time zone,
  "scope" text,
  "created_at" timestamp with time zone DEFAULT now(),
  "updated_at" timestamp with time zone DEFAULT now(),
  "metadata" jsonb DEFAULT '{}'::jsonb
);

ALTER TABLE public."oauth_accounts" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."performance_metrics" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "session_id" uuid,
  "user_id" uuid,
  "metric_type" character varying(100) NOT NULL,
  "metric_value" numeric NOT NULL,
  "metric_unit" character varying(20),
  "device_info" jsonb DEFAULT '{}'::jsonb,
  "network_info" jsonb DEFAULT '{}'::jsonb,
  "timestamp" timestamp with time zone DEFAULT now(),
  "created_at" timestamp with time zone DEFAULT now()
);

ALTER TABLE public."performance_metrics" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."phone_auth" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "user_id" uuid,
  "phone_number" text NOT NULL,
  "country_code" text DEFAULT '+86'::text NOT NULL,
  "formatted_number" text NOT NULL,
  "verification_code" text,
  "code_expires_at" timestamp with time zone,
  "verification_attempts" integer DEFAULT 0,
  "is_verified" boolean DEFAULT false,
  "last_verification_at" timestamp with time zone,
  "created_at" timestamp with time zone DEFAULT now(),
  "metadata" jsonb DEFAULT '{}'::jsonb
);

ALTER TABLE public."phone_auth" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."profiles" (
  "id" uuid NOT NULL,
  "display_name" text,
  "phone_number" text,
  "avatar_url" text,
  "updated_at" timestamp with time zone DEFAULT now()
);

ALTER TABLE public."profiles" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."rate_limit_config" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "config_name" text NOT NULL,
  "ip_max_per_minute" integer DEFAULT 5,
  "device_max_per_hour" integer DEFAULT 3,
  "identifier_max_per_day" integer DEFAULT 5,
  "global_max_per_second" integer DEFAULT 10,
  "captcha_trigger_threshold" integer DEFAULT 2,
  "is_active" boolean DEFAULT true,
  "created_at" timestamp with time zone DEFAULT now(),
  "updated_at" timestamp with time zone DEFAULT now()
);

ALTER TABLE public."rate_limit_config" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."real_time_messages" (
  "id" uuid DEFAULT uuid_generate_v4() NOT NULL,
  "sender_device_id" uuid NOT NULL,
  "receiver_device_id" uuid NOT NULL,
  "message_type" character varying(50) NOT NULL,
  "message_content" jsonb NOT NULL,
  "priority" integer DEFAULT 1,
  "is_delivered" boolean DEFAULT false,
  "is_read" boolean DEFAULT false,
  "delivered_at" timestamp with time zone,
  "read_at" timestamp with time zone,
  "created_at" timestamp with time zone DEFAULT now()
);

ALTER TABLE public."real_time_messages" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."registered_devices" (
  "id" bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
  "tenant_id" uuid NOT NULL,
  "user_id" uuid NOT NULL,
  "device_id" text NOT NULL,
  "protocol_signing_algorithm" text NOT NULL,
  "protocol_public_key_fingerprint" text NOT NULL,
  "device_name" text DEFAULT 'Unknown Device'::text NOT NULL,
  "status" text NOT NULL,
  "approved_by" uuid,
  "approval_method" text,
  "approval_timestamp" timestamp with time zone,
  "registered_at" timestamp with time zone DEFAULT now() NOT NULL,
  "last_seen_at" timestamp with time zone,
  "identity_generation" bigint DEFAULT 1 NOT NULL,
  "protocol_public_key_base64" text,
  "platform" text,
  "device_model" text,
  "os_version" text,
  "app_version" text,
  "last_lan_addresses" text[],
  "last_public_address" text,
  "last_capabilities" text[],
  "last_presence_at" timestamp with time zone
);

ALTER TABLE public."registered_devices" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."registration_attempt_tickets" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "ip_address" text NOT NULL,
  "device_fingerprint" text NOT NULL,
  "identifier_hash" text NOT NULL,
  "identifier_type" text NOT NULL,
  "config_name" text DEFAULT 'default'::text NOT NULL,
  "issued_at" timestamp with time zone DEFAULT now() NOT NULL,
  "expires_at" timestamp with time zone DEFAULT (now() + '00:10:00'::interval) NOT NULL,
  "used_at" timestamp with time zone,
  "attempt_type" text DEFAULT 'register'::text NOT NULL
);

ALTER TABLE public."registration_attempt_tickets" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."registration_attempts" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "ip_address" text NOT NULL,
  "device_fingerprint" text NOT NULL,
  "identifier_hash" text NOT NULL,
  "identifier_type" text NOT NULL,
  "attempt_type" text NOT NULL,
  "success" boolean DEFAULT false,
  "failure_reason" text,
  "user_agent" text,
  "os_version" text,
  "hardware_model" text,
  "captcha_required" boolean DEFAULT false,
  "captcha_passed" boolean,
  "behavior_score" numeric(5,4),
  "created_at" timestamp with time zone DEFAULT now(),
  "metadata" jsonb DEFAULT '{}'::jsonb
);

ALTER TABLE public."registration_attempts" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."registration_blacklist" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "blacklist_type" text NOT NULL,
  "value" text NOT NULL,
  "reason" text NOT NULL,
  "expires_at" timestamp with time zone,
  "created_by" uuid,
  "created_at" timestamp with time zone DEFAULT now(),
  "updated_at" timestamp with time zone DEFAULT now()
);

ALTER TABLE public."registration_blacklist" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."remote_connections" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "user_id" uuid NOT NULL,
  "session_id" character varying(255) NOT NULL,
  "target_device_id" character varying(255) NOT NULL,
  "target_ip" inet,
  "target_port" integer,
  "connection_type" character varying(50) DEFAULT 'p2p'::character varying,
  "status" character varying(20) DEFAULT 'pending'::character varying,
  "encryption_method" character varying(50) DEFAULT 'aes-256'::character varying,
  "quality_settings" jsonb DEFAULT '{}'::jsonb,
  "started_at" timestamp with time zone DEFAULT now(),
  "ended_at" timestamp with time zone,
  "duration_seconds" integer,
  "created_at" timestamp with time zone DEFAULT now(),
  "updated_at" timestamp with time zone DEFAULT now()
);

ALTER TABLE public."remote_connections" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."security_logs" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "user_id" uuid,
  "event_type" character varying(100) NOT NULL,
  "event_data" jsonb DEFAULT '{}'::jsonb,
  "ip_address" inet,
  "user_agent" text,
  "device_fingerprint" text,
  "risk_score" integer DEFAULT 0,
  "is_suspicious" boolean DEFAULT false,
  "created_at" timestamp with time zone DEFAULT now()
);

ALTER TABLE public."security_logs" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."send_rate_limits" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "limit_type" text NOT NULL,
  "limit_value" text NOT NULL,
  "send_count" integer DEFAULT 0,
  "resend_click_count" integer DEFAULT 0,
  "window_start" timestamp with time zone NOT NULL,
  "window_end" timestamp with time zone NOT NULL,
  "captcha_required" boolean DEFAULT false,
  "created_at" timestamp with time zone DEFAULT now(),
  "updated_at" timestamp with time zone DEFAULT now()
);

ALTER TABLE public."send_rate_limits" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."session_messages" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "session_id" uuid NOT NULL,
  "message_type" character varying(50) NOT NULL,
  "message_data" jsonb DEFAULT '{}'::jsonb,
  "sender_type" character varying(20) NOT NULL,
  "timestamp" timestamp with time zone DEFAULT now(),
  "processed" boolean DEFAULT false,
  "created_at" timestamp with time zone DEFAULT now()
);

ALTER TABLE public."session_messages" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."sms_channel_stats" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "channel" text NOT NULL,
  "date" date DEFAULT CURRENT_DATE NOT NULL,
  "total_sent" integer DEFAULT 0,
  "success_count" integer DEFAULT 0,
  "failure_count" integer DEFAULT 0,
  "timeout_count" integer DEFAULT 0,
  "success_rate" numeric(5,4) GENERATED ALWAYS AS (
CASE
    WHEN (total_sent > 0) THEN ((success_count)::numeric / (total_sent)::numeric)
    ELSE (0)::numeric
END) STORED,
  "avg_response_time" integer,
  "consecutive_failures" integer DEFAULT 0,
  "last_failure_at" timestamp with time zone,
  "is_circuit_open" boolean DEFAULT false,
  "circuit_open_until" timestamp with time zone,
  "updated_at" timestamp with time zone DEFAULT now()
);

ALTER TABLE public."sms_channel_stats" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."sms_delivery_callbacks" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "record_id" uuid,
  "message_id" text NOT NULL,
  "carrier" text,
  "status_code" text,
  "status_message" text,
  "raw_callback" jsonb,
  "callback_time" timestamp with time zone,
  "received_at" timestamp with time zone DEFAULT now()
);

ALTER TABLE public."sms_delivery_callbacks" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."sync_status" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "user_id" uuid NOT NULL,
  "last_sync_at" timestamp with time zone DEFAULT now(),
  "sync_version" integer DEFAULT 1,
  "pending_changes" integer DEFAULT 0,
  "web_last_sync" timestamp with time zone,
  "mobile_last_sync" timestamp with time zone,
  "desktop_last_sync" timestamp with time zone,
  "has_conflicts" boolean DEFAULT false,
  "conflict_data" jsonb DEFAULT '{}'::jsonb,
  "created_at" timestamp with time zone DEFAULT now(),
  "updated_at" timestamp with time zone DEFAULT now()
);

ALTER TABLE public."sync_status" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."system_logs" (
  "id" uuid DEFAULT uuid_generate_v4() NOT NULL,
  "user_id" uuid,
  "device_id" uuid,
  "log_level" character varying(20) NOT NULL,
  "log_category" character varying(50) NOT NULL,
  "log_message" text NOT NULL,
  "log_data" jsonb,
  "ip_address" inet,
  "user_agent" text,
  "created_at" timestamp with time zone DEFAULT now()
);

ALTER TABLE public."system_logs" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."tenant_security_policy" (
  "tenant_id" uuid NOT NULL,
  "public_signaling_enabled" boolean DEFAULT false NOT NULL,
  "allowlist_only" boolean DEFAULT false NOT NULL,
  "min_supported_client_version" text,
  "min_supported_protocol_version" text,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL
);

ALTER TABLE public."tenant_security_policy" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."universal_users" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "universal_id" text NOT NULL,
  "primary_email" text,
  "primary_phone" text,
  "display_name" text,
  "avatar_url" text,
  "user_type" text DEFAULT 'standard'::text NOT NULL,
  "account_status" text DEFAULT 'active'::text NOT NULL,
  "security_level" integer DEFAULT 1,
  "created_at" timestamp with time zone DEFAULT now(),
  "updated_at" timestamp with time zone DEFAULT now(),
  "last_login_at" timestamp with time zone,
  "metadata" jsonb DEFAULT '{}'::jsonb,
  "username" text,
  "bio_summary" text,
  "profile_completion_score" integer DEFAULT 0,
  "is_nebula_user" boolean DEFAULT false,
  "nebula_level" integer DEFAULT 0,
  "auth_user_id" uuid
);

ALTER TABLE public."universal_users" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."user_activity" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "user_id" text NOT NULL,
  "event_type" text NOT NULL,
  "event_data" jsonb,
  "page_url" text,
  "session_id" text,
  "user_agent" text,
  "ip_address" inet,
  "device_type" text,
  "browser_name" text,
  "timestamp" timestamp with time zone DEFAULT now(),
  "created_at" timestamp with time zone DEFAULT now()
);

ALTER TABLE public."user_activity" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."user_analytics" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "user_id" text NOT NULL,
  "page_views" jsonb DEFAULT '{}'::jsonb,
  "feature_usage" jsonb DEFAULT '{}'::jsonb,
  "session_duration" integer DEFAULT 0,
  "total_clicks" integer DEFAULT 0,
  "keyboard_shortcuts_used" integer DEFAULT 0,
  "preferred_features" text[] DEFAULT '{}'::text[],
  "most_used_pages" text[] DEFAULT '{}'::text[],
  "usage_patterns" jsonb DEFAULT '{}'::jsonb,
  "average_load_time" numeric(8,3) DEFAULT 0,
  "error_count" integer DEFAULT 0,
  "date" date DEFAULT CURRENT_DATE,
  "created_at" timestamp with time zone DEFAULT now(),
  "updated_at" timestamp with time zone DEFAULT now()
);

ALTER TABLE public."user_analytics" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."user_avatars" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "user_id" uuid NOT NULL,
  "avatar_url" text NOT NULL,
  "avatar_type" text DEFAULT 'upload'::text NOT NULL,
  "file_name" text,
  "file_size" integer,
  "mime_type" text,
  "width" integer,
  "height" integer,
  "crop_data" jsonb,
  "is_active" boolean DEFAULT true,
  "is_approved" boolean DEFAULT true,
  "created_at" timestamp with time zone DEFAULT now(),
  "metadata" jsonb DEFAULT '{}'::jsonb
);

ALTER TABLE public."user_avatars" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."user_devices" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "user_id" uuid NOT NULL,
  "device_name" character varying(255) NOT NULL,
  "device_type" character varying(50) NOT NULL,
  "device_fingerprint" text NOT NULL,
  "operating_system" character varying(100),
  "browser_info" character varying(255),
  "ip_address" inet,
  "is_trusted" boolean DEFAULT false,
  "last_used_at" timestamp with time zone DEFAULT now(),
  "created_at" timestamp with time zone DEFAULT now(),
  "updated_at" timestamp with time zone DEFAULT now(),
  "public_key" text
);

ALTER TABLE public."user_devices" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."user_error_logs" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "user_id" text NOT NULL,
  "error_type" text NOT NULL,
  "error_message" text NOT NULL,
  "error_stack" text,
  "page_url" text,
  "user_agent" text,
  "browser_info" jsonb,
  "device_info" jsonb,
  "user_action" text,
  "component_name" text,
  "severity" text DEFAULT 'info'::text,
  "is_resolved" boolean DEFAULT false,
  "resolution_notes" text,
  "created_at" timestamp with time zone DEFAULT now()
);

ALTER TABLE public."user_error_logs" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."user_preferences" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "user_id" uuid,
  "weather_wallpaper_enabled" boolean DEFAULT true,
  "wallpaper_style" text DEFAULT 'dynamic'::text,
  "effect_intensity" integer DEFAULT 5,
  "sound_enabled" boolean DEFAULT true,
  "auto_location" boolean DEFAULT true,
  "created_at" timestamp with time zone DEFAULT now(),
  "updated_at" timestamp with time zone DEFAULT now()
);

ALTER TABLE public."user_preferences" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."user_profiles" (
  "id" uuid DEFAULT auth.uid() NOT NULL,
  "email" text,
  "nebula_id" text,
  "constellation" text,
  "constellation_name" text,
  "constellation_description" text,
  "account_type" text DEFAULT 'email'::text,
  "phone" text,
  "full_name" text,
  "avatar_url" text,
  "created_at" timestamp with time zone DEFAULT timezone('utc'::text, now()) NOT NULL,
  "updated_at" timestamp with time zone DEFAULT timezone('utc'::text, now()) NOT NULL,
  "custom_user_id" text
);

ALTER TABLE public."user_profiles" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."user_sessions" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "user_id" uuid NOT NULL,
  "session_token" text NOT NULL,
  "auth_method_id" uuid,
  "device_fingerprint" text,
  "device_info" jsonb,
  "ip_address" inet,
  "user_agent" text,
  "expires_at" timestamp with time zone NOT NULL,
  "is_active" boolean DEFAULT true,
  "created_at" timestamp with time zone DEFAULT now(),
  "last_activity_at" timestamp with time zone DEFAULT now()
);

ALTER TABLE public."user_sessions" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."user_settings" (
  "id" integer DEFAULT nextval('user_settings_id_seq'::regclass) NOT NULL,
  "user_id" text NOT NULL,
  "setting_key" character varying(100) NOT NULL,
  "setting_value" text NOT NULL,
  "setting_type" character varying(50) DEFAULT 'string'::character varying NOT NULL,
  "created_at" timestamp with time zone DEFAULT now(),
  "updated_at" timestamp with time zone DEFAULT now()
);

ALTER TABLE public."user_settings" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."username_change_limits" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "user_id" uuid NOT NULL,
  "changes_count" integer DEFAULT 0,
  "last_change_at" timestamp with time zone,
  "period_start" timestamp with time zone DEFAULT now(),
  "max_changes_per_period" integer DEFAULT 3,
  "period_days" integer DEFAULT 30
);

ALTER TABLE public."username_change_limits" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."username_history" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "user_id" uuid NOT NULL,
  "old_display_name" text NOT NULL,
  "new_display_name" text NOT NULL,
  "change_reason" text,
  "changed_at" timestamp with time zone DEFAULT now(),
  "changed_by_user_id" uuid,
  "is_automatic" boolean DEFAULT false
);

ALTER TABLE public."username_history" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."verification_code_records" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "phone_number" text NOT NULL,
  "code_hash" text NOT NULL,
  "channel" text NOT NULL,
  "status" text DEFAULT 'pending'::text NOT NULL,
  "delivery_status" text,
  "retry_count" integer DEFAULT 0,
  "retry_channels" text[],
  "device_fingerprint" text NOT NULL,
  "ip_address" text NOT NULL,
  "created_at" timestamp with time zone DEFAULT now(),
  "sent_at" timestamp with time zone,
  "delivered_at" timestamp with time zone,
  "expired_at" timestamp with time zone,
  "error_message" text,
  "message_id" text,
  "metadata" jsonb DEFAULT '{}'::jsonb
);

ALTER TABLE public."verification_code_records" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."verification_codes" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "user_id" uuid,
  "contact_value" character varying(255) NOT NULL,
  "contact_type" character varying(10) NOT NULL,
  "code" character varying(6) NOT NULL,
  "purpose" character varying(20) NOT NULL,
  "expires_at" timestamp with time zone NOT NULL,
  "is_used" boolean DEFAULT false,
  "attempts" integer DEFAULT 0,
  "max_attempts" integer DEFAULT 5,
  "created_at" timestamp with time zone DEFAULT now(),
  "used_at" timestamp with time zone,
  "ip_address" inet
);

ALTER TABLE public."verification_codes" ENABLE ROW LEVEL SECURITY;

SET check_function_bodies = false;

CREATE OR REPLACE FUNCTION public.assert_avatar_backend_ready()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
begin
    if to_regclass('public.universal_users') is null then
        raise exception 'avatar backend misconfigured: public.universal_users is missing';
    end if;

    if to_regclass('public.user_avatars') is null then
        raise exception 'avatar backend misconfigured: public.user_avatars is missing';
    end if;

    if to_regclass('public.user_profiles') is null then
        raise exception 'avatar backend misconfigured: public.user_profiles is missing';
    end if;

    if not exists (
        select 1
        from information_schema.columns
        where table_schema = 'public'
          and table_name = 'universal_users'
          and column_name = 'auth_user_id'
    ) then
        raise exception 'avatar backend misconfigured: public.universal_users.auth_user_id is missing';
    end if;

    if not exists (
        select 1
        from information_schema.columns
        where table_schema = 'public'
          and table_name = 'user_profiles'
          and column_name = 'avatar_url'
    ) then
        raise exception 'avatar backend misconfigured: public.user_profiles.avatar_url is missing';
    end if;

    if not exists (
        select 1
        from information_schema.columns
        where table_schema = 'public'
          and table_name = 'user_avatars'
          and column_name in ('user_id', 'avatar_url', 'is_active')
        group by table_schema, table_name
        having count(*) = 3
    ) then
        raise exception 'avatar backend misconfigured: public.user_avatars is missing required columns';
    end if;

    if not exists (
        select 1
        from storage.buckets
        where id = 'avatars'
    ) then
        raise exception 'avatar backend misconfigured: storage bucket avatars is missing';
    end if;
end;
$function$;

CREATE OR REPLACE FUNCTION public.assert_service_role_request_v5(p_function_name text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog', 'public'
AS $function$
declare
    v_request_role text;
    v_request_claims text;
begin
    v_request_role := nullif(current_setting('request.jwt.claim.role', true), '');

    if v_request_role is null then
        v_request_claims := nullif(current_setting('request.jwt.claims', true), '');
        if v_request_claims is not null then
            v_request_role := nullif((v_request_claims::jsonb ->> 'role'), '');
        end if;
    end if;

    if v_request_role = 'service_role' then
        return;
    end if;

    if v_request_role is null and session_user in ('postgres', 'supabase_admin', 'supabase_auth_admin') then
        return;
    end if;

    raise exception using
        errcode = '42501',
        message = 'service_role_required',
        detail = coalesce(p_function_name, 'This function') || ' may only be invoked by service_role or trusted internal callers.';
end;
$function$;

CREATE OR REPLACE FUNCTION public.audit_changes()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
  INSERT INTO audit_logs (
    table_name,
    operation_type,
    user_id,
    old_values,
    new_values,
    session_id
  ) VALUES (
    TG_TABLE_NAME,
    TG_OP,
    COALESCE(NEW.user_id, OLD.user_id),
    CASE WHEN TG_OP = 'DELETE' THEN to_jsonb(OLD) ELSE NULL END,
    CASE WHEN TG_OP = 'INSERT' OR TG_OP = 'UPDATE' THEN to_jsonb(NEW) ELSE NULL END,
    current_setting('request.jwt.claims', true)::json->>'sid'
  );
  RETURN COALESCE(NEW, OLD);
END;
$function$;

CREATE OR REPLACE FUNCTION public.avatar_finalize_upload(p_storage_path text, p_avatar_url text, p_mime_type text DEFAULT NULL::text, p_file_size bigint DEFAULT NULL::bigint, p_width integer DEFAULT NULL::integer, p_height integer DEFAULT NULL::integer, p_crop_data jsonb DEFAULT NULL::jsonb, p_avatar_type text DEFAULT 'upload'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare
    v_auth_user_id uuid := auth.uid();
    v_universal_user_id uuid;
    v_avatar_id uuid;
    v_expected_avatar_suffix text;
begin
    perform public.assert_avatar_backend_ready();

    if v_auth_user_id is null then
        raise exception 'avatar finalize requires an authenticated user';
    end if;

    if p_storage_path is null or btrim(p_storage_path) = '' then
        raise exception 'storage_path is required';
    end if;

    if split_part(p_storage_path, '/', 1) <> v_auth_user_id::text then
        raise exception 'storage_path must begin with the authenticated user id';
    end if;

    if p_avatar_url is null or btrim(p_avatar_url) = '' then
        raise exception 'avatar_url is required';
    end if;

    v_expected_avatar_suffix := '/storage/v1/object/public/avatars/' || p_storage_path;
    if right(p_avatar_url, length(v_expected_avatar_suffix)) <> v_expected_avatar_suffix then
        raise exception 'avatar_url must resolve to avatars/%', p_storage_path;
    end if;

    if not exists (
        select 1
        from storage.objects so
        where so.bucket_id = 'avatars'
          and so.name = p_storage_path
    ) then
        raise exception 'uploaded avatar object does not exist at avatars/%', p_storage_path;
    end if;

    v_universal_user_id := public.ensure_avatar_universal_user(v_auth_user_id);

    insert into public.user_profiles (
        id,
        email,
        full_name,
        custom_user_id,
        avatar_url,
        created_at,
        updated_at
    )
    select
        u.id,
        u.email,
        nullif(coalesce(u.raw_user_meta_data ->> 'full_name', u.raw_user_meta_data ->> 'display_name'), ''),
        nullif(u.raw_user_meta_data ->> 'custom_user_id', ''),
        p_avatar_url,
        coalesce(u.created_at, now()),
        now()
    from auth.users u
    where u.id = v_auth_user_id
    on conflict (id) do update
        set avatar_url = excluded.avatar_url,
            updated_at = now();

    update public.user_avatars
       set is_active = false
     where user_id = v_universal_user_id
       and is_active = true;

    insert into public.user_avatars (
        user_id,
        avatar_url,
        avatar_type,
        file_name,
        file_size,
        mime_type,
        width,
        height,
        crop_data,
        is_active,
        is_approved,
        metadata
    ) values (
        v_universal_user_id,
        p_avatar_url,
        coalesce(nullif(p_avatar_type, ''), 'upload'),
        regexp_replace(p_storage_path, '^.*/', ''),
        p_file_size,
        p_mime_type,
        p_width,
        p_height,
        p_crop_data,
        true,
        true,
        jsonb_build_object(
            'storage_path', p_storage_path,
            'auth_user_id', v_auth_user_id
        )
    )
    returning id into v_avatar_id;

    update public.universal_users
       set avatar_url = p_avatar_url,
           updated_at = now()
     where id = v_universal_user_id;

    return jsonb_build_object(
        'avatar_id', v_avatar_id,
        'avatar_url', p_avatar_url,
        'storage_path', p_storage_path,
        'universal_user_id', v_universal_user_id,
        'auth_user_id', v_auth_user_id,
        'is_active', true,
        'projection_status', 'projected'
    );
end;
$function$;

CREATE OR REPLACE FUNCTION public.bind_contact_method(contact_type_param text, contact_value_param text, verification_code_param text, client_ip_param inet DEFAULT NULL::inet, client_user_agent_param text DEFAULT NULL::text)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    current_user_id UUID;
    verification_result JSON;
    conflict_user_id UUID;
    result JSON;
BEGIN
    -- 获取当前用户ID
    current_user_id := auth.uid();
    IF current_user_id IS NULL THEN
        RAISE EXCEPTION 'User not authenticated';
    END IF;

    -- 验证输入参数
    IF contact_type_param NOT IN ('email', 'phone') THEN
        RAISE EXCEPTION 'Invalid contact type. Must be email or phone';
    END IF;

    -- 验证格式
    IF contact_type_param = 'email' AND contact_value_param !~ '^[^@]+@[^@]+\.[^@]+$' THEN
        RETURN json_build_object(
            'success', false,
            'error', '邮箱格式不正确',
            'code', 'INVALID_EMAIL_FORMAT'
        );
    END IF;

    IF contact_type_param = 'phone' AND contact_value_param !~ '^1[3-9]\d{9}$' THEN
        RETURN json_build_object(
            'success', false,
            'error', '手机号格式不正确',
            'code', 'INVALID_PHONE_FORMAT'
        );
    END IF;

    -- 验证验证码
    SELECT verify_verification_code(
        contact_value_param,
        contact_type_param,
        verification_code_param,
        'bind'
    ) INTO verification_result;

    IF NOT (verification_result->>'success')::BOOLEAN THEN
        RETURN verification_result;
    END IF;

    -- 检查是否已被其他用户绑定
    IF contact_type_param = 'email' THEN
        SELECT id INTO conflict_user_id
        FROM user_profiles
        WHERE email = contact_value_param AND id != current_user_id;
    ELSE
        SELECT id INTO conflict_user_id
        FROM user_profiles
        WHERE phone = contact_value_param AND id != current_user_id;
    END IF;

    IF conflict_user_id IS NOT NULL THEN
        RETURN json_build_object(
            'success', false,
            'error', '该' || CASE WHEN contact_type_param = 'email' THEN '邮箱' ELSE '手机号' END || '已被其他用户绑定',
            'code', 'CONTACT_ALREADY_BOUND'
        );
    END IF;

    -- 检查用户是否有星云ID，如果没有则生成
    IF NOT EXISTS (SELECT 1 FROM user_profiles WHERE id = current_user_id AND nebula_id IS NOT NULL) THEN
        UPDATE user_profiles
        SET nebula_id = generate_unique_nebula_id(),
            updated_at = NOW()
        WHERE id = current_user_id;
    END IF;

    -- 执行绑定
    IF contact_type_param = 'email' THEN
        UPDATE user_profiles
        SET email = contact_value_param,
            updated_at = NOW()
        WHERE id = current_user_id;
    ELSE
        UPDATE user_profiles
        SET phone = contact_value_param,
            updated_at = NOW()
        WHERE id = current_user_id;
    END IF;

    -- 记录绑定历史
    INSERT INTO account_bindings (
        user_id,
        contact_type,
        contact_value,
        action,
        verification_code,
        verified_at,
        ip_address,
        user_agent
    ) VALUES (
        current_user_id,
        contact_type_param,
        contact_value_param,
        'bind',
        verification_code_param,
        NOW(),
        client_ip_param,
        client_user_agent_param
    );

    RETURN json_build_object(
        'success', true,
        'message', CASE WHEN contact_type_param = 'email' THEN '邮箱' ELSE '手机号' END || '绑定成功',
        'contact_type', contact_type_param,
        'contact_value', contact_value_param
    );
END;
$function$;

CREATE OR REPLACE FUNCTION public.bootstrap_register_device_v5(p_tenant_id uuid, p_user_id uuid, p_device_id text, p_protocol_signing_algorithm text, p_protocol_public_key_fingerprint text, p_device_name text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
    v_existing public.registered_devices%rowtype;
    v_existing_count integer;
begin
    perform public.assert_service_role_request_v5('bootstrap_register_device_v5');

    select *
      into v_existing
      from public.registered_devices
     where tenant_id = p_tenant_id
       and user_id = p_user_id
       and device_id = p_device_id
       and protocol_signing_algorithm = p_protocol_signing_algorithm
       and protocol_public_key_fingerprint = lower(p_protocol_public_key_fingerprint)
     for update;

    if found then
        if v_existing.status = 'revoked' then
            raise exception 'device_revoked';
        end if;

        if v_existing.status = 'frozen' then
            raise exception 'device_frozen';
        end if;

        if v_existing.status <> 'active' then
            update public.registered_devices
               set status = 'active',
                   device_name = coalesce(nullif(p_device_name, ''), device_name),
                   approved_by = coalesce(approved_by, p_user_id),
                   approval_timestamp = coalesce(approval_timestamp, now()),
                   last_seen_at = now()
             where id = v_existing.id
             returning * into v_existing;
        end if;

        return to_jsonb(v_existing);
    end if;

    select count(*)
      into v_existing_count
      from public.registered_devices
     where tenant_id = p_tenant_id
       and user_id = p_user_id
       and status in ('pending', 'active', 'frozen');

    if v_existing_count > 0 then
        raise exception 'bootstrap_activation_not_allowed';
    end if;

    insert into public.registered_devices (
        tenant_id,
        user_id,
        device_id,
        protocol_signing_algorithm,
        protocol_public_key_fingerprint,
        device_name,
        status,
        approved_by,
        approval_timestamp,
        registered_at,
        last_seen_at
    )
    values (
        p_tenant_id,
        p_user_id,
        p_device_id,
        p_protocol_signing_algorithm,
        lower(p_protocol_public_key_fingerprint),
        coalesce(nullif(p_device_name, ''), 'Trusted Device'),
        'active',
        p_user_id,
        now(),
        now(),
        now()
    )
    returning * into v_existing;

    return to_jsonb(v_existing);
end;
$function$;

CREATE OR REPLACE FUNCTION public.check_auth_attempt_allowed_v1(check_ip text, check_fingerprint text, check_identifier_hash text, risk_config_name text DEFAULT 'default'::text, attempt_type text DEFAULT 'register'::text)
 RETURNS TABLE(allowed boolean, requires_captcha boolean, reason text, retry_after integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    config RECORD;
    ip_attempts INT;
    device_attempts INT;
    identifier_attempts INT;
    normalized_attempt_type TEXT := lower(coalesce(btrim(attempt_type), 'register'));
BEGIN
    IF lower(coalesce(btrim(risk_config_name), '')) = 'login' THEN
        normalized_attempt_type := 'login';
    END IF;

    IF normalized_attempt_type NOT IN ('register', 'verify_code', 'login') THEN
        normalized_attempt_type := 'register';
    END IF;

    IF normalized_attempt_type = 'login' THEN
        RETURN QUERY SELECT TRUE, FALSE, NULL::TEXT, NULL::INT;
        RETURN;
    END IF;

    SELECT *
      INTO config
      FROM public.rate_limit_config
     WHERE config_name = COALESCE(NULLIF(btrim(risk_config_name), ''), 'default')
       AND is_active = TRUE;

    IF NOT FOUND THEN
        SELECT *
          INTO config
          FROM public.rate_limit_config
         WHERE config_name = 'default'
           AND is_active = TRUE;
    END IF;

    IF public.is_ip_blacklisted(check_ip) THEN
        RETURN QUERY SELECT FALSE, FALSE, '您的IP已被限制注册'::TEXT, NULL::INT;
        RETURN;
    END IF;

    IF public.is_device_blacklisted(check_fingerprint) THEN
        RETURN QUERY SELECT FALSE, FALSE, '该设备已被限制注册'::TEXT, NULL::INT;
        RETURN;
    END IF;

    SELECT COUNT(*)::INT
      INTO ip_attempts
      FROM public.registration_attempts
     WHERE ip_address = check_ip
       AND attempt_type = normalized_attempt_type
       AND created_at > NOW() - INTERVAL '60 seconds';

    SELECT COUNT(*)::INT
      INTO device_attempts
      FROM public.registration_attempts
     WHERE device_fingerprint = check_fingerprint
       AND attempt_type = normalized_attempt_type
       AND created_at > NOW() - INTERVAL '3600 seconds';

    SELECT COUNT(*)::INT
      INTO identifier_attempts
      FROM public.registration_attempts
     WHERE identifier_hash = check_identifier_hash
       AND attempt_type = normalized_attempt_type
       AND created_at > NOW() - INTERVAL '24 hours';

    IF ip_attempts >= config.ip_max_per_minute THEN
        RETURN QUERY SELECT FALSE, FALSE, '操作过于频繁，请稍后再试'::TEXT, 60;
        RETURN;
    END IF;

    IF device_attempts >= config.device_max_per_hour THEN
        RETURN QUERY SELECT FALSE, FALSE,
            CASE normalized_attempt_type
                WHEN 'verify_code' THEN '该设备验证码请求过多，请稍后再试'
                ELSE '该设备注册次数过多，请稍后再试'
            END::TEXT,
            3600;
        RETURN;
    END IF;

    IF identifier_attempts >= config.identifier_max_per_day THEN
        RETURN QUERY SELECT FALSE, FALSE,
            CASE normalized_attempt_type
                WHEN 'verify_code' THEN '该账号验证码请求过多，请稍后再试'
                ELSE '该账号注册尝试次数过多，请明天再试'
            END::TEXT,
            86400;
        RETURN;
    END IF;

    IF GREATEST(ip_attempts, device_attempts) >= config.captcha_trigger_threshold THEN
        RETURN QUERY SELECT TRUE, TRUE, '请完成安全验证'::TEXT, NULL::INT;
        RETURN;
    END IF;

    RETURN QUERY SELECT TRUE, FALSE, NULL::TEXT, NULL::INT;
END;
$function$;

CREATE OR REPLACE FUNCTION public.check_device_send_limit(check_device text, max_per_day integer DEFAULT 20)
 RETURNS TABLE(allowed boolean, unique_phones_count integer, next_available_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    today_start TIMESTAMPTZ := DATE_TRUNC('day', NOW());
    today_count INT;
    unique_phones INT;
BEGIN
    SELECT COUNT(*), COUNT(DISTINCT phone_number)
    INTO today_count, unique_phones
    FROM verification_code_records
    WHERE device_fingerprint = check_device
    AND created_at >= today_start;

    IF today_count >= max_per_day THEN
        RETURN QUERY SELECT
            FALSE,
            unique_phones,
            (today_start + INTERVAL '1 day')::TIMESTAMPTZ;
    ELSE
        RETURN QUERY SELECT
            TRUE,
            unique_phones,
            NULL::TIMESTAMPTZ;
    END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION public.check_phone_send_limit(check_phone text, max_per_day integer DEFAULT 10)
 RETURNS TABLE(allowed boolean, remaining_count integer, next_available_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    today_start TIMESTAMPTZ := DATE_TRUNC('day', NOW());
    today_count INT;
BEGIN
    SELECT COUNT(*) INTO today_count
    FROM verification_code_records
    WHERE phone_number = check_phone
    AND created_at >= today_start;

    IF today_count >= max_per_day THEN
        RETURN QUERY SELECT
            FALSE,
            0,
            (today_start + INTERVAL '1 day')::TIMESTAMPTZ;
    ELSE
        RETURN QUERY SELECT
            TRUE,
            (max_per_day - today_count)::INT,
            NULL::TIMESTAMPTZ;
    END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION public.check_registration_allowed(check_ip text, check_fingerprint text, check_identifier_hash text, config_name text DEFAULT 'default'::text)
 RETURNS TABLE(allowed boolean, requires_captcha boolean, reason text, retry_after integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
    RETURN QUERY
    SELECT *
      FROM public.check_auth_attempt_allowed_v1(
        check_ip,
        check_fingerprint,
        check_identifier_hash,
        config_name,
        'register'
      );
END;
$function$;

CREATE OR REPLACE FUNCTION public.check_user_profile_access(target_user_id text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
  SELECT
    CASE
      WHEN current_setting('role') = 'service_role' THEN true
      WHEN auth.uid()::TEXT = target_user_id THEN true
      WHEN target_user_id LIKE 'nebula_%' THEN true
      ELSE false
    END;
$function$;

CREATE OR REPLACE FUNCTION public.cleanup_expired_blacklist()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    DELETE FROM registration_blacklist
    WHERE expires_at IS NOT NULL AND expires_at < NOW();
    RETURN NULL;
END;
$function$;

CREATE OR REPLACE FUNCTION public.cleanup_expired_rate_limits()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    deleted_count INT;
BEGIN
    DELETE FROM send_rate_limits
    WHERE window_end < NOW() - INTERVAL '1 day';

    GET DIAGNOSTICS deleted_count = ROW_COUNT;
    RETURN deleted_count;
END;
$function$;

CREATE OR REPLACE FUNCTION public.cleanup_expired_vcode_records()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    deleted_count INT;
BEGIN
    DELETE FROM verification_code_records
    WHERE created_at < NOW() - INTERVAL '7 days';

    GET DIAGNOSTICS deleted_count = ROW_COUNT;
    RETURN deleted_count;
END;
$function$;

CREATE OR REPLACE FUNCTION public.cleanup_old_attempts()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
    DELETE FROM registration_attempts
    WHERE created_at < NOW() - INTERVAL '30 days';
END;
$function$;

CREATE OR REPLACE FUNCTION public.cleanup_old_idempotent_requests()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
  DELETE FROM idempotent_requests
  WHERE created_at < NOW() - INTERVAL '7 days';
END;
$function$;

CREATE OR REPLACE FUNCTION public.commit_device_identity_rotation_v6(p_rotation_id uuid, p_tenant_id uuid, p_user_id uuid, p_device_id text, p_old_generation bigint, p_old_protocol_signing_algorithm text, p_old_protocol_public_key_fingerprint text, p_transcript_hash text, p_grace_expires_at timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
$function$;

CREATE OR REPLACE FUNCTION public.confirm_device_enrollment_v5(p_tenant_id uuid, p_user_id uuid, p_approver_device_id text, p_approver_protocol_signing_algorithm text, p_approver_protocol_public_key_fingerprint text, p_pending_device_id text, p_pending_protocol_signing_algorithm text, p_pending_protocol_public_key_fingerprint text, p_device_name text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
    v_approver public.registered_devices%rowtype;
    v_pending public.registered_devices%rowtype;
begin
    perform public.assert_service_role_request_v5('confirm_device_enrollment_v5');

    select *
      into v_approver
      from public.registered_devices
     where tenant_id = p_tenant_id
       and user_id = p_user_id
       and device_id = p_approver_device_id
       and protocol_signing_algorithm = p_approver_protocol_signing_algorithm
       and protocol_public_key_fingerprint = lower(p_approver_protocol_public_key_fingerprint)
       and status = 'active'
     for update;

    if not found then
        raise exception 'approver_not_active';
    end if;

    insert into public.registered_devices (
        tenant_id,
        user_id,
        device_id,
        protocol_signing_algorithm,
        protocol_public_key_fingerprint,
        device_name,
        status,
        registered_at
    )
    values (
        p_tenant_id,
        p_user_id,
        p_pending_device_id,
        p_pending_protocol_signing_algorithm,
        lower(p_pending_protocol_public_key_fingerprint),
        coalesce(nullif(p_device_name, ''), 'Pending Device'),
        'pending',
        now()
    )
    on conflict (tenant_id, protocol_signing_algorithm, protocol_public_key_fingerprint) do nothing;

    select *
      into v_pending
      from public.registered_devices
     where tenant_id = p_tenant_id
       and user_id = p_user_id
       and device_id = p_pending_device_id
       and protocol_signing_algorithm = p_pending_protocol_signing_algorithm
       and protocol_public_key_fingerprint = lower(p_pending_protocol_public_key_fingerprint)
     for update;

    if not found then
        raise exception 'pending_device_not_found';
    end if;

    if v_pending.status = 'revoked' then
        raise exception 'pending_device_revoked';
    end if;

    if v_pending.status = 'frozen' then
        raise exception 'pending_device_frozen';
    end if;

    update public.registered_devices
       set status = 'active',
           device_name = coalesce(nullif(p_device_name, ''), device_name),
           approved_by = p_user_id,
           approval_method = 'trusted_device_confirmation',
           approval_timestamp = now(),
           last_seen_at = now()
     where id = v_pending.id
     returning * into v_pending;

    return to_jsonb(v_pending);
end;
$function$;

CREATE OR REPLACE FUNCTION public.count_recent_device_attempts(check_fingerprint text, seconds integer)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
    RETURN (
        SELECT COUNT(*)::INT FROM registration_attempts
        WHERE device_fingerprint = check_fingerprint
        AND created_at > NOW() - (seconds || ' seconds')::INTERVAL
    );
END;
$function$;

CREATE OR REPLACE FUNCTION public.count_recent_ip_attempts(check_ip text, seconds integer)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
    RETURN (
        SELECT COUNT(*)::INT FROM registration_attempts
        WHERE ip_address = check_ip
        AND created_at > NOW() - (seconds || ' seconds')::INTERVAL
    );
END;
$function$;

CREATE OR REPLACE FUNCTION public.create_universal_user(p_auth_type text, p_identifier text, p_display_name text DEFAULT NULL::text, p_email text DEFAULT NULL::text, p_phone text DEFAULT NULL::text, p_provider text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
AS $function$
DECLARE
    new_user_id UUID;
    new_universal_id TEXT;
    auth_method_id UUID;
BEGIN
    -- 检查是否已存在相同的认证方法
    IF EXISTS (SELECT 1 FROM public.auth_methods WHERE auth_type = p_auth_type AND identifier = p_identifier) THEN
        RAISE EXCEPTION '认证方法已存在: % %', p_auth_type, p_identifier;
    END IF;

    -- 生成统一ID
    new_universal_id := generate_universal_id(p_auth_type, p_identifier);

    -- 创建统一用户记录
    INSERT INTO public.universal_users (
        universal_id,
        primary_email,
        primary_phone,
        display_name,
        user_type,
        account_status
    ) VALUES (
        new_universal_id,
        p_email,
        p_phone,
        COALESCE(p_display_name, '用户' || SUBSTRING(new_universal_id, -6)),
        'standard',
        'active'
    ) RETURNING id INTO new_user_id;

    -- 创建认证方法记录
    INSERT INTO public.auth_methods (
        user_id,
        auth_type,
        auth_provider,
        identifier,
        is_primary,
        is_verified
    ) VALUES (
        new_user_id,
        p_auth_type,
        COALESCE(p_provider, 'supabase'),
        p_identifier,
        true,
        CASE WHEN p_auth_type = 'oauth' THEN true ELSE false END
    ) RETURNING id INTO auth_method_id;

    RETURN new_user_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.create_user_session(user_uuid uuid, auth_method_uuid uuid, device_info jsonb DEFAULT NULL::jsonb, session_duration_hours integer DEFAULT 24)
 RETURNS text
 LANGUAGE plpgsql
AS $function$
DECLARE
    session_token TEXT;
    expires_at TIMESTAMP WITH TIME ZONE;
BEGIN
    -- 生成会话令牌
    session_token := 'ss_' || ENCODE(gen_random_bytes(32), 'base64');
    session_token := REGEXP_REPLACE(session_token, '[^A-Za-z0-9]', '', 'g');

    -- 计算过期时间
    expires_at := NOW() + (session_duration_hours || ' hours')::INTERVAL;

    -- 创建会话记录
    INSERT INTO public.user_sessions (
        user_id,
        session_token,
        auth_method_id,
        device_info,
        expires_at
    ) VALUES (
        user_uuid,
        session_token,
        auth_method_uuid,
        device_info,
        expires_at
    );

    -- 更新用户最后登录时间
    UPDATE public.universal_users
    SET last_login_at = NOW(), updated_at = NOW()
    WHERE id = user_uuid;

    -- 更新认证方法最后使用时间
    UPDATE public.auth_methods
    SET last_used_at = NOW()
    WHERE id = auth_method_uuid;

    RETURN session_token;
END;
$function$;

CREATE OR REPLACE FUNCTION public.detect_suspicious_behavior(check_device text, time_window_minutes integer DEFAULT 10, threshold integer DEFAULT 3)
 RETURNS TABLE(is_suspicious boolean, unique_phones integer, recommendation text)
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    window_start TIMESTAMPTZ := NOW() - (time_window_minutes || ' minutes')::INTERVAL;
    phone_count INT;
BEGIN
    SELECT COUNT(DISTINCT phone_number) INTO phone_count
    FROM verification_code_records
    WHERE device_fingerprint = check_device
    AND created_at >= window_start;

    IF phone_count >= threshold THEN
        RETURN QUERY SELECT
            TRUE,
            phone_count,
            'require_captcha'::TEXT;
    ELSE
        RETURN QUERY SELECT
            FALSE,
            phone_count,
            'allow'::TEXT;
    END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION public.enroll_first_device_v5(p_invite_token_hash text, p_tenant_id uuid, p_target_user_id uuid, p_device_id text, p_protocol_signing_algorithm text, p_protocol_public_key_fingerprint text, p_device_name text, p_approved_by uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
    v_invite public.device_enrollment_invites%rowtype;
    v_existing_count integer;
    v_result public.registered_devices%rowtype;
begin
    perform public.assert_service_role_request_v5('enroll_first_device_v5');

    select *
      into v_invite
      from public.device_enrollment_invites
     where invite_token_hash = p_invite_token_hash
       and tenant_id = p_tenant_id
       and target_user_id = p_target_user_id
     for update;

    if not found then
        raise exception 'invite_not_found';
    end if;

    if v_invite.state <> 'issued' then
        raise exception 'invite_not_issuable';
    end if;

    if v_invite.expires_at <= now() then
        update public.device_enrollment_invites
           set state = 'expired'
         where id = v_invite.id;
        raise exception 'invite_expired';
    end if;

    select count(*)
      into v_existing_count
      from public.registered_devices
     where tenant_id = p_tenant_id
       and user_id = p_target_user_id
       and status in ('pending', 'active', 'frozen');

    if v_existing_count > 0 then
        raise exception 'first_device_already_exists';
    end if;

    insert into public.registered_devices (
        tenant_id,
        user_id,
        device_id,
        protocol_signing_algorithm,
        protocol_public_key_fingerprint,
        device_name,
        status,
        approved_by,
        approval_method,
        approval_timestamp,
        registered_at,
        last_seen_at
    )
    values (
        p_tenant_id,
        p_target_user_id,
        p_device_id,
        p_protocol_signing_algorithm,
        lower(p_protocol_public_key_fingerprint),
        coalesce(nullif(p_device_name, ''), 'Trusted Device'),
        'active',
        coalesce(p_approved_by, v_invite.issued_by),
        'invite_token',
        now(),
        now(),
        now()
    )
    returning * into v_result;

    update public.device_enrollment_invites
       set state = 'consumed',
           consumed_at = now()
     where id = v_invite.id;

    return to_jsonb(v_result);
end;
$function$;

CREATE OR REPLACE FUNCTION public.ensure_avatar_universal_user(p_auth_user_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare
    v_universal_user_id uuid;
begin
    if p_auth_user_id is null then
        raise exception 'auth user id is required';
    end if;

    select uu.id
      into v_universal_user_id
      from public.universal_users uu
     where uu.auth_user_id = p_auth_user_id
     limit 1;

    if v_universal_user_id is not null then
        return v_universal_user_id;
    end if;

    insert into public.universal_users (
        universal_id,
        primary_email,
        display_name,
        avatar_url,
        user_type,
        account_status,
        auth_user_id,
        created_at,
        updated_at
    )
    select
        'auth:' || u.id::text,
        u.email,
        coalesce(
            nullif(u.raw_user_meta_data ->> 'display_name', ''),
            nullif(u.raw_user_meta_data ->> 'full_name', ''),
            u.email,
            '用户'
        ),
        up.avatar_url,
        'standard',
        'active',
        u.id,
        coalesce(u.created_at, now()),
        now()
    from auth.users u
    left join public.user_profiles up
        on up.id = u.id
    where u.id = p_auth_user_id
    on conflict (auth_user_id) do update
        set primary_email = coalesce(public.universal_users.primary_email, excluded.primary_email),
            display_name = coalesce(public.universal_users.display_name, excluded.display_name),
            avatar_url = coalesce(public.universal_users.avatar_url, excluded.avatar_url),
            updated_at = now()
    returning id into v_universal_user_id;

    if v_universal_user_id is null then
        select uu.id
          into v_universal_user_id
          from public.universal_users uu
         where uu.auth_user_id = p_auth_user_id
         limit 1;
    end if;

    if v_universal_user_id is null then
        raise exception 'failed to resolve universal_users row for auth user %', p_auth_user_id;
    end if;

    return v_universal_user_id;
end;
$function$;

CREATE OR REPLACE FUNCTION public.ensure_tenant_security_policy_v5(p_tenant_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
    perform public.assert_service_role_request_v5('ensure_tenant_security_policy_v5');

    insert into public.tenant_security_policy (
        tenant_id,
        public_signaling_enabled,
        allowlist_only,
        min_supported_client_version,
        min_supported_protocol_version
    )
    values (
        p_tenant_id,
        true,
        false,
        '1.0.0',
        '1'
    )
    on conflict (tenant_id) do update
        set public_signaling_enabled = excluded.public_signaling_enabled,
            min_supported_client_version = excluded.min_supported_client_version,
            min_supported_protocol_version = excluded.min_supported_protocol_version,
            updated_at = now();
end;
$function$;

CREATE OR REPLACE FUNCTION public.expire_device_identity_grace_v6(p_limit integer DEFAULT 1000)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
$function$;

CREATE OR REPLACE FUNCTION public.generate_unique_nebula_id()
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    new_id BIGINT;
    formatted_id TEXT;
BEGIN
    -- 原子性地获取下一个ID
    UPDATE nebula_id_sequence
    SET current_value = current_value + 1,
        updated_at = NOW()
    WHERE id = 1
    RETURNING current_value INTO new_id;

    -- 如果到达最大值，扩展到下一个数量级
    IF new_id >= (SELECT max_value FROM nebula_id_sequence WHERE id = 1) THEN
        UPDATE nebula_id_sequence
        SET max_value = max_value * 10
        WHERE id = 1;
    END IF;

    RETURN new_id::TEXT;
END;
$function$;

CREATE OR REPLACE FUNCTION public.generate_universal_id(auth_type text, identifier text)
 RETURNS text
 LANGUAGE plpgsql
AS $function$
DECLARE
    prefix TEXT;
    unique_part TEXT;
    timestamp_part TEXT;
    random_part TEXT;
BEGIN
    -- 根据认证类型设置前缀
    CASE auth_type
        WHEN 'email' THEN prefix := 'EM';
        WHEN 'phone' THEN prefix := 'PH';
        WHEN 'oauth' THEN prefix := 'OA';
        WHEN 'nebula' THEN prefix := 'NB';
        WHEN 'guest' THEN prefix := 'GT';
        ELSE prefix := 'UN';
    END CASE;

    -- 生成时间戳部分（Base36编码）
    timestamp_part := UPPER(ENCODE(INT8SEND(EXTRACT(EPOCH FROM NOW())::BIGINT), 'base64'));
    timestamp_part := REGEXP_REPLACE(timestamp_part, '[^A-Z0-9]', '', 'g');
    timestamp_part := SUBSTRING(timestamp_part, 1, 6);

    -- 生成随机部分
    random_part := UPPER(SUBSTRING(MD5(identifier || RANDOM()::TEXT), 1, 6));

    -- 组合最终ID
    RETURN prefix || '_' || timestamp_part || random_part;
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_best_channel(carrier text DEFAULT NULL::text)
 RETURNS TABLE(channel_name text, current_success_rate numeric, is_available boolean)
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
    RETURN QUERY
    SELECT
        s.channel,
        s.success_rate,
        NOT s.is_circuit_open AND (s.circuit_open_until IS NULL OR s.circuit_open_until < NOW())
    FROM sms_channel_stats s
    WHERE s.date = CURRENT_DATE
    AND (carrier IS NULL OR s.channel = carrier)
    ORDER BY
        CASE WHEN carrier IS NOT NULL AND s.channel = carrier THEN 0 ELSE 1 END,
        s.success_rate DESC
    LIMIT 3;
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_email_by_nebula_id(nebula_id_input text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    found_email TEXT;
BEGIN
    -- 查找星云ID对应的邮箱
    SELECT email INTO found_email
    FROM user_profiles
    WHERE nebula_id = nebula_id_input;

    RETURN found_email;
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_user_binding_status(target_user_id uuid)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    result JSON;
    user_profile RECORD;
BEGIN
    -- 检查权限：只能查询自己的状态
    IF auth.uid() != target_user_id THEN
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

CREATE OR REPLACE FUNCTION public.guard_registration_attempt_v1(identifier_hash text, identifier_type text, raw_identifier text, device_fingerprint text, config_name text DEFAULT 'default'::text, attempt_type text DEFAULT 'register'::text)
 RETURNS TABLE(allowed boolean, requires_captcha boolean, reason text, retry_after integer, audit_ticket text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    resolved_ip TEXT := public.resolve_registration_request_ip_v1();
    normalized_identifier_type TEXT := lower(coalesce(btrim(identifier_type), ''));
    normalized_raw_identifier TEXT := coalesce(btrim(raw_identifier), '');
    normalized_config_name TEXT := COALESCE(NULLIF(btrim(config_name), ''), 'default');
    normalized_attempt_type TEXT := lower(coalesce(btrim(attempt_type), 'register'));
    derived_identifier_hash TEXT;
    guard_result RECORD;
    issued_ticket UUID;
BEGIN
    DELETE FROM public.registration_attempt_tickets
    WHERE expires_at <= NOW()
       OR (used_at IS NOT NULL AND used_at <= NOW() - INTERVAL '1 day');

    IF normalized_config_name = 'login' THEN
        normalized_attempt_type := 'login';
    END IF;

    IF normalized_attempt_type NOT IN ('register', 'verify_code', 'login') THEN
        RETURN QUERY SELECT FALSE, FALSE, '认证风控请求缺少有效 attempt_type'::TEXT, NULL::INT, NULL::TEXT;
        RETURN;
    END IF;

    IF normalized_attempt_type = 'login' THEN
        RETURN QUERY SELECT TRUE, FALSE, NULL::TEXT, NULL::INT, NULL::TEXT;
        RETURN;
    END IF;

    IF device_fingerprint IS NULL OR btrim(device_fingerprint) = '' THEN
        RETURN QUERY SELECT FALSE, FALSE, '认证风控请求缺少 device_fingerprint'::TEXT, NULL::INT, NULL::TEXT;
        RETURN;
    END IF;

    IF normalized_identifier_type NOT IN ('email', 'phone', 'username') THEN
        RETURN QUERY SELECT FALSE, FALSE, '认证风控请求缺少有效 identifier_type'::TEXT, NULL::INT, NULL::TEXT;
        RETURN;
    END IF;

    IF normalized_identifier_type = 'phone' THEN
        normalized_raw_identifier := regexp_replace(normalized_raw_identifier, '[^0-9+]', '', 'g');
    ELSE
        normalized_raw_identifier := lower(normalized_raw_identifier);
    END IF;

    IF normalized_raw_identifier = '' THEN
        RETURN QUERY SELECT FALSE, FALSE, '认证风控请求缺少 raw_identifier'::TEXT, NULL::INT, NULL::TEXT;
        RETURN;
    END IF;

    IF normalized_attempt_type = 'register'
       AND normalized_identifier_type = 'email'
       AND public.is_disposable_email(normalized_raw_identifier) THEN
        RETURN QUERY SELECT FALSE, FALSE, '不支持使用临时邮箱注册'::TEXT, NULL::INT, NULL::TEXT;
        RETURN;
    END IF;

    derived_identifier_hash := encode(extensions.digest(normalized_raw_identifier, 'sha256'), 'hex');

    SELECT *
      INTO guard_result
      FROM public.check_auth_attempt_allowed_v1(
        resolved_ip,
        btrim(device_fingerprint),
        derived_identifier_hash,
        normalized_config_name,
        normalized_attempt_type
      );

    IF COALESCE(guard_result.allowed, FALSE) THEN
        INSERT INTO public.registration_attempt_tickets (
            ip_address,
            device_fingerprint,
            identifier_hash,
            identifier_type,
            config_name,
            attempt_type
        )
        VALUES (
            resolved_ip,
            btrim(device_fingerprint),
            derived_identifier_hash,
            normalized_identifier_type,
            normalized_config_name,
            normalized_attempt_type
        )
        RETURNING id INTO issued_ticket;
    END IF;

    RETURN QUERY
    SELECT
        COALESCE(guard_result.allowed, FALSE),
        COALESCE(guard_result.requires_captcha, FALSE),
        guard_result.reason,
        guard_result.retry_after,
        issued_ticket::TEXT;
END;
$function$;

CREATE OR REPLACE FUNCTION public.handle_new_user()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
    INSERT INTO public.profiles (id, display_name)
    VALUES (NEW.id, NEW.raw_user_meta_data->>'display_name');
    RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.hook_skybridge_before_user_created_v1(event jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    metadata JSONB := COALESCE(event -> 'metadata', '{}'::jsonb);
    user_data JSONB := COALESCE(event -> 'user', '{}'::jsonb);
    user_metadata JSONB := COALESCE(user_data -> 'user_metadata', '{}'::jsonb);
    raw_email TEXT := lower(COALESCE(NULLIF(btrim(user_data ->> 'email'), ''), ''));
    raw_phone TEXT := regexp_replace(COALESCE(NULLIF(btrim(user_data ->> 'phone'), ''), ''), '[^0-9+]', '', 'g');
    resolved_ip TEXT := COALESCE(NULLIF(btrim(metadata ->> 'ip_address'), ''), 'unknown');
    raw_identifier TEXT := NULL;
    identifier_type TEXT := NULL;
    identifier_hash TEXT := NULL;
    device_fingerprint TEXT := NULL;
    effective_fingerprint TEXT := NULL;
    request_tag TEXT := COALESCE(NULLIF(btrim(metadata ->> 'request_id'), ''), gen_random_uuid()::TEXT);
    guard_result RECORD;
    denial_message TEXT := NULL;
    denial_status INT := 403;
BEGIN
    IF raw_email <> '' THEN
        identifier_type := 'email';
        raw_identifier := raw_email;
    ELSIF raw_phone <> '' THEN
        identifier_type := 'phone';
        raw_identifier := raw_phone;
    ELSE
        RETURN jsonb_build_object(
            'error',
            jsonb_build_object(
                'http_code', 400,
                'message', '注册请求缺少邮箱或手机号'
            )
        );
    END IF;

    IF identifier_type = 'email' AND public.is_disposable_email(raw_identifier) THEN
        denial_message := '不支持使用临时邮箱注册';
        identifier_hash := encode(extensions.digest(raw_identifier, 'sha256'), 'hex');
        effective_fingerprint := 'hook:' || encode(extensions.digest(resolved_ip || ':' || identifier_hash || ':' || request_tag, 'sha256'), 'hex');

        INSERT INTO public.registration_attempts (
            ip_address,
            device_fingerprint,
            identifier_hash,
            identifier_type,
            attempt_type,
            success,
            failure_reason,
            captcha_required,
            captcha_passed,
            metadata
        )
        VALUES (
            resolved_ip,
            effective_fingerprint,
            identifier_hash,
            identifier_type,
            'register',
            FALSE,
            denial_message,
            FALSE,
            FALSE,
            jsonb_build_object(
                'hook', 'before_user_created',
                'request_id', request_tag,
                'device_fingerprint_supplied', FALSE
            )
        );

        RETURN jsonb_build_object(
            'error',
            jsonb_build_object(
                'http_code', 403,
                'message', denial_message
            )
        );
    END IF;

    identifier_hash := encode(extensions.digest(raw_identifier, 'sha256'), 'hex');
    device_fingerprint := COALESCE(
        NULLIF(btrim(user_metadata ->> 'device_fingerprint'), ''),
        NULLIF(btrim(user_metadata ->> 'deviceFingerprint'), '')
    );
    effective_fingerprint := COALESCE(
        device_fingerprint,
        'hook:' || encode(extensions.digest(resolved_ip || ':' || identifier_hash || ':' || request_tag, 'sha256'), 'hex')
    );

    SELECT *
      INTO guard_result
      FROM public.check_registration_allowed(
        resolved_ip,
        effective_fingerprint,
        identifier_hash,
        'default'
      );

    IF COALESCE(guard_result.requires_captcha, FALSE) THEN
        denial_message := COALESCE(guard_result.reason, '请先完成安全验证后再注册');
        denial_status := 429;
    ELSIF NOT COALESCE(guard_result.allowed, FALSE) THEN
        denial_message := COALESCE(guard_result.reason, '当前注册请求已被拒绝');
        denial_status := CASE
            WHEN guard_result.retry_after IS NOT NULL AND guard_result.retry_after > 0 THEN 429
            ELSE 403
        END;
    END IF;

    INSERT INTO public.registration_attempts (
        ip_address,
        device_fingerprint,
        identifier_hash,
        identifier_type,
        attempt_type,
        success,
        failure_reason,
        captcha_required,
        captcha_passed,
        metadata
    )
    VALUES (
        resolved_ip,
        effective_fingerprint,
        identifier_hash,
        identifier_type,
        'register',
        denial_message IS NULL,
        denial_message,
        COALESCE(guard_result.requires_captcha, FALSE),
        FALSE,
        jsonb_build_object(
            'hook', 'before_user_created',
            'request_id', request_tag,
            'device_fingerprint_supplied', device_fingerprint IS NOT NULL
        )
    );

    IF denial_message IS NOT NULL THEN
        RETURN jsonb_build_object(
            'error',
            jsonb_build_object(
                'http_code', denial_status,
                'message', denial_message
            )
        );
    END IF;

    RETURN event;
END;
$function$;

CREATE OR REPLACE FUNCTION public.is_device_blacklisted(check_fingerprint text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
    RETURN EXISTS (
        SELECT 1 FROM registration_blacklist
        WHERE blacklist_type = 'device_fingerprint'
        AND value = check_fingerprint
        AND (expires_at IS NULL OR expires_at > NOW())
    );
END;
$function$;

CREATE OR REPLACE FUNCTION public.is_disposable_email(check_email text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    email_domain TEXT;
BEGIN
    email_domain := LOWER(SPLIT_PART(check_email, '@', 2));
    RETURN EXISTS (
        SELECT 1 FROM disposable_email_domains
        WHERE domain = email_domain
    );
END;
$function$;

CREATE OR REPLACE FUNCTION public.is_ip_blacklisted(check_ip text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
    RETURN EXISTS (
        SELECT 1 FROM registration_blacklist
        WHERE blacklist_type = 'ip'
        AND value = check_ip
        AND (expires_at IS NULL OR expires_at > NOW())
    );
END;
$function$;

CREATE OR REPLACE FUNCTION public.is_valid_protocol_identity_key_v6(p_algorithm text, p_public_key_base64 text)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'pg_catalog'
AS $function$
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
$function$;

CREATE OR REPLACE FUNCTION public.issue_device_identity_rotation_v6(p_request_id uuid, p_rotation_id uuid, p_tenant_id uuid, p_user_id uuid, p_device_id text, p_old_generation bigint, p_old_protocol_signing_algorithm text, p_old_protocol_public_key_fingerprint text, p_old_protocol_public_key_base64 text, p_new_protocol_signing_algorithm text, p_new_protocol_public_key_fingerprint text, p_new_protocol_public_key_base64 text, p_nonce text, p_transcript_hash text, p_expires_at timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
$function$;

CREATE OR REPLACE FUNCTION public.link_accounts(primary_user_uuid uuid, secondary_auth_type text, secondary_identifier text, link_type text DEFAULT 'associate'::text)
 RETURNS boolean
 LANGUAGE plpgsql
AS $function$
DECLARE
    secondary_user_id UUID;
    secondary_auth_method_id UUID;
BEGIN
    -- 查找次要认证方法对应的用户
    SELECT am.user_id, am.id INTO secondary_user_id, secondary_auth_method_id
    FROM public.auth_methods am
    WHERE am.auth_type = secondary_auth_type AND am.identifier = secondary_identifier
    LIMIT 1;

    IF secondary_user_id IS NULL THEN
        RAISE EXCEPTION '未找到要关联的认证方法: % %', secondary_auth_type, secondary_identifier;
    END IF;

    -- 检查是否已经关联
    IF EXISTS (
        SELECT 1 FROM public.account_links
        WHERE (primary_user_id = primary_user_uuid AND linked_user_id = secondary_user_id)
           OR (primary_user_id = secondary_user_id AND linked_user_id = primary_user_uuid)
    ) THEN
        RETURN false; -- 已经关联
    END IF;

    -- 创建账户关联
    INSERT INTO public.account_links (
        primary_user_id,
        linked_user_id,
        link_type,
        linked_by_auth_method
    ) VALUES (
        primary_user_uuid,
        secondary_user_id,
        link_type,
        secondary_auth_type
    );

    -- 更新次要认证方法的用户ID为主用户ID
    UPDATE public.auth_methods
    SET user_id = primary_user_uuid
    WHERE id = secondary_auth_method_id;

    -- 将次要用户标记为非活跃（软删除）
    UPDATE public.universal_users
    SET account_status = 'merged', updated_at = NOW()
    WHERE id = secondary_user_id;

    RETURN true;
END;
$function$;

CREATE OR REPLACE FUNCTION public.nextval(sequence_name text)
 RETURNS bigint
 LANGUAGE sql
 SECURITY DEFINER
AS $function$
  SELECT nextval(sequence_name::regclass);
$function$;

CREATE OR REPLACE FUNCTION public.record_registration_attempt_v1(raw_identifier text, identifier_type text, device_fingerprint text, attempt_type text DEFAULT 'register'::text, success boolean DEFAULT false, failure_reason text DEFAULT NULL::text, captcha_required boolean DEFAULT false, captcha_passed boolean DEFAULT false, audit_ticket text DEFAULT NULL::text, metadata jsonb DEFAULT '{}'::jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    headers JSONB;
    resolved_ip TEXT := public.resolve_registration_request_ip_v1();
    request_user_agent TEXT;
    normalized_identifier_type TEXT := lower(coalesce(btrim(identifier_type), ''));
    normalized_attempt_type TEXT := lower(coalesce(btrim(attempt_type), 'register'));
    normalized_raw_identifier TEXT := coalesce(btrim(raw_identifier), '');
    normalized_device_fingerprint TEXT := btrim(coalesce(device_fingerprint, ''));
    normalized_failure_reason TEXT := NULLIF(left(btrim(coalesce(failure_reason, '')), 256), '');
    normalized_metadata JSONB := COALESCE(metadata, '{}'::jsonb);
    derived_identifier_hash TEXT;
    ticket_uuid UUID;
    issued_ticket public.registration_attempt_tickets%ROWTYPE;
BEGIN
    DELETE FROM public.registration_attempt_tickets
    WHERE expires_at <= NOW()
       OR (used_at IS NOT NULL AND used_at <= NOW() - INTERVAL '1 day');

    IF lower(coalesce(btrim(normalized_metadata ->> 'attempt_type'), '')) = 'login' THEN
        normalized_attempt_type := 'login';
    END IF;

    IF normalized_attempt_type NOT IN ('register', 'verify_code', 'login') THEN
        RETURN;
    END IF;

    IF normalized_attempt_type = 'login' THEN
        RETURN;
    END IF;

    IF normalized_device_fingerprint = '' THEN
        RETURN;
    END IF;

    IF normalized_identifier_type NOT IN ('email', 'phone', 'username') THEN
        RETURN;
    END IF;

    IF normalized_identifier_type = 'phone' THEN
        normalized_raw_identifier := regexp_replace(normalized_raw_identifier, '[^0-9+]', '', 'g');
    ELSE
        normalized_raw_identifier := lower(normalized_raw_identifier);
    END IF;

    IF normalized_raw_identifier = '' THEN
        RETURN;
    END IF;

    derived_identifier_hash := encode(extensions.digest(normalized_raw_identifier, 'sha256'), 'hex');

    IF audit_ticket IS NULL OR btrim(audit_ticket) = '' THEN
        RETURN;
    END IF;

    BEGIN
        ticket_uuid := btrim(audit_ticket)::UUID;
    EXCEPTION WHEN invalid_text_representation THEN
        RETURN;
    END;

    SELECT *
      INTO issued_ticket
      FROM public.registration_attempt_tickets
     WHERE id = ticket_uuid
     FOR UPDATE;

    IF NOT FOUND
       OR issued_ticket.used_at IS NOT NULL
       OR issued_ticket.expires_at <= NOW()
       OR issued_ticket.ip_address <> resolved_ip
       OR issued_ticket.device_fingerprint <> normalized_device_fingerprint
       OR issued_ticket.identifier_hash <> derived_identifier_hash
       OR issued_ticket.identifier_type <> normalized_identifier_type
       OR issued_ticket.attempt_type <> normalized_attempt_type THEN
        RETURN;
    END IF;

    UPDATE public.registration_attempt_tickets
       SET used_at = NOW()
     WHERE id = issued_ticket.id;

    BEGIN
        headers := NULLIF(current_setting('request.headers', true), '')::jsonb;
    EXCEPTION WHEN OTHERS THEN
        headers := NULL;
    END;

    request_user_agent := headers ->> 'user-agent';

    IF jsonb_typeof(normalized_metadata) IS DISTINCT FROM 'object' THEN
        normalized_metadata := '{}'::jsonb;
    END IF;

    INSERT INTO public.registration_attempts (
        ip_address,
        device_fingerprint,
        identifier_hash,
        identifier_type,
        attempt_type,
        success,
        failure_reason,
        user_agent,
        captcha_required,
        captcha_passed,
        metadata
    )
    VALUES (
        resolved_ip,
        normalized_device_fingerprint,
        derived_identifier_hash,
        normalized_identifier_type,
        normalized_attempt_type,
        COALESCE(success, FALSE),
        normalized_failure_reason,
        NULLIF(request_user_agent, ''),
        COALESCE(captcha_required, FALSE),
        COALESCE(captcha_passed, FALSE),
        normalized_metadata
    );
END;
$function$;

CREATE OR REPLACE FUNCTION public.reject_device_identity_rotation_audit_mutation_v6()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog', 'public'
AS $function$
begin
    raise exception 'identity_rotation_audit_is_immutable';
end;
$function$;

CREATE OR REPLACE FUNCTION public.resolve_registration_request_ip_v1()
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    headers JSONB;
    forwarded TEXT;
BEGIN
    BEGIN
        headers := NULLIF(current_setting('request.headers', true), '')::jsonb;
    EXCEPTION WHEN OTHERS THEN
        headers := NULL;
    END;

    forwarded := COALESCE(
        headers ->> 'cf-connecting-ip',
        headers ->> 'x-real-ip',
        headers ->> 'x-forwarded-for'
    );

    IF forwarded IS NULL OR btrim(forwarded) = '' THEN
        RETURN 'unknown';
    END IF;

    RETURN btrim(split_part(forwarded, ',', 1));
END;
$function$;

CREATE OR REPLACE FUNCTION public.sync_tenant_security_policy_for_auth_user_v5()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
    perform public.ensure_tenant_security_policy_v5(new.id);
    return new;
end;
$function$;

CREATE OR REPLACE FUNCTION public.touch_registered_device_presence_v7(p_tenant_id uuid, p_user_id uuid, p_device_id text, p_protocol_signing_algorithm text, p_protocol_public_key_fingerprint text, p_device_name text DEFAULT NULL::text, p_platform text DEFAULT NULL::text, p_device_model text DEFAULT NULL::text, p_os_version text DEFAULT NULL::text, p_app_version text DEFAULT NULL::text, p_lan_addresses text[] DEFAULT NULL::text[], p_public_address text DEFAULT NULL::text, p_capabilities text[] DEFAULT NULL::text[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare
    v_rows integer := 0;
    v_now timestamptz := now();
    v_address text;
    v_capability text;
begin
    perform public.assert_service_role_request_v5('touch_registered_device_presence_v7');

    if p_lan_addresses is not null then
        if cardinality(p_lan_addresses) > 8 then
            raise exception 'presence_lan_addresses_too_many';
        end if;
        foreach v_address in array p_lan_addresses loop
            -- raises on anything that is not an IP literal
            perform v_address::inet;
        end loop;
    end if;

    if p_public_address is not null then
        perform p_public_address::inet;
    end if;

    if p_capabilities is not null then
        if cardinality(p_capabilities) > 16 then
            raise exception 'presence_capabilities_too_many';
        end if;
        foreach v_capability in array p_capabilities loop
            if v_capability !~ '^[a-z0-9_]{1,32}$' then
                raise exception 'presence_capability_invalid';
            end if;
        end loop;
    end if;

    update public.registered_devices
       set device_name = coalesce(nullif(p_device_name, ''), device_name),
           platform = p_platform,
           device_model = p_device_model,
           os_version = p_os_version,
           app_version = p_app_version,
           last_lan_addresses = p_lan_addresses,
           last_public_address = p_public_address,
           last_capabilities = p_capabilities,
           last_presence_at = v_now,
           last_seen_at = v_now
     where tenant_id = p_tenant_id
       and user_id = p_user_id
       and device_id = p_device_id
       and protocol_signing_algorithm = p_protocol_signing_algorithm
       and protocol_public_key_fingerprint = lower(p_protocol_public_key_fingerprint)
       and status = 'active';

    get diagnostics v_rows = row_count;

    return jsonb_build_object(
        'updated', v_rows = 1,
        'touched_at', v_now
    );
end;
$function$;

CREATE OR REPLACE FUNCTION public.unbind_contact_method(contact_type_param text, verification_code_param text, client_ip_param inet DEFAULT NULL::inet, client_user_agent_param text DEFAULT NULL::text)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    current_user_id UUID;
    current_contact_value TEXT;
    verification_result JSON;
    result JSON;
BEGIN
    -- 获取当前用户ID
    current_user_id := auth.uid();
    IF current_user_id IS NULL THEN
        RAISE EXCEPTION 'User not authenticated';
    END IF;

    -- 验证输入参数
    IF contact_type_param NOT IN ('email', 'phone') THEN
        RAISE EXCEPTION 'Invalid contact type. Must be email or phone';
    END IF;

    -- 获取当前绑定的联系方式
    IF contact_type_param = 'email' THEN
        SELECT email INTO current_contact_value
        FROM user_profiles
        WHERE id = current_user_id;
    ELSE
        SELECT phone INTO current_contact_value
        FROM user_profiles
        WHERE id = current_user_id;
    END IF;

    IF current_contact_value IS NULL THEN
        RETURN json_build_object(
            'success', false,
            'error', '您尚未绑定该' || CASE WHEN contact_type_param = 'email' THEN '邮箱' ELSE '手机号' END,
            'code', 'NOT_BOUND'
        );
    END IF;

    -- 验证验证码
    SELECT verify_verification_code(
        current_contact_value,
        contact_type_param,
        verification_code_param,
        'unbind'
    ) INTO verification_result;

    IF NOT (verification_result->>'success')::BOOLEAN THEN
        RETURN verification_result;
    END IF;

    -- 执行解绑
    IF contact_type_param = 'email' THEN
        UPDATE user_profiles
        SET email = NULL,
            updated_at = NOW()
        WHERE id = current_user_id;
    ELSE
        UPDATE user_profiles
        SET phone = NULL,
            updated_at = NOW()
        WHERE id = current_user_id;
    END IF;

    -- 记录解绑历史
    INSERT INTO account_bindings (
        user_id,
        contact_type,
        contact_value,
        action,
        verification_code,
        verified_at,
        ip_address,
        user_agent
    ) VALUES (
        current_user_id,
        contact_type_param,
        current_contact_value,
        'unbind',
        verification_code_param,
        NOW(),
        client_ip_param,
        client_user_agent_param
    );

    RETURN json_build_object(
        'success', true,
        'message', CASE WHEN contact_type_param = 'email' THEN '邮箱' ELSE '手机号' END || '解绑成功',
        'contact_type', contact_type_param,
        'previous_value', current_contact_value
    );
END;
$function$;

CREATE OR REPLACE FUNCTION public.update_channel_stats(p_channel text, p_success boolean, p_response_time integer DEFAULT NULL::integer)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
    INSERT INTO sms_channel_stats (channel, date, total_sent, success_count, failure_count, avg_response_time, consecutive_failures)
    VALUES (p_channel, CURRENT_DATE, 1,
            CASE WHEN p_success THEN 1 ELSE 0 END,
            CASE WHEN p_success THEN 0 ELSE 1 END,
            p_response_time,
            CASE WHEN p_success THEN 0 ELSE 1 END)
    ON CONFLICT (channel, date) DO UPDATE SET
        total_sent = sms_channel_stats.total_sent + 1,
        success_count = sms_channel_stats.success_count + CASE WHEN p_success THEN 1 ELSE 0 END,
        failure_count = sms_channel_stats.failure_count + CASE WHEN p_success THEN 0 ELSE 1 END,
        avg_response_time = CASE
            WHEN p_response_time IS NOT NULL THEN
                (COALESCE(sms_channel_stats.avg_response_time, 0) * sms_channel_stats.total_sent + p_response_time) / (sms_channel_stats.total_sent + 1)
            ELSE sms_channel_stats.avg_response_time
        END,
        consecutive_failures = CASE WHEN p_success THEN 0 ELSE sms_channel_stats.consecutive_failures + 1 END,
        last_failure_at = CASE WHEN p_success THEN sms_channel_stats.last_failure_at ELSE NOW() END,
        is_circuit_open = CASE WHEN NOT p_success AND sms_channel_stats.consecutive_failures >= 4 THEN TRUE ELSE FALSE END,
        circuit_open_until = CASE WHEN NOT p_success AND sms_channel_stats.consecutive_failures >= 4 THEN NOW() + INTERVAL '30 minutes' ELSE sms_channel_stats.circuit_open_until END,
        updated_at = NOW();
END;
$function$;

CREATE OR REPLACE FUNCTION public.update_profile_version()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  NEW.version = OLD.version + 1;
  NEW.etag = md5(random()::text || NEW.version::text);
  NEW.last_modified_at = NOW();
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.update_updated_at_column()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    NEW.updated_at = timezone('utc'::text, now());
    RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.verify_verification_code(contact_value_param text, contact_type_param text, code_param text, purpose_param text DEFAULT 'bind'::text)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    verification_record RECORD;
    current_user_id UUID;
    result JSON;
BEGIN
    -- 获取当前用户ID
    current_user_id := auth.uid();
    IF current_user_id IS NULL THEN
        RAISE EXCEPTION 'User not authenticated';
    END IF;

    -- 查找有效的验证码
    SELECT * INTO verification_record
    FROM verification_codes
    WHERE contact_value = contact_value_param
        AND contact_type = contact_type_param
        AND code = code_param
        AND purpose = purpose_param
        AND expires_at > NOW()
        AND is_used = FALSE
        AND attempts < max_attempts
    ORDER BY created_at DESC
    LIMIT 1;

    -- 如果没找到有效验证码
    IF NOT FOUND THEN
        -- 检查是否存在已过期或已使用的验证码
        IF EXISTS (
            SELECT 1 FROM verification_codes
            WHERE contact_value = contact_value_param
                AND contact_type = contact_type_param
                AND code = code_param
        ) THEN
            RETURN json_build_object(
                'success', false,
                'error', '验证码已过期或已使用',
                'code', 'CODE_EXPIRED_OR_USED'
            );
        ELSE
            RETURN json_build_object(
                'success', false,
                'error', '验证码不正确',
                'code', 'INVALID_CODE'
            );
        END IF;
    END IF;

    -- 标记验证码为已使用
    UPDATE verification_codes
    SET is_used = TRUE,
        used_at = NOW()
    WHERE id = verification_record.id;

    RETURN json_build_object(
        'success', true,
        'message', '验证码验证成功',
        'verification_id', verification_record.id
    );
END;
$function$;

CREATE OR REPLACE PROCEDURE public.scheduled_maintenance_4ea8045d()
 LANGUAGE plpgsql
AS $procedure$
            BEGIN
            PERFORM net.http_post(
            url:='https://hloqytmhjludmuhwyyzb.supabase.co/functions/v1/scheduled-maintenance',
            headers:=jsonb_build_object('Content-Type', 'application/json'),
            body:='{"edge_function_name":"scheduled-maintenance"}',
            timeout_milliseconds:=10000
            );
            COMMIT;
            END;
            $procedure$;

SET check_function_bodies = true;

ALTER TABLE public."account_bindings" ADD CONSTRAINT "account_bindings_action_check" CHECK (((action)::text = ANY (ARRAY[('bind'::character varying)::text, ('unbind'::character varying)::text])));

ALTER TABLE public."account_bindings" ADD CONSTRAINT "account_bindings_contact_type_check" CHECK (((contact_type)::text = ANY (ARRAY[('email'::character varying)::text, ('phone'::character varying)::text])));

ALTER TABLE public."cli_login_sessions" ADD CONSTRAINT "cli_login_sessions_status_check" CHECK ((status = ANY (ARRAY['pending'::text, 'approved'::text, 'cancelled'::text, 'expired'::text])));

ALTER TABLE public."device_enrollment_invites" ADD CONSTRAINT "device_enrollment_invites_issued_channel_check" CHECK ((issued_channel = ANY (ARRAY['admin_console'::text, 'email'::text, 'manual'::text])));

ALTER TABLE public."device_enrollment_invites" ADD CONSTRAINT "device_enrollment_invites_state_check" CHECK ((state = ANY (ARRAY['issued'::text, 'consumed'::text, 'revoked'::text, 'expired'::text])));

ALTER TABLE public."device_identity_history" ADD CONSTRAINT "device_identity_history_check" CHECK (is_valid_protocol_identity_key_v6(protocol_signing_algorithm, protocol_public_key_base64));

ALTER TABLE public."device_identity_history" ADD CONSTRAINT "device_identity_history_check1" CHECK ((((state = 'active'::text) AND (grace_started_at IS NULL) AND (grace_expires_at IS NULL) AND (revoked_at IS NULL)) OR ((state = 'grace'::text) AND (grace_started_at IS NOT NULL) AND (grace_expires_at IS NOT NULL) AND (revoked_at IS NULL)) OR ((state = 'revoked'::text) AND (revoked_at IS NOT NULL))));

ALTER TABLE public."device_identity_history" ADD CONSTRAINT "device_identity_history_generation_check" CHECK ((generation > 0));

ALTER TABLE public."device_identity_history" ADD CONSTRAINT "device_identity_history_key_material_v9" CHECK ((((state = 'revoked'::text) AND (protocol_public_key_base64 IS NULL)) OR ((protocol_public_key_base64 IS NOT NULL) AND is_valid_protocol_identity_key_v6(protocol_signing_algorithm, protocol_public_key_base64))));

ALTER TABLE public."device_identity_history" ADD CONSTRAINT "device_identity_history_protocol_public_key_fingerprint_check" CHECK ((protocol_public_key_fingerprint ~ '^[0-9a-f]{64}$'::text));

ALTER TABLE public."device_identity_history" ADD CONSTRAINT "device_identity_history_protocol_signing_algorithm_check" CHECK ((protocol_signing_algorithm = ANY (ARRAY['Ed25519'::text, 'ML-DSA-65'::text, 'ML-DSA-87'::text])));

ALTER TABLE public."device_identity_history" ADD CONSTRAINT "device_identity_history_state_check" CHECK ((state = ANY (ARRAY['active'::text, 'grace'::text, 'revoked'::text])));

ALTER TABLE public."device_identity_rotation_audit" ADD CONSTRAINT "device_identity_rotation_audit_event_type_check" CHECK ((event_type = ANY (ARRAY['challenged'::text, 'committed'::text, 'expired'::text, 'cancelled'::text])));

ALTER TABLE public."device_identity_rotation_audit" ADD CONSTRAINT "device_identity_rotation_audit_transcript_hash_check" CHECK ((transcript_hash ~ '^[0-9a-f]{64}$'::text));

ALTER TABLE public."device_identity_rotations" ADD CONSTRAINT "device_identity_rotations_check" CHECK ((expires_at > issued_at));

ALTER TABLE public."device_identity_rotations" ADD CONSTRAINT "device_identity_rotations_check1" CHECK (is_valid_protocol_identity_key_v6(old_protocol_signing_algorithm, old_protocol_public_key_base64));

ALTER TABLE public."device_identity_rotations" ADD CONSTRAINT "device_identity_rotations_check2" CHECK (is_valid_protocol_identity_key_v6(new_protocol_signing_algorithm, new_protocol_public_key_base64));

ALTER TABLE public."device_identity_rotations" ADD CONSTRAINT "device_identity_rotations_committed_generation_check" CHECK (((committed_generation IS NULL) OR (committed_generation > 0)));

ALTER TABLE public."device_identity_rotations" ADD CONSTRAINT "device_identity_rotations_new_protocol_public_key_fingerp_check" CHECK ((new_protocol_public_key_fingerprint ~ '^[0-9a-f]{64}$'::text));

ALTER TABLE public."device_identity_rotations" ADD CONSTRAINT "device_identity_rotations_new_protocol_signing_algorithm_check" CHECK ((new_protocol_signing_algorithm = ANY (ARRAY['Ed25519'::text, 'ML-DSA-65'::text, 'ML-DSA-87'::text])));

ALTER TABLE public."device_identity_rotations" ADD CONSTRAINT "device_identity_rotations_nonce_check" CHECK ((nonce ~ '^[A-Za-z0-9_-]{43}$'::text));

ALTER TABLE public."device_identity_rotations" ADD CONSTRAINT "device_identity_rotations_old_generation_check" CHECK ((old_generation > 0));

ALTER TABLE public."device_identity_rotations" ADD CONSTRAINT "device_identity_rotations_old_protocol_public_key_fingerp_check" CHECK ((old_protocol_public_key_fingerprint ~ '^[0-9a-f]{64}$'::text));

ALTER TABLE public."device_identity_rotations" ADD CONSTRAINT "device_identity_rotations_old_protocol_signing_algorithm_check" CHECK ((old_protocol_signing_algorithm = ANY (ARRAY['Ed25519'::text, 'ML-DSA-65'::text, 'ML-DSA-87'::text])));

ALTER TABLE public."device_identity_rotations" ADD CONSTRAINT "device_identity_rotations_state_check" CHECK ((state = ANY (ARRAY['issued'::text, 'committed'::text, 'expired'::text, 'cancelled'::text])));

ALTER TABLE public."device_identity_rotations" ADD CONSTRAINT "device_identity_rotations_transcript_hash_check" CHECK ((transcript_hash ~ '^[0-9a-f]{64}$'::text));

ALTER TABLE public."registered_devices" ADD CONSTRAINT "registered_devices_approval_method_check" CHECK (((approval_method IS NULL) OR (approval_method = ANY (ARRAY['invite_token'::text, 'trusted_device_confirmation'::text, 'key_rotation_confirmation'::text, 'admin_override'::text]))));

ALTER TABLE public."registered_devices" ADD CONSTRAINT "registered_devices_identity_generation_check" CHECK ((identity_generation > 0));

ALTER TABLE public."registered_devices" ADD CONSTRAINT "registered_devices_presence_metadata_bounds_v7" CHECK ((((platform IS NULL) OR ((char_length(platform) <= 32) AND (platform ~ '^[a-z0-9_]+$'::text))) AND ((device_model IS NULL) OR (octet_length(device_model) <= 64)) AND ((os_version IS NULL) OR (octet_length(os_version) <= 64)) AND ((app_version IS NULL) OR (octet_length(app_version) <= 64)) AND ((last_lan_addresses IS NULL) OR (cardinality(last_lan_addresses) <= 8)) AND ((last_public_address IS NULL) OR (octet_length(last_public_address) <= 64)) AND ((last_capabilities IS NULL) OR (cardinality(last_capabilities) <= 16))));

ALTER TABLE public."registered_devices" ADD CONSTRAINT "registered_devices_status_check" CHECK ((status = ANY (ARRAY['pending'::text, 'active'::text, 'frozen'::text, 'revoked'::text])));

ALTER TABLE public."registration_attempt_tickets" ADD CONSTRAINT "registration_attempt_tickets_attempt_type_check" CHECK ((attempt_type = ANY (ARRAY['register'::text, 'verify_code'::text, 'login'::text])));

ALTER TABLE public."registration_attempt_tickets" ADD CONSTRAINT "registration_attempt_tickets_identifier_type_check" CHECK ((identifier_type = ANY (ARRAY['email'::text, 'phone'::text, 'username'::text])));

ALTER TABLE public."registration_attempts" ADD CONSTRAINT "registration_attempts_attempt_type_check" CHECK ((attempt_type = ANY (ARRAY['register'::text, 'verify_code'::text, 'login'::text])));

ALTER TABLE public."registration_attempts" ADD CONSTRAINT "registration_attempts_identifier_type_check" CHECK ((identifier_type = ANY (ARRAY['phone'::text, 'email'::text, 'username'::text])));

ALTER TABLE public."registration_blacklist" ADD CONSTRAINT "registration_blacklist_blacklist_type_check" CHECK ((blacklist_type = ANY (ARRAY['ip'::text, 'device_fingerprint'::text, 'identifier'::text, 'email_domain'::text])));

ALTER TABLE public."user_error_logs" ADD CONSTRAINT "user_error_logs_severity_check" CHECK ((severity = ANY (ARRAY['info'::text, 'warning'::text, 'error'::text, 'critical'::text])));

ALTER TABLE public."user_profiles" ADD CONSTRAINT "check_custom_user_id_format" CHECK (((custom_user_id IS NULL) OR ((custom_user_id ~ '^[\u4e00-\u9fff\u3400-\u4dbfa-zA-Z0-9_-]+$'::text) AND (length(custom_user_id) <= 50))));

ALTER TABLE public."user_profiles" ADD CONSTRAINT "check_custom_user_id_length" CHECK (((custom_user_id IS NULL) OR ((length(custom_user_id) >= 3) AND (length(custom_user_id) <= 30))));

ALTER TABLE public."user_profiles" ADD CONSTRAINT "user_profiles_account_type_check" CHECK ((account_type = ANY (ARRAY['email'::text, 'constellation'::text, 'phone'::text])));

ALTER TABLE public."verification_codes" ADD CONSTRAINT "verification_codes_contact_type_check" CHECK (((contact_type)::text = ANY (ARRAY[('email'::character varying)::text, ('phone'::character varying)::text])));

ALTER TABLE public."verification_codes" ADD CONSTRAINT "verification_codes_purpose_check" CHECK (((purpose)::text = ANY (ARRAY[('bind'::character varying)::text, ('unbind'::character varying)::text, ('verify'::character varying)::text])));

ALTER TABLE public."account_bindings" ADD CONSTRAINT "account_bindings_pkey" PRIMARY KEY (id);

ALTER TABLE public."account_links" ADD CONSTRAINT "account_links_pkey" PRIMARY KEY (id);

ALTER TABLE public."activity_logs" ADD CONSTRAINT "activity_logs_pkey" PRIMARY KEY (id);

ALTER TABLE public."api_keys" ADD CONSTRAINT "api_keys_pkey" PRIMARY KEY (id);

ALTER TABLE public."audit_logs" ADD CONSTRAINT "audit_logs_pkey" PRIMARY KEY (id);

ALTER TABLE public."auth_methods" ADD CONSTRAINT "auth_methods_pkey" PRIMARY KEY (id);

ALTER TABLE public."cli_login_sessions" ADD CONSTRAINT "cli_login_sessions_pkey" PRIMARY KEY (session_id);

ALTER TABLE public."constellation_data" ADD CONSTRAINT "constellation_data_pkey" PRIMARY KEY (id);

ALTER TABLE public."constellations" ADD CONSTRAINT "constellations_pkey" PRIMARY KEY (id);

ALTER TABLE public."contact_submissions" ADD CONSTRAINT "contact_submissions_pkey" PRIMARY KEY (id);

ALTER TABLE public."device_connections" ADD CONSTRAINT "device_connections_pkey" PRIMARY KEY (id);

ALTER TABLE public."device_enrollment_invites" ADD CONSTRAINT "device_enrollment_invites_pkey" PRIMARY KEY (id);

ALTER TABLE public."device_group_members" ADD CONSTRAINT "device_group_members_pkey" PRIMARY KEY (id);

ALTER TABLE public."device_groups" ADD CONSTRAINT "device_groups_pkey" PRIMARY KEY (id);

ALTER TABLE public."device_identity_history" ADD CONSTRAINT "device_identity_history_pkey" PRIMARY KEY (id);

ALTER TABLE public."device_identity_rotation_audit" ADD CONSTRAINT "device_identity_rotation_audit_pkey" PRIMARY KEY (id);

ALTER TABLE public."device_identity_rotations" ADD CONSTRAINT "device_identity_rotations_pkey" PRIMARY KEY (rotation_id);

ALTER TABLE public."device_pairings" ADD CONSTRAINT "device_pairings_pkey" PRIMARY KEY (id);

ALTER TABLE public."device_permissions" ADD CONSTRAINT "device_permissions_pkey" PRIMARY KEY (id);

ALTER TABLE public."devices" ADD CONSTRAINT "devices_pkey" PRIMARY KEY (id);

ALTER TABLE public."disposable_email_domains" ADD CONSTRAINT "disposable_email_domains_pkey" PRIMARY KEY (domain);

ALTER TABLE public."file_transfers" ADD CONSTRAINT "file_transfers_pkey" PRIMARY KEY (id);

ALTER TABLE public."idempotent_requests" ADD CONSTRAINT "idempotent_requests_pkey" PRIMARY KEY (id);

ALTER TABLE public."mfa_settings" ADD CONSTRAINT "mfa_settings_pkey" PRIMARY KEY (id);

ALTER TABLE public."nebula_accounts" ADD CONSTRAINT "nebula_accounts_pkey" PRIMARY KEY (id);

ALTER TABLE public."nebula_id_sequence" ADD CONSTRAINT "nebula_id_sequence_pkey" PRIMARY KEY (id);

ALTER TABLE public."nebula_privileges" ADD CONSTRAINT "nebula_privileges_pkey" PRIMARY KEY (id);

ALTER TABLE public."nebula_security_logs" ADD CONSTRAINT "nebula_security_logs_pkey" PRIMARY KEY (id);

ALTER TABLE public."nebula_sessions" ADD CONSTRAINT "nebula_sessions_pkey" PRIMARY KEY (id);

ALTER TABLE public."notifications" ADD CONSTRAINT "notifications_pkey" PRIMARY KEY (id);

ALTER TABLE public."oauth_accounts" ADD CONSTRAINT "oauth_accounts_pkey" PRIMARY KEY (id);

ALTER TABLE public."performance_metrics" ADD CONSTRAINT "performance_metrics_pkey" PRIMARY KEY (id);

ALTER TABLE public."phone_auth" ADD CONSTRAINT "phone_auth_pkey" PRIMARY KEY (id);

ALTER TABLE public."profiles" ADD CONSTRAINT "profiles_pkey" PRIMARY KEY (id);

ALTER TABLE public."rate_limit_config" ADD CONSTRAINT "rate_limit_config_pkey" PRIMARY KEY (id);

ALTER TABLE public."real_time_messages" ADD CONSTRAINT "real_time_messages_pkey" PRIMARY KEY (id);

ALTER TABLE public."registered_devices" ADD CONSTRAINT "registered_devices_pkey" PRIMARY KEY (id);

ALTER TABLE public."registration_attempt_tickets" ADD CONSTRAINT "registration_attempt_tickets_pkey" PRIMARY KEY (id);

ALTER TABLE public."registration_attempts" ADD CONSTRAINT "registration_attempts_pkey" PRIMARY KEY (id);

ALTER TABLE public."registration_blacklist" ADD CONSTRAINT "registration_blacklist_pkey" PRIMARY KEY (id);

ALTER TABLE public."remote_connections" ADD CONSTRAINT "remote_connections_pkey" PRIMARY KEY (id);

ALTER TABLE public."security_logs" ADD CONSTRAINT "security_logs_pkey" PRIMARY KEY (id);

ALTER TABLE public."send_rate_limits" ADD CONSTRAINT "send_rate_limits_pkey" PRIMARY KEY (id);

ALTER TABLE public."session_messages" ADD CONSTRAINT "session_messages_pkey" PRIMARY KEY (id);

ALTER TABLE public."sms_channel_stats" ADD CONSTRAINT "sms_channel_stats_pkey" PRIMARY KEY (id);

ALTER TABLE public."sms_delivery_callbacks" ADD CONSTRAINT "sms_delivery_callbacks_pkey" PRIMARY KEY (id);

ALTER TABLE public."sync_status" ADD CONSTRAINT "sync_status_pkey" PRIMARY KEY (id);

ALTER TABLE public."system_logs" ADD CONSTRAINT "system_logs_pkey" PRIMARY KEY (id);

ALTER TABLE public."tenant_security_policy" ADD CONSTRAINT "tenant_security_policy_pkey" PRIMARY KEY (tenant_id);

ALTER TABLE public."universal_users" ADD CONSTRAINT "universal_users_pkey" PRIMARY KEY (id);

ALTER TABLE public."user_activity" ADD CONSTRAINT "user_activity_pkey" PRIMARY KEY (id);

ALTER TABLE public."user_analytics" ADD CONSTRAINT "user_analytics_pkey" PRIMARY KEY (id);

ALTER TABLE public."user_avatars" ADD CONSTRAINT "user_avatars_pkey" PRIMARY KEY (id);

ALTER TABLE public."user_devices" ADD CONSTRAINT "user_devices_pkey" PRIMARY KEY (id);

ALTER TABLE public."user_error_logs" ADD CONSTRAINT "user_error_logs_pkey" PRIMARY KEY (id);

ALTER TABLE public."user_preferences" ADD CONSTRAINT "user_preferences_pkey" PRIMARY KEY (id);

ALTER TABLE public."user_profiles" ADD CONSTRAINT "user_profiles_pkey" PRIMARY KEY (id);

ALTER TABLE public."user_sessions" ADD CONSTRAINT "user_sessions_pkey" PRIMARY KEY (id);

ALTER TABLE public."user_settings" ADD CONSTRAINT "user_settings_pkey" PRIMARY KEY (id);

ALTER TABLE public."username_change_limits" ADD CONSTRAINT "username_change_limits_pkey" PRIMARY KEY (id);

ALTER TABLE public."username_history" ADD CONSTRAINT "username_history_pkey" PRIMARY KEY (id);

ALTER TABLE public."verification_code_records" ADD CONSTRAINT "verification_code_records_pkey" PRIMARY KEY (id);

ALTER TABLE public."verification_codes" ADD CONSTRAINT "verification_codes_pkey" PRIMARY KEY (id);

ALTER TABLE public."account_links" ADD CONSTRAINT "account_links_primary_user_id_linked_user_id_key" UNIQUE (primary_user_id, linked_user_id);

ALTER TABLE public."api_keys" ADD CONSTRAINT "api_keys_api_key_key" UNIQUE (api_key);

ALTER TABLE public."auth_methods" ADD CONSTRAINT "auth_methods_auth_type_identifier_key" UNIQUE (auth_type, identifier);

ALTER TABLE public."constellation_data" ADD CONSTRAINT "constellation_data_code_key" UNIQUE (code);

ALTER TABLE public."constellations" ADD CONSTRAINT "constellations_code_key" UNIQUE (code);

ALTER TABLE public."device_enrollment_invites" ADD CONSTRAINT "device_enrollment_invites_invite_token_hash_key" UNIQUE (invite_token_hash);

ALTER TABLE public."device_identity_history" ADD CONSTRAINT "device_identity_history_tenant_id_protocol_signing_algorith_key" UNIQUE (tenant_id, protocol_signing_algorithm, protocol_public_key_fingerprint);

ALTER TABLE public."device_identity_history" ADD CONSTRAINT "device_identity_history_tenant_id_user_id_device_id_generat_key" UNIQUE (tenant_id, user_id, device_id, generation);

ALTER TABLE public."device_identity_rotation_audit" ADD CONSTRAINT "device_identity_rotation_audit_rotation_id_event_type_key" UNIQUE (rotation_id, event_type);

ALTER TABLE public."device_pairings" ADD CONSTRAINT "device_pairings_pairing_code_key" UNIQUE (pairing_code);

ALTER TABLE public."devices" ADD CONSTRAINT "devices_device_token_key" UNIQUE (device_token);

ALTER TABLE public."idempotent_requests" ADD CONSTRAINT "idempotent_requests_key_user_id_key" UNIQUE (key, user_id);

ALTER TABLE public."nebula_accounts" ADD CONSTRAINT "nebula_accounts_nebula_id_key" UNIQUE (nebula_id);

ALTER TABLE public."nebula_sessions" ADD CONSTRAINT "nebula_sessions_session_token_key" UNIQUE (session_token);

ALTER TABLE public."oauth_accounts" ADD CONSTRAINT "oauth_accounts_provider_provider_user_id_key" UNIQUE (provider, provider_user_id);

ALTER TABLE public."phone_auth" ADD CONSTRAINT "phone_auth_phone_number_key" UNIQUE (phone_number);

ALTER TABLE public."rate_limit_config" ADD CONSTRAINT "rate_limit_config_config_name_key" UNIQUE (config_name);

ALTER TABLE public."registered_devices" ADD CONSTRAINT "registered_devices_tenant_id_protocol_signing_algorithm_pro_key" UNIQUE (tenant_id, protocol_signing_algorithm, protocol_public_key_fingerprint);

ALTER TABLE public."registered_devices" ADD CONSTRAINT "registered_devices_tenant_id_user_id_device_id_key" UNIQUE (tenant_id, user_id, device_id);

ALTER TABLE public."registration_blacklist" ADD CONSTRAINT "registration_blacklist_blacklist_type_value_key" UNIQUE (blacklist_type, value);

ALTER TABLE public."remote_connections" ADD CONSTRAINT "remote_connections_session_id_key" UNIQUE (session_id);

ALTER TABLE public."send_rate_limits" ADD CONSTRAINT "send_rate_limits_limit_type_limit_value_window_start_key" UNIQUE (limit_type, limit_value, window_start);

ALTER TABLE public."sms_channel_stats" ADD CONSTRAINT "sms_channel_stats_channel_date_key" UNIQUE (channel, date);

ALTER TABLE public."sync_status" ADD CONSTRAINT "sync_status_user_id_key" UNIQUE (user_id);

ALTER TABLE public."universal_users" ADD CONSTRAINT "universal_users_universal_id_key" UNIQUE (universal_id);

ALTER TABLE public."user_analytics" ADD CONSTRAINT "user_analytics_user_id_date_key" UNIQUE (user_id, date);

ALTER TABLE public."user_devices" ADD CONSTRAINT "user_devices_device_fingerprint_key" UNIQUE (device_fingerprint);

ALTER TABLE public."user_profiles" ADD CONSTRAINT "user_profiles_custom_user_id_key" UNIQUE (custom_user_id);

ALTER TABLE public."user_profiles" ADD CONSTRAINT "user_profiles_email_key" UNIQUE (email);

ALTER TABLE public."user_profiles" ADD CONSTRAINT "user_profiles_nebula_id_key" UNIQUE (nebula_id);

ALTER TABLE public."user_sessions" ADD CONSTRAINT "user_sessions_session_token_key" UNIQUE (session_token);

ALTER TABLE public."username_change_limits" ADD CONSTRAINT "username_change_limits_user_id_key" UNIQUE (user_id);

ALTER TABLE public."account_bindings" ADD CONSTRAINT "account_bindings_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;

ALTER TABLE public."account_links" ADD CONSTRAINT "account_links_linked_user_id_fkey" FOREIGN KEY (linked_user_id) REFERENCES universal_users(id) ON DELETE CASCADE;

ALTER TABLE public."account_links" ADD CONSTRAINT "account_links_primary_user_id_fkey" FOREIGN KEY (primary_user_id) REFERENCES universal_users(id) ON DELETE CASCADE;

ALTER TABLE public."activity_logs" ADD CONSTRAINT "activity_logs_user_id_fkey" FOREIGN KEY (user_id) REFERENCES universal_users(id) ON DELETE CASCADE;

ALTER TABLE public."auth_methods" ADD CONSTRAINT "auth_methods_user_id_fkey" FOREIGN KEY (user_id) REFERENCES universal_users(id) ON DELETE CASCADE;

ALTER TABLE public."device_groups" ADD CONSTRAINT "device_groups_owner_id_fkey" FOREIGN KEY (owner_id) REFERENCES auth.users(id) ON DELETE CASCADE;

ALTER TABLE public."device_identity_history" ADD CONSTRAINT "device_identity_history_source_rotation_id_fkey" FOREIGN KEY (source_rotation_id) REFERENCES device_identity_rotations(rotation_id);

ALTER TABLE public."device_identity_rotation_audit" ADD CONSTRAINT "device_identity_rotation_audit_rotation_id_fkey" FOREIGN KEY (rotation_id) REFERENCES device_identity_rotations(rotation_id);

ALTER TABLE public."devices" ADD CONSTRAINT "devices_owner_id_fkey" FOREIGN KEY (owner_id) REFERENCES auth.users(id) ON DELETE CASCADE;

ALTER TABLE public."nebula_accounts" ADD CONSTRAINT "nebula_accounts_constellation_id_fkey" FOREIGN KEY (constellation_id) REFERENCES constellations(id);

ALTER TABLE public."nebula_accounts" ADD CONSTRAINT "nebula_accounts_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;

ALTER TABLE public."nebula_privileges" ADD CONSTRAINT "nebula_privileges_nebula_id_fkey" FOREIGN KEY (nebula_id) REFERENCES nebula_accounts(nebula_id) ON DELETE CASCADE;

ALTER TABLE public."nebula_security_logs" ADD CONSTRAINT "nebula_security_logs_nebula_id_fkey" FOREIGN KEY (nebula_id) REFERENCES nebula_accounts(nebula_id) ON DELETE CASCADE;

ALTER TABLE public."nebula_sessions" ADD CONSTRAINT "nebula_sessions_nebula_id_fkey" FOREIGN KEY (nebula_id) REFERENCES nebula_accounts(nebula_id) ON DELETE CASCADE;

ALTER TABLE public."oauth_accounts" ADD CONSTRAINT "oauth_accounts_user_id_fkey" FOREIGN KEY (user_id) REFERENCES universal_users(id) ON DELETE CASCADE;

ALTER TABLE public."phone_auth" ADD CONSTRAINT "phone_auth_user_id_fkey" FOREIGN KEY (user_id) REFERENCES universal_users(id) ON DELETE CASCADE;

ALTER TABLE public."profiles" ADD CONSTRAINT "profiles_id_fkey" FOREIGN KEY (id) REFERENCES auth.users(id);

ALTER TABLE public."registration_blacklist" ADD CONSTRAINT "registration_blacklist_created_by_fkey" FOREIGN KEY (created_by) REFERENCES auth.users(id);

ALTER TABLE public."sms_delivery_callbacks" ADD CONSTRAINT "sms_delivery_callbacks_record_id_fkey" FOREIGN KEY (record_id) REFERENCES verification_code_records(id);

ALTER TABLE public."sync_status" ADD CONSTRAINT "sync_status_user_id_fkey" FOREIGN KEY (user_id) REFERENCES universal_users(id) ON DELETE CASCADE;

ALTER TABLE public."universal_users" ADD CONSTRAINT "universal_users_auth_user_id_fkey" FOREIGN KEY (auth_user_id) REFERENCES auth.users(id) ON DELETE CASCADE;

ALTER TABLE public."user_avatars" ADD CONSTRAINT "user_avatars_user_id_fkey" FOREIGN KEY (user_id) REFERENCES universal_users(id) ON DELETE CASCADE;

ALTER TABLE public."user_preferences" ADD CONSTRAINT "user_preferences_user_id_fkey" FOREIGN KEY (user_id) REFERENCES user_profiles(id) ON DELETE CASCADE;

ALTER TABLE public."user_sessions" ADD CONSTRAINT "user_sessions_auth_method_id_fkey" FOREIGN KEY (auth_method_id) REFERENCES auth_methods(id);

ALTER TABLE public."user_sessions" ADD CONSTRAINT "user_sessions_user_id_fkey" FOREIGN KEY (user_id) REFERENCES universal_users(id) ON DELETE CASCADE;

ALTER TABLE public."username_change_limits" ADD CONSTRAINT "username_change_limits_user_id_fkey" FOREIGN KEY (user_id) REFERENCES universal_users(id) ON DELETE CASCADE;

ALTER TABLE public."username_history" ADD CONSTRAINT "username_history_changed_by_user_id_fkey" FOREIGN KEY (changed_by_user_id) REFERENCES universal_users(id);

ALTER TABLE public."username_history" ADD CONSTRAINT "username_history_user_id_fkey" FOREIGN KEY (user_id) REFERENCES universal_users(id) ON DELETE CASCADE;

ALTER TABLE public."verification_codes" ADD CONSTRAINT "verification_codes_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;

CREATE INDEX cli_login_sessions_status_expires_idx ON public.cli_login_sessions USING btree (status, expires_at DESC);

CREATE INDEX cli_login_sessions_auth_user_idx ON public.cli_login_sessions USING btree (auth_user_id) WHERE (auth_user_id IS NOT NULL);

CREATE INDEX idx_reg_attempts_ip ON public.registration_attempts USING btree (ip_address, created_at DESC);

CREATE INDEX idx_reg_attempts_device ON public.registration_attempts USING btree (device_fingerprint, created_at DESC);

CREATE INDEX idx_reg_attempts_identifier ON public.registration_attempts USING btree (identifier_hash, created_at DESC);

CREATE INDEX idx_reg_attempts_type ON public.registration_attempts USING btree (attempt_type, created_at DESC);

CREATE INDEX idx_reg_attempts_created ON public.registration_attempts USING btree (created_at DESC);

CREATE INDEX idx_blacklist_type_value ON public.registration_blacklist USING btree (blacklist_type, value);

CREATE INDEX idx_blacklist_expires ON public.registration_blacklist USING btree (expires_at) WHERE (expires_at IS NOT NULL);

CREATE INDEX idx_vcode_phone ON public.verification_code_records USING btree (phone_number, created_at DESC);

CREATE INDEX idx_vcode_device ON public.verification_code_records USING btree (device_fingerprint, created_at DESC);

CREATE INDEX idx_vcode_status ON public.verification_code_records USING btree (status, created_at DESC);

CREATE INDEX idx_vcode_channel ON public.verification_code_records USING btree (channel, created_at DESC);

CREATE INDEX idx_vcode_message_id ON public.verification_code_records USING btree (message_id) WHERE (message_id IS NOT NULL);

CREATE INDEX idx_channel_stats_date ON public.sms_channel_stats USING btree (date DESC);

CREATE INDEX idx_rate_limits_value ON public.send_rate_limits USING btree (limit_type, limit_value, window_end DESC);

CREATE INDEX idx_callback_message ON public.sms_delivery_callbacks USING btree (message_id);

CREATE INDEX idx_callback_record ON public.sms_delivery_callbacks USING btree (record_id);

CREATE INDEX idx_registration_attempt_tickets_attempt_type ON public.registration_attempt_tickets USING btree (attempt_type, expires_at);

CREATE INDEX idx_registration_attempt_tickets_expires_at ON public.registration_attempt_tickets USING btree (expires_at);

CREATE INDEX idx_registration_attempt_tickets_lookup ON public.registration_attempt_tickets USING btree (identifier_hash, device_fingerprint, ip_address);

CREATE INDEX idx_account_bindings_contact_type ON public.account_bindings USING btree (contact_type);

CREATE INDEX idx_account_bindings_created_at ON public.account_bindings USING btree (created_at);

CREATE INDEX idx_account_bindings_user_id ON public.account_bindings USING btree (user_id);

CREATE INDEX idx_api_keys_key ON public.api_keys USING btree (api_key) WHERE (is_active = true);

CREATE INDEX idx_api_keys_user ON public.api_keys USING btree (user_id, is_active);

CREATE INDEX idx_activity_logs_created_at ON public.activity_logs USING btree (created_at DESC);

CREATE INDEX idx_activity_logs_type ON public.activity_logs USING btree (activity_type);

CREATE INDEX idx_activity_logs_user_id ON public.activity_logs USING btree (user_id);

CREATE INDEX idx_auth_methods_identifier ON public.auth_methods USING btree (identifier);

CREATE INDEX idx_auth_methods_type_provider ON public.auth_methods USING btree (auth_type, auth_provider);

CREATE INDEX idx_auth_methods_user_id ON public.auth_methods USING btree (user_id);

CREATE INDEX idx_connections_controller ON public.device_connections USING btree (controller_device_id, connection_status);

CREATE INDEX idx_connections_target ON public.device_connections USING btree (target_device_id, connection_status);

CREATE INDEX idx_devices_last_seen ON public.devices USING btree (last_seen_at DESC);

CREATE INDEX idx_devices_owner_online ON public.devices USING btree (owner_id, is_online);

CREATE INDEX idx_devices_token ON public.devices USING btree (device_token);

CREATE INDEX idx_permissions_controller ON public.device_permissions USING btree (controller_device_id, is_active);

CREATE INDEX idx_permissions_target ON public.device_permissions USING btree (target_device_id, is_active);

CREATE INDEX idx_idempotent_requests_created_at ON public.idempotent_requests USING btree (created_at);

CREATE INDEX idx_idempotent_requests_key_user ON public.idempotent_requests USING btree (key, user_id);

CREATE INDEX device_enrollment_invites_target_idx ON public.device_enrollment_invites USING btree (tenant_id, target_user_id, state);

CREATE INDEX idx_nebula_accounts_constellation_id_new ON public.nebula_accounts USING btree (constellation_id);

CREATE INDEX idx_nebula_accounts_id ON public.nebula_accounts USING btree (id);

CREATE INDEX idx_messages_receiver ON public.real_time_messages USING btree (receiver_device_id, is_delivered, created_at DESC);

CREATE INDEX idx_messages_sender ON public.real_time_messages USING btree (sender_device_id, created_at DESC);

CREATE INDEX idx_notifications_user_id ON public.notifications USING btree (user_id);

CREATE INDEX idx_oauth_accounts_provider ON public.oauth_accounts USING btree (provider, provider_user_id);

CREATE INDEX idx_phone_auth_phone ON public.phone_auth USING btree (phone_number);

CREATE INDEX idx_logs_device_category ON public.system_logs USING btree (device_id, log_category, created_at DESC);

CREATE INDEX idx_logs_user ON public.system_logs USING btree (user_id, created_at DESC);

CREATE UNIQUE INDEX device_identity_rotations_request_id_idx ON public.device_identity_rotations USING btree (tenant_id, user_id, device_id, request_id);

CREATE UNIQUE INDEX device_identity_rotations_one_issued_per_device_idx ON public.device_identity_rotations USING btree (tenant_id, user_id, device_id) WHERE (state = 'issued'::text);

CREATE UNIQUE INDEX device_identity_rotations_one_issued_per_new_key_idx ON public.device_identity_rotations USING btree (tenant_id, new_protocol_signing_algorithm, new_protocol_public_key_fingerprint) WHERE (state = 'issued'::text);

CREATE INDEX device_identity_rotations_new_key_idx ON public.device_identity_rotations USING btree (tenant_id, new_protocol_signing_algorithm, new_protocol_public_key_fingerprint, state);

CREATE INDEX device_identity_rotations_device_issued_at_idx ON public.device_identity_rotations USING btree (tenant_id, user_id, device_id, issued_at DESC);

CREATE INDEX device_identity_rotations_user_issued_at_idx ON public.device_identity_rotations USING btree (tenant_id, user_id, issued_at DESC);

CREATE UNIQUE INDEX device_identity_history_one_active_per_device_idx ON public.device_identity_history USING btree (tenant_id, user_id, device_id) WHERE (state = 'active'::text);

CREATE INDEX device_identity_history_device_generation_idx ON public.device_identity_history USING btree (tenant_id, user_id, device_id, generation DESC);

CREATE INDEX idx_sync_status_user_id ON public.sync_status USING btree (user_id);

CREATE INDEX idx_user_error_logs_user_id_created ON public.user_error_logs USING btree (user_id, created_at DESC);

CREATE INDEX idx_user_avatars_active ON public.user_avatars USING btree (user_id) WHERE (is_active = true);

CREATE INDEX idx_user_avatars_user_id ON public.user_avatars USING btree (user_id);

CREATE UNIQUE INDEX user_avatars_active_per_user_uidx ON public.user_avatars USING btree (user_id) WHERE is_active;

CREATE INDEX user_avatars_user_created_idx ON public.user_avatars USING btree (user_id, created_at DESC);

CREATE INDEX registered_devices_tenant_user_status_idx ON public.registered_devices USING btree (tenant_id, user_id, status);

CREATE INDEX idx_user_sessions_token ON public.user_sessions USING btree (session_token);

CREATE INDEX idx_user_sessions_user_id ON public.user_sessions USING btree (user_id);

CREATE INDEX idx_username_change_limits_user_id ON public.username_change_limits USING btree (user_id);

CREATE INDEX idx_username_history_user_id ON public.username_history USING btree (user_id);

CREATE INDEX idx_verification_codes_code ON public.verification_codes USING btree (code);

CREATE INDEX idx_verification_codes_contact ON public.verification_codes USING btree (contact_value, contact_type);

CREATE INDEX idx_verification_codes_expires_at ON public.verification_codes USING btree (expires_at);

CREATE INDEX idx_verification_codes_user_id ON public.verification_codes USING btree (user_id);

CREATE INDEX idx_user_activity_event_type ON public.user_activity USING btree (event_type);

CREATE INDEX idx_user_activity_session_id ON public.user_activity USING btree (session_id);

CREATE INDEX idx_user_activity_timestamp ON public.user_activity USING btree ("timestamp" DESC);

CREATE INDEX idx_user_activity_user_id ON public.user_activity USING btree (user_id);

CREATE INDEX idx_universal_users_email ON public.universal_users USING btree (primary_email);

CREATE INDEX idx_universal_users_phone ON public.universal_users USING btree (primary_phone);

CREATE INDEX idx_universal_users_universal_id ON public.universal_users USING btree (universal_id);

CREATE UNIQUE INDEX idx_universal_users_username_unique ON public.universal_users USING btree (username) WHERE (username IS NOT NULL);

CREATE UNIQUE INDEX universal_users_auth_user_id_uidx ON public.universal_users USING btree (auth_user_id) WHERE (auth_user_id IS NOT NULL);

CREATE INDEX idx_user_profiles_custom_user_id ON public.user_profiles USING btree (custom_user_id);

CREATE INDEX idx_user_settings_user_id ON public.user_settings USING btree (user_id);

CREATE INDEX idx_user_analytics_user_id_date ON public.user_analytics USING btree (user_id, date);

GRANT ALL ON ALL TABLES IN SCHEMA public TO anon, authenticated, service_role;

GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO anon, authenticated, service_role;

GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO anon, authenticated, service_role;

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES TO anon, authenticated, service_role;

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES TO anon, authenticated, service_role;

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON FUNCTIONS TO anon, authenticated, service_role;

REVOKE EXECUTE ON FUNCTION public.assert_service_role_request_v5(text) FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION public.assert_service_role_request_v5(text) FROM anon;

REVOKE EXECUTE ON FUNCTION public.assert_service_role_request_v5(text) FROM authenticated;

REVOKE EXECUTE ON FUNCTION public.bind_contact_method(text,text,text,inet,text) FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION public.bind_contact_method(text,text,text,inet,text) FROM anon;

REVOKE EXECUTE ON FUNCTION public.bootstrap_register_device_v5(uuid,uuid,text,text,text,text) FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION public.bootstrap_register_device_v5(uuid,uuid,text,text,text,text) FROM anon;

REVOKE EXECUTE ON FUNCTION public.bootstrap_register_device_v5(uuid,uuid,text,text,text,text) FROM authenticated;

REVOKE EXECUTE ON FUNCTION public.commit_device_identity_rotation_v6(uuid,uuid,uuid,text,bigint,text,text,text,timestamp with time zone) FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION public.commit_device_identity_rotation_v6(uuid,uuid,uuid,text,bigint,text,text,text,timestamp with time zone) FROM anon;

REVOKE EXECUTE ON FUNCTION public.commit_device_identity_rotation_v6(uuid,uuid,uuid,text,bigint,text,text,text,timestamp with time zone) FROM authenticated;

REVOKE EXECUTE ON FUNCTION public.confirm_device_enrollment_v5(uuid,uuid,text,text,text,text,text,text,text) FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION public.confirm_device_enrollment_v5(uuid,uuid,text,text,text,text,text,text,text) FROM anon;

REVOKE EXECUTE ON FUNCTION public.confirm_device_enrollment_v5(uuid,uuid,text,text,text,text,text,text,text) FROM authenticated;

REVOKE EXECUTE ON FUNCTION public.enroll_first_device_v5(text,uuid,uuid,text,text,text,text,uuid) FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION public.enroll_first_device_v5(text,uuid,uuid,text,text,text,text,uuid) FROM anon;

REVOKE EXECUTE ON FUNCTION public.enroll_first_device_v5(text,uuid,uuid,text,text,text,text,uuid) FROM authenticated;

REVOKE EXECUTE ON FUNCTION public.ensure_tenant_security_policy_v5(uuid) FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION public.ensure_tenant_security_policy_v5(uuid) FROM anon;

REVOKE EXECUTE ON FUNCTION public.ensure_tenant_security_policy_v5(uuid) FROM authenticated;

REVOKE EXECUTE ON FUNCTION public.expire_device_identity_grace_v6(integer) FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION public.expire_device_identity_grace_v6(integer) FROM anon;

REVOKE EXECUTE ON FUNCTION public.expire_device_identity_grace_v6(integer) FROM authenticated;

REVOKE EXECUTE ON FUNCTION public.get_email_by_nebula_id(text) FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION public.get_email_by_nebula_id(text) FROM anon;

REVOKE EXECUTE ON FUNCTION public.get_email_by_nebula_id(text) FROM authenticated;

REVOKE EXECUTE ON FUNCTION public.get_user_binding_status(uuid) FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION public.get_user_binding_status(uuid) FROM anon;

REVOKE EXECUTE ON FUNCTION public.hook_skybridge_before_user_created_v1(jsonb) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.hook_skybridge_before_user_created_v1(jsonb) TO supabase_auth_admin;

REVOKE EXECUTE ON FUNCTION public.is_valid_protocol_identity_key_v6(text,text) FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION public.is_valid_protocol_identity_key_v6(text,text) FROM anon;

REVOKE EXECUTE ON FUNCTION public.is_valid_protocol_identity_key_v6(text,text) FROM authenticated;

REVOKE EXECUTE ON FUNCTION public.issue_device_identity_rotation_v6(uuid,uuid,uuid,uuid,text,bigint,text,text,text,text,text,text,text,text,timestamp with time zone) FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION public.issue_device_identity_rotation_v6(uuid,uuid,uuid,uuid,text,bigint,text,text,text,text,text,text,text,text,timestamp with time zone) FROM anon;

REVOKE EXECUTE ON FUNCTION public.issue_device_identity_rotation_v6(uuid,uuid,uuid,uuid,text,bigint,text,text,text,text,text,text,text,text,timestamp with time zone) FROM authenticated;

REVOKE EXECUTE ON FUNCTION public.reject_device_identity_rotation_audit_mutation_v6() FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION public.reject_device_identity_rotation_audit_mutation_v6() FROM anon;

REVOKE EXECUTE ON FUNCTION public.reject_device_identity_rotation_audit_mutation_v6() FROM authenticated;

REVOKE EXECUTE ON FUNCTION public.resolve_registration_request_ip_v1() FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION public.touch_registered_device_presence_v7(uuid,uuid,text,text,text,text,text,text,text,text,text[],text,text[]) FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION public.touch_registered_device_presence_v7(uuid,uuid,text,text,text,text,text,text,text,text,text[],text,text[]) FROM anon;

REVOKE EXECUTE ON FUNCTION public.touch_registered_device_presence_v7(uuid,uuid,text,text,text,text,text,text,text,text,text[],text,text[]) FROM authenticated;

REVOKE EXECUTE ON FUNCTION public.unbind_contact_method(text,text,inet,text) FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION public.unbind_contact_method(text,text,inet,text) FROM anon;

CREATE POLICY "System can insert binding records" ON public."account_bindings" AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (true);

CREATE POLICY "Users can view own binding history" ON public."account_bindings" AS PERMISSIVE FOR SELECT TO PUBLIC USING ((auth.uid() = user_id));

CREATE POLICY "服务角色全权限-account_links" ON public."account_links" AS PERMISSIVE FOR ALL TO "service_role" USING (true);

CREATE POLICY "用户只能访问相关的账户关联" ON public."account_links" AS PERMISSIVE FOR ALL TO PUBLIC USING ((((primary_user_id)::text = (auth.uid())::text) OR ((linked_user_id)::text = (auth.uid())::text)));

CREATE POLICY "服务角色全权限-activity_logs" ON public."activity_logs" AS PERMISSIVE FOR ALL TO "service_role" USING (true);

CREATE POLICY "用户只能查看自己的活动日志" ON public."activity_logs" AS PERMISSIVE FOR SELECT TO PUBLIC USING ((user_id = auth.uid()));

CREATE POLICY "audit_logs_service_role_only" ON public."audit_logs" AS PERMISSIVE FOR ALL TO "service_role" USING (true) WITH CHECK (true);

CREATE POLICY "服务角色全权限-auth_methods" ON public."auth_methods" AS PERMISSIVE FOR ALL TO "service_role" USING (true);

CREATE POLICY "用户只能访问自己的认证方法" ON public."auth_methods" AS PERMISSIVE FOR ALL TO PUBLIC USING (((user_id)::text = (auth.uid())::text));

CREATE POLICY "星座信息公开可读" ON public."constellations" AS PERMISSIVE FOR SELECT TO PUBLIC USING (true);

CREATE POLICY "Anyone can read disposable domains" ON public."disposable_email_domains" AS PERMISSIVE FOR SELECT TO "anon", "authenticated" USING (true);

CREATE POLICY "idempotent_requests_service_role" ON public."idempotent_requests" AS PERMISSIVE FOR ALL TO "service_role" USING (true) WITH CHECK (true);

CREATE POLICY "idempotent_requests_user_access" ON public."idempotent_requests" AS PERMISSIVE FOR ALL TO "authenticated" USING (((auth.uid())::text = user_id));

CREATE POLICY "用户只能更新自己的星云账户" ON public."nebula_accounts" AS PERMISSIVE FOR UPDATE TO "authenticated" USING ((( SELECT auth.uid() AS uid) = id)) WITH CHECK ((( SELECT auth.uid() AS uid) = id));

CREATE POLICY "用户只能读取自己的星云账户" ON public."nebula_accounts" AS PERMISSIVE FOR SELECT TO "authenticated" USING ((( SELECT auth.uid() AS uid) = id));

CREATE POLICY "用户插入自己的星云账户" ON public."nebula_accounts" AS PERMISSIVE FOR INSERT TO "authenticated" WITH CHECK ((( SELECT auth.uid() AS uid) = id));

CREATE POLICY "enterprise_notifications_service_role" ON public."notifications" AS PERMISSIVE FOR ALL TO "service_role" USING (true) WITH CHECK (true);

CREATE POLICY "enterprise_notifications_user_access" ON public."notifications" AS PERMISSIVE FOR ALL TO "authenticated" USING (check_user_profile_access(user_id));

CREATE POLICY "服务角色全权限-oauth_accounts" ON public."oauth_accounts" AS PERMISSIVE FOR ALL TO "service_role" USING (true);

CREATE POLICY "用户只能访问自己的OAuth账户" ON public."oauth_accounts" AS PERMISSIVE FOR ALL TO PUBLIC USING (((user_id)::text = (auth.uid())::text));

CREATE POLICY "服务角色全权限-phone_auth" ON public."phone_auth" AS PERMISSIVE FOR ALL TO "service_role" USING (true);

CREATE POLICY "用户只能访问自己的手机认证" ON public."phone_auth" AS PERMISSIVE FOR ALL TO PUBLIC USING (((user_id)::text = (auth.uid())::text));

CREATE POLICY "Users can insert own profile" ON public."profiles" AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK ((auth.uid() = id));

CREATE POLICY "Users can update own profile" ON public."profiles" AS PERMISSIVE FOR UPDATE TO PUBLIC USING ((auth.uid() = id));

CREATE POLICY "Users can view own profile" ON public."profiles" AS PERMISSIVE FOR SELECT TO PUBLIC USING ((auth.uid() = id));

CREATE POLICY "profiles_select_own" ON public."profiles" AS PERMISSIVE FOR SELECT TO "authenticated" USING ((id = auth.uid()));

CREATE POLICY "Admin can manage rate_limit_config" ON public."rate_limit_config" AS PERMISSIVE FOR ALL TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM auth.users
  WHERE ((users.id = auth.uid()) AND ((users.raw_user_meta_data ->> 'role'::text) = 'admin'::text)))));

CREATE POLICY "Service role can read rate_limit_config" ON public."rate_limit_config" AS PERMISSIVE FOR SELECT TO "service_role" USING (true);

CREATE POLICY "Service role can manage registration_attempt_tickets" ON public."registration_attempt_tickets" AS PERMISSIVE FOR ALL TO "service_role" USING (true) WITH CHECK (true);

CREATE POLICY "Service role can manage registration_attempts" ON public."registration_attempts" AS PERMISSIVE FOR ALL TO "service_role" USING (true) WITH CHECK (true);

CREATE POLICY "Admin can manage blacklist" ON public."registration_blacklist" AS PERMISSIVE FOR ALL TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM auth.users
  WHERE ((users.id = auth.uid()) AND ((users.raw_user_meta_data ->> 'role'::text) = 'admin'::text)))));

CREATE POLICY "Service role full access to rate_limits" ON public."send_rate_limits" AS PERMISSIVE FOR ALL TO "service_role" USING (true) WITH CHECK (true);

CREATE POLICY "Service role full access to channel_stats" ON public."sms_channel_stats" AS PERMISSIVE FOR ALL TO "service_role" USING (true) WITH CHECK (true);

CREATE POLICY "Service role full access to callbacks" ON public."sms_delivery_callbacks" AS PERMISSIVE FOR ALL TO "service_role" USING (true) WITH CHECK (true);

CREATE POLICY "服务角色全权限-sync_status" ON public."sync_status" AS PERMISSIVE FOR ALL TO "service_role" USING (true);

CREATE POLICY "用户只能访问自己的同步状态" ON public."sync_status" AS PERMISSIVE FOR ALL TO PUBLIC USING ((user_id = auth.uid()));

CREATE POLICY "服务角色全权限-universal_users" ON public."universal_users" AS PERMISSIVE FOR ALL TO "service_role" USING (true);

CREATE POLICY "用户只能访问自己的记录" ON public."universal_users" AS PERMISSIVE FOR ALL TO PUBLIC USING (((auth.uid())::text = (id)::text));

CREATE POLICY "Allow users to insert their own activity" ON public."user_activity" AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (((auth.uid())::text = user_id));

CREATE POLICY "Allow users to view their own activity" ON public."user_activity" AS PERMISSIVE FOR SELECT TO PUBLIC USING (((auth.uid())::text = user_id));

CREATE POLICY "服务角色全权限-user_avatars" ON public."user_avatars" AS PERMISSIVE FOR ALL TO "service_role" USING (true);

CREATE POLICY "用户只能访问自己的头像" ON public."user_avatars" AS PERMISSIVE FOR ALL TO PUBLIC USING ((user_id = auth.uid()));

CREATE POLICY "Users can insert own profile" ON public."user_profiles" AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK ((auth.uid() = id));

CREATE POLICY "Users can update own profile" ON public."user_profiles" AS PERMISSIVE FOR UPDATE TO PUBLIC USING ((auth.uid() = id));

CREATE POLICY "Users can view own profile" ON public."user_profiles" AS PERMISSIVE FOR SELECT TO PUBLIC USING ((auth.uid() = id));

CREATE POLICY "user_profiles_select_own" ON public."user_profiles" AS PERMISSIVE FOR SELECT TO "authenticated" USING ((id = auth.uid()));

CREATE POLICY "服务角色全权限-user_sessions" ON public."user_sessions" AS PERMISSIVE FOR ALL TO "service_role" USING (true);

CREATE POLICY "用户只能访问自己的会话" ON public."user_sessions" AS PERMISSIVE FOR ALL TO PUBLIC USING (((user_id)::text = (auth.uid())::text));

CREATE POLICY "enterprise_settings_service_role" ON public."user_settings" AS PERMISSIVE FOR ALL TO "service_role" USING (true) WITH CHECK (true);

CREATE POLICY "enterprise_settings_user_access" ON public."user_settings" AS PERMISSIVE FOR ALL TO "authenticated" USING (check_user_profile_access(user_id));

CREATE POLICY "服务角色全权限-username_change_limits" ON public."username_change_limits" AS PERMISSIVE FOR ALL TO "service_role" USING (true);

CREATE POLICY "用户只能访问自己的用户名修改限制" ON public."username_change_limits" AS PERMISSIVE FOR ALL TO PUBLIC USING ((user_id = auth.uid()));

CREATE POLICY "服务角色全权限-username_history" ON public."username_history" AS PERMISSIVE FOR ALL TO "service_role" USING (true);

CREATE POLICY "用户只能查看自己的用户名历史" ON public."username_history" AS PERMISSIVE FOR SELECT TO PUBLIC USING ((user_id = auth.uid()));

CREATE POLICY "Service role full access to vcode_records" ON public."verification_code_records" AS PERMISSIVE FOR ALL TO "service_role" USING (true) WITH CHECK (true);

CREATE POLICY "System can manage verification codes" ON public."verification_codes" AS PERMISSIVE FOR ALL TO PUBLIC WITH CHECK (true);

CREATE POLICY "Users can view own verification codes" ON public."verification_codes" AS PERMISSIVE FOR SELECT TO PUBLIC USING ((auth.uid() = user_id));

CREATE TRIGGER on_auth_user_created AFTER INSERT ON auth.users FOR EACH ROW EXECUTE FUNCTION handle_new_user();

CREATE TRIGGER sync_tenant_security_policy_for_auth_user_v5 AFTER INSERT ON auth.users FOR EACH ROW EXECUTE FUNCTION sync_tenant_security_policy_for_auth_user_v5();

CREATE TRIGGER device_identity_rotation_audit_immutable_v6 BEFORE DELETE OR UPDATE ON public.device_identity_rotation_audit FOR EACH ROW EXECUTE FUNCTION reject_device_identity_rotation_audit_mutation_v6();

CREATE TRIGGER trigger_cleanup_blacklist AFTER INSERT ON public.registration_blacklist FOR EACH STATEMENT EXECUTE FUNCTION cleanup_expired_blacklist();

CREATE TRIGGER update_user_analytics_updated_at BEFORE UPDATE ON public.user_analytics FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_user_profiles_updated_at BEFORE UPDATE ON public.user_profiles FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_user_settings_updated_at BEFORE UPDATE ON public.user_settings FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
