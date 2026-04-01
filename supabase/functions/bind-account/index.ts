// 账户绑定的边缘函数
import { generateNebulaId, getCorsHeaders } from '../_shared/security.ts';

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
    const { type, contact, code } = await req.json();

    // 验证参数
    if (!type || !contact) {
      return new Response(
        JSON.stringify({
          error: {
            code: 'INVALID_PARAMETERS',
            message: '绑定类型和联系方式不能为空'
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
            message: '绑定类型只能是email或phone'
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

    // 需要验证码的绑定类型需要验证码
    if (type === 'email' || type === 'phone') {
      if (!code) {
        return new Response(
          JSON.stringify({
            error: {
              code: 'CODE_REQUIRED',
              message: `绑定${type === 'email' ? '邮箱' : '手机号'}需要验证码`
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

      // 验证验证码
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
    }

    // 检查该联系方式是否已被其他用户绑定
    let conflictCheckQuery = '';
    if (type === 'email') {
      conflictCheckQuery = `email=eq.${encodeURIComponent(contact)}`;
    } else if (type === 'phone') {
      conflictCheckQuery = `phone=eq.${encodeURIComponent(contact)}`;
    }

    const conflictResponse = await fetch(
      `${supabaseUrl}/rest/v1/user_profiles?${conflictCheckQuery}&id=neq.${userId}&select=id`,
      {
        method: 'GET',
        headers: {
          'Authorization': `Bearer ${supabaseServiceKey}`,
          'apikey': supabaseServiceKey,
          'Content-Type': 'application/json'
        }
      }
    );

    if (conflictResponse.ok) {
      const conflicts = await conflictResponse.json();
      if (conflicts.length > 0) {
        return new Response(
          JSON.stringify({
            error: {
              code: 'ALREADY_BOUND',
              message: `该${type === 'email' ? '邮箱' : '手机号'}已被其他用户绑定`
            }
          }),
          {
            status: 409,
            headers: { ...corsHeaders, 'Content-Type': 'application/json' }
          }
        );
      }
    }

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

    // 检查用户是否已有星云ID，如果没有则生成一个
    if (!profile.nebula_id) {
      const seqResponse = await fetch(`${supabaseUrl}/rest/v1/rpc/nextval`, {
        method: 'POST',
        headers: {
          'Authorization': `Bearer ${supabaseServiceKey}`,
          'apikey': supabaseServiceKey,
          'Content-Type': 'application/json'
        },
        body: JSON.stringify({ sequence_name: 'nebula_id_seq' })
      });

      let nebulaId;
      if (seqResponse.ok) {
        nebulaId = await seqResponse.json();
      } else {
        // 备用方案：生成随机ID
        nebulaId = generateNebulaId();
      }

      profile.nebula_id = nebulaId.toString();
    }

    // 准备更新数据
    const updateData: any = {
      updated_at: new Date().toISOString()
    };

    // 确保星云ID被设置
    if (profile.nebula_id) {
      updateData.nebula_id = profile.nebula_id;
    }

    // 根据类型设置对应字段
    if (type === 'email') {
      updateData.email = contact;
    } else if (type === 'phone') {
      updateData.phone = contact;
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
          message: `${type === 'email' ? '邮箱' : '手机号'}绑定成功`,
          profile: updatedProfile[0]
        }
      }),
      {
        status: 200,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      }
    );

  } catch (error) {
    console.error('绑定账户错误:', error);
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
