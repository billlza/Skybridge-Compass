-- 验证码发送服务相关数据库迁移
-- 支持多通道轮询、状态回调、通道统计

-- =============================================================================
-- 1. 验证码发送记录表
-- =============================================================================

CREATE TABLE IF NOT EXISTS verification_code_records (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    -- 发送信息
    phone_number TEXT NOT NULL,
    code_hash TEXT NOT NULL,  -- 验证码哈希（不存储明文）
    channel TEXT NOT NULL,    -- 发送通道：china_mobile, china_unicom, china_telecom
    
    -- 状态信息
    status TEXT NOT NULL DEFAULT 'pending',  -- pending, sending, delivered, failed, expired
    delivery_status TEXT,     -- 运营商回调状态
    
    -- 重试信息
    retry_count INT DEFAULT 0,
    retry_channels TEXT[],    -- 尝试过的通道列表
    
    -- 设备和IP信息
    device_fingerprint TEXT NOT NULL,
    ip_address TEXT NOT NULL,
    
    -- 时间戳
    created_at TIMESTAMPTZ DEFAULT NOW(),
    sent_at TIMESTAMPTZ,
    delivered_at TIMESTAMPTZ,
    expired_at TIMESTAMPTZ,   -- 验证码过期时间（通常5分钟）
    
    -- 错误信息
    error_message TEXT,
    message_id TEXT,          -- 运营商返回的消息ID
    
    -- 元数据
    metadata JSONB DEFAULT '{}'::jsonb
);

