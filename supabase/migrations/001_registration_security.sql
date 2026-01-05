-- 注册安全相关数据库迁移
-- SkyBridge Compass Pro - 防止恶意注册

-- =============================================================================
-- 1. 注册尝试记录表
-- =============================================================================

CREATE TABLE IF NOT EXISTS registration_attempts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    -- 请求来源信息
    ip_address TEXT NOT NULL,
    device_fingerprint TEXT NOT NULL,
    identifier_hash TEXT NOT NULL,  -- 手机号/邮箱的SHA256哈希（隐私保护）
    identifier_type TEXT NOT NULL CHECK (identifier_type IN ('phone', 'email', 'username')),
    
    -- 请求详情
    attempt_type TEXT NOT NULL CHECK (attempt_type IN ('register', 'verify_code', 'login')),
    success BOOLEAN DEFAULT FALSE,
    failure_reason TEXT,
    
    -- 设备信息
    user_agent TEXT,
    os_version TEXT,
    hardware_model TEXT,
    
    -- 行为验证
    captcha_required BOOLEAN DEFAULT FALSE,
    captcha_passed BOOLEAN,
    behavior_score DECIMAL(5,4),  -- 行为分析评分 0.0000 - 1.0000
    
    -- 时间戳
    created_at TIMESTAMPTZ DEFAULT NOW(),
    
    -- 额外元数据
    metadata JSONB DEFAULT '{}'::jsonb
);

