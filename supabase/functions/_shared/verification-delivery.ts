import { maskContact } from './security.ts';

export type ContactType = 'email' | 'phone';
export type VerificationPurpose = 'bind' | 'unbind' | 'verify';

interface DeliveryRequest {
  contactType: ContactType;
  contactValue: string;
  code: string;
  purpose?: VerificationPurpose;
}

interface DeliveryReceipt {
  provider: string;
  externalId?: string;
}

type AliyunApiResult = {
  Code?: string;
  Message?: string;
  RequestId?: string;
  BizId?: string;
  Success?: boolean;
};

const defaultBrandName = Deno.env.get('VERIFICATION_BRAND_NAME')?.trim() || 'skybridge.com';
const defaultSupportEmail =
  Deno.env.get('VERIFICATION_SUPPORT_EMAIL')?.trim() || 'support@nebula-technologies.net';

export class VerificationProviderError extends Error {
  code: string;
  status: number;

  constructor(code: string, message: string, status = 400) {
    super(message);
    this.name = 'VerificationProviderError';
    this.code = code;
    this.status = status;
  }
}

function readEnv(name: string) {
  return Deno.env.get(name)?.trim() || '';
}

export function isValidEmail(email: string) {
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email);
}

export function isChinaMainlandPhone(phone: string) {
  const digits = phone.replace(/\D/g, '');
  return /^1[3-9]\d{9}$/.test(digits) || /^86(1[3-9]\d{9})$/.test(digits);
}

export function isValidPhone(phone: string) {
  return isChinaMainlandPhone(phone);
}

export function shouldUseAliyunSmsVerification(phone: string) {
  return Boolean(
    readEnv('ALIYUN_ACCESS_KEY_ID') &&
      readEnv('ALIYUN_ACCESS_KEY_SECRET') &&
      isChinaMainlandPhone(phone)
  );
}

function buildPurposeLabel(purpose: VerificationPurpose) {
  switch (purpose) {
    case 'unbind':
      return '解绑确认';
    case 'verify':
      return '安全校验';
    case 'bind':
    default:
      return '绑定验证';
  }
}

function buildSmsBody(code: string, purpose: VerificationPurpose) {
  return `${defaultBrandName}${buildPurposeLabel(purpose)}验证码：${code}。5分钟内有效，如非本人操作请忽略。`;
}

function buildEmailPayload(email: string, code: string, purpose: VerificationPurpose) {
  const purposeLabel = buildPurposeLabel(purpose);
  const subject = `${defaultBrandName}${purposeLabel}验证码：${code}`;
  const text = [
    `${defaultBrandName} ${purposeLabel}`,
    '',
    `您的验证码是：${code}`,
    '5分钟内有效，如非本人操作请忽略此邮件。',
    '',
    `支持邮箱：${defaultSupportEmail}`,
  ].join('\n');

  const html = `
    <div style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;background:#0f172a;padding:32px;color:#e2e8f0;">
      <div style="max-width:560px;margin:0 auto;background:#111827;border-radius:20px;padding:32px;border:1px solid rgba(148,163,184,0.2);">
        <p style="margin:0 0 12px;font-size:14px;letter-spacing:0.08em;text-transform:uppercase;color:#38bdf8;">${defaultBrandName}</p>
        <h1 style="margin:0 0 16px;font-size:28px;line-height:1.2;color:#f8fafc;">${purposeLabel}验证码</h1>
        <p style="margin:0 0 24px;font-size:16px;line-height:1.7;color:#cbd5e1;">
          您正在进行${purposeLabel}，请输入下面的 6 位验证码完成操作。
        </p>
        <div style="margin:0 0 24px;padding:20px 24px;background:linear-gradient(135deg,#0ea5e9,#2563eb);border-radius:16px;text-align:center;">
          <span style="display:block;font-size:34px;font-weight:700;letter-spacing:0.3em;color:#ffffff;">${code}</span>
        </div>
        <p style="margin:0 0 8px;font-size:14px;color:#94a3b8;">验证码将在 5 分钟后失效。</p>
        <p style="margin:0 0 24px;font-size:14px;color:#94a3b8;">如果这不是您的操作，请忽略本邮件。</p>
        <p style="margin:0;font-size:13px;color:#64748b;">支持邮箱：${defaultSupportEmail}</p>
      </div>
    </div>
  `;

  return {
    from: readEnv('VERIFICATION_EMAIL_FROM') || readEnv('RESEND_FROM_EMAIL'),
    replyTo: readEnv('VERIFICATION_EMAIL_REPLY_TO') || defaultSupportEmail,
    to: email,
    subject,
    text,
    html,
  };
}

