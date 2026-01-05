// Supabase Edge Function: 检查注册限流
// 用于防止恶意注册的服务端限流检查

import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from "https://esm.sh/@supabase/supabase-js@2"

// CORS 头
const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-device-fingerprint, x-real-ip',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

// 请求体类型
interface CheckRegistrationRequest {
  identifier: string          // 手机号或邮箱（客户端已做哈希）
  identifier_type: 'phone' | 'email' | 'username'
  device_fingerprint: string  // 设备指纹
  user_agent?: string
  os_version?: string
  hardware_model?: string
  captcha_passed?: boolean
  behavior_score?: number
}

// 响应类型
interface CheckRegistrationResponse {
  allowed: boolean
  requires_captcha: boolean
  reason?: string
  retry_after?: number  // 秒
}

serve(async (req: Request) => {
  // 处理 CORS 预检请求
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    // 只允许 POST 请求
    if (req.method !== 'POST') {
      return new Response(
        JSON.stringify({ error: 'Method not allowed' }),
        { status: 405, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    // 获取客户端 IP
    const clientIP = req.headers.get('x-real-ip') || 
                     req.headers.get('x-forwarded-for')?.split(',')[0]?.trim() ||
                     'unknown'

    // 解析请求体
    const body: CheckRegistrationRequest = await req.json()

    // 验证必填字段
    if (!body.identifier || !body.identifier_type || !body.device_fingerprint) {
      return new Response(
        JSON.stringify({ error: 'Missing required fields' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    // 创建 Supabase 客户端
    const supabaseUrl = Deno.env.get('SUPABASE_URL')!
    const supabaseServiceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    
    const supabase = createClient(supabaseUrl, supabaseServiceKey)

    // 如果是邮箱，检查是否为一次性邮箱
    if (body.identifier_type === 'email') {
      const emailDomain = body.identifier.split('@')[1]?.toLowerCase()
      if (emailDomain) {
        const { data: disposableCheck } = await supabase
          .from('disposable_email_domains')
          .select('domain')
          .eq('domain', emailDomain)
          .single()

        if (disposableCheck) {
          return new Response(
            JSON.stringify({
              allowed: false,
              requires_captcha: false,
              reason: '不支持使用临时邮箱注册'
            } as CheckRegistrationResponse),
            { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          )
        }
      }
    }

    // 调用数据库函数检查是否允许注册
    const { data: checkResult, error: checkError } = await supabase
      .rpc('check_registration_allowed', {
        check_ip: clientIP,
        check_fingerprint: body.device_fingerprint,
        check_identifier_hash: body.identifier,
        config_name: 'default'
      })

    if (checkError) {
      console.error('Check registration error:', checkError)
      throw checkError
    }

    const result = checkResult?.[0] || { allowed: true, requires_captcha: false }

    // 如果需要验证码但客户端已通过验证
    if (result.requires_captcha && body.captcha_passed) {
      result.requires_captcha = false
    }

    // 记录此次尝试
    const { error: insertError } = await supabase
      .from('registration_attempts')
      .insert({
        ip_address: clientIP,
        device_fingerprint: body.device_fingerprint,
        identifier_hash: body.identifier,
        identifier_type: body.identifier_type,
        attempt_type: 'register',
        success: result.allowed && !result.requires_captcha,
        failure_reason: result.reason || null,
        user_agent: body.user_agent || req.headers.get('user-agent'),
        os_version: body.os_version,
        hardware_model: body.hardware_model,
        captcha_required: result.requires_captcha,
        captcha_passed: body.captcha_passed,
        behavior_score: body.behavior_score,
        metadata: {
          timestamp: new Date().toISOString(),
          source: 'edge_function'
        }
      })

    if (insertError) {
      console.error('Insert attempt error:', insertError)
      // 不阻塞流程，只记录错误
    }

    // 返回结果
    const response: CheckRegistrationResponse = {
      allowed: result.allowed,
      requires_captcha: result.requires_captcha,
      reason: result.reason,
      retry_after: result.retry_after
    }

    return new Response(
      JSON.stringify(response),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    )

  } catch (error) {
    console.error('Edge function error:', error)
    
    return new Response(
      JSON.stringify({ 
        error: 'Internal server error',
        message: error instanceof Error ? error.message : 'Unknown error'
      }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    )
  }
})