-- 创建索引以优化查询性能
CREATE INDEX IF NOT EXISTS idx_reg_attempts_ip ON registration_attempts(ip_address, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_reg_attempts_device ON registration_attempts(device_fingerprint, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_reg_attempts_identifier ON registration_attempts(identifier_hash, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_reg_attempts_type ON registration_attempts(attempt_type, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_reg_attempts_created ON registration_attempts(created_at DESC);

-- =============================================================================
-- 2. 黑名单表
-- =============================================================================

CREATE TABLE IF NOT EXISTS registration_blacklist (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    -- 黑名单类型
    blacklist_type TEXT NOT NULL CHECK (blacklist_type IN ('ip', 'device_fingerprint', 'identifier', 'email_domain')),
    value TEXT NOT NULL,
    
    -- 封禁信息
    reason TEXT NOT NULL,
    expires_at TIMESTAMPTZ,  -- NULL 表示永久封禁
    
    -- 管理信息
    created_by UUID REFERENCES auth.users(id),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    
    -- 唯一约束
    UNIQUE(blacklist_type, value)
);

CREATE INDEX IF NOT EXISTS idx_blacklist_type_value ON registration_blacklist(blacklist_type, value);
CREATE INDEX IF NOT EXISTS idx_blacklist_expires ON registration_blacklist(expires_at) WHERE expires_at IS NOT NULL;

-- =============================================================================
-- 3. 一次性邮箱域名表
-- =============================================================================

CREATE TABLE IF NOT EXISTS disposable_email_domains (
    domain TEXT PRIMARY KEY,
    added_at TIMESTAMPTZ DEFAULT NOW(),
    source TEXT DEFAULT 'manual'  -- 来源：manual, api, community
);

-- 预填充常见的一次性邮箱域名
INSERT INTO disposable_email_domains (domain, source) VALUES
    ('tempmail.com', 'builtin'),
    ('guerrillamail.com', 'builtin'),
    ('10minutemail.com', 'builtin'),
    ('mailinator.com', 'builtin'),
    ('throwaway.email', 'builtin'),
    ('fakeinbox.com', 'builtin'),
    ('temp-mail.org', 'builtin'),
    ('dispostable.com', 'builtin'),
    ('maildrop.cc', 'builtin'),
    ('yopmail.com', 'builtin'),
    ('trashmail.com', 'builtin'),
    ('sharklasers.com', 'builtin'),
    ('guerrillamailblock.com', 'builtin'),
    ('pokemail.net', 'builtin'),
    ('spam4.me', 'builtin')
ON CONFLICT (domain) DO NOTHING;

-- =============================================================================
-- 4. 限流配置表
-- =============================================================================

CREATE TABLE IF NOT EXISTS rate_limit_config (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    -- 配置名称
    config_name TEXT UNIQUE NOT NULL,
    
    -- 限流参数
    ip_max_per_minute INT DEFAULT 5,
    device_max_per_hour INT DEFAULT 3,
    identifier_max_per_day INT DEFAULT 5,
    global_max_per_second INT DEFAULT 10,
    captcha_trigger_threshold INT DEFAULT 2,
    
    -- 启用状态
    is_active BOOLEAN DEFAULT TRUE,
    
    -- 管理信息
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- 插入默认配置
INSERT INTO rate_limit_config (config_name, ip_max_per_minute, device_max_per_hour, identifier_max_per_day, global_max_per_second, captcha_trigger_threshold)
VALUES ('default', 5, 3, 5, 10, 2)
ON CONFLICT (config_name) DO NOTHING;

-- 插入严格配置
INSERT INTO rate_limit_config (config_name, ip_max_per_minute, device_max_per_hour, identifier_max_per_day, global_max_per_second, captcha_trigger_threshold)
VALUES ('strict', 3, 2, 3, 5, 1)
ON CONFLICT (config_name) DO NOTHING;

-- =============================================================================
-- 5. 辅助函数
-- =============================================================================

-- 检查IP是否在黑名单中
CREATE OR REPLACE FUNCTION is_ip_blacklisted(check_ip TEXT)
RETURNS BOOLEAN AS $$
BEGIN
    RETURN EXISTS (
        SELECT 1 FROM registration_blacklist
        WHERE blacklist_type = 'ip'
        AND value = check_ip
        AND (expires_at IS NULL OR expires_at > NOW())
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 检查设备指纹是否在黑名单中
CREATE OR REPLACE FUNCTION is_device_blacklisted(check_fingerprint TEXT)
RETURNS BOOLEAN AS $$
BEGIN
    RETURN EXISTS (
        SELECT 1 FROM registration_blacklist
        WHERE blacklist_type = 'device_fingerprint'
        AND value = check_fingerprint
        AND (expires_at IS NULL OR expires_at > NOW())
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 检查邮箱域名是否为一次性邮箱
CREATE OR REPLACE FUNCTION is_disposable_email(check_email TEXT)
RETURNS BOOLEAN AS $$
DECLARE
    email_domain TEXT;
BEGIN
    email_domain := LOWER(SPLIT_PART(check_email, '@', 2));
    RETURN EXISTS (
        SELECT 1 FROM disposable_email_domains
        WHERE domain = email_domain
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 统计指定IP最近的注册尝试次数
CREATE OR REPLACE FUNCTION count_recent_ip_attempts(check_ip TEXT, seconds INT)
RETURNS INT AS $$
BEGIN
    RETURN (
        SELECT COUNT(*)::INT FROM registration_attempts
        WHERE ip_address = check_ip
        AND created_at > NOW() - (seconds || ' seconds')::INTERVAL
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 统计指定设备最近的注册尝试次数
CREATE OR REPLACE FUNCTION count_recent_device_attempts(check_fingerprint TEXT, seconds INT)
RETURNS INT AS $$
BEGIN
    RETURN (
        SELECT COUNT(*)::INT FROM registration_attempts
        WHERE device_fingerprint = check_fingerprint
        AND created_at > NOW() - (seconds || ' seconds')::INTERVAL
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 综合检查是否允许注册
CREATE OR REPLACE FUNCTION check_registration_allowed(
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
DECLARE
    config RECORD;
    ip_attempts INT;
    device_attempts INT;
    identifier_attempts INT;
BEGIN
    -- 获取配置
    SELECT * INTO config FROM rate_limit_config WHERE rate_limit_config.config_name = check_registration_allowed.config_name AND is_active = TRUE;
    IF NOT FOUND THEN
        SELECT * INTO config FROM rate_limit_config WHERE rate_limit_config.config_name = 'default';
    END IF;
    
    -- 检查IP黑名单
    IF is_ip_blacklisted(check_ip) THEN
        RETURN QUERY SELECT FALSE, FALSE, '您的IP已被限制注册'::TEXT, NULL::INT;
        RETURN;
    END IF;
    
    -- 检查设备黑名单
    IF is_device_blacklisted(check_fingerprint) THEN
        RETURN QUERY SELECT FALSE, FALSE, '该设备已被限制注册'::TEXT, NULL::INT;
        RETURN;
    END IF;
    
    -- 统计尝试次数
    ip_attempts := count_recent_ip_attempts(check_ip, 60);  -- 1分钟
    device_attempts := count_recent_device_attempts(check_fingerprint, 3600);  -- 1小时
    identifier_attempts := (
        SELECT COUNT(*)::INT FROM registration_attempts
        WHERE identifier_hash = check_identifier_hash
        AND created_at > NOW() - INTERVAL '24 hours'
    );
    
    -- 检查IP限流
    IF ip_attempts >= config.ip_max_per_minute THEN
        RETURN QUERY SELECT FALSE, FALSE, '操作过于频繁，请稍后再试'::TEXT, 60;
        RETURN;
    END IF;
    
    -- 检查设备限流
    IF device_attempts >= config.device_max_per_hour THEN
        RETURN QUERY SELECT FALSE, FALSE, '该设备注册次数过多，请稍后再试'::TEXT, 3600;
        RETURN;
    END IF;
    
    -- 检查账号限流
    IF identifier_attempts >= config.identifier_max_per_day THEN
        RETURN QUERY SELECT FALSE, FALSE, '该账号注册尝试次数过多，请明天再试'::TEXT, 86400;
        RETURN;
    END IF;
    
    -- 检查是否需要验证码
    IF GREATEST(ip_attempts, device_attempts) >= config.captcha_trigger_threshold THEN
        RETURN QUERY SELECT TRUE, TRUE, '请完成安全验证'::TEXT, NULL::INT;
        RETURN;
    END IF;
    
    -- 允许注册
    RETURN QUERY SELECT TRUE, FALSE, NULL::TEXT, NULL::INT;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- =============================================================================
-- 6. RLS 策略
-- =============================================================================

-- 启用 RLS
ALTER TABLE registration_attempts ENABLE ROW LEVEL SECURITY;
ALTER TABLE registration_blacklist ENABLE ROW LEVEL SECURITY;
ALTER TABLE disposable_email_domains ENABLE ROW LEVEL SECURITY;
ALTER TABLE rate_limit_config ENABLE ROW LEVEL SECURITY;

-- registration_attempts: 仅服务角色可以插入和查询
CREATE POLICY "Service role can manage registration_attempts"
ON registration_attempts
FOR ALL
TO service_role
USING (true)
WITH CHECK (true);

-- registration_blacklist: 仅管理员可以管理
CREATE POLICY "Admin can manage blacklist"
ON registration_blacklist
FOR ALL
TO authenticated
USING (
    EXISTS (
        SELECT 1 FROM auth.users
        WHERE auth.users.id = auth.uid()
        AND auth.users.raw_user_meta_data->>'role' = 'admin'
    )
);

-- disposable_email_domains: 所有人可以读取
CREATE POLICY "Anyone can read disposable domains"
ON disposable_email_domains
FOR SELECT
TO anon, authenticated
USING (true);

-- rate_limit_config: 仅管理员可以管理，服务角色可以读取
CREATE POLICY "Service role can read rate_limit_config"
ON rate_limit_config
FOR SELECT
TO service_role
USING (true);

CREATE POLICY "Admin can manage rate_limit_config"
ON rate_limit_config
FOR ALL
TO authenticated
USING (
    EXISTS (
        SELECT 1 FROM auth.users
        WHERE auth.users.id = auth.uid()
        AND auth.users.raw_user_meta_data->>'role' = 'admin'
    )
);

-- =============================================================================
-- 7. 触发器：自动清理过期数据
-- =============================================================================

-- 清理过期的黑名单条目
CREATE OR REPLACE FUNCTION cleanup_expired_blacklist()
RETURNS TRIGGER AS $$
BEGIN
    DELETE FROM registration_blacklist
    WHERE expires_at IS NOT NULL AND expires_at < NOW();
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

-- 每次插入新的黑名单条目时，清理过期条目
CREATE TRIGGER trigger_cleanup_blacklist
AFTER INSERT ON registration_blacklist
EXECUTE FUNCTION cleanup_expired_blacklist();

-- 清理超过30天的注册尝试记录
CREATE OR REPLACE FUNCTION cleanup_old_attempts()
RETURNS void AS $$
BEGIN
    DELETE FROM registration_attempts
    WHERE created_at < NOW() - INTERVAL '30 days';
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 可以通过 pg_cron 定时调用 cleanup_old_attempts()

COMMENT ON TABLE registration_attempts IS '注册尝试记录表，用于防止恶意注册';
COMMENT ON TABLE registration_blacklist IS '注册黑名单表，存储被封禁的IP、设备和账号';
COMMENT ON TABLE disposable_email_domains IS '一次性邮箱域名表，阻止临时邮箱注册';
COMMENT ON TABLE rate_limit_config IS '限流配置表，存储不同场景的限流参数';

