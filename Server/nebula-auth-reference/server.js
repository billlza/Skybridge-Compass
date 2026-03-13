'use strict';

const http = require('node:http');
const crypto = require('node:crypto');

const port = Number(process.env.PORT || 8788);
const issuer = String(process.env.NEBULA_ISSUER || `http://127.0.0.1:${port}`).replace(/\/+$/, '');
const accessTokenTtlSec = Number(process.env.NEBULA_ACCESS_TOKEN_TTL_SEC || 900);
const refreshTokenTtlSec = Number(process.env.NEBULA_REFRESH_TOKEN_TTL_SEC || 60 * 60 * 24 * 30);
const headlessAuthorizeEnabled = !/^(0|false|no)$/i.test(process.env.NEBULA_ALLOW_DEV_HEADLESS_AUTHORIZE || 'true');

const defaultClients = {
  skybridge_compass_pro: {
    redirectUris: ['skybridge://auth/nebula'],
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

function json(res, statusCode, payload, headers = {}) {
  res.writeHead(statusCode, {
    'content-type': 'application/json; charset=utf-8',
    'cache-control': 'no-store',
    ...headers
  });
  res.end(JSON.stringify(payload));
}

function text(res, statusCode, body, headers = {}) {
  res.writeHead(statusCode, {
    'content-type': 'text/plain; charset=utf-8',
    ...headers
  });
  res.end(body);
}

function html(res, statusCode, body) {
  res.writeHead(statusCode, {
    'content-type': 'text/html; charset=utf-8',
    'cache-control': 'no-store'
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
        } catch (error) {
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

function validateAuthorizeRequest(input) {
  const responseType = String(input.response_type || '');
  const clientId = String(input.client_id || '').trim();
  const redirectUri = String(input.redirect_uri || '').trim();
  const scope = String(input.scope || 'openid profile email').trim();
  const state = String(input.state || '').trim();
  const codeChallenge = String(input.code_challenge || '').trim();
  const codeChallengeMethod = String(input.code_challenge_method || '').trim().toUpperCase();

  if (responseType !== 'code') return { error: 'unsupported_response_type' };
  if (!clientId) return { error: 'invalid_client' };
  if (!redirectUri) return { error: 'invalid_redirect_uri' };
  if (!state) return { error: 'invalid_state' };
  if (!codeChallenge) return { error: 'invalid_code_challenge' };
  if (codeChallengeMethod !== 'S256') return { error: 'invalid_code_challenge_method' };

  const client = publicClients[clientId];
  if (!client) return { error: 'unauthorized_client' };
  if (!Array.isArray(client.redirectUris) || !client.redirectUris.includes(redirectUri)) {
    return { error: 'redirect_uri_mismatch' };
  }

  return {
    clientId,
    redirectUri,
    scope,
    state,
    codeChallenge,
    codeChallengeMethod
  };
}

function issueAuthorizationCode(request, user) {
  const code = randomToken(24);
  authorizationCodes.set(code, {
    clientId: request.clientId,
    redirectUri: request.redirectUri,
    scope: request.scope,
    state: request.state,
    codeChallenge: request.codeChallenge,
    codeChallengeMethod: request.codeChallengeMethod,
    user,
    createdAt: now(),
    expiresAt: now() + 5 * 60 * 1000,
    used: false
  });
  return code;
}

function issueAccessToken(user, clientId, scope) {
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

function issueRefreshToken(user, clientId, scope) {
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
  const accessToken = issueAccessToken(user, clientId, scope);
  const wantsRefresh = String(scope).split(/\s+/).includes('offline_access');
  const refreshToken = wantsRefresh ? issueRefreshToken(user, clientId, scope) : undefined;
  return {
    access_token: accessToken,
    token_type: 'Bearer',
    expires_in: accessTokenTtlSec,
    refresh_token: refreshToken,
    scope
  };
}

function renderAuthorizePage(requestId, request, errorMessage = '') {
  const escaped = (value) => String(value)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');

  return `<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>Nebula Sign In</title>
    <style>
      body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; background:#0f172a; color:#e2e8f0; display:flex; justify-content:center; padding:48px 16px; }
      .card { width:100%; max-width:420px; background:#111827; border:1px solid #1f2937; border-radius:16px; padding:24px; box-shadow:0 20px 60px rgba(0,0,0,0.35); }
      h1 { margin:0 0 8px; font-size:24px; }
      p { color:#94a3b8; }
      label { display:block; margin:16px 0 8px; font-size:14px; }
      input { width:100%; box-sizing:border-box; padding:12px; border-radius:10px; border:1px solid #334155; background:#0b1220; color:#e2e8f0; }
      button { width:100%; margin-top:20px; padding:12px; border-radius:10px; border:none; background:#38bdf8; color:#082f49; font-weight:700; cursor:pointer; }
      .meta { margin-top:18px; font-size:12px; color:#64748b; line-height:1.5; }
      .error { margin-top:12px; color:#fca5a5; }
      code { color:#bae6fd; }
    </style>
  </head>
  <body>
    <div class="card">
      <h1>Nebula Sign In</h1>
      <p>Reference public-client OAuth 2.1 + PKCE login page.</p>
      <form method="post" action="/oauth/authorize">
        <input type="hidden" name="request_id" value="${escaped(requestId)}" />
        <label for="username">Username</label>
        <input id="username" name="username" type="text" value="${escaped(demoUser.username)}" autocomplete="username" />
        <label for="password">Password</label>
        <input id="password" name="password" type="password" value="${escaped(demoUser.password)}" autocomplete="current-password" />
        <button type="submit">Authorize</button>
      </form>
      ${errorMessage ? `<div class="error">${escaped(errorMessage)}</div>` : ''}
      <div class="meta">
        Client: <code>${escaped(request.clientId)}</code><br />
        Redirect URI: <code>${escaped(request.redirectUri)}</code><br />
        Scope: <code>${escaped(request.scope)}</code>
      </div>
    </div>
  </body>
</html>`;
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

setInterval(purgeExpired, 30_000).unref();

const server = http.createServer(async (req, res) => {
  purgeExpired();
  const url = new URL(req.url, issuer);

  if (req.method === 'GET' && url.pathname === '/health') {
    return json(res, 200, {
      service: 'nebula-auth-reference',
      mode: 'public_client_pkce',
      issuer,
      headlessAuthorizeEnabled,
      clients: Object.keys(publicClients)
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
    const username = String(body.form.username || body.json.username || '').trim();
    const password = String(body.form.password || body.json.password || '');
    const authRequest = authorizeRequests.get(requestId);

    if (!authRequest) {
      return html(res, 400, renderAuthorizePage('unknown', {
        clientId: 'unknown',
        redirectUri: 'unknown',
        scope: 'unknown'
      }, 'Authorization request expired. Please restart login.'));
    }

    if (username !== demoUser.username || password !== demoUser.password) {
      return html(res, 401, renderAuthorizePage(requestId, authRequest, 'Invalid username or password.'));
    }

    authorizeRequests.delete(requestId);
    const code = issueAuthorizationCode(authRequest, demoUser);
    const redirectURL = new URL(authRequest.redirectUri);
    redirectURL.searchParams.set('code', code);
    redirectURL.searchParams.set('state', authRequest.state);
    res.writeHead(302, { location: redirectURL.toString(), 'cache-control': 'no-store' });
    return res.end();
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

    const username = String(input.username || '').trim();
    const password = String(input.password || '');
    if (username !== demoUser.username || password !== demoUser.password) {
      return json(res, 401, { error: 'invalid_credentials' });
    }

    const code = issueAuthorizationCode(validated, demoUser);
    const redirectURL = new URL(validated.redirectUri);
    redirectURL.searchParams.set('code', code);
    redirectURL.searchParams.set('state', validated.state);
    return json(res, 200, {
      code,
      state: validated.state,
      redirect_to: redirectURL.toString()
    });
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
      return json(res, 200, tokenPayload(record.user, clientId, record.scope));
    }

    if (grantType === 'refresh_token') {
      const refreshToken = String(input.refresh_token || '').trim();
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

  return json(res, 404, { error: 'not_found' });
});

server.listen(port, () => {
  console.log(`[nebula-auth-reference] issuer=${issuer}`);
  console.log(`[nebula-auth-reference] listening on http://127.0.0.1:${port}`);
  console.log(`[nebula-auth-reference] public clients=${Object.keys(publicClients).join(', ')}`);
  console.log(`[nebula-auth-reference] demo user=${demoUser.username}`);
});
