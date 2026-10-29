-- Scope auth risk limits by attempt type so sign-in failures cannot consume
-- registration quota or surface "device registration" copy to legitimate users.

INSERT INTO public.rate_limit_config (
    config_name,
    ip_max_per_minute,
    device_max_per_hour,
    identifier_max_per_day,
    global_max_per_second,
    captcha_trigger_threshold
)
VALUES
    ('login', 10, 12, 20, 20, 5),
    ('verify_code', 5, 6, 8, 15, 3)
ON CONFLICT (config_name) DO UPDATE
SET
    ip_max_per_minute = EXCLUDED.ip_max_per_minute,
    device_max_per_hour = EXCLUDED.device_max_per_hour,
    identifier_max_per_day = EXCLUDED.identifier_max_per_day,
    global_max_per_second = EXCLUDED.global_max_per_second,
    captcha_trigger_threshold = EXCLUDED.captcha_trigger_threshold,
    updated_at = NOW();

ALTER TABLE public.registration_attempt_tickets
ADD COLUMN IF NOT EXISTS attempt_type TEXT NOT NULL DEFAULT 'register'
CHECK (attempt_type IN ('register', 'verify_code', 'login'));

CREATE INDEX IF NOT EXISTS idx_registration_attempt_tickets_attempt_type
    ON public.registration_attempt_tickets (attempt_type, expires_at);

CREATE OR REPLACE FUNCTION public.check_auth_attempt_allowed_v1(
    check_ip TEXT,
    check_fingerprint TEXT,
    check_identifier_hash TEXT,
    risk_config_name TEXT DEFAULT 'default',
    attempt_type TEXT DEFAULT 'register'
)
RETURNS TABLE (
    allowed BOOLEAN,
    requires_captcha BOOLEAN,
    reason TEXT,
    retry_after INT
) AS $$
DECLARE
    config RECORD;
    ip_attempts INT;
    device_attempts INT;
    identifier_attempts INT;
    normalized_attempt_type TEXT := lower(coalesce(btrim(attempt_type), 'register'));
BEGIN
    IF normalized_attempt_type NOT IN ('register', 'verify_code', 'login') THEN
        normalized_attempt_type := 'register';
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
       AND created_at > NOW() - INTERVAL '60 seconds'
       AND (normalized_attempt_type <> 'login' OR success = FALSE);

    SELECT COUNT(*)::INT
      INTO device_attempts
      FROM public.registration_attempts
     WHERE device_fingerprint = check_fingerprint
       AND attempt_type = normalized_attempt_type
       AND created_at > NOW() - INTERVAL '3600 seconds'
       AND (normalized_attempt_type <> 'login' OR success = FALSE);

    SELECT COUNT(*)::INT
      INTO identifier_attempts
      FROM public.registration_attempts
     WHERE identifier_hash = check_identifier_hash
       AND attempt_type = normalized_attempt_type
       AND created_at > NOW() - INTERVAL '24 hours'
       AND (normalized_attempt_type <> 'login' OR success = FALSE);

    IF ip_attempts >= config.ip_max_per_minute THEN
        RETURN QUERY SELECT FALSE, FALSE, '操作过于频繁，请稍后再试'::TEXT, 60;
        RETURN;
    END IF;

    IF device_attempts >= config.device_max_per_hour THEN
        RETURN QUERY SELECT FALSE, FALSE,
            CASE normalized_attempt_type
                WHEN 'login' THEN '该设备登录尝试过多，请稍后再试'
                WHEN 'verify_code' THEN '该设备验证码请求过多，请稍后再试'
                ELSE '该设备注册次数过多，请稍后再试'
            END::TEXT,
            3600;
        RETURN;
    END IF;

    IF identifier_attempts >= config.identifier_max_per_day THEN
        RETURN QUERY SELECT FALSE, FALSE,
            CASE normalized_attempt_type
                WHEN 'login' THEN '该账号登录失败次数过多，请稍后再试'
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
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION public.check_registration_allowed(
    check_ip TEXT,
    check_fingerprint TEXT,
    check_identifier_hash TEXT,
    config_name TEXT DEFAULT 'default'
)
RETURNS TABLE (
    allowed BOOLEAN,
    requires_captcha BOOLEAN,
    reason TEXT,
    retry_after INT
) AS $$
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
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP FUNCTION IF EXISTS public.guard_registration_attempt_v1(TEXT, TEXT, TEXT, TEXT, TEXT);
DROP FUNCTION IF EXISTS public.guard_registration_attempt_v1(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT);

CREATE OR REPLACE FUNCTION public.guard_registration_attempt_v1(
    identifier_hash TEXT,
    identifier_type TEXT,
    raw_identifier TEXT,
    device_fingerprint TEXT,
    config_name TEXT DEFAULT 'default',
    attempt_type TEXT DEFAULT 'register'
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
    normalized_attempt_type TEXT := lower(coalesce(btrim(attempt_type), 'register'));
    derived_identifier_hash TEXT;
    guard_result RECORD;
    issued_ticket UUID;
BEGIN
    DELETE FROM public.registration_attempt_tickets
    WHERE expires_at <= NOW()
       OR (used_at IS NOT NULL AND used_at <= NOW() - INTERVAL '1 day');

    IF device_fingerprint IS NULL OR btrim(device_fingerprint) = '' THEN
        RETURN QUERY SELECT FALSE, FALSE, '认证风控请求缺少 device_fingerprint'::TEXT, NULL::INT, NULL::TEXT;
        RETURN;
    END IF;

    IF normalized_identifier_type NOT IN ('email', 'phone', 'username') THEN
        RETURN QUERY SELECT FALSE, FALSE, '认证风控请求缺少有效 identifier_type'::TEXT, NULL::INT, NULL::TEXT;
        RETURN;
    END IF;

    IF normalized_attempt_type NOT IN ('register', 'verify_code', 'login') THEN
        RETURN QUERY SELECT FALSE, FALSE, '认证风控请求缺少有效 attempt_type'::TEXT, NULL::INT, NULL::TEXT;
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
$$;

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
$$;

GRANT EXECUTE ON FUNCTION public.check_auth_attempt_allowed_v1(TEXT, TEXT, TEXT, TEXT, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.guard_registration_attempt_v1(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.record_registration_attempt_v1(TEXT, TEXT, TEXT, TEXT, BOOLEAN, TEXT, BOOLEAN, BOOLEAN, TEXT, JSONB) TO anon, authenticated, service_role;

COMMENT ON FUNCTION public.guard_registration_attempt_v1(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT)
IS 'Auth 风控 guard：按 register / verify_code / login 分桶限流并签发单次审计票据';
