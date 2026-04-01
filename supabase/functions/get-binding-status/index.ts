// 获取用户绑定状态的边缘函数
import { getCorsHeaders } from '../_shared/security.ts';
import {
  getAuthProfileSnapshot,
  mergeBindingStatusRecord
} from '../_shared/auth-profile.ts';

type BindingHistoryRecord = {
  contact_type: string
  action: string
  contact_value: string
  created_at: string
  ip_address?: string
}

type PendingCodeRecord = {
  contact_type: string
  contact_value: string
  expires_at: string
  created_at: string
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
    if (req.method !== 'GET' && req.method !== 'POST') {
      return new Response(
        JSON.stringify({
          error: {
            code: 'METHOD_NOT_ALLOWED',
            message: '只支持GET和POST方法'
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
    const authSnapshot = getAuthProfileSnapshot(userData);
    const usersRowResponse = await fetch(
      `${supabaseUrl}/rest/v1/users?select=nebula_id&id=eq.${userId}&limit=1`,
      {
        method: 'GET',
        headers: {
          'Authorization': `Bearer ${supabaseServiceKey}`,
          'apikey': supabaseServiceKey,
          'Content-Type': 'application/json'
        }
      }
    );
    let usersRowNebulaId: string | null = null;
    if (usersRowResponse.ok) {
      const usersRows = await usersRowResponse.json();
      if (Array.isArray(usersRows) && typeof usersRows[0]?.nebula_id === 'string') {
        usersRowNebulaId = usersRows[0].nebula_id.trim() || null;
      }
    }
    const canonicalNebulaId = authSnapshot.metadataNebulaId || usersRowNebulaId;

    // 调用数据库函数获取绑定状态
    const statusResponse = await fetch(
      `${supabaseUrl}/rest/v1/rpc/get_user_binding_status`,
      {
        method: 'POST',
        headers: {
          'Authorization': `Bearer ${token}`,
          'apikey': supabaseServiceKey,
          'Content-Type': 'application/json'
        },
        body: JSON.stringify({
          target_user_id: userId
        })
      }
    );

    if (!statusResponse.ok) {
      const errorText = await statusResponse.text();
      throw new Error(`获取绑定状态失败: ${errorText}`);
    }

    const bindingStatus = await statusResponse.json();
    const mergedBindingStatus = mergeBindingStatusRecord(
      bindingStatus,
      userData,
      canonicalNebulaId
    );

    // 获取绑定历史（最近10条记录）
    const historyResponse = await fetch(
      `${supabaseUrl}/rest/v1/account_bindings?user_id=eq.${userId}&select=*&order=created_at.desc&limit=10`,
      {
        method: 'GET',
        headers: {
          'Authorization': `Bearer ${supabaseServiceKey}`,
          'apikey': supabaseServiceKey,
          'Content-Type': 'application/json'
        }
      }
    );

    let bindingHistory: BindingHistoryRecord[] = [];
    if (historyResponse.ok) {
      bindingHistory = await historyResponse.json();
    }

    // 获取待验证的验证码数量（未过期且未使用）
    const pendingCodesResponse = await fetch(
      `${supabaseUrl}/rest/v1/verification_codes?user_id=eq.${userId}&is_used=eq.false&expires_at=gte.${new Date().toISOString()}&select=contact_type,contact_value,expires_at,created_at`,
      {
        method: 'GET',
        headers: {
          'Authorization': `Bearer ${supabaseServiceKey}`,
          'apikey': supabaseServiceKey,
          'Content-Type': 'application/json'
        }
      }
    );

    let pendingCodes: PendingCodeRecord[] = [];
    if (pendingCodesResponse.ok) {
      pendingCodes = await pendingCodesResponse.json();
    }

    return new Response(
      JSON.stringify({
        data: {
          binding_status: mergedBindingStatus,
          binding_history: bindingHistory.map((record: BindingHistoryRecord) => ({
            contact_type: record.contact_type,
            action: record.action,
            contact_masked: record.contact_type === 'email' 
              ? record.contact_value.replace(/(.{2}).*(@.*)/, '$1***$2')
              : record.contact_value.replace(/(\d{3})\d{4}(\d{4})/, '$1****$2'),
            created_at: record.created_at,
            ip_address: record.ip_address
          })),
          pending_verifications: pendingCodes.map((code: PendingCodeRecord) => ({
            contact_type: code.contact_type,
            contact_masked: code.contact_type === 'email' 
              ? code.contact_value.replace(/(.{2}).*(@.*)/, '$1***$2')
              : code.contact_value.replace(/(\d{3})\d{4}(\d{4})/, '$1****$2'),
            expires_at: code.expires_at,
            created_at: code.created_at
          })),
          timestamp: new Date().toISOString()
        }
      }),
      {
        status: 200,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      }
    );

  } catch (error) {
    console.error('获取绑定状态错误:', error);
    const errorMessage = error instanceof Error ? error.message : '服务器内部错误';
    return new Response(
      JSON.stringify({
        error: {
          code: 'INTERNAL_ERROR',
          message: errorMessage
        }
      }),
      {
        status: 500,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      }
    );
  }
});
