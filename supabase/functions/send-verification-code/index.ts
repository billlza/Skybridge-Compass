// 发送验证码的边缘函数
import { deliverVerificationCode } from '../_shared/verification-delivery.ts';
import { getCorsHeaders, maskContact } from '../_shared/security.ts';

// 生成6位数字验证码
function generateVerificationCode(): string {
  const bytes = crypto.getRandomValues(new Uint32Array(1));
  return (100000 + (bytes[0] % 900000)).toString();
}

// 验证邮箱格式
function isValidEmail(email: string): boolean {
  const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
  return emailRegex.test(email);
}

// 验证手机号格式（支持中国手机号）
function isValidPhone(phone: string): boolean {
  const phoneRegex = /^1[3-9]\d{9}$/;
  return phoneRegex.test(phone);
}

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
    const { type, contact } = await req.json();

    // 验证参数
    if (!type || !contact) {
      return new Response(
        JSON.stringify({
          error: {
            code: 'INVALID_PARAMETERS',
            message: '验证类型和联系方式不能为空'
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

    // 验证联系方式格式
    if (type === 'email' && !isValidEmail(contact)) {
      return new Response(
        JSON.stringify({
          error: {
            code: 'INVALID_EMAIL',
            message: '邮箱格式不正确'
          }
        }),
        {
          status: 400,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        }
      );
    }

    if (type === 'phone' && !isValidPhone(contact)) {
      return new Response(
        JSON.stringify({
          error: {
            code: 'INVALID_PHONE',
            message: '手机号格式不正确'
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

    // 检查60秒内是否已发送过验证码
    const recentCodeResponse = await fetch(
      `${supabaseUrl}/rest/v1/verification_codes?user_id=eq.${userId}&type=eq.${type}&contact=eq.${encodeURIComponent(contact)}&created_at=gte.${new Date(Date.now() - 60000).toISOString()}&select=id`,
      {
        method: 'GET',
        headers: {
          'Authorization': `Bearer ${supabaseServiceKey}`,
          'apikey': supabaseServiceKey,
          'Content-Type': 'application/json'
        }
      }
    );

    if (recentCodeResponse.ok) {
      const recentCodes = await recentCodeResponse.json();
      if (recentCodes.length > 0) {
        return new Response(
          JSON.stringify({
            error: {
              code: 'TOO_FREQUENT',
              message: '验证码发送过于频繁，请60秒后再试'
            }
          }),
          {
            status: 429,
            headers: { ...corsHeaders, 'Content-Type': 'application/json' }
          }
        );
      }
    }

    // 生成验证码
    const code = generateVerificationCode();
    const expiresAt = new Date(Date.now() + 5 * 60 * 1000); // 5分钟后过期

    // 保存验证码到数据库
    const insertResponse = await fetch(`${supabaseUrl}/rest/v1/verification_codes`, {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${supabaseServiceKey}`,
        'apikey': supabaseServiceKey,
        'Content-Type': 'application/json'
      },
      body: JSON.stringify({
        user_id: userId,
        code: code,
        type: type,
        contact: contact,
        expires_at: expiresAt.toISOString()
      })
    });

    if (!insertResponse.ok) {
      const errorText = await insertResponse.text();
      throw new Error(`保存验证码失败: ${errorText}`);
    }

    try {
      await deliverVerificationCode({
        contactType: type,
        contactValue: contact,
        code,
        purpose: 'bind',
      });
    } catch (deliveryError) {
      console.error(`验证码发送失败: ${maskContact(type, contact)}`, deliveryError);

      await fetch(
        `${supabaseUrl}/rest/v1/verification_codes?user_id=eq.${userId}&contact=eq.${encodeURIComponent(contact)}&code=eq.${code}`,
        {
          method: 'DELETE',
          headers: {
            'Authorization': `Bearer ${supabaseServiceKey}`,
            'apikey': supabaseServiceKey
          }
        }
      );

      return new Response(
        JSON.stringify({
          error: {
            code: 'SEND_FAILED',
            message: deliveryError instanceof Error ? deliveryError.message : '验证码发送失败'
          }
        }),
        {
          status: 500,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        }
      );
    }

    return new Response(
      JSON.stringify({
        data: {
          message: `验证码已发送到 ${type === 'email' ? '邮箱' : '手机'}`,
          expires_at: expiresAt.toISOString()
        }
      }),
      {
        status: 200,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      }
    );

  } catch (error) {
    console.error('发送验证码错误:', error);
    return new Response(
      JSON.stringify({
        error: {
          code: 'INTERNAL_ERROR',
          message: error instanceof Error ? error.message : '服务器内部错误'
        }
      }),
      {
        status: 500,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      }
    );
  }
});
