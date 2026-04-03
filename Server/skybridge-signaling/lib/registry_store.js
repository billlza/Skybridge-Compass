'use strict';

function safeJsonParse(raw, fallback = null) {
  if (!raw) return fallback;
  try {
    return JSON.parse(raw);
  } catch (_) {
    return fallback;
  }
}

function normalizeSupabaseURL(raw) {
  const value = String(raw || '').trim().replace(/\/+$/, '');
  return value;
}

class RegistryStore {
  constructor(options = {}) {
    this.supabaseUrl = normalizeSupabaseURL(options.supabaseUrl || process.env.SUPABASE_URL);
    this.supabaseAnonKey = String(options.supabaseAnonKey || process.env.SUPABASE_ANON_KEY || '').trim();
    this.supabaseServiceRoleKey = String(options.supabaseServiceRoleKey || process.env.SUPABASE_SERVICE_ROLE_KEY || '').trim();
    this.timeoutMs = Number(options.timeoutMs || process.env.SUPABASE_TIMEOUT_MS || 8_000);
  }

  get canVerifyAccessToken() {
    return Boolean(this.supabaseUrl && this.supabaseAnonKey);
  }

  get canAccessRegistry() {
    return Boolean(this.canVerifyAccessToken && this.supabaseServiceRoleKey);
  }

  get configured() {
    return this.canAccessRegistry;
  }

  async verifyAccessToken(accessToken) {
    if (!this.canVerifyAccessToken) {
      throw new Error('registry_not_configured');
    }
    const response = await this.request({
      path: '/auth/v1/user',
      method: 'GET',
      useServiceRole: false,
      accessToken
    });
    const appMetadata = response.app_metadata && typeof response.app_metadata === 'object' ? response.app_metadata : {};
    const userMetadata = response.user_metadata && typeof response.user_metadata === 'object' ? response.user_metadata : {};
    return {
      id: String(response.id || '').trim(),
      email: typeof response.email === 'string' ? response.email : null,
      appMetadata,
      userMetadata,
      isGuest: Boolean(
        response.is_anonymous
        || userMetadata.is_guest
        || appMetadata.is_guest
        || appMetadata.provider === 'anonymous'
        || userMetadata.role === 'guest'
      )
    };
  }

  async getTenantPolicy(tenantId) {
    if (!this.canAccessRegistry) {
      throw new Error('registry_not_configured');
    }
    let rows;
    try {
      rows = await this.request({
        path: `/rest/v1/tenant_security_policy?tenant_id=eq.${encodeURIComponent(tenantId)}&select=*`,
        method: 'GET',
        useServiceRole: true
      });
    } catch (error) {
      if (String(error.message || '').includes('PGRST205')) {
        return null;
      }
      throw error;
    }
    if (!Array.isArray(rows) || rows.length === 0) {
      return null;
    }
    return rows[0];
  }

  async getRegisteredDevice({ tenantId, userId, deviceId, protocolSigningAlgorithm, protocolPublicKeyFingerprint }) {
    if (!this.canAccessRegistry) {
      throw new Error('registry_not_configured');
    }
    const params = [
      `tenant_id=eq.${encodeURIComponent(tenantId)}`,
      `user_id=eq.${encodeURIComponent(userId)}`,
      `device_id=eq.${encodeURIComponent(deviceId)}`,
      `protocol_signing_algorithm=eq.${encodeURIComponent(protocolSigningAlgorithm)}`,
      `protocol_public_key_fingerprint=eq.${encodeURIComponent(protocolPublicKeyFingerprint)}`,
      'select=*',
      'limit=1'
    ];
    let rows;
    try {
      rows = await this.request({
        path: `/rest/v1/registered_devices?${params.join('&')}`,
        method: 'GET',
        useServiceRole: true
      });
    } catch (error) {
      if (String(error.message || '').includes('PGRST205')) {
        return null;
      }
      throw error;
    }
    if (!Array.isArray(rows) || rows.length === 0) {
      return null;
    }
    return rows[0];
  }

  async enrollFirstDevice(payload) {
    return this.request({
      path: '/rest/v1/rpc/enroll_first_device_v5',
      method: 'POST',
      useServiceRole: true,
      body: payload
    });
  }

  async confirmDeviceEnrollment(payload) {
    return this.request({
      path: '/rest/v1/rpc/confirm_device_enrollment_v5',
      method: 'POST',
      useServiceRole: true,
      body: payload
    });
  }

  async bootstrapRegisterDevice(payload) {
    return this.request({
      path: '/rest/v1/rpc/bootstrap_register_device_v5',
      method: 'POST',
      useServiceRole: true,
      body: payload
    });
  }

  async request({ path, method = 'GET', useServiceRole = true, accessToken = '', body = null }) {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), this.timeoutMs);
    try {
      const headers = {
        Accept: 'application/json'
      };
      if (useServiceRole) {
        headers.apikey = this.supabaseServiceRoleKey;
        headers.Authorization = `Bearer ${this.supabaseServiceRoleKey}`;
      } else {
        headers.apikey = this.supabaseAnonKey;
        headers.Authorization = `Bearer ${String(accessToken || '').trim()}`;
      }
      if (body !== null) {
        headers['Content-Type'] = 'application/json';
      }
      const response = await fetch(`${this.supabaseUrl}${path}`, {
        method,
        headers,
        body: body === null ? undefined : JSON.stringify(body),
        signal: controller.signal
      });
      const text = await response.text();
      if (!response.ok) {
        const parsed = safeJsonParse(text, {});
        const detail = parsed?.message || parsed?.error_description || parsed?.error || text || 'registry_error';
        throw new Error(`registry_http_${response.status}:${detail}`);
      }
      if (!text) return null;
      return safeJsonParse(text, null);
    } finally {
      clearTimeout(timeout);
    }
  }
}

module.exports = {
  RegistryStore
};
