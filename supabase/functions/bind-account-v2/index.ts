import {
  getAuthProfileSnapshot,
  mergeBindingStatusRecord,
} from '../_shared/auth-profile.ts';
import {
  type ContactType,
  VerificationProviderError,
  isValidEmail,
  isValidPhone,
  shouldUseAliyunSmsVerification,
  verifyPhoneVerificationCode,
} from '../_shared/verification-delivery.ts';
import {
  fetchLatestPendingVerification,
  patchVerificationRecord,
} from '../_shared/verification-records.ts';
import { getCorsHeaders } from '../_shared/security.ts';

function getClientIP(request: Request) {
  const forwardedFor = request.headers.get('x-forwarded-for');
  if (forwardedFor) {
    return forwardedFor.split(',')[0].trim();
  }
  return request.headers.get('x-real-ip') || 'unknown';
}

function jsonResponse(
  status: number,
  payload: Record<string, unknown>,
  corsHeaders: Record<string, string>
) {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}

Deno.serve(async (req) => {
  const corsHeaders = getCorsHeaders(req);

  if (req.method === 'OPTIONS') {
    return new Response(null, { status: 200, headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
    const supabaseServiceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

    if (req.method !== 'POST') {
      return jsonResponse(
        405,
        {
          error: {
            code: 'METHOD_NOT_ALLOWED',
            message: '只支持POST方法',
          },
        },
        corsHeaders
      );
    }

    const authHeader = req.headers.get('Authorization');
    if (!authHeader) {
      return jsonResponse(
        401,
        {
          error: {
            code: 'UNAUTHORIZED',
            message: '缺少授权头',
          },
        },
        corsHeaders
      );
    }

    const { contact_type, contact_value, verification_code } = await req.json();

    if (!contact_type || !contact_value || !verification_code) {
      return jsonResponse(
        400,
        {
          error: {
            code: 'INVALID_PARAMETERS',
            message: '联系方式类型、值和验证码不能为空',
          },
        },
        corsHeaders
      );
    }

    if (!['email', 'phone'].includes(contact_type)) {
      return jsonResponse(
        400,
        {
          error: {
            code: 'INVALID_CONTACT_TYPE',
            message: '联系方式类型只能是email或phone',
          },
        },
        corsHeaders
      );
    }

    if (contact_type === 'email' && !isValidEmail(contact_value)) {
      return jsonResponse(
        400,
        {
          error: {
            code: 'INVALID_EMAIL_FORMAT',
            message: '邮箱格式不正确',
          },
        },
        corsHeaders
      );
    }

    if (contact_type === 'phone' && !isValidPhone(contact_value)) {
      return jsonResponse(
        400,
        {
          error: {
            code: 'INVALID_PHONE_FORMAT',
            message: '手机号格式不正确，请输入11位中国大陆手机号',
          },
        },
        corsHeaders
      );
    }

    if (!/^\d{6}$/.test(verification_code)) {
      return jsonResponse(
        400,
        {
          error: {
            code: 'INVALID_CODE_FORMAT',
            message: '验证码必须是6位数字',
          },
        },
        corsHeaders
      );
    }

    const token = authHeader.replace('Bearer ', '');
    const userResponse = await fetch(`${supabaseUrl}/auth/v1/user`, {
      headers: {
        Authorization: `Bearer ${token}`,
        apikey: supabaseServiceKey,
      },
    });

    if (!userResponse.ok) {
      return jsonResponse(
        401,
        {
          error: {
            code: 'UNAUTHORIZED',
            message: '无效的授权token',
          },
        },
        corsHeaders
      );
    }

    const userData = await userResponse.json();
    const userId = userData.id as string;
    const authSnapshot = getAuthProfileSnapshot(userData);
    const clientIP = getClientIP(req);
    const userAgent = req.headers.get('user-agent') || 'unknown';

    if (
      contact_type === 'phone' &&
      shouldUseAliyunSmsVerification(contact_value)
    ) {
      const pendingVerification = await fetchLatestPendingVerification({
        supabaseUrl,
        supabaseServiceKey,
        userId,
        contactType: contact_type as ContactType,
        contactValue: contact_value,
        purpose: 'bind',
      });

      if (!pendingVerification) {
        return jsonResponse(
          400,
          {
            error: {
              code: 'VERIFICATION_REQUIRED',
              message: '请先获取验证码',
            },
          },
          corsHeaders
        );
      }

      try {
        await verifyPhoneVerificationCode(contact_value, verification_code);
      } catch (error) {
        if (error instanceof VerificationProviderError) {
          return jsonResponse(
            error.status,
            {
              error: {
                code: error.code,
                message: error.message,
              },
            },
            corsHeaders
          );
        }

        throw error;
      }

      await patchVerificationRecord(
        supabaseUrl,
        supabaseServiceKey,
        pendingVerification.id,
        {
          code: verification_code,
          attempts: 0,
        }
      );
    }

    const bindResponse = await fetch(`${supabaseUrl}/rest/v1/rpc/bind_contact_method`, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${supabaseServiceKey}`,
        apikey: supabaseServiceKey,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        contact_type_param: contact_type,
        contact_value_param: contact_value,
        verification_code_param: verification_code,
        client_ip_param: clientIP,
        client_user_agent_param: userAgent,
      }),
    });

    if (!bindResponse.ok) {
      throw new Error(`绑定操作失败: ${await bindResponse.text()}`);
    }

    const bindResult = await bindResponse.json();

    if (!bindResult.success) {
      return jsonResponse(
        400,
        {
          error: {
            code: bindResult.code || 'BIND_FAILED',
            message: bindResult.error || '绑定失败',
          },
        },
        corsHeaders
      );
    }

    const statusResponse = await fetch(`${supabaseUrl}/rest/v1/rpc/get_user_binding_status`, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${token}`,
        apikey: supabaseServiceKey,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        target_user_id: userId,
      }),
    });

    let updatedStatus = null;
    if (statusResponse.ok) {
      const usersRowResponse = await fetch(
        `${supabaseUrl}/rest/v1/users?select=nebula_id&id=eq.${userId}&limit=1`,
        {
          method: 'GET',
          headers: {
            Authorization: `Bearer ${supabaseServiceKey}`,
            apikey: supabaseServiceKey,
            'Content-Type': 'application/json',
          },
        }
      );

      let usersRowNebulaId: string | null = null;
      if (usersRowResponse.ok) {
        const usersRows = await usersRowResponse.json();
        if (Array.isArray(usersRows) && typeof usersRows[0]?.nebula_id === 'string') {
          usersRowNebulaId = usersRows[0].nebula_id.trim() || null;
        }
      }

      updatedStatus = mergeBindingStatusRecord(
        await statusResponse.json(),
        userData,
        authSnapshot.metadataNebulaId || usersRowNebulaId
      );
    }

    return jsonResponse(
      200,
      {
        data: {
          message: bindResult.message,
          contact_type,
          contact_value,
          binding_status: updatedStatus,
          timestamp: new Date().toISOString(),
        },
      },
      corsHeaders
    );
  } catch (error) {
    console.error('绑定账户错误:', error);
    return jsonResponse(
      500,
      {
        error: {
          code: 'INTERNAL_ERROR',
          message: error instanceof Error ? error.message : '服务器内部错误',
        },
      },
      corsHeaders
    );
  }
});