function normalizePhone(phone: string) {
  if (/^\+\d{8,15}$/.test(phone)) {
    return phone;
  }

  const digits = phone.replace(/\D/g, '');

  if (/^1[3-9]\d{9}$/.test(digits)) {
    return `+86${digits}`;
  }

  if (/^86\d{11}$/.test(digits)) {
    return `+${digits}`;
  }

  throw new VerificationProviderError(
    'INVALID_PHONE_FORMAT',
    '短信服务仅支持 E.164 或中国大陆手机号格式'
  );
}

function normalizeAliyunMainlandPhone(phone: string) {
  const digits = phone.replace(/\D/g, '');

  if (/^1[3-9]\d{9}$/.test(digits)) {
    return digits;
  }

  if (/^86(1[3-9]\d{9})$/.test(digits)) {
    return digits.slice(2);
  }

  throw new VerificationProviderError(
    'INVALID_PHONE_FORMAT',
    '阿里云短信认证仅支持 11 位中国大陆手机号'
  );
}

function aliyunPercentEncode(value: string) {
  return encodeURIComponent(value)
    .replace(/\+/g, '%20')
    .replace(/\*/g, '%2A')
    .replace(/%7E/g, '~');
}

function base64Encode(bytes: Uint8Array) {
  let binary = '';
  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }
  return btoa(binary);
}

async function signAliyunRequest(parameters: Record<string, string>, accessKeySecret: string) {
  const queryString = Object.entries(parameters)
    .sort(([left], [right]) => left.localeCompare(right))
    .map(([key, value]) => `${aliyunPercentEncode(key)}=${aliyunPercentEncode(value)}`)
    .join('&');

  const stringToSign = `GET&${aliyunPercentEncode('/')}&${aliyunPercentEncode(queryString)}`;
  const key = await crypto.subtle.importKey(
    'raw',
    new TextEncoder().encode(`${accessKeySecret}&`),
    { name: 'HMAC', hash: 'SHA-1' },
    false,
    ['sign']
  );
  const signature = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(stringToSign));
  return base64Encode(new Uint8Array(signature));
}

function getAliyunSmsVerificationConfig(purpose: VerificationPurpose) {
  const signName =
    readEnv('ALIYUN_SMS_VERIFY_SIGN_NAME') ||
    readEnv('ALIYUN_SMS_SIGN_NAME');

  const bindTemplate =
    readEnv('ALIYUN_SMS_VERIFY_TEMPLATE_BIND') ||
    readEnv('ALIYUN_SMS_VERIFY_TEMPLATE_CODE_BIND') ||
    '100004';
  const unbindTemplate =
    readEnv('ALIYUN_SMS_VERIFY_TEMPLATE_UNBIND') ||
    readEnv('ALIYUN_SMS_VERIFY_TEMPLATE_CODE_UNBIND') ||
    '100002';
  const verifyTemplate =
    readEnv('ALIYUN_SMS_VERIFY_TEMPLATE_VERIFY') ||
    readEnv('ALIYUN_SMS_VERIFY_TEMPLATE_CODE_VERIFY') ||
    '100001';

  const templateCode =
    purpose === 'unbind' ? unbindTemplate : purpose === 'verify' ? verifyTemplate : bindTemplate;

  if (!signName || !templateCode) {
    throw new VerificationProviderError(
      'CONFIGURATION_ERROR',
      '阿里云短信认证未配置，请设置阿里云控制台里实际可用的签名和模板编号',
      500
    );
  }

  return { signName, templateCode };
}

