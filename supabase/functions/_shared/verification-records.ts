import type { ContactType, VerificationPurpose } from './verification-delivery.ts';

export interface VerificationRecord {
  id: string;
  user_id: string;
  contact_type: ContactType;
  contact_value: string;
  code: string;
  purpose?: VerificationPurpose;
  expires_at: string;
  is_used?: boolean;
  attempts?: number;
  created_at?: string;
}

interface VerificationQuery {
  supabaseUrl: string;
  supabaseServiceKey: string;
  userId: string;
  contactType: ContactType;
  contactValue: string;
  purpose?: VerificationPurpose;
}

interface CreateVerificationInput extends VerificationQuery {
  code: string;
  expiresAt: string;
  ipAddress?: string;
}

function adminHeaders(serviceKey: string, prefer?: string) {
  const headers: Record<string, string> = {
    Authorization: `Bearer ${serviceKey}`,
    apikey: serviceKey,
    'Content-Type': 'application/json',
  };

  if (prefer) {
    headers.Prefer = prefer;
  }

  return headers;
}

function buildPendingVerificationQuery({
  userId,
  contactType,
  contactValue,
  purpose,
}: VerificationQuery) {
  const query = new URLSearchParams({
    user_id: `eq.${userId}`,
    contact_type: `eq.${contactType}`,
    contact_value: `eq.${contactValue}`,
    is_used: 'eq.false',
    expires_at: `gte.${new Date().toISOString()}`,
    order: 'created_at.desc',
    limit: '1',
    select:
      'id,user_id,contact_type,contact_value,code,purpose,expires_at,is_used,attempts,created_at',
  });

  if (purpose) {
    query.set('purpose', `eq.${purpose}`);
  }

  return query.toString();
}

export async function hasRecentVerification({
  supabaseUrl,
  supabaseServiceKey,
  userId,
  contactType,
  contactValue,
}: VerificationQuery) {
  const query = new URLSearchParams({
    user_id: `eq.${userId}`,
    contact_type: `eq.${contactType}`,
    contact_value: `eq.${contactValue}`,
    created_at: `gte.${new Date(Date.now() - 60_000).toISOString()}`,
    select: 'id',
  });

  const response = await fetch(`${supabaseUrl}/rest/v1/verification_codes?${query.toString()}`, {
    method: 'GET',
    headers: adminHeaders(supabaseServiceKey),
  });

  if (!response.ok) {
    throw new Error(`查询近期验证码失败: ${await response.text()}`);
  }

  const recentCodes = await response.json();
  return Array.isArray(recentCodes) && recentCodes.length > 0;
}

export async function createVerificationRecord({
  supabaseUrl,
  supabaseServiceKey,
  userId,
  contactType,
  contactValue,
  purpose,
  code,
  expiresAt,
  ipAddress,
}: CreateVerificationInput): Promise<VerificationRecord> {
  const response = await fetch(`${supabaseUrl}/rest/v1/verification_codes`, {
    method: 'POST',
    headers: adminHeaders(supabaseServiceKey, 'return=representation'),
    body: JSON.stringify({
      user_id: userId,
      contact_type: contactType,
      contact_value: contactValue,
      code,
      purpose,
      expires_at: expiresAt,
      ip_address: ipAddress,
    }),
  });

  if (!response.ok) {
    throw new Error(`保存验证码失败: ${await response.text()}`);
  }

  const rows = await response.json();
  if (!Array.isArray(rows) || !rows[0]?.id) {
    throw new Error('保存验证码失败: 未返回验证码记录');
  }

  return rows[0] as VerificationRecord;
}

export async function deleteVerificationRecordById(
  supabaseUrl: string,
  supabaseServiceKey: string,
  verificationId: string
) {
  const response = await fetch(
    `${supabaseUrl}/rest/v1/verification_codes?id=eq.${verificationId}`,
    {
      method: 'DELETE',
      headers: adminHeaders(supabaseServiceKey),
    }
  );

  if (!response.ok) {
    throw new Error(`删除验证码记录失败: ${await response.text()}`);
  }
}

export async function fetchLatestPendingVerification(
  params: VerificationQuery
): Promise<VerificationRecord | null> {
  const response = await fetch(
    `${params.supabaseUrl}/rest/v1/verification_codes?${buildPendingVerificationQuery(params)}`,
    {
      method: 'GET',
      headers: adminHeaders(params.supabaseServiceKey),
    }
  );

  if (!response.ok) {
    throw new Error(`查询验证码失败: ${await response.text()}`);
  }

  const rows = await response.json();
  if (!Array.isArray(rows) || rows.length === 0) {
    return null;
  }

  return rows[0] as VerificationRecord;
}

export async function patchVerificationRecord(
  supabaseUrl: string,
  supabaseServiceKey: string,
  verificationId: string,
  patch: Record<string, unknown>
) {
  const response = await fetch(
    `${supabaseUrl}/rest/v1/verification_codes?id=eq.${verificationId}`,
    {
      method: 'PATCH',
      headers: adminHeaders(supabaseServiceKey),
      body: JSON.stringify(patch),
    }
  );

  if (!response.ok) {
    throw new Error(`更新验证码记录失败: ${await response.text()}`);
  }
}
