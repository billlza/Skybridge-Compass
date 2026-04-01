// 生成唯一星云ID的边缘函数
import { generateNebulaId, getCorsHeaders } from '../_shared/security.ts';

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

    // 检查用户是否已有星云ID
    const checkResponse = await fetch(`${supabaseUrl}/rest/v1/user_profiles?id=eq.${userId}&select=nebula_id`, {
      method: 'GET',
      headers: {
        'Authorization': `Bearer ${supabaseServiceKey}`,
        'apikey': supabaseServiceKey,
        'Content-Type': 'application/json'
      }
    });

    if (!checkResponse.ok) {
      throw new Error('检查用户信息失败');
    }

    const userProfiles = await checkResponse.json();
    if (userProfiles.length > 0 && userProfiles[0].nebula_id) {
      return new Response(
        JSON.stringify({
          error: {
            code: 'NEBULA_ID_EXISTS',
            message: '您已经有星云ID，无需重复生成'
          }
        }),
        {
          status: 400,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        }
      );
    }

    let nebulaId: string | null = null;

    for (let attempt = 0; attempt < 5; attempt += 1) {
      const candidate = generateNebulaId();
      const uniquenessResponse = await fetch(
        `${supabaseUrl}/rest/v1/user_profiles?nebula_id=eq.${encodeURIComponent(candidate)}&select=id&limit=1`,
        {
          method: 'GET',
          headers: {
            'Authorization': `Bearer ${supabaseServiceKey}`,
            'apikey': supabaseServiceKey,
            'Content-Type': 'application/json'
          }
        }
      );

      if (!uniquenessResponse.ok) {
        throw new Error('检查星云ID唯一性失败');
      }

      const existingProfiles = await uniquenessResponse.json();
      if (existingProfiles.length === 0) {
        nebulaId = candidate;
        break;
      }
    }

    if (!nebulaId) {
      throw new Error('生成唯一星云ID失败，请稍后重试');
    }

    // 更新用户资料
    const updateResponse = await fetch(`${supabaseUrl}/rest/v1/user_profiles?id=eq.${userId}`, {
      method: 'PATCH',
      headers: {
        'Authorization': `Bearer ${supabaseServiceKey}`,
        'apikey': supabaseServiceKey,
        'Content-Type': 'application/json',
        'Prefer': 'return=representation'
      },
      body: JSON.stringify({
        nebula_id: nebulaId,
        updated_at: new Date().toISOString()
      })
    });

    if (!updateResponse.ok) {
      const errorText = await updateResponse.text();
      throw new Error(`更新用户资料失败: ${errorText}`);
    }

    const updatedProfile = await updateResponse.json();

    return new Response(
      JSON.stringify({
        data: {
          nebula_id: nebulaId.toString(),
          format: 'macos-compatible',
          message: '星云ID生成成功'
        }
      }),
      {
        status: 200,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      }
    );

  } catch (error) {
    console.error('生成星云ID错误:', error);
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
