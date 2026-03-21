'use strict';

const http = require('node:http');
const crypto = require('node:crypto');

const port = Number(process.env.PORT || 8788);
const issuer = String(process.env.NEBULA_ISSUER || `http://127.0.0.1:${port}`).replace(/\/+$/, '');
const accessTokenTtlSec = Number(process.env.NEBULA_ACCESS_TOKEN_TTL_SEC || 900);
const refreshTokenTtlSec = Number(process.env.NEBULA_REFRESH_TOKEN_TTL_SEC || 60 * 60 * 24 * 30);
const headlessAuthorizeEnabled = !/^(0|false|no)$/i.test(process.env.NEBULA_ALLOW_DEV_HEADLESS_AUTHORIZE || 'true');
const supabaseUrl = normalizeBaseURL(process.env.SUPABASE_URL);
const supabaseAnonKey = String(process.env.SUPABASE_ANON_KEY || '').trim();
const supabaseServiceRoleKey = String(process.env.SUPABASE_SERVICE_ROLE_KEY || '').trim();

const defaultClients = {
  skybridge_compass_pro: {
    redirectUris: [
      'skybridge://auth/nebula',
      'http://127.0.0.1/auth/callback',
      'http://localhost/auth/callback'
    ],
    scopes: ['openid', 'profile', 'email', 'offline_access']
  },
  skybridge_compass_ios: {
    redirectUris: ['skybridge://auth/nebula'],
    scopes: ['openid', 'profile', 'email', 'offline_access']
  }
};

const publicClients = (() => {
  const raw = process.env.NEBULA_PUBLIC_CLIENTS_JSON;
  if (!raw) return defaultClients;
  try {
    const parsed = JSON.parse(raw);
    return parsed && typeof parsed === 'object' ? parsed : defaultClients;
  } catch (error) {
    console.warn('[nebula-auth-reference] failed to parse NEBULA_PUBLIC_CLIENTS_JSON, using defaults:', error.message);
    return defaultClients;
  }
})();

const demoUser = {
  id: 'nebula-demo-001',
  username: process.env.NEBULA_DEMO_USERNAME || 'demo',
  password: process.env.NEBULA_DEMO_PASSWORD || 'demo-pass',
  name: process.env.NEBULA_DEMO_DISPLAY_NAME || 'Nebula Demo User',
  email: process.env.NEBULA_DEMO_EMAIL || 'demo@nebula.local'
};

const authorizeRequests = new Map();
const authorizationCodes = new Map();
const accessTokens = new Map();
const refreshTokens = new Map();
let supabase = null;

function normalizeBaseURL(raw) {
  const value = String(raw || '').trim().replace(/\/+$/, '');
  return value || '';
}

function json(res, statusCode, payload, headers = {}) {
  res.writeHead(statusCode, {
    'content-type': 'application/json; charset=utf-8',
    'cache-control': 'no-store',
    ...headers
  });
  res.end(JSON.stringify(payload));
}

function html(res, statusCode, body, headers = {}) {
  res.writeHead(statusCode, {
    'content-type': 'text/html; charset=utf-8',
    'cache-control': 'no-store',
    ...headers
  });
  res.end(body);
}

function randomToken(bytes = 32) {
  return crypto.randomBytes(bytes).toString('base64url');
}

function sha256base64url(input) {
  return crypto.createHash('sha256').update(input).digest('base64url');
}

function now() {
  return Date.now();
}

function parseBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on('data', (chunk) => chunks.push(chunk));
    req.on('end', () => {
      const raw = Buffer.concat(chunks).toString('utf8');
      const contentType = String(req.headers['content-type'] || '').split(';')[0].trim().toLowerCase();

      if (!raw) {
        resolve({ raw: '', form: {}, json: {} });
        return;
      }

      if (contentType === 'application/json') {
        try {
          const parsed = JSON.parse(raw);
          resolve({ raw, form: {}, json: parsed });
        } catch {
          reject(new Error('invalid_json'));
        }
        return;
      }

      const form = Object.fromEntries(new URLSearchParams(raw));
      resolve({ raw, form, json: {} });
    });
    req.on('error', reject);
  });
}

function isLoopbackHost(host) {
  return host === '127.0.0.1' || host === 'localhost';
}

function matchesRegisteredRedirect(registeredUri, redirectUri) {
  if (registeredUri === redirectUri) return true;

  let registered;
  let actual;
  try {
    registered = new URL(registeredUri);
    actual = new URL(redirectUri);
  } catch {
    return false;
  }

  if (
    registered.protocol !== actual.protocol
    || registered.hostname !== actual.hostname
    || registered.pathname !== actual.pathname
  ) {
    return false;
  }

  if (registered.search || registered.hash) return false;
  if (!isLoopbackHost(registered.hostname) || !isLoopbackHost(actual.hostname)) {
    return registered.port === actual.port;
  }

  if (registered.port) {
    return registered.port === actual.port;
  }
  return Boolean(actual.port);
}

