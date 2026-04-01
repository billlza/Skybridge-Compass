import { getCorsHeaders } from '../_shared/security.ts';

const INVALID_LOGIN_MESSAGE = '星云ID或密钥错误';

Deno.serve(async (req) => {
  const corsHeaders = getCorsHeaders(req);

  if (req.method === 'OPTIONS') {
    return new Response(null, { status: 200, headers: corsHeaders });
  }

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

  try {
    const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
    const supabaseServiceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
    const supabaseAnonKey = Deno.env.get('SUPABASE_ANON_KEY')!;

    const { nebula_id, password } = await req.json();
    const normalizedNebulaId = typeof nebula_id === 'string' ? nebula_id.trim().toUpperCase() : '';

    if (!normalizedNebulaId || typeof password !== 'string' || password.length === 0) {
      return new Response(
        JSON.stringify({
          error: {
            code: 'INVALID_PARAMETERS',
            message: '星云ID和密钥不能为空'
          }
        }),
        {
          status: 400,
          headers: { ...corsHeaders, 'Content-Type': 'application/json', 'Cache-Control': 'no-store' }
        }
      );
    }

    const profileResponse = await fetch(
      `${supabaseUrl}/rest/v1/user_profiles?nebula_id=eq.${encodeURIComponent(normalizedNebulaId)}&email=not.is.null&select=email&limit=1`,
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
      throw new Error('查询星云账号失败');
    }

    const profiles = await profileResponse.json();
    const email = profiles[0]?.email;

    if (!email) {
      return new Response(
        JSON.stringify({
          error: {
            code: 'INVALID_CREDENTIALS',
            message: INVALID_LOGIN_MESSAGE
          }
        }),
        {
          status: 401,
          headers: { ...corsHeaders, 'Content-Type': 'application/json', 'Cache-Control': 'no-store' }
        }
      );
    }

    const authResponse = await fetch(
      `${supabaseUrl}/auth/v1/token?grant_type=password`,
      {
        method: 'POST',
        headers: {
          'Authorization': `Bearer ${supabaseAnonKey}`,
          'apikey': supabaseAnonKey,
          'Content-Type': 'application/json'
        },
        body: JSON.stringify({
          email,
          password
        })
      }
    );

    const authResult = await authResponse.json().catch(() => null);

    if (!authResponse.ok || !authResult?.access_token || !authResult?.refresh_token) {
      return new Response(
        JSON.stringify({
          error: {
            code: 'INVALID_CREDENTIALS',
            message: INVALID_LOGIN_MESSAGE
          }
        }),
        {
          status: 401,
          headers: { ...corsHeaders, 'Content-Type': 'application/json', 'Cache-Control': 'no-store' }
        }
      );
    }

    return new Response(
      JSON.stringify({
        data: {
          session: {
            access_token: authResult.access_token,
            refresh_token: authResult.refresh_token,
            expires_in: authResult.expires_in,
            expires_at: authResult.expires_at,
            token_type: authResult.token_type,
            user: authResult.user
          }
        }
      }),
      {
        status: 200,
        headers: { ...corsHeaders, 'Content-Type': 'application/json', 'Cache-Control': 'no-store' }
      }
    );
  } catch (error) {
    console.error('nebula-login failed:', error);

    return new Response(
      JSON.stringify({
        error: {
          code: 'INTERNAL_ERROR',
          message: '登录服务暂时不可用'
        }
      }),
      {
        status: 500,
        headers: { ...corsHeaders, 'Content-Type': 'application/json', 'Cache-Control': 'no-store' }
      }
    );
  }
});
