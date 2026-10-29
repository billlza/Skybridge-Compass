-- Fix registration security functions to resolve pgcrypto digest from the
-- extensions schema under SECURITY DEFINER search_path = public.

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

CREATE OR REPLACE FUNCTION public.hook_skybridge_before_user_created_v1(event JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
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
$$;

GRANT EXECUTE ON FUNCTION public.guard_registration_attempt_v1(TEXT, TEXT, TEXT, TEXT, TEXT) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.record_registration_attempt_v1(TEXT, TEXT, TEXT, TEXT, BOOLEAN, TEXT, BOOLEAN, BOOLEAN, TEXT, JSONB) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.hook_skybridge_before_user_created_v1(JSONB) TO supabase_auth_admin;