function mapAliyunSendError(code?: string, message?: string) {
  switch (code) {
    case 'biz.FREQUENCY':
      return new VerificationProviderError(
        'TOO_FREQUENT',
        '验证码发送过于频繁，请稍后再试',
        429
      );
    case 'isv.BUSINESS_LIMIT_CONTROL':
      return new VerificationProviderError(
        'TOO_FREQUENT',
        '短信发送次数已达上限，请稍后再试',
        429
      );
    default:
      return new VerificationProviderError(
        'SEND_FAILED',
        message || '短信验证码发送失败，请稍后重试',
        502
      );
  }
}

function mapAliyunVerifyError(code?: string, message?: string) {
  switch (code) {
    case 'isv.ValidateFail':
      return new VerificationProviderError(
        'INVALID_OR_EXPIRED_CODE',
        '验证码错误或已过期',
        400
      );
    case 'biz.FREQUENCY':
      return new VerificationProviderError(
        'TOO_MANY_ATTEMPTS',
        '验证过于频繁，请稍后再试',
        429
      );
    default:
      return new VerificationProviderError(
        'VERIFY_FAILED',
        message || '短信验证码校验失败，请稍后重试',
        502
      );
  }
}

async function callAliyunApi(
  action: 'SendSmsVerifyCode' | 'CheckSmsVerifyCode',
  requestParams: Record<string, string>
) {
  const accessKeyId = readEnv('ALIYUN_ACCESS_KEY_ID');
  const accessKeySecret = readEnv('ALIYUN_ACCESS_KEY_SECRET');
  const endpoint =
    readEnv('ALIYUN_SMS_VERIFY_ENDPOINT') ||
    readEnv('ALIYUN_SMS_ENDPOINT') ||
    'dypnsapi.aliyuncs.com';

  if (!accessKeyId || !accessKeySecret) {
    throw new VerificationProviderError(
      'CONFIGURATION_ERROR',
      '阿里云短信认证未配置，请设置 ALIYUN_ACCESS_KEY_ID 和 ALIYUN_ACCESS_KEY_SECRET',
      500
    );
  }

  const parameters: Record<string, string> = {
    AccessKeyId: accessKeyId,
    Action: action,
    Format: 'JSON',
    RegionId: 'cn-hangzhou',
    SignatureMethod: 'HMAC-SHA1',
    SignatureNonce: crypto.randomUUID(),
    SignatureVersion: '1.0',
    Timestamp: new Date().toISOString().replace(/\.\d{3}Z$/, 'Z'),
    Version: '2017-05-25',
    ...requestParams,
  };

  const signature = await signAliyunRequest(parameters, accessKeySecret);
  const url = new URL(`https://${endpoint}/`);
  for (const [key, value] of Object.entries({ ...parameters, Signature: signature })) {
    url.searchParams.set(key, value);
  }

  const response = await fetch(url.toString(), {
    method: 'GET',
    headers: {
      Accept: 'application/json',
    },
  });

  const result = (await response.json().catch(() => null)) as AliyunApiResult | null;
  const hasBusinessError =
    result?.Success === false || (typeof result?.Code === 'string' && result.Code !== 'OK');

  if (!response.ok || hasBusinessError) {
    return {
      ok: false,
      code: result?.Code,
      message: result?.Message,
      requestId: result?.RequestId,
    };
  }

  return {
    ok: true,
    data: result,
  };
}

export async function sendPhoneVerificationCode(
  phone: string,
  purpose: VerificationPurpose
): Promise<DeliveryReceipt> {
  const { signName, templateCode } = getAliyunSmsVerificationConfig(purpose);
  const response = await callAliyunApi('SendSmsVerifyCode', {
    PhoneNumber: normalizeAliyunMainlandPhone(phone),
    SignName: signName,
    TemplateCode: templateCode,
    TemplateParam: JSON.stringify({ min: '5' }),
    ExpireTime: '300',
  });

  if (!response.ok) {
    throw mapAliyunSendError(response.code, response.message);
  }

  return {
    provider: 'aliyun-sms-verify',
    externalId: response.data?.RequestId,
  };
}