function clientAllowsRedirect(client, redirectUri) {
  const redirectUris = Array.isArray(client?.redirectUris) ? client.redirectUris : [];
  return redirectUris.some((registeredUri) => matchesRegisteredRedirect(registeredUri, redirectUri));
}

function validateAuthorizeRequest(input) {
  const responseType = String(input.response_type || '');
  const clientId = String(input.client_id || '').trim();
  const redirectUri = String(input.redirect_uri || '').trim();
  const scope = String(input.scope || 'openid profile email').trim();
  const state = String(input.state || '').trim();
  const codeChallenge = String(input.code_challenge || '').trim();
  const codeChallengeMethod = String(input.code_challenge_method || '').trim().toUpperCase();
  const flow = String(input.flow || 'login').trim().toLowerCase() === 'register' ? 'register' : 'login';

  if (responseType !== 'code') return { error: 'unsupported_response_type' };
  if (!clientId) return { error: 'invalid_client' };
  if (!redirectUri) return { error: 'invalid_redirect_uri' };
  if (!state) return { error: 'invalid_state' };
  if (!codeChallenge) return { error: 'invalid_code_challenge' };
  if (codeChallengeMethod !== 'S256') return { error: 'invalid_code_challenge_method' };

  const client = publicClients[clientId];
  if (!client) return { error: 'unauthorized_client' };
  if (!clientAllowsRedirect(client, redirectUri)) {
    return { error: 'redirect_uri_mismatch' };
  }

  return {
    clientId,
    redirectUri,
    scope,
    state,
    codeChallenge,
    codeChallengeMethod,
    flow
  };
}

function issueAuthorizationCode(request, grant) {
  const code = randomToken(24);
  authorizationCodes.set(code, {
    clientId: request.clientId,
    redirectUri: request.redirectUri,
    scope: request.scope,
    state: request.state,
    codeChallenge: request.codeChallenge,
    codeChallengeMethod: request.codeChallengeMethod,
    grant,
    createdAt: now(),
    expiresAt: now() + 5 * 60 * 1000,
    used: false
  });
  return code;
}

function issueDemoAccessToken(user, clientId, scope) {
  const token = randomToken(32);
  accessTokens.set(token, {
    user,
    clientId,
    scope,
    issuedAt: now(),
    expiresAt: now() + accessTokenTtlSec * 1000
  });
  return token;
}

function issueDemoRefreshToken(user, clientId, scope) {
  const token = randomToken(32);
  refreshTokens.set(token, {
    user,
    clientId,
    scope,
    issuedAt: now(),
    expiresAt: now() + refreshTokenTtlSec * 1000,
    revoked: false
  });
  return token;
}

function tokenPayload(user, clientId, scope) {
  const accessToken = issueDemoAccessToken(user, clientId, scope);
  const wantsRefresh = String(scope).split(/\s+/).includes('offline_access');
  const refreshToken = wantsRefresh ? issueDemoRefreshToken(user, clientId, scope) : undefined;
  return {
    access_token: accessToken,
    token_type: 'Bearer',
    expires_in: accessTokenTtlSec,
    refresh_token: refreshToken,
    scope
  };
}

function purgeExpired() {
  const current = now();
  for (const [key, value] of authorizeRequests) {
    if (value.expiresAt <= current) authorizeRequests.delete(key);
  }
  for (const [key, value] of authorizationCodes) {
    if (value.expiresAt <= current || value.used) authorizationCodes.delete(key);
  }
  for (const [key, value] of accessTokens) {
    if (value.expiresAt <= current) accessTokens.delete(key);
  }
  for (const [key, value] of refreshTokens) {
    if (value.expiresAt <= current || value.revoked) refreshTokens.delete(key);
  }
}

