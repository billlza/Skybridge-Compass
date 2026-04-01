// 账户解绑的边缘函数
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
    const { type, code } = await req.json();

    // 验证参数
    if (!type) {
      return new Response(
        JSON.stringify({
          error: {
            code: 'INVALID_PARAMETERS',
            message: '解绑类型不能为空'
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
            message: '解绑类型只能是email或phone'
          }
        }),
        {
          status: 400,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        }
      );
    }

    // 星云ID不允许解绑
    if (type === 'nebula_id') {
      return new Response(
        JSON.stringify({
          error: {
            code: 'NEBULA_ID_CANNOT_UNBIND',
            message: '星云ID不允许解绑，它是您的永久标识符'
          }
        }),
        {
          status: 403,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        }
      );
    }

    if (!code) {
      return new Response(
        JSON.stringify({
          error: {
            code: 'CODE_REQUIRED',
            message: `解绑${type === 'email' ? '邮箱' : '手机号'}需要验证码`
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

    // 获取用户当前资料
    const profileResponse = await fetch(
      `${supabaseUrl}/rest/v1/user_profiles?id=eq.${userId}&select=*`,
      {
        method: 'GET',
        headers: {
          'Authorization': `Bearer ${supabaseServiceKey}`,
          'apikey': supabaseServiceKey,
          'Content-Type': 'application/json'
        }
      }
    );

    if (!profileResponse.ok) {
      throw new Error('获取用户资料失败');
    }

    const profiles = await profileResponse.json();
    if (profiles.length === 0) {
      return new Response(
        JSON.stringify({
          error: {
            code: 'USER_PROFILE_NOT_FOUND',
            message: '用户资料不存在'
          }
        }),
        {
          status: 404,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        }
      );
    }

    const profile = profiles[0];

    // 检查用户是否已绑定该类型
    let currentContact = '';
    if (type === 'email') {
      currentContact = profile.email;
    } else if (type === 'phone') {
      currentContact = profile.phone;
    }

    if (!currentContact) {
      return new Response(
        JSON.stringify({
          error: {
            code: 'NOT_BOUND',
            message: `您尚未绑定${type === 'email' ? '邮箱' : '手机号'}`
          }
        }),
        {
          status: 400,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        }
      );
    }

    // 验证验证码
    const verificationResponse = await fetch(
      `${supabaseUrl}/rest/v1/verification_codes?user_id=eq.${userId}&type=eq.${type}&contact=eq.${encodeURIComponent(currentContact)}&is_used=eq.false&expires_at=gte.${new Date().toISOString()}&order=created_at.desc&limit=1`,
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

    if ((verification.attempts || 0) >= 5) {
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

      return new Response(
        JSON.stringify({
          error: {
            code: nextAttempts >= 5 ? 'TOO_MANY_ATTEMPTS' : 'INVALID_OR_EXPIRED_CODE',
            message: nextAttempts >= 5 ? '验证失败次数过多，请重新获取验证码' : '验证码错误或已过期'
          }
        }),
        {
          status: nextAttempts >= 5 ? 429 : 400,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        }
      );
    }

    // 标记验证码为已使用
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
          is_used: true
        })
      }
    );

    // 准备更新数据
    const updateData: any = {
      updated_at: new Date().toISOString()
    };

    // 根据类型清空对应字段
    if (type === 'email') {
      updateData.email = null;
    } else if (type === 'phone') {
      updateData.phone = null;
    }

    // 更新用户资料
    const updateResponse = await fetch(
      `${supabaseUrl}/rest/v1/user_profiles?id=eq.${userId}`,
      {
        method: 'PATCH',
        headers: {
          'Authorization': `Bearer ${supabaseServiceKey}`,
          'apikey': supabaseServiceKey,
          'Content-Type': 'application/json',
          'Prefer': 'return=representation'
        },
        body: JSON.stringify(updateData)
      }
    );

    if (!updateResponse.ok) {
      const errorText = await updateResponse.text();
      throw new Error(`更新用户资料失败: ${errorText}`);
    }

    const updatedProfile = await updateResponse.json();

    return new Response(
      JSON.stringify({
        data: {
          message: `${type === 'email' ? '邮箱' : '手机号'}解绑成功`,
          profile: updatedProfile[0]
        }
      }),
      {
        status: 200,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      }
    );

  } catch (error) {
    console.error('解绑账户错误:', error);
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