export async function verifyPhoneVerificationCode(phone: string, verificationCode: string) {
  const response = await callAliyunApi('CheckSmsVerifyCode', {
    PhoneNumber: normalizeAliyunMainlandPhone(phone),
    VerifyCode: verificationCode,
  });

  if (!response.ok) {
    throw mapAliyunVerifyError(response.code, response.message);
  }

  return {
    provider: 'aliyun-sms-verify',
    externalId: response.data?.RequestId,
  };
}

async function sendEmailViaResend(
  email: string,
  code: string,
  purpose: VerificationPurpose
): Promise<DeliveryReceipt> {
  const apiKey = readEnv('RESEND_API_KEY');
  const payload = buildEmailPayload(email, code, purpose);

  if (!apiKey || !payload.from) {
    throw new VerificationProviderError(
      'CONFIGURATION_ERROR',
      '邮件发送未配置，请设置 RESEND_API_KEY 和 VERIFICATION_EMAIL_FROM',
      500
    );
  }

  const response = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${apiKey}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      from: payload.from,
      to: [payload.to],
      reply_to: payload.replyTo,
      subject: payload.subject,
      html: payload.html,
      text: payload.text,
    }),
  });

  const result = await response.json().catch(() => null);

  if (!response.ok) {
    const message =
      result?.message || result?.error?.message || '邮件服务返回异常，请稍后重试';
    throw new VerificationProviderError('SEND_FAILED', message, 502);
  }

  return {
    provider: 'resend',
    externalId: result?.id,
  };
}

async function sendSmsViaTwilio(
  phone: string,
  code: string,
  purpose: VerificationPurpose
): Promise<DeliveryReceipt> {
  const accountSid = readEnv('TWILIO_ACCOUNT_SID');
  const authToken = readEnv('TWILIO_AUTH_TOKEN');
  const messagingServiceSid = readEnv('TWILIO_MESSAGING_SERVICE_SID');
  const fromPhone = readEnv('TWILIO_FROM_PHONE');

  if (!accountSid || !authToken || (!messagingServiceSid && !fromPhone)) {
    throw new VerificationProviderError(
      'CONFIGURATION_ERROR',
      '短信发送未配置，请设置 TWILIO_ACCOUNT_SID、TWILIO_AUTH_TOKEN，以及 TWILIO_MESSAGING_SERVICE_SID 或 TWILIO_FROM_PHONE',
      500
    );
  }

  const body = new URLSearchParams({
    To: normalizePhone(phone),
    Body: buildSmsBody(code, purpose),
  });

  if (messagingServiceSid) {
    body.set('MessagingServiceSid', messagingServiceSid);
  } else {
    body.set('From', fromPhone);
  }

  const response = await fetch(
    `https://api.twilio.com/2010-04-01/Accounts/${accountSid}/Messages.json`,
    {
      method: 'POST',
      headers: {
        Authorization: `Basic ${btoa(`${accountSid}:${authToken}`)}`,
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: body.toString(),
    }
  );

  const result = await response.json().catch(() => null);

  if (!response.ok) {
    const message = result?.message || '短信服务返回异常，请稍后重试';
    throw new VerificationProviderError('SEND_FAILED', message, 502);
  }

  return {
    provider: 'twilio',
    externalId: result?.sid,
  };
}

export async function deliverVerificationCode({
  contactType,
  contactValue,
  code,
  purpose = 'bind',
}: DeliveryRequest): Promise<DeliveryReceipt> {
  let receipt: DeliveryReceipt;

  if (contactType === 'email') {
    receipt = await sendEmailViaResend(contactValue, code, purpose);
  } else if (shouldUseAliyunSmsVerification(contactValue)) {
    receipt = await sendPhoneVerificationCode(contactValue, purpose);
  } else {
    receipt = await sendSmsViaTwilio(contactValue, code, purpose);
  }

  console.log(
    `[verification] delivered via ${receipt.provider} to ${maskContact(contactType, contactValue)}`
  );

  return receipt;
}