-- 索引
CREATE INDEX IF NOT EXISTS idx_vcode_phone ON verification_code_records(phone_number, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_vcode_device ON verification_code_records(device_fingerprint, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_vcode_status ON verification_code_records(status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_vcode_channel ON verification_code_records(channel, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_vcode_message_id ON verification_code_records(message_id) WHERE message_id IS NOT NULL;

-- =============================================================================
-- 2. 通道统计表
-- =============================================================================

CREATE TABLE IF NOT EXISTS sms_channel_stats (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    -- 通道信息
    channel TEXT NOT NULL,
    date DATE NOT NULL DEFAULT CURRENT_DATE,
    
    -- 统计数据
    total_sent INT DEFAULT 0,
    success_count INT DEFAULT 0,
    failure_count INT DEFAULT 0,
    timeout_count INT DEFAULT 0,
    
    -- 成功率
    success_rate DECIMAL(5,4) GENERATED ALWAYS AS (
        CASE WHEN total_sent > 0 THEN success_count::DECIMAL / total_sent ELSE 0 END
    ) STORED,
    
    -- 平均响应时间（毫秒）
    avg_response_time INT,
    
    -- 熔断信息
    consecutive_failures INT DEFAULT 0,
    last_failure_at TIMESTAMPTZ,
    is_circuit_open BOOLEAN DEFAULT FALSE,
    circuit_open_until TIMESTAMPTZ,
    
    -- 时间戳
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    
    -- 唯一约束
    UNIQUE(channel, date)
);

CREATE INDEX IF NOT EXISTS idx_channel_stats_date ON sms_channel_stats(date DESC);

-- =============================================================================
-- 3. 发送频率限制表（补充客户端限制）
-- =============================================================================

CREATE TABLE IF NOT EXISTS send_rate_limits (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    -- 限制维度
    limit_type TEXT NOT NULL,  -- phone, device, ip
    limit_value TEXT NOT NULL, -- 手机号/设备指纹/IP
    
    -- 计数
    send_count INT DEFAULT 0,
    resend_click_count INT DEFAULT 0,  -- "收不到验证码"点击次数
    
    -- 时间窗口
    window_start TIMESTAMPTZ NOT NULL,
    window_end TIMESTAMPTZ NOT NULL,
    
    -- 是否触发行为验证
    captcha_required BOOLEAN DEFAULT FALSE,
    
    -- 时间戳
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    
    -- 唯一约束（同一窗口内）
    UNIQUE(limit_type, limit_value, window_start)
);

CREATE INDEX IF NOT EXISTS idx_rate_limits_value ON send_rate_limits(limit_type, limit_value, window_end DESC);

-- =============================================================================
-- 4. 状态回调记录表
-- =============================================================================

CREATE TABLE IF NOT EXISTS sms_delivery_callbacks (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    -- 关联发送记录
    record_id UUID REFERENCES verification_code_records(id),
    message_id TEXT NOT NULL,
    
    -- 运营商回调信息
    carrier TEXT,
    status_code TEXT,
    status_message TEXT,
    
    -- 原始回调数据
    raw_callback JSONB,
    
    -- 时间戳
    callback_time TIMESTAMPTZ,
    received_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_callback_message ON sms_delivery_callbacks(message_id);
CREATE INDEX IF NOT EXISTS idx_callback_record ON sms_delivery_callbacks(record_id);

-- =============================================================================
-- 5. 辅助函数
-- =============================================================================

-- 检查手机号发送限额
CREATE OR REPLACE FUNCTION check_phone_send_limit(
    check_phone TEXT,
    max_per_day INT DEFAULT 10
)
RETURNS TABLE (
    allowed BOOLEAN,
    remaining_count INT,
    next_available_at TIMESTAMPTZ
) AS $$
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
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 检查设备发送限额（跨手机号）
CREATE OR REPLACE FUNCTION check_device_send_limit(
    check_device TEXT,
    max_per_day INT DEFAULT 20
)
RETURNS TABLE (
    allowed BOOLEAN,
    unique_phones_count INT,
    next_available_at TIMESTAMPTZ
) AS $$
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
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 检测异常行为：同一设备短时间内向多个不同手机号发送
CREATE OR REPLACE FUNCTION detect_suspicious_behavior(
    check_device TEXT,
    time_window_minutes INT DEFAULT 10,
    threshold INT DEFAULT 3
)
RETURNS TABLE (
    is_suspicious BOOLEAN,
    unique_phones INT,
    recommendation TEXT
) AS $$
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
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 获取最优通道（基于成功率）
CREATE OR REPLACE FUNCTION get_best_channel(
    carrier TEXT DEFAULT NULL
)
RETURNS TABLE (
    channel_name TEXT,
    current_success_rate DECIMAL,
    is_available BOOLEAN
) AS $$
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
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 更新通道统计
CREATE OR REPLACE FUNCTION update_channel_stats(
    p_channel TEXT,
    p_success BOOLEAN,
    p_response_time INT DEFAULT NULL
)
RETURNS void AS $$
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
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- =============================================================================
-- 6. RLS 策略
-- =============================================================================

ALTER TABLE verification_code_records ENABLE ROW LEVEL SECURITY;
ALTER TABLE sms_channel_stats ENABLE ROW LEVEL SECURITY;
ALTER TABLE send_rate_limits ENABLE ROW LEVEL SECURITY;
ALTER TABLE sms_delivery_callbacks ENABLE ROW LEVEL SECURITY;

-- Service role 可以完全访问
CREATE POLICY "Service role full access to vcode_records"
ON verification_code_records FOR ALL TO service_role
USING (true) WITH CHECK (true);

CREATE POLICY "Service role full access to channel_stats"
ON sms_channel_stats FOR ALL TO service_role
USING (true) WITH CHECK (true);

CREATE POLICY "Service role full access to rate_limits"
ON send_rate_limits FOR ALL TO service_role
USING (true) WITH CHECK (true);

CREATE POLICY "Service role full access to callbacks"
ON sms_delivery_callbacks FOR ALL TO service_role
USING (true) WITH CHECK (true);

-- =============================================================================
-- 7. 清理函数
-- =============================================================================

-- 清理过期的验证码记录（保留7天）
CREATE OR REPLACE FUNCTION cleanup_expired_vcode_records()
RETURNS INT AS $$
DECLARE
    deleted_count INT;
BEGIN
    DELETE FROM verification_code_records
    WHERE created_at < NOW() - INTERVAL '7 days';
    
    GET DIAGNOSTICS deleted_count = ROW_COUNT;
    RETURN deleted_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 清理过期的限流记录
CREATE OR REPLACE FUNCTION cleanup_expired_rate_limits()
RETURNS INT AS $$
DECLARE
    deleted_count INT;
BEGIN
    DELETE FROM send_rate_limits
    WHERE window_end < NOW() - INTERVAL '1 day';
    
    GET DIAGNOSTICS deleted_count = ROW_COUNT;
    RETURN deleted_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- =============================================================================
-- 8. 定时任务（需要 pg_cron 扩展）
-- =============================================================================

-- 注意：以下 SQL 需要在启用 pg_cron 扩展后执行
-- SELECT cron.schedule('cleanup-vcode-records', '0 3 * * *', 'SELECT cleanup_expired_vcode_records()');
-- SELECT cron.schedule('cleanup-rate-limits', '0 4 * * *', 'SELECT cleanup_expired_rate_limits()');

COMMENT ON TABLE verification_code_records IS '验证码发送记录表，存储所有验证码发送历史';
COMMENT ON TABLE sms_channel_stats IS '短信通道统计表，按日统计各通道的成功率和熔断状态';
COMMENT ON TABLE send_rate_limits IS '发送频率限制表，用于防止滥用';
COMMENT ON TABLE sms_delivery_callbacks IS '短信状态回调表，存储运营商的送达状态回调';

