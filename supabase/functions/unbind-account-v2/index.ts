import {
  getAuthProfileSnapshot,
  mergeBindingStatusRecord,
} from '../_shared/auth-profile.ts';
import {
  type ContactType,
  VerificationProviderError,
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

    const { contact_type, verification_code } = await req.json();

    if (!contact_type || !verification_code) {
      return jsonResponse(
        400,
        {
          error: {
            code: 'INVALID_PARAMETERS',
            message: '联系方式类型和验证码不能为空',
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

    if (contact_type === 'nebula_id') {
      return jsonResponse(
        403,
        {
          error: {
            code: 'NEBULA_ID_CANNOT_UNBIND',
            message: '星云ID不允许解绑，它是您的永久标识符',
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

    if (contact_type === 'phone') {
      const currentPhone = authSnapshot.phone;
      if (!currentPhone) {
        return jsonResponse(
          400,
          {
            error: {
              code: 'NOT_BOUND',
              message: '您尚未绑定手机号',
            },
          },
          corsHeaders
        );
      }

      if (shouldUseAliyunSmsVerification(currentPhone)) {
        const pendingVerification = await fetchLatestPendingVerification({
          supabaseUrl,
          supabaseServiceKey,
          userId,
          contactType: contact_type as ContactType,
          contactValue: currentPhone,
          purpose: 'unbind',
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
          await verifyPhoneVerificationCode(currentPhone, verification_code);
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
    }

    const unbindResponse = await fetch(`${supabaseUrl}/rest/v1/rpc/unbind_contact_method`, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${supabaseServiceKey}`,
        apikey: supabaseServiceKey,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        contact_type_param: contact_type,
        verification_code_param: verification_code,
        client_ip_param: clientIP,
        client_user_agent_param: userAgent,
      }),
    });

    if (!unbindResponse.ok) {
      throw new Error(`解绑操作失败: ${await unbindResponse.text()}`);
    }

    const unbindResult = await unbindResponse.json();

    if (!unbindResult.success) {
      return jsonResponse(
        400,
        {
          error: {
            code: unbindResult.code || 'UNBIND_FAILED',
            message: unbindResult.error || '解绑失败',
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
          message: unbindResult.message,
          contact_type,
          previous_value: unbindResult.previous_value,
          binding_status: updatedStatus,
          timestamp: new Date().toISOString(),
        },
      },
      corsHeaders
    );
  } catch (error) {
    console.error('解绑账户错误:', error);
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