function escapedHtml(value) {
  return String(value)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

function renderAuthorizePage(requestId, request, options = {}) {
  const errorMessage = options.errorMessage || '';
  const flow = request.flow === 'register' ? 'register' : 'login';
  const title = flow === 'register' ? 'Create Nebula Account' : 'Nebula Sign In';
  const subtitle = supabase
    ? (flow === 'register' ? 'Create an account backed by Supabase Auth.' : 'Sign in with the same account used across SkyBridge clients.')
    : 'Reference public-client OAuth 2.1 + PKCE login page.';
  const defaultIdentifier = options.defaultIdentifier || (supabase ? '' : demoUser.email);
  const defaultDisplayName = options.defaultDisplayName || '';

  return `<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>${escapedHtml(title)}</title>
    <style>
      body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; background:#0f172a; color:#e2e8f0; display:flex; justify-content:center; padding:48px 16px; }
      .card { width:100%; max-width:460px; background:#111827; border:1px solid #1f2937; border-radius:16px; padding:24px; box-shadow:0 20px 60px rgba(0,0,0,0.35); }
      h1 { margin:0 0 8px; font-size:24px; }
      p { color:#94a3b8; }
      label { display:block; margin:16px 0 8px; font-size:14px; }
      input { width:100%; box-sizing:border-box; padding:12px; border-radius:10px; border:1px solid #334155; background:#0b1220; color:#e2e8f0; }
      button { width:100%; margin-top:20px; padding:12px; border-radius:10px; border:none; background:#38bdf8; color:#082f49; font-weight:700; cursor:pointer; }
      .secondary { display:block; margin-top:12px; text-align:center; color:#93c5fd; text-decoration:none; }
      .meta { margin-top:18px; font-size:12px; color:#64748b; line-height:1.5; }
      .error { margin-top:12px; color:#fca5a5; }
      code { color:#bae6fd; }
    </style>
  </head>
  <body>
    <div class="card">
      <h1>${escapedHtml(title)}</h1>
      <p>${escapedHtml(subtitle)}</p>
      <form method="post" action="/oauth/authorize">
        <input type="hidden" name="request_id" value="${escapedHtml(requestId)}" />
        <label for="identifier">${flow === 'register' ? 'Email' : 'Email or username'}</label>
        <input id="identifier" name="identifier" type="text" value="${escapedHtml(defaultIdentifier)}" autocomplete="username" />
        <label for="password">Password</label>
        <input id="password" name="password" type="password" value="${supabase ? '' : escapedHtml(demoUser.password)}" autocomplete="${flow === 'register' ? 'new-password' : 'current-password'}" />
        ${flow === 'register' ? `
        <label for="display_name">Display name</label>
        <input id="display_name" name="display_name" type="text" value="${escapedHtml(defaultDisplayName)}" autocomplete="name" />
        ` : ''}
        <button type="submit">${flow === 'register' ? 'Create Account' : 'Authorize'}</button>
      </form>
      ${flow === 'login'
        ? `<a class="secondary" href="/oauth/authorize?response_type=code&client_id=${encodeURIComponent(request.clientId)}&redirect_uri=${encodeURIComponent(request.redirectUri)}&scope=${encodeURIComponent(request.scope)}&state=${encodeURIComponent(request.state)}&code_challenge=${encodeURIComponent(request.codeChallenge)}&code_challenge_method=${encodeURIComponent(request.codeChallengeMethod)}&flow=register">Need an account? Create one</a>`
        : `<a class="secondary" href="/oauth/authorize?response_type=code&client_id=${encodeURIComponent(request.clientId)}&redirect_uri=${encodeURIComponent(request.redirectUri)}&scope=${encodeURIComponent(request.scope)}&state=${encodeURIComponent(request.state)}&code_challenge=${encodeURIComponent(request.codeChallenge)}&code_challenge_method=${encodeURIComponent(request.codeChallengeMethod)}">Already have an account? Sign in</a>`
      }
      ${errorMessage ? `<div class="error">${escapedHtml(errorMessage)}</div>` : ''}
      <div class="meta">
        Client: <code>${escapedHtml(request.clientId)}</code><br />
        Redirect URI: <code>${escapedHtml(request.redirectUri)}</code><br />
        Scope: <code>${escapedHtml(request.scope)}</code><br />
        Backend mode: <code>${supabase ? 'supabase' : 'demo'}</code>
      </div>
    </div>
  </body>
</html>`;
}

function redirectWithError(res, request, error, description) {
  const redirectURL = new URL(request.redirectUri);
  redirectURL.searchParams.set('error', error);
  redirectURL.searchParams.set('state', request.state);
  if (description) {
    redirectURL.searchParams.set('error_description', description);
  }
  res.writeHead(302, { location: redirectURL.toString(), 'cache-control': 'no-store' });
  res.end();
}

function userMetadata(user) {
  return user && typeof user.user_metadata === 'object' && user.user_metadata ? user.user_metadata : {};
}

function appMetadata(user) {
  return user && typeof user.app_metadata === 'object' && user.app_metadata ? user.app_metadata : {};
}

function deriveDisplayName(user) {
  const meta = userMetadata(user);
  return (
    meta.display_name
    || meta.full_name
    || meta.name
    || user?.email
    || user?.phone
    || user?.id
    || 'Nebula User'
  );
}

function deriveUsername(user) {
  const meta = userMetadata(user);
  return meta.username || meta.preferred_username || user?.email || user?.phone || user?.id || 'nebula-user';
}

function deriveAvatar(user) {
  const meta = userMetadata(user);
  return meta.avatar_url || meta.avatar || meta.picture || null;
}

function deriveTenantId(user) {
  const appMeta = appMetadata(user);
  const meta = userMetadata(user);
  return (
    appMeta.tenant_id
    || appMeta.tenantId
    || appMeta.org_id
    || meta.tenant_id
    || meta.tenantId
    || meta.org_id
    || user?.id
    || ''
  );
}

function deriveCompanyName(user) {
  const appMeta = appMetadata(user);
  const meta = userMetadata(user);
  return appMeta.company_name || appMeta.companyName || meta.company_name || meta.companyName || 'Nebula';
}

function normalizePermissions(user) {
  const appMeta = appMetadata(user);
  const meta = userMetadata(user);
  const permissions = appMeta.permissions || meta.permissions;
  return Array.isArray(permissions) ? permissions.map((value) => String(value)) : [];
}

function makeLegacyUserInfo(user) {
  return {
    userId: String(user?.id || '').trim(),
    username: deriveUsername(user),
    email: typeof user?.email === 'string' ? user.email : '',
    displayName: deriveDisplayName(user),
    avatar: deriveAvatar(user),
    companyId: deriveTenantId(user),
    companyName: deriveCompanyName(user),
    department: userMetadata(user).department || null,
    role: userMetadata(user).role || appMetadata(user).role || 'user',
    permissions: normalizePermissions(user),
    lastLoginAt: typeof user?.last_sign_in_at === 'string' ? user.last_sign_in_at : null
  };
}

function makeLegacyAuthResponse(authResult) {
  return {
    success: true,
    message: null,
    userInfo: makeLegacyUserInfo(authResult.user),
    accessToken: authResult.session.access_token,
    refreshToken: authResult.session.refresh_token || null,
    expiresIn: authResult.session.expires_in || null,
    mfaRequired: false,
    mfaToken: null
  };
}

function makeRegistrationResponse(authResult, message = 'Account created.') {
  return {
    success: true,
    userId: authResult.user?.id || null,
    username: deriveUsername(authResult.user),
    email: authResult.user?.email || null,
    displayName: deriveDisplayName(authResult.user),
    message,
    requiresEmailVerification: !authResult.session.access_token,
    requiresAdminApproval: false
  };
}

function normalizeEmailIdentifier(value) {
  return String(value || '').trim();
}

function normalizePhoneNumber(value) {
  const trimmed = String(value || '').trim();
  const digits = trimmed.replace(/[^\d+]/g, '');
  if (digits.startsWith('+')) return digits;
  if (/^1[3-9]\d{9}$/.test(digits)) return `+86${digits}`;
  if (/^861[3-9]\d{9}$/.test(digits)) return `+${digits}`;
  return digits;
}

class SupabaseAuthClient {
  constructor({ baseUrl, anonKey, serviceRoleKey }) {
    this.baseUrl = baseUrl;
    this.anonKey = anonKey;
    this.serviceRoleKey = serviceRoleKey;
  }

  async request(path, { method = 'GET', accessToken = '', body = null, useServiceRole = false } = {}) {
    const headers = {
      Accept: 'application/json',
      apikey: useServiceRole ? this.serviceRoleKey : this.anonKey,
      Authorization: `Bearer ${useServiceRole ? this.serviceRoleKey : (accessToken || this.anonKey)}`
    };
    if (body !== null) {
      headers['Content-Type'] = 'application/json';
    }

    const response = await fetch(`${this.baseUrl}${path}`, {
      method,
      headers,
      body: body === null ? undefined : JSON.stringify(body)
    });
    const text = await response.text();
    const parsed = safeJsonParse(text, null);
    if (!response.ok) {
      const detail = parsed?.msg || parsed?.message || parsed?.error_description || parsed?.error || text || 'supabase_request_failed';
      const error = new Error(String(detail));
      error.statusCode = response.status;
      error.body = parsed;
      throw error;
    }
    return parsed || {};
  }

  async signInWithPassword(identifier, password) {
    return this.request('/auth/v1/token?grant_type=password', {
      method: 'POST',
      body: {
        email: normalizeEmailIdentifier(identifier),
        password: String(password || '')
      }
    });
  }

  async signUp({ email, password, displayName, username }) {
    const data = {};
    if (displayName) data.display_name = displayName;
    if (username) data.username = username;
    return this.request('/auth/v1/signup', {
      method: 'POST',
      body: {
        email: normalizeEmailIdentifier(email),
        password: String(password || ''),
        data
      }
    });
  }

  async refreshToken(refreshToken) {
    return this.request('/auth/v1/token?grant_type=refresh_token', {
      method: 'POST',
      body: {
        refresh_token: String(refreshToken || '')
      }
    });
  }

  async getUser(accessToken) {
    return this.request('/auth/v1/user', {
      method: 'GET',
      accessToken
    });
  }

  async sendPhoneOtp(phoneNumber, createUser = false, data = null) {
    const payload = {
      phone: normalizePhoneNumber(phoneNumber),
      type: 'sms',
      create_user: Boolean(createUser)
    };
    if (data && typeof data === 'object' && Object.keys(data).length > 0) {
      payload.data = data;
    }
    return this.request('/auth/v1/otp', {
      method: 'POST',
      body: payload
    });
  }

  async verifyPhoneOtp(phoneNumber, code) {
    return this.request('/auth/v1/verify', {
      method: 'POST',
      body: {
        phone: normalizePhoneNumber(phoneNumber),
        token: String(code || '').trim(),
        type: 'sms'
      }
    });
  }

  async exchangeApple(identityToken, nonce = null) {
    const payload = {
      provider: 'apple',
      id_token: identityToken
    };
    if (nonce) payload.nonce = nonce;
    return this.request('/auth/v1/token?grant_type=id_token', {
      method: 'POST',
      body: payload
    });
  }

  async sendPasswordReset(email) {
    return this.request('/auth/v1/recover', {
      method: 'POST',
      body: {
        email: normalizeEmailIdentifier(email)
      }
    });
  }

  async checkUsername(username) {
    if (!this.serviceRoleKey) {
      return { available: true, message: 'service_role_not_configured' };
    }
    const response = await this.request(
      `/rest/v1/profiles?username=eq.${encodeURIComponent(String(username || '').trim())}&select=id&limit=1`,
      {
        method: 'GET',
        useServiceRole: true
      }
    );
    return {
      available: !Array.isArray(response) || response.length === 0,
      message: null
    };
  }
}

supabase = supabaseUrl && supabaseAnonKey
  ? new SupabaseAuthClient({
    baseUrl: supabaseUrl,
    anonKey: supabaseAnonKey,
    serviceRoleKey: supabaseServiceRoleKey
  })
  : null;

function safeJsonParse(raw, fallback = null) {
  if (!raw) return fallback;
  try {
    return JSON.parse(raw);
  } catch {
    return fallback;
  }
}

async function performSupabaseLogin(identifier, password) {
  if (!supabase) throw new Error('supabase_not_configured');
  const session = await supabase.signInWithPassword(identifier, password);
  const user = session.user && typeof session.user === 'object'
    ? session.user
    : await supabase.getUser(session.access_token);
  return { session, user };
}

async function performSupabaseRegistration(identifier, password, displayName) {
  if (!supabase) throw new Error('supabase_not_configured');
  const email = normalizeEmailIdentifier(identifier);
  const session = await supabase.signUp({
    email,
    password,
    displayName,
    username: email.includes('@') ? email.split('@')[0] : email
  });
  const user = session.user && typeof session.user === 'object'
    ? session.user
    : (session.access_token ? await supabase.getUser(session.access_token) : { email });
  return { session, user };
}

function grantFromAuthResult(authResult) {
  return {
    kind: 'supabase',
    session: {
      access_token: authResult.session.access_token,
      token_type: authResult.session.token_type || 'Bearer',
      expires_in: authResult.session.expires_in || null,
      refresh_token: authResult.session.refresh_token || null,
      scope: authResult.session.scope || 'openid profile email offline_access'
    }
  };
}

setInterval(purgeExpired, 30_000).unref();

const server = http.createServer(async (req, res) => {
  purgeExpired();
  const url = new URL(req.url, issuer);

  if (req.method === 'GET' && url.pathname === '/health') {
    return json(res, 200, {
      service: 'nebula-auth-reference',
      mode: supabase ? 'supabase_gateway' : 'demo',
      issuer,
      headlessAuthorizeEnabled,
      clients: Object.keys(publicClients),
      supabaseConfigured: Boolean(supabase)
    });
  }

  if (req.method === 'GET' && url.pathname === '/.well-known/openid-configuration') {
    return json(res, 200, {
      issuer,
      authorization_endpoint: `${issuer}/oauth/authorize`,
      token_endpoint: `${issuer}/oauth/token`,
      userinfo_endpoint: `${issuer}/oauth/userinfo`,
      revocation_endpoint: `${issuer}/oauth/revoke`,
      response_types_supported: ['code'],
      grant_types_supported: ['authorization_code', 'refresh_token'],
      token_endpoint_auth_methods_supported: ['none'],
      code_challenge_methods_supported: ['S256'],
      scopes_supported: ['openid', 'profile', 'email', 'offline_access']
    });
  }

  if (req.method === 'GET' && url.pathname === '/oauth/authorize') {
    const validated = validateAuthorizeRequest(Object.fromEntries(url.searchParams));
    if (validated.error) {
      return json(res, 400, { error: validated.error });
    }
    const requestId = randomToken(16);
    authorizeRequests.set(requestId, {
      ...validated,
      createdAt: now(),
      expiresAt: now() + 10 * 60 * 1000
    });
    return html(res, 200, renderAuthorizePage(requestId, validated));
  }

  if (req.method === 'POST' && url.pathname === '/oauth/authorize') {
    let body;
    try {
      body = await parseBody(req);
    } catch {
      return json(res, 400, { error: 'invalid_request' });
    }

    const requestId = String(body.form.request_id || body.json.request_id || '').trim();
    const identifier = String(body.form.identifier || body.json.identifier || body.form.username || body.json.username || '').trim();
    const password = String(body.form.password || body.json.password || '');
    const displayName = String(body.form.display_name || body.json.display_name || '').trim();
    const authRequest = authorizeRequests.get(requestId);

    if (!authRequest) {
      return html(res, 400, renderAuthorizePage('unknown', {
        clientId: 'unknown',
        redirectUri: 'unknown',
        scope: 'unknown',
        state: '',
        codeChallenge: '',
        codeChallengeMethod: 'S256',
        flow: 'login'
      }, { errorMessage: 'Authorization request expired. Please restart login.' }));
    }

    try {
      let grant;
      if (supabase) {
        const authResult = authRequest.flow === 'register'
          ? await performSupabaseRegistration(identifier, password, displayName)
          : await performSupabaseLogin(identifier, password);

        if (!authResult.session.access_token) {
          authorizeRequests.delete(requestId);
          return redirectWithError(
            res,
            authRequest,
            'email_verification_required',
            'Account created. Complete email verification, then sign in again.'
          );
        }
        grant = grantFromAuthResult(authResult);
      } else {
        const demoIdentifier = identifier || demoUser.username;
        if (
          (demoIdentifier !== demoUser.username && demoIdentifier !== demoUser.email)
          || password !== demoUser.password
        ) {
          return html(res, 401, renderAuthorizePage(requestId, authRequest, {
            errorMessage: 'Invalid username or password.',
            defaultIdentifier: identifier,
            defaultDisplayName: displayName
          }));
        }
        grant = {
          kind: 'demo',
          user: demoUser
        };
      }

      authorizeRequests.delete(requestId);
      const code = issueAuthorizationCode(authRequest, grant);
      const redirectURL = new URL(authRequest.redirectUri);
      redirectURL.searchParams.set('code', code);
      redirectURL.searchParams.set('state', authRequest.state);
      res.writeHead(302, { location: redirectURL.toString(), 'cache-control': 'no-store' });
      return res.end();
    } catch (error) {
      return html(res, 401, renderAuthorizePage(requestId, authRequest, {
        errorMessage: error.message || 'Authentication failed.',
        defaultIdentifier: identifier,
        defaultDisplayName: displayName
      }));
    }
  }

  if (req.method === 'POST' && url.pathname === '/dev/authorize') {
    if (!headlessAuthorizeEnabled) {
      return json(res, 404, { error: 'not_found' });
    }

    let body;
    try {
      body = await parseBody(req);
    } catch {
      return json(res, 400, { error: 'invalid_request' });
    }

    const input = Object.keys(body.json).length ? body.json : body.form;
    const validated = validateAuthorizeRequest(input);
    if (validated.error) {
      return json(res, 400, { error: validated.error });
    }

    try {
      let grant;
      if (supabase) {
        const authResult = validated.flow === 'register'
          ? await performSupabaseRegistration(input.username || input.email, input.password, input.display_name)
          : await performSupabaseLogin(input.username || input.email, input.password);
        if (!authResult.session.access_token) {
          return json(res, 400, {
            error: 'email_verification_required',
            error_description: 'Account created. Complete email verification, then sign in again.'
          });
        }
        grant = grantFromAuthResult(authResult);
      } else {
        const username = String(input.username || '').trim();
        const password = String(input.password || '');
        if (
          (username !== demoUser.username && username !== demoUser.email)
          || password !== demoUser.password
        ) {
          return json(res, 401, { error: 'invalid_credentials' });
        }
        grant = { kind: 'demo', user: demoUser };
      }

      const code = issueAuthorizationCode(validated, grant);
      const redirectURL = new URL(validated.redirectUri);
      redirectURL.searchParams.set('code', code);
      redirectURL.searchParams.set('state', validated.state);
      return json(res, 200, {
        code,
        state: validated.state,
        redirect_to: redirectURL.toString()
      });
    } catch (error) {
      return json(res, 401, {
        error: 'invalid_credentials',
        error_description: error.message || 'Authentication failed.'
      });
    }
  }

  if (req.method === 'POST' && url.pathname === '/oauth/token') {
    let body;
    try {
      body = await parseBody(req);
    } catch {
      return json(res, 400, { error: 'invalid_request' });
    }

    const input = Object.keys(body.json).length ? body.json : body.form;
    const grantType = String(input.grant_type || '').trim();
    const clientId = String(input.client_id || '').trim();

    if (!publicClients[clientId]) {
      return json(res, 401, { error: 'unauthorized_client' });
    }

    if (grantType === 'authorization_code') {
      const code = String(input.code || '').trim();
      const redirectUri = String(input.redirect_uri || '').trim();
      const codeVerifier = String(input.code_verifier || '').trim();
      const record = authorizationCodes.get(code);

      if (!record || record.used || record.expiresAt <= now()) {
        return json(res, 400, { error: 'invalid_grant' });
      }
      if (record.clientId !== clientId || record.redirectUri !== redirectUri) {
        return json(res, 400, { error: 'invalid_grant' });
      }
      if (!codeVerifier || sha256base64url(codeVerifier) !== record.codeChallenge) {
        return json(res, 400, { error: 'invalid_code_verifier' });
      }

      record.used = true;
      authorizationCodes.set(code, record);

      if (record.grant.kind === 'supabase') {
        return json(res, 200, record.grant.session);
      }
      return json(res, 200, tokenPayload(record.grant.user, clientId, record.scope));
    }

    if (grantType === 'refresh_token') {
      const refreshToken = String(input.refresh_token || '').trim();
      if (supabase) {
        try {
          const refreshed = await supabase.refreshToken(refreshToken);
          return json(res, 200, {
            access_token: refreshed.access_token,
            token_type: refreshed.token_type || 'Bearer',
            expires_in: refreshed.expires_in || null,
            refresh_token: refreshed.refresh_token || null,
            scope: refreshed.scope || 'openid profile email offline_access'
          });
        } catch (error) {
          return json(res, 400, { error: 'invalid_grant', error_description: error.message || 'Refresh failed.' });
        }
      }

      const record = refreshTokens.get(refreshToken);
      if (!record || record.revoked || record.expiresAt <= now() || record.clientId !== clientId) {
        return json(res, 400, { error: 'invalid_grant' });
      }
      record.revoked = true;
      refreshTokens.set(refreshToken, record);
      return json(res, 200, tokenPayload(record.user, clientId, record.scope));
    }

    return json(res, 400, { error: 'unsupported_grant_type' });
  }

  if (req.method === 'GET' && url.pathname === '/oauth/userinfo') {
    const authHeader = String(req.headers.authorization || '');
    const token = authHeader.startsWith('Bearer ') ? authHeader.slice('Bearer '.length).trim() : '';

    if (supabase) {
      try {
        const user = await supabase.getUser(token);
        return json(res, 200, {
          sub: user.id,
          preferred_username: deriveUsername(user),
          name: deriveDisplayName(user),
          email: user.email || null,
          picture: deriveAvatar(user)
        });
      } catch (error) {
        return json(res, 401, { error: 'invalid_token', error_description: error.message || 'Invalid token.' });
      }
    }

    const record = accessTokens.get(token);
    if (!record || record.expiresAt <= now()) {
      return json(res, 401, { error: 'invalid_token' });
    }

    return json(res, 200, {
      sub: record.user.id,
      preferred_username: record.user.username,
      name: record.user.name,
      email: record.user.email
    });
  }

  if (req.method === 'POST' && url.pathname === '/oauth/revoke') {
    let body;
    try {
      body = await parseBody(req);
    } catch {
      return json(res, 400, { error: 'invalid_request' });
    }

    const input = Object.keys(body.json).length ? body.json : body.form;
    const token = String(input.token || '').trim();
    if (accessTokens.has(token)) {
      accessTokens.delete(token);
    }
    if (refreshTokens.has(token)) {
      const record = refreshTokens.get(token);
      if (record) {
        record.revoked = true;
        refreshTokens.set(token, record);
      }
    }
    return json(res, 200, { revoked: true });
  }

  if (req.method === 'POST' && (url.pathname === '/auth/login' || url.pathname === '/auth/nebula/login')) {
    let body;
    try {
      body = await parseBody(req);
    } catch {
      return json(res, 400, { success: false, message: 'invalid_request' });
    }
    const input = Object.keys(body.json).length ? body.json : body.form;
    try {
      const authResult = supabase
        ? await performSupabaseLogin(input.username || input.email, input.password)
        : { session: tokenPayload(demoUser, 'skybridge_compass_pro', 'profile email company'), user: demoUser };
      return json(res, 200, makeLegacyAuthResponse(authResult));
    } catch (error) {
      return json(res, 401, { success: false, message: error.message || 'authentication_failed' });
    }
  }

  if (req.method === 'POST' && url.pathname === '/auth/refresh') {
    let body;
    try {
      body = await parseBody(req);
    } catch {
      return json(res, 400, { success: false, message: 'invalid_request' });
    }
    const input = Object.keys(body.json).length ? body.json : body.form;
    try {
      if (supabase) {
        const session = await supabase.refreshToken(input.refreshToken || input.refresh_token);
        const user = await supabase.getUser(session.access_token);
        return json(res, 200, makeLegacyAuthResponse({ session, user }));
      }

      const refreshToken = String(input.refreshToken || input.refresh_token || '').trim();
      const record = refreshTokens.get(refreshToken);
      if (!record || record.revoked || record.expiresAt <= now()) {
        return json(res, 401, { success: false, message: 'refresh_token_invalid' });
      }
      record.revoked = true;
      refreshTokens.set(refreshToken, record);
      const session = tokenPayload(record.user, String(input.clientId || 'skybridge_compass_pro'), record.scope);
      return json(res, 200, makeLegacyAuthResponse({ session, user: record.user }));
    } catch (error) {
      return json(res, 401, { success: false, message: error.message || 'refresh_token_invalid' });
    }
  }

  if (req.method === 'POST' && url.pathname === '/auth/register') {
    let body;
    try {
      body = await parseBody(req);
    } catch {
      return json(res, 400, { success: false, message: 'invalid_request' });
    }
    const input = Object.keys(body.json).length ? body.json : body.form;
    try {
      if (!supabase) {
        return json(res, 201, {
          success: true,
          userId: demoUser.id,
          username: demoUser.username,
          email: demoUser.email,
          displayName: demoUser.name,
          message: 'Demo account ready.',
          requiresEmailVerification: false,
          requiresAdminApproval: false
        });
      }

      const authResult = await performSupabaseRegistration(
        input.email || input.username,
        input.password,
        input.displayName || input.display_name
      );
      return json(res, 201, makeRegistrationResponse(authResult, 'Account created.'));
    } catch (error) {
      return json(res, 400, { success: false, message: error.message || 'registration_failed' });
    }
  }

  if (req.method === 'POST' && url.pathname === '/auth/phone/send-code') {
    let body;
    try {
      body = await parseBody(req);
    } catch {
      return json(res, 400, { success: false, message: 'invalid_request' });
    }
    if (!supabase) {
      return json(res, 200, { success: true, message: 'Demo mode does not send real SMS.' });
    }
    const input = Object.keys(body.json).length ? body.json : body.form;
    try {
      await supabase.sendPhoneOtp(input.phoneNumber || input.phone, Boolean(input.createUser || input.create_user));
      return json(res, 200, { success: true, message: 'Verification code sent.' });
    } catch (error) {
      return json(res, 400, { success: false, message: error.message || 'send_code_failed' });
    }
  }

  if (req.method === 'POST' && url.pathname === '/auth/phone/login') {
    let body;
    try {
      body = await parseBody(req);
    } catch {
      return json(res, 400, { success: false, message: 'invalid_request' });
    }
    if (!supabase) {
      return json(res, 501, { success: false, message: 'phone_login_requires_supabase' });
    }
    const input = Object.keys(body.json).length ? body.json : body.form;
    try {
      const session = await supabase.verifyPhoneOtp(input.number || input.phoneNumber || input.phone, input.code || input.token);
      const user = await supabase.getUser(session.access_token);
      return json(res, 200, makeLegacyAuthResponse({ session, user }));
    } catch (error) {
      return json(res, 401, { success: false, message: error.message || 'phone_login_failed' });
    }
  }

  if (req.method === 'POST' && url.pathname === '/auth/email/login') {
    let body;
    try {
      body = await parseBody(req);
    } catch {
      return json(res, 400, { success: false, message: 'invalid_request' });
    }
    const input = Object.keys(body.json).length ? body.json : body.form;
    try {
      const authResult = supabase
        ? await performSupabaseLogin(input.email || input.username, input.password)
        : { session: tokenPayload(demoUser, 'skybridge_compass_pro', 'profile email company'), user: demoUser };
      return json(res, 200, makeLegacyAuthResponse(authResult));
    } catch (error) {
      return json(res, 401, { success: false, message: error.message || 'email_login_failed' });
    }
  }

  if (req.method === 'POST' && url.pathname === '/auth/apple/exchange') {
    let body;
    try {
      body = await parseBody(req);
    } catch {
      return json(res, 400, { success: false, message: 'invalid_request' });
    }
    if (!supabase) {
      return json(res, 501, { success: false, message: 'apple_exchange_requires_supabase' });
    }
    const input = Object.keys(body.json).length ? body.json : body.form;
    try {
      const rawToken = String(input.identityToken || input.id_token || '').trim();
      const decodedToken = Buffer.from(rawToken, 'base64').toString('utf8');
      const session = await supabase.exchangeApple(decodedToken, input.nonce || null);
      const user = await supabase.getUser(session.access_token);
      return json(res, 200, makeLegacyAuthResponse({ session, user }));
    } catch (error) {
      return json(res, 401, { success: false, message: error.message || 'apple_exchange_failed' });
    }
  }

  if (req.method === 'POST' && url.pathname === '/auth/check-username') {
    let body;
    try {
      body = await parseBody(req);
    } catch {
      return json(res, 400, { available: false, message: 'invalid_request' });
    }
    const input = Object.keys(body.json).length ? body.json : body.form;
    if (!supabase) {
      return json(res, 200, { available: String(input.username || '').trim() !== demoUser.username, message: null });
    }
    try {
      const result = await supabase.checkUsername(input.username);
      return json(res, 200, result);
    } catch (error) {
      return json(res, 400, { available: false, message: error.message || 'username_check_failed' });
    }
  }

  if (req.method === 'POST' && url.pathname === '/auth/email/reset-password') {
    let body;
    try {
      body = await parseBody(req);
    } catch {
      return json(res, 400, { success: false, message: 'invalid_request' });
    }
    if (!supabase) {
      return json(res, 200, { success: true, message: 'Demo mode does not send real email.' });
    }
    const input = Object.keys(body.json).length ? body.json : body.form;
    try {
      await supabase.sendPasswordReset(input.email);
      return json(res, 200, { success: true, message: 'Password reset email sent.' });
    } catch (error) {
      return json(res, 400, { success: false, message: error.message || 'reset_password_failed' });
    }
  }

  return json(res, 404, { error: 'not_found' });
});

server.listen(port, () => {
  console.log(`[nebula-auth-reference] issuer=${issuer}`);
  console.log(`[nebula-auth-reference] listening on http://127.0.0.1:${port}`);
  console.log(`[nebula-auth-reference] public clients=${Object.keys(publicClients).join(', ')}`);
  console.log(`[nebula-auth-reference] mode=${supabase ? 'supabase_gateway' : 'demo'}`);
});
