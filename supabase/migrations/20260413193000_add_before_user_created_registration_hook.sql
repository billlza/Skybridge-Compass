-- Server-enforced registration guard for Supabase Auth sign-up.
-- This closes the gap where malicious clients can bypass local preflight checks
-- and call /auth/v1/signup directly with a publishable key.

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

REVOKE ALL ON FUNCTION public.hook_skybridge_before_user_created_v1(JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.hook_skybridge_before_user_created_v1(JSONB) TO supabase_auth_admin;

COMMENT ON FUNCTION public.hook_skybridge_before_user_created_v1(JSONB)
IS 'Supabase before-user-created Postgres hook: server-enforced registration guard for direct /auth/v1/signup requests.';
