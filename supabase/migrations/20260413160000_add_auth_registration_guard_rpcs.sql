-- Auth registration guard RPCs
-- 为客户端注册/验证码链路提供基于服务端观测 IP 的风控检查与审计落点。

CREATE OR REPLACE FUNCTION public.resolve_registration_request_ip_v1()
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
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
$$;

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
    retry_after INT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    resolved_ip TEXT := public.resolve_registration_request_ip_v1();
    normalized_identifier_type TEXT := lower(coalesce(btrim(identifier_type), ''));
    normalized_raw_identifier TEXT := coalesce(btrim(raw_identifier), '');
    derived_identifier_hash TEXT;
BEGIN
    IF device_fingerprint IS NULL OR btrim(device_fingerprint) = '' THEN
        RETURN QUERY SELECT FALSE, FALSE, '注册风控请求缺少 device_fingerprint'::TEXT, NULL::INT;
        RETURN;
    END IF;

    IF normalized_identifier_type NOT IN ('email', 'phone', 'username') THEN
        RETURN QUERY SELECT FALSE, FALSE, '注册风控请求缺少有效 identifier_type'::TEXT, NULL::INT;
        RETURN;
    END IF;

    IF normalized_identifier_type = 'phone' THEN
        normalized_raw_identifier := regexp_replace(normalized_raw_identifier, '[^0-9+]', '', 'g');
    ELSE
        normalized_raw_identifier := lower(normalized_raw_identifier);
    END IF;

    IF normalized_raw_identifier = '' THEN
        RETURN QUERY SELECT FALSE, FALSE, '注册风控请求缺少 raw_identifier'::TEXT, NULL::INT;
        RETURN;
    END IF;

    IF normalized_identifier_type = 'email'
       AND normalized_raw_identifier <> ''
       AND public.is_disposable_email(normalized_raw_identifier) THEN
        RETURN QUERY SELECT FALSE, FALSE, '不支持使用临时邮箱注册'::TEXT, NULL::INT;
        RETURN;
    END IF;

    derived_identifier_hash := encode(extensions.digest(normalized_raw_identifier, 'sha256'), 'hex');

    RETURN QUERY
    SELECT *
    FROM public.check_registration_allowed(
        resolved_ip,
        btrim(device_fingerprint),
        derived_identifier_hash,
        COALESCE(NULLIF(btrim(config_name), ''), 'default')
    );
END;
$$;

DROP FUNCTION IF EXISTS public.record_registration_attempt_v1(TEXT, TEXT, TEXT, TEXT, BOOLEAN, TEXT, BOOLEAN, BOOLEAN, JSONB);

CREATE OR REPLACE FUNCTION public.record_registration_attempt_v1(
    raw_identifier TEXT,
    identifier_type TEXT,
    device_fingerprint TEXT,
    attempt_type TEXT DEFAULT 'register',
    success BOOLEAN DEFAULT FALSE,
    failure_reason TEXT DEFAULT NULL,
    captcha_required BOOLEAN DEFAULT FALSE,
    captcha_passed BOOLEAN DEFAULT FALSE,
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
    derived_identifier_hash TEXT;
BEGIN
    IF device_fingerprint IS NULL OR btrim(device_fingerprint) = '' THEN
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

    BEGIN
        headers := NULLIF(current_setting('request.headers', true), '')::jsonb;
    EXCEPTION WHEN OTHERS THEN
        headers := NULL;
    END;

    request_user_agent := headers ->> 'user-agent';

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
        btrim(device_fingerprint),
        derived_identifier_hash,
        normalized_identifier_type,
        normalized_attempt_type,
        COALESCE(success, FALSE),
        NULLIF(btrim(failure_reason), ''),
        NULLIF(request_user_agent, ''),
        COALESCE(captcha_required, FALSE),
        COALESCE(captcha_passed, FALSE),
        COALESCE(metadata, '{}'::jsonb)
    );
END;
$$;

REVOKE ALL ON FUNCTION public.resolve_registration_request_ip_v1() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.guard_registration_attempt_v1(TEXT, TEXT, TEXT, TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.record_registration_attempt_v1(TEXT, TEXT, TEXT, TEXT, BOOLEAN, TEXT, BOOLEAN, BOOLEAN, JSONB) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.resolve_registration_request_ip_v1() TO service_role;
GRANT EXECUTE ON FUNCTION public.guard_registration_attempt_v1(TEXT, TEXT, TEXT, TEXT, TEXT) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.record_registration_attempt_v1(TEXT, TEXT, TEXT, TEXT, BOOLEAN, TEXT, BOOLEAN, BOOLEAN, JSONB) TO service_role;

COMMENT ON FUNCTION public.guard_registration_attempt_v1(TEXT, TEXT, TEXT, TEXT, TEXT)
IS 'Auth 注册/验证码前置风控 RPC：服务端 IP + 设备指纹 + 服务端归一化标识联合判定';

COMMENT ON FUNCTION public.record_registration_attempt_v1(TEXT, TEXT, TEXT, TEXT, BOOLEAN, TEXT, BOOLEAN, BOOLEAN, JSONB)
IS 'Auth 注册/验证码尝试审计 RPC：仅允许受信服务端调用，避免匿名/前端可写导致风控被反向利用';
