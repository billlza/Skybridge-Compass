-- Harden auth registration audit writes with single-use tickets.
-- This keeps audit writes available to pre-auth clients without reopening
-- the old anonymous writable RPC abuse surface.

CREATE TABLE IF NOT EXISTS public.registration_attempt_tickets (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    ip_address TEXT NOT NULL,
    device_fingerprint TEXT NOT NULL,
    identifier_hash TEXT NOT NULL,
    identifier_type TEXT NOT NULL CHECK (identifier_type IN ('email', 'phone', 'username')),
    config_name TEXT NOT NULL DEFAULT 'default',
    issued_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at TIMESTAMPTZ NOT NULL DEFAULT (NOW() + INTERVAL '10 minutes'),
    used_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_registration_attempt_tickets_expires_at
    ON public.registration_attempt_tickets (expires_at);

CREATE INDEX IF NOT EXISTS idx_registration_attempt_tickets_lookup
    ON public.registration_attempt_tickets (identifier_hash, device_fingerprint, ip_address);

ALTER TABLE public.registration_attempt_tickets ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Service role can manage registration_attempt_tickets" ON public.registration_attempt_tickets;

CREATE POLICY "Service role can manage registration_attempt_tickets"
ON public.registration_attempt_tickets
FOR ALL
TO service_role
USING (true)
WITH CHECK (true);

DROP FUNCTION IF EXISTS public.guard_registration_attempt_v1(TEXT, TEXT, TEXT, TEXT, TEXT);

CREATE OR REPLACE FUNCTION public.guard_registration_attempt_v1(
    identifier_hash TEXT,
    identifier_type TEXT,
    raw_identifier TEXT,
    device_fingerprint TEXT,
    config_name TEXT DEFAULT 'default'
)
RETURNS TABLE (
    allowed BOOLEAN,
    requires_captcha BOOLEAN,
    reason TEXT,
    retry_after INT,
    audit_ticket TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    resolved_ip TEXT := public.resolve_registration_request_ip_v1();
    normalized_identifier_type TEXT := lower(coalesce(btrim(identifier_type), ''));
    normalized_raw_identifier TEXT := coalesce(btrim(raw_identifier), '');
    normalized_config_name TEXT := COALESCE(NULLIF(btrim(config_name), ''), 'default');
    derived_identifier_hash TEXT;
    guard_result RECORD;
    issued_ticket UUID;
BEGIN
    DELETE FROM public.registration_attempt_tickets
    WHERE expires_at <= NOW()
       OR (used_at IS NOT NULL AND used_at <= NOW() - INTERVAL '1 day');

    IF device_fingerprint IS NULL OR btrim(device_fingerprint) = '' THEN
        RETURN QUERY SELECT FALSE, FALSE, '注册风控请求缺少 device_fingerprint'::TEXT, NULL::INT, NULL::TEXT;
        RETURN;
    END IF;

    IF normalized_identifier_type NOT IN ('email', 'phone', 'username') THEN
        RETURN QUERY SELECT FALSE, FALSE, '注册风控请求缺少有效 identifier_type'::TEXT, NULL::INT, NULL::TEXT;
        RETURN;
    END IF;

    IF normalized_identifier_type = 'phone' THEN
        normalized_raw_identifier := regexp_replace(normalized_raw_identifier, '[^0-9+]', '', 'g');
    ELSE
        normalized_raw_identifier := lower(normalized_raw_identifier);
    END IF;

    IF normalized_raw_identifier = '' THEN
        RETURN QUERY SELECT FALSE, FALSE, '注册风控请求缺少 raw_identifier'::TEXT, NULL::INT, NULL::TEXT;
        RETURN;
    END IF;

    IF normalized_identifier_type = 'email'
       AND public.is_disposable_email(normalized_raw_identifier) THEN
        RETURN QUERY SELECT FALSE, FALSE, '不支持使用临时邮箱注册'::TEXT, NULL::INT, NULL::TEXT;
        RETURN;
    END IF;

    derived_identifier_hash := encode(extensions.digest(normalized_raw_identifier, 'sha256'), 'hex');

    SELECT *
      INTO guard_result
      FROM public.check_registration_allowed(
        resolved_ip,
        btrim(device_fingerprint),
        derived_identifier_hash,
        normalized_config_name
      );

    IF COALESCE(guard_result.allowed, FALSE) THEN
        INSERT INTO public.registration_attempt_tickets (
            ip_address,
            device_fingerprint,
            identifier_hash,
            identifier_type,
            config_name
        )
        VALUES (
            resolved_ip,
            btrim(device_fingerprint),
            derived_identifier_hash,
            normalized_identifier_type,
            normalized_config_name
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
$$;

DROP FUNCTION IF EXISTS public.record_registration_attempt_v1(TEXT, TEXT, TEXT, TEXT, BOOLEAN, TEXT, BOOLEAN, BOOLEAN, JSONB);
DROP FUNCTION IF EXISTS public.record_registration_attempt_v1(TEXT, TEXT, TEXT, TEXT, BOOLEAN, TEXT, BOOLEAN, BOOLEAN, TEXT, JSONB);

CREATE OR REPLACE FUNCTION public.record_registration_attempt_v1(
    raw_identifier TEXT,
    identifier_type TEXT,
    device_fingerprint TEXT,
    attempt_type TEXT DEFAULT 'register',
    success BOOLEAN DEFAULT FALSE,
    failure_reason TEXT DEFAULT NULL,
    captcha_required BOOLEAN DEFAULT FALSE,
    captcha_passed BOOLEAN DEFAULT FALSE,
    audit_ticket TEXT DEFAULT NULL,
    metadata JSONB DEFAULT '{}'::jsonb
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
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

    IF normalized_device_fingerprint = '' THEN
        RETURN;
    END IF;

    IF normalized_identifier_type NOT IN ('email', 'phone', 'username') THEN
        RETURN;
    END IF;

    IF normalized_attempt_type NOT IN ('register', 'verify_code', 'login') THEN
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
       OR issued_ticket.identifier_type <> normalized_identifier_type THEN
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
$$;

REVOKE ALL ON FUNCTION public.guard_registration_attempt_v1(TEXT, TEXT, TEXT, TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.record_registration_attempt_v1(TEXT, TEXT, TEXT, TEXT, BOOLEAN, TEXT, BOOLEAN, BOOLEAN, TEXT, JSONB) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.guard_registration_attempt_v1(TEXT, TEXT, TEXT, TEXT, TEXT) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.record_registration_attempt_v1(TEXT, TEXT, TEXT, TEXT, BOOLEAN, TEXT, BOOLEAN, BOOLEAN, TEXT, JSONB) TO anon, authenticated, service_role;

COMMENT ON FUNCTION public.guard_registration_attempt_v1(TEXT, TEXT, TEXT, TEXT, TEXT)
IS 'Auth 注册/验证码前置风控 RPC：返回判定结果并签发单次审计票据，供后续安全记录写入使用';

COMMENT ON FUNCTION public.record_registration_attempt_v1(TEXT, TEXT, TEXT, TEXT, BOOLEAN, TEXT, BOOLEAN, BOOLEAN, TEXT, JSONB)
IS 'Auth 注册/验证码尝试审计 RPC：要求 guard_registration_attempt_v1 签发的单次票据，避免匿名裸写造成风控污染';

COMMENT ON TABLE public.registration_attempt_tickets
IS '注册/验证码风控单次审计票据表，绑定服务端观测 IP、设备指纹和归一化标识，避免客户端匿名裸写 registration_attempts';
