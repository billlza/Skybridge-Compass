// 验证验证码的边缘函数
import { getCorsHeaders } from '../_shared/security.ts';

Deno.serve(async (req) => {
  const corsHeaders = getCorsHeaders(req);
  // 处理预检请求
  if (req.method === 'OPTIONS') {
    return new Response(null, { status: 200, headers: corsHeaders });
  }

  try {
    // 获取环境变量
    const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
    const supabaseServiceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

    // 验证HTTP方法
    if (req.method !== 'POST') {
      return new Response(
        JSON.stringify({
          error: {
            code: 'METHOD_NOT_ALLOWED',
            message: '只支持POST方法'
          }
        }),
        {
          status: 405,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        }
      );
    }

    // 获取授权token
    const authHeader = req.headers.get('Authorization');
    if (!authHeader) {
      return new Response(
        JSON.stringify({
          error: {
            code: 'UNAUTHORIZED',
            message: '缺少授权头'
          }
        }),
        {
          status: 401,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        }
      );
    }

    // 解析请求体
    const { code, type, contact } = await req.json();

    // 验证参数
    if (!code || !type || !contact) {
      return new Response(
        JSON.stringify({
          error: {
            code: 'INVALID_PARAMETERS',
            message: '验证码、类型和联系方式不能为空'
          }
        }),
        {
          status: 400,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        }
      );
    }

    if (!['email', 'phone'].includes(type)) {
      return new Response(
        JSON.stringify({
          error: {
            code: 'INVALID_TYPE',
            message: '验证类型只能是email或phone'
          }
        }),
        {
          status: 400,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        }
      );
    }

    // 验证码格式验证（6位数字）
    if (!/^\d{6}$/.test(code)) {
      return new Response(
        JSON.stringify({
          error: {
            code: 'INVALID_CODE_FORMAT',
            message: '验证码必须是6位数字'
          }
        }),
        {
          status: 400,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        }
      );
    }

    // 验证用户身份
    const token = authHeader.replace('Bearer ', '');
    const userResponse = await fetch(`${supabaseUrl}/auth/v1/user`, {
      headers: {
        'Authorization': `Bearer ${token}`,
        'apikey': supabaseServiceKey
      }
    });

    if (!userResponse.ok) {
      return new Response(
        JSON.stringify({
          error: {
            code: 'UNAUTHORIZED',
            message: '无效的授权token'
          }
        }),
        {
          status: 401,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        }
      );
    }

    const userData = await userResponse.json();
    const userId = userData.id;

    // 查找有效的验证码
    const verificationResponse = await fetch(
      `${supabaseUrl}/rest/v1/verification_codes?user_id=eq.${userId}&type=eq.${type}&contact=eq.${encodeURIComponent(contact)}&is_used=eq.false&expires_at=gte.${new Date().toISOString()}&order=created_at.desc&limit=1`,
      {
        method: 'GET',
        headers: {
          'Authorization': `Bearer ${supabaseServiceKey}`,
          'apikey': supabaseServiceKey,
          'Content-Type': 'application/json'
        }
      }
    );

    if (!verificationResponse.ok) {
      throw new Error('查询验证码失败');
    }

    const verifications = await verificationResponse.json();

    if (verifications.length === 0) {
      return new Response(
        JSON.stringify({
          error: {
            code: 'INVALID_OR_EXPIRED_CODE',
            message: '验证码错误或已过期'
          }
        }),
        {
          status: 400,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        }
      );
    }

    const verification = verifications[0];

    // 检查尝试次数（最多5次）
    if (verification.attempts >= 5) {
      return new Response(
        JSON.stringify({
          error: {
            code: 'TOO_MANY_ATTEMPTS',
            message: '验证失败次数过多，请重新获取验证码'
          }
        }),
        {
          status: 429,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        }
      );
    }

    if (verification.code !== code) {
      const nextAttempts = (verification.attempts || 0) + 1;

      await fetch(
        `${supabaseUrl}/rest/v1/verification_codes?id=eq.${verification.id}`,
        {
          method: 'PATCH',
          headers: {
            'Authorization': `Bearer ${supabaseServiceKey}`,
            'apikey': supabaseServiceKey,
            'Content-Type': 'application/json'
          },
          body: JSON.stringify({
            attempts: nextAttempts
          })
        }
      );

      const errorPayload = nextAttempts >= 5
        ? {
            code: 'TOO_MANY_ATTEMPTS',
            message: '验证失败次数过多，请重新获取验证码'
          }
        : {
            code: 'INVALID_OR_EXPIRED_CODE',
            message: '验证码错误或已过期'
          };

      return new Response(
        JSON.stringify({ error: errorPayload }),
        {
          status: nextAttempts >= 5 ? 429 : 400,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        }
      );
    }

    // 标记验证码为已使用
    const updateResponse = await fetch(
      `${supabaseUrl}/rest/v1/verification_codes?id=eq.${verification.id}`,
      {
        method: 'PATCH',
        headers: {
          'Authorization': `Bearer ${supabaseServiceKey}`,
          'apikey': supabaseServiceKey,
          'Content-Type': 'application/json'
        },
        body: JSON.stringify({
          is_used: true
        })
      }
    );

    if (!updateResponse.ok) {
      throw new Error('更新验证码状态失败');
    }

    return new Response(
      JSON.stringify({
        data: {
          message: '验证码验证成功',
          verified: true
        }
      }),
      {
        status: 200,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      }
    );

  } catch (error) {
    console.error('验证验证码错误:', error);
    return new Response(
      JSON.stringify({
        error: {
          code: 'INTERNAL_ERROR',
          message: error.message || '服务器内部错误'
        }
      }),
      {
        status: 500,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      }
    );
  }
});
