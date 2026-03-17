'use strict';

const crypto = require('crypto');

function normalizeClientIP(raw) {
  const value = String(raw || '').split(',')[0].trim().replace(/^\[|\]$/g, '');
  if (!value) return '';
  if (value.startsWith('::ffff:')) {
    return value.slice(7);
  }
  return value;
}

function clientIPForRequest(req, { trustProxy = false } = {}) {
  if (trustProxy) {
    const cfConnectingIP = normalizeClientIP(req.get('CF-Connecting-IP'));
    if (cfConnectingIP) return cfConnectingIP;
    const forwardedFor = normalizeClientIP(req.get('X-Forwarded-For'));
    if (forwardedFor) return forwardedFor;
  }
  return normalizeClientIP(req.ip || req.connection?.remoteAddress || '');
}

function clampSessionTtlMs(rawSeconds, fallbackMs) {
  const seconds = Number(rawSeconds);
  if (!Number.isFinite(seconds)) return fallbackMs;
  return Math.max(60_000, Math.min(24 * 3600_000, Math.trunc(seconds * 1000)));
}

function stableCanonicalJSON(value) {
  if (value === null || typeof value !== 'object') {
    return JSON.stringify(value);
  }
  if (Array.isArray(value)) {
    return `[${value.map((item) => stableCanonicalJSON(item)).join(',')}]`;
  }
  const keys = Object.keys(value).sort();
  const parts = keys.map((key) => `${JSON.stringify(key)}:${stableCanonicalJSON(value[key])}`);
  return `{${parts.join(',')}}`;
}

function businessPayloadForIdempotency({ action, body, backendName, fallbackTtlMs }) {
  switch (action) {
    case 'register-session': {
      const requestedSessionId = String(body?.sessionId || '').trim();
      return {
        sessionId: backendName === 'redis' && requestedSessionId ? requestedSessionId : null,
        ttlSeconds: Math.round(clampSessionTtlMs(body?.ttlSeconds, fallbackTtlMs) / 1000)
      };
    }
    case 'redeem-session':
      return {
        sessionId: String(body?.sessionId || '').trim(),
        qrBootstrapToken: String(body?.qrBootstrapToken || '').trim()
      };
    default:
      return {};
  }
}

function buildIdempotencyFingerprint({ action, body, admissionToken, backendName, fallbackTtlMs }) {
  const hashedAdmissionToken = crypto.createHash('sha256')
    .update(Buffer.from(String(admissionToken || ''), 'utf8'))
    .digest();
  const canonicalBody = stableCanonicalJSON(
    businessPayloadForIdempotency({ action, body, backendName, fallbackTtlMs })
  );
  return crypto.createHash('sha256')
    .update(hashedAdmissionToken)
    .update(Buffer.from(canonicalBody, 'utf8'))
    .digest('hex');
}

module.exports = {
  buildIdempotencyFingerprint,
  businessPayloadForIdempotency,
  clientIPForRequest,
  normalizeClientIP,
  stableCanonicalJSON
};
