import {
  type ContactType,
  type VerificationPurpose,
  VerificationProviderError,
  deliverVerificationCode,
  isValidEmail,
  isValidPhone,
} from '../_shared/verification-delivery.ts';
import {
  createVerificationRecord,
  deleteVerificationRecordById,
  hasRecentVerification,
} from '../_shared/verification-records.ts';
import { getCorsHeaders, maskContact } from '../_shared/security.ts';

function generateVerificationCode() {
  const bytes = crypto.getRandomValues(new Uint32Array(1));
  return (100000 + (bytes[0] % 900000)).toString();
}

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

    const { contact_type, contact_value, purpose = 'bind' } = await req.json();

    if (!contact_type || !contact_value) {
      return jsonResponse(
        400,
        {
          error: {
            code: 'INVALID_PARAMETERS',
            message: '联系方式类型和值不能为空',
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

    if (!['bind', 'unbind', 'verify'].includes(purpose)) {
      return jsonResponse(
        400,
        {
          error: {
            code: 'INVALID_PURPOSE',
            message: '目的只能是bind、unbind或verify',
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
    const clientIP = getClientIP(req);

    const recentCodeExists = await hasRecentVerification({
      supabaseUrl,
      supabaseServiceKey,
      userId,
      contactType: contact_type as ContactType,
      contactValue: contact_value,
      purpose: purpose as VerificationPurpose,
    });

    if (recentCodeExists) {
      return jsonResponse(
        429,
        {
          error: {
            code: 'TOO_FREQUENT',
            message: '验证码发送过于频繁，请60秒后再试',
          },
        },
        corsHeaders
      );
    }

    const verification = await createVerificationRecord({
      supabaseUrl,
      supabaseServiceKey,
      userId,
      contactType: contact_type as ContactType,
      contactValue: contact_value,
      purpose: purpose as VerificationPurpose,
      code: generateVerificationCode(),
      expiresAt: new Date(Date.now() + 5 * 60 * 1000).toISOString(),
      ipAddress: clientIP,
    });

    try {
      await deliverVerificationCode({
        contactType: contact_type as ContactType,
        contactValue: contact_value,
        code: verification.code,
        purpose: purpose as VerificationPurpose,
      });
    } catch (deliveryError) {
      console.error(`验证码发送失败: ${maskContact(contact_type, contact_value)}`, deliveryError);

      try {
        await deleteVerificationRecordById(
          supabaseUrl,
          supabaseServiceKey,
          verification.id
        );
      } catch (cleanupError) {
        console.error('清理验证码记录失败:', cleanupError);
      }

      const providerError =
        deliveryError instanceof VerificationProviderError ? deliveryError : null;

      return jsonResponse(
        providerError?.status || 500,
        {
          error: {
            code: providerError?.code || 'SEND_FAILED',
            message:
              providerError?.message ||
              (deliveryError instanceof Error
                ? deliveryError.message
                : '发送服务暂时不可用，请稍后重试'),
          },
        },
        corsHeaders
      );
    }

    return jsonResponse(
      200,
      {
        data: {
          message: `验证码已发送到您的${contact_type === 'email' ? '邮箱' : '手机'}`,
          contact_type,
          contact_masked: maskContact(contact_type, contact_value),
          expires_in: 300,
          can_resend_after: 60,
        },
      },
      corsHeaders
    );
  } catch (error) {
    console.error('发送验证码错误:', error);
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
