'use strict';

function getIncomingHeader(req, name, options = {}) {
  if (hasDuplicateRawHeader(req, name)) {
    return { error: 'duplicate_session_credentials' };
  }
  const raw = req.headers?.[name.toLowerCase()];
  if (Array.isArray(raw)) {
    return { error: 'duplicate_session_credentials' };
  }
  const value = String(raw || '').trim();
  if (!value) return { value: '' };
  if (options.rejectCommaSeparated && value.includes(',')) {
    return { error: 'duplicate_session_credentials' };
  }
  if (containsControlCharacters(value)) {
    return { error: 'invalid_session_credentials' };
  }
  return { value };
}

function hasDuplicateRawHeader(req, name) {
  const rawHeaders = Array.isArray(req.rawHeaders) ? req.rawHeaders : [];
  let count = 0;
  for (let i = 0; i < rawHeaders.length; i += 2) {
    if (String(rawHeaders[i] || '').toLowerCase() === name.toLowerCase()) {
      count += 1;
      if (count > 1) return true;
    }
  }
  return false;
}

function containsControlCharacters(value) {
  return /[\u0000-\u001F\u007F]/.test(String(value || ''));
}

function validateWebSocketCredentialValue(value, maxLength = 4096) {
  const normalized = String(value || '').trim();
  if (!normalized || normalized.length > maxLength || containsControlCharacters(normalized)) {
    return '';
  }
  return normalized;
}

function allowsLegacyQueryTokenFromEnv(env = process.env) {
  return /^(1|true|yes)$/i.test(
    String(
      env.SKYBRIDGE_SIGNALING_ALLOW_LEGACY_QUERY_TOKEN ||
      env.SIGNALING_ALLOW_LEGACY_QUERY_TOKEN ||
      ''
    ).trim()
  );
}

function extractWebSocketSessionCredentials(req, requestURL, options = {}) {
  const allowLegacyQueryToken = options.allowLegacyQueryToken === true;
  const headerSessionId = getIncomingHeader(req, 'X-SkyBridge-Session-Id', { rejectCommaSeparated: true });
  const headerSessionToken = getIncomingHeader(req, 'X-SkyBridge-Session', { rejectCommaSeparated: true });
  const headerClientVersion = getIncomingHeader(req, 'X-SkyBridge-Client-Version');
  const headerProtocolVersion = getIncomingHeader(req, 'X-SkyBridge-Protocol-Version');
  for (const header of [headerSessionId, headerSessionToken, headerClientVersion, headerProtocolVersion]) {
    if (header.error) return { error: header.error };
  }

  if (hasDuplicateQueryCredential(requestURL, 'shard') || hasDuplicateQueryCredential(requestURL, 'st')) {
    return { error: 'duplicate_session_credentials' };
  }
  const hasQuerySessionId = requestURL.searchParams.has('shard');
  const hasQuerySessionToken = requestURL.searchParams.has('st');
  const querySessionId = validateWebSocketCredentialValue(requestURL.searchParams.get('shard'), 512);
  const querySessionToken = validateWebSocketCredentialValue(requestURL.searchParams.get('st'));
  const queryClientVersion = validateWebSocketCredentialValue(requestURL.searchParams.get('cv'), 64);
  const queryProtocolVersion = validateWebSocketCredentialValue(requestURL.searchParams.get('pv'), 64);
  const hasHeaderSessionId = Boolean(headerSessionId.value);
  const hasHeaderSessionToken = Boolean(headerSessionToken.value);
  const hasHeaderCredentials = hasHeaderSessionId || hasHeaderSessionToken;

  if (hasHeaderCredentials) {
    if (!hasHeaderSessionId || !hasHeaderSessionToken) {
      return { error: 'partial_session_credentials' };
    }
    if (hasQuerySessionToken) {
      return { error: 'conflicting_session_credentials' };
    }
    const sessionId = validateWebSocketCredentialValue(headerSessionId.value, 512);
    const sessionToken = validateWebSocketCredentialValue(headerSessionToken.value);
    if (!sessionId || !sessionToken) {
      return { error: 'invalid_session_credentials' };
    }
    if (hasQuerySessionId && !querySessionId) {
      return { error: 'invalid_session_credentials' };
    }
    if (querySessionId && querySessionId !== sessionId) {
      return { error: 'conflicting_session_credentials' };
    }
    return {
      authTransport: 'header',
      sessionId,
      sessionToken,
      clientVersion: validateWebSocketCredentialValue(headerClientVersion.value, 64) || queryClientVersion || '0.0.0',
      protocolVersion: validateWebSocketCredentialValue(headerProtocolVersion.value, 64) || queryProtocolVersion || '0'
    };
  }

  if (hasQuerySessionId && !querySessionId) {
    return { error: 'invalid_session_credentials' };
  }
  if (hasQuerySessionToken && !querySessionToken) {
    return { error: 'invalid_session_credentials' };
  }
  if (!querySessionId || !querySessionToken) {
    return { error: 'missing_session_token' };
  }
  if (!allowLegacyQueryToken) {
    return { error: 'legacy_query_token_disabled' };
  }
  return {
    authTransport: 'legacy_query',
    sessionId: querySessionId,
    sessionToken: querySessionToken,
    clientVersion: queryClientVersion || '0.0.0',
    protocolVersion: queryProtocolVersion || '0'
  };
}

module.exports = {
  allowsLegacyQueryTokenFromEnv,
  containsControlCharacters,
  extractWebSocketSessionCredentials,
  getIncomingHeader,
  hasDuplicateRawHeader,
  validateWebSocketCredentialValue
};

function hasDuplicateQueryCredential(requestURL, name) {
  return requestURL.searchParams.getAll(name).length > 1;
}
