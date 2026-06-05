'use strict';

const http = require('http');
const crypto = require('crypto');
const express = require('express');
const { WebSocketServer, WebSocket } = require('ws');

const PORT = Number(process.env.PORT || 18443);
const HOST = process.env.HOST || '0.0.0.0';
const PUBLIC_HOST = String(process.env.PUBLIC_HOST || '').trim();
const CODE_LEN = Number(process.env.CODE_LEN || 8);
const CODE_TTL_MS = Number(process.env.CODE_TTL_MS || 10 * 60_000);
const TURN_URIS = String(process.env.TURN_URIS || '')
  .split(',')
  .map((value) => value.trim())
  .filter(Boolean);
const ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
function normalizeSignalingWebSocketPath(rawPath) {
  const value = String(rawPath || '').trim();
  if (
    !value
    || value === '/'
    || !value.startsWith('/')
    || value.includes('?')
    || value.includes('#')
    || !/^[\x21-\x7E]+$/.test(value)
  ) {
    throw new Error('invalid_signaling_websocket_path');
  }
  return value;
}
const SIGNALING_WEBSOCKET_PATH = normalizeSignalingWebSocketPath(
  process.env.SKYBRIDGE_SIGNALING_WEBSOCKET_PATH
  || process.env.SIGNALING_WEBSOCKET_PATH
  || '/ws'
);

const app = express();
app.disable('x-powered-by');
app.use(express.json({ limit: '64kb' }));

const challenges = new Map();
const sessions = new Map();

function nowMs() {
  return Date.now();
}

function randomToken(bytes = 24) {
  return crypto.randomBytes(bytes).toString('base64url');
}

function generateCode(length = CODE_LEN) {
  let value = '';
  for (let i = 0; i < length; i += 1) {
    value += ALPHABET[crypto.randomInt(0, ALPHABET.length)];
  }
  return value;
}

function normalizeSessionID(value) {
  return String(value || '').trim().toUpperCase();
}

function sha256Hex(value) {
  return crypto.createHash('sha256').update(String(value || '')).digest('hex');
}

function parseJWTClaims(token) {
  const raw = String(token || '').trim();
  if (!raw) return {};
  const parts = raw.split('.');
  if (parts.length < 2) return {};
  try {
    const normalized = parts[1].replace(/-/g, '+').replace(/_/g, '/');
    const padded = normalized + '='.repeat((4 - (normalized.length % 4 || 4)) % 4);
    return JSON.parse(Buffer.from(padded, 'base64').toString('utf8'));
  } catch (_) {
    return {};
  }
}

function resolveOrigin(req) {
  const host = PUBLIC_HOST || String(req.get('host') || '').trim();
  if (!host) {
    return `http://127.0.0.1:${PORT}`;
  }
  return `http://${host}`;
}

function authContext(req) {
  const bearer = String(req.get('authorization') || '')
    .replace(/^Bearer\s+/i, '')
    .trim();
  const claims = parseJWTClaims(bearer);
  const appMetadata = claims.app_metadata && typeof claims.app_metadata === 'object' ? claims.app_metadata : {};
  const userMetadata = claims.user_metadata && typeof claims.user_metadata === 'object' ? claims.user_metadata : {};
  const tenantId = String(
    req.get('X-SkyBridge-Tenant-Id')
    || appMetadata.tenant_id
    || appMetadata.tenantId
    || userMetadata.tenant_id
    || userMetadata.tenantId
    || claims.tenant_id
    || claims.tenantId
    || claims.sub
    || 'local-tenant'
  ).trim();
  const userId = String(claims.sub || claims.user_id || userMetadata.user_id || `user-${sha256Hex(bearer).slice(0, 16)}`).trim();
  return { tenantId, userId };
}

function bindingFromAdmission(record) {
  return {
    tenantId: record.tenantId,
    userId: record.userId,
    deviceId: record.deviceId,
    protocolSigningAlgorithm: record.protocolSigningAlgorithm,
    protocolPublicKeyFingerprint: record.protocolPublicKeyFingerprint,
    protocolPublicKeyBytes: Buffer.from(record.protocolPublicKeyBytes || '', 'base64')
  };
}

function legacyBindingFromRequest(req) {
  const deviceId = String(req.query.deviceId || req.body?.deviceId || '').trim();
  const protocolSigningAlgorithm = String(
    req.query.protocolSigningAlgorithm || req.body?.protocolSigningAlgorithm || 'ED25519'
  ).trim();
  const protocolPublicKeyFingerprint = String(
    req.query.protocolPublicKeyFingerprint || req.body?.protocolPublicKeyFingerprint || ''
  ).trim();
  if (!deviceId || !protocolPublicKeyFingerprint) {
    return null;
  }
  const auth = authContext(req);
  return {
    tenantId: auth.tenantId,
    userId: auth.userId,
    deviceId,
    protocolSigningAlgorithm,
    protocolPublicKeyFingerprint,
    protocolPublicKeyBytes: Buffer.alloc(0)
  };
}

function sessionResponse(record, role) {
  const isInitiator = role === 'initiator';
  const token = isInitiator ? record.initiator.sessionToken : record.responder.sessionToken;
  const turnAdmissionToken = isInitiator
    ? record.initiator.turnAdmissionToken
    : record.responder.turnAdmissionToken;
  return {
    code: record.code,
    found: true,
    sessionId: record.sessionId,
    sessionToken: token,
    initiatorToken: record.initiator.sessionToken,
    responderToken: record.responder ? record.responder.sessionToken : token,
    qrBootstrapToken: record.qrBootstrapToken,
    turnAdmissionToken,
    expiresIn: Math.max(0, Math.round((record.expiresAt - nowMs()) / 1000)),
    signalingServerOrigin: record.signalingServerOrigin,
    wsPath: SIGNALING_WEBSOCKET_PATH,
    initiatorDeviceId: record.initiator.deviceId,
    initiatorProtocolSigningAlgorithm: record.initiator.protocolSigningAlgorithm,
    initiatorProtocolPublicKeyFingerprint: record.initiator.protocolPublicKeyFingerprint,
    initiatorDeviceName: record.initiator.deviceName || null
  };
}

function requireAdmission(req) {
  const token = String(req.get('X-SkyBridge-Admission') || '').trim();
  if (!token) {
    const error = new Error('missing_admission_token');
    error.statusCode = 401;
    throw error;
  }
  const record = challenges.get(token);
  if (!record || record.expiresAt <= nowMs()) {
    const error = new Error('admission_token_expired');
    error.statusCode = 401;
    throw error;
  }
  return bindingFromAdmission(record);
}

function compareBinding(left, right) {
  return left
    && right
    && left.deviceId === right.deviceId
    && String(left.protocolSigningAlgorithm).toUpperCase() === String(right.protocolSigningAlgorithm).toUpperCase()
    && left.protocolPublicKeyFingerprint === right.protocolPublicKeyFingerprint;
}

function sendServerFrame(ws, frame) {
  if (!ws || ws.readyState !== WebSocket.OPEN) return;
  ws.send(JSON.stringify(frame));
}

app.get('/', (req, res) => {
  res.json({
    ok: true,
    service: 'skybridge-local-compat-signaling',
    endpoints: [
      '/health',
      '/api/webrtc/admission/challenge',
      '/api/webrtc/admission',
      '/api/webrtc/register-code',
      '/api/webrtc/lookup/:code',
      '/api/turn/credentials',
      SIGNALING_WEBSOCKET_PATH
    ]
  });
});

app.get('/health', (req, res) => {
  res.json({
    status: 'ok',
    sessions: sessions.size,
    challenges: challenges.size
  });
});

app.post('/api/webrtc/admission/challenge', (req, res) => {
  const auth = authContext(req);
  const challengeId = randomToken(18);
  const nonce = randomToken(18);
  const issuedAt = nowMs();
  const expiresAt = issuedAt + 120_000;
  const record = {
    challengeId,
    nonce,
    tenantId: auth.tenantId,
    userId: auth.userId,
    deviceId: String(req.body?.deviceId || '').trim(),
    protocolSigningAlgorithm: String(req.body?.protocolSigningAlgorithm || 'ED25519').trim(),
    protocolPublicKeyFingerprint: String(req.body?.protocolPublicKeyFingerprint || '').trim(),
    protocolPublicKeyBytes: '',
    clientVersion: String(req.body?.clientVersion || '0.0.0').trim(),
    protocolVersion: String(req.body?.protocolVersion || '1').trim(),
    issuedAt,
    expiresAt
  };
  challenges.set(challengeId, record);
  res.json({
    challengeId,
    nonce,
    tenantId: record.tenantId,
    userId: record.userId,
    deviceId: record.deviceId,
    clientIpHash: sha256Hex(req.ip || '127.0.0.1').slice(0, 24),
    clientVersion: record.clientVersion,
    protocolVersion: record.protocolVersion,
    state: 'issued',
    issuedAt,
    expiresAt
  });
});

app.post('/api/webrtc/admission', (req, res) => {
  const challengeId = String(req.body?.challengeId || '').trim();
  const record = challenges.get(challengeId);
  if (!record || record.expiresAt <= nowMs()) {
    return res.status(401).json({ error: 'challenge_expired' });
  }
  const admissionToken = randomToken(24);
  record.protocolPublicKeyBytes = Buffer.from(req.body?.protocolPublicKeyBytes || []).toString('base64');
  challenges.set(admissionToken, record);
  res.json({
    admissionToken,
    state: 'issued',
    issuedAt: nowMs(),
    expiresAt: nowMs() + 120_000
  });
});

app.post('/api/webrtc/register-code', (req, res) => {
  let binding;
  try {
    binding = requireAdmission(req);
  } catch (error) {
    return res.status(error.statusCode || 401).json({ error: error.message });
  }
  let code = '';
  do {
    code = generateCode();
  } while (sessions.has(code));
  const signalingServerOrigin = resolveOrigin(req);
  const record = {
    code,
    sessionId: code,
    signalingServerOrigin,
    createdAt: nowMs(),
    expiresAt: nowMs() + CODE_TTL_MS,
    qrBootstrapToken: randomToken(18),
    initiator: {
      ...binding,
      deviceName: String(req.body?.deviceName || 'Mac').trim() || 'Mac',
      sessionToken: randomToken(24),
      turnAdmissionToken: randomToken(18),
      socket: null
    },
    responder: null
  };
  sessions.set(code, record);
  console.log(`[http] register-code code=${code} initiator=${binding.deviceId}`);
  res.json(sessionResponse(record, 'initiator'));
});

app.get('/api/webrtc/lookup/:code', (req, res) => {
  const sessionId = normalizeSessionID(req.params.code);
  const record = sessions.get(sessionId);
  if (!record || record.expiresAt <= nowMs()) {
    return res.status(404).json({ found: false });
  }
  let binding = null;
  try {
    binding = requireAdmission(req);
  } catch (_) {
    binding = legacyBindingFromRequest(req);
  }
  if (!binding) {
    console.log(`[http] lookup denied code=${sessionId} reason=missing_identity_binding`);
    return res.status(401).json({ error: 'missing_identity_binding' });
  }
  if (!record.responder) {
    record.responder = {
      ...binding,
      sessionToken: randomToken(24),
      turnAdmissionToken: randomToken(18),
      socket: null
    };
  } else if (!compareBinding(record.responder, binding)) {
    console.log(`[http] lookup denied code=${sessionId} reason=session_peer_mismatch responder=${binding.deviceId}`);
    return res.status(409).json({ error: 'session_peer_mismatch' });
  }
  sessions.set(sessionId, record);
  console.log(`[http] lookup code=${sessionId} responder=${binding.deviceId}`);
  res.json(sessionResponse(record, 'responder'));
});

app.get('/api/turn/credentials', (req, res) => {
  res.json({
    mode: 'compat',
    username: 'local',
    credential: 'local',
    ttl: 60,
    uris: TURN_URIS
  });
});

app.use((err, req, res, next) => {
  if (!err) return next();
  res.status(err.statusCode || 500).json({ error: err.message || 'server_error' });
});

const server = http.createServer(app);
const wss = new WebSocketServer({ server, path: SIGNALING_WEBSOCKET_PATH });

wss.on('connection', (ws, req) => {
  const url = new URL(req.url, 'http://127.0.0.1');
  const sessionId = normalizeSessionID(url.searchParams.get('shard'));
  const sessionToken = String(url.searchParams.get('st') || '').trim();
  const record = sessions.get(sessionId);
  if (!record) {
    console.log(`[ws] reject session=${sessionId} reason=unknown_session`);
    ws.close(1008, 'unknown_session');
    return;
  }

  let role = null;
  if (record.initiator.sessionToken === sessionToken) {
    role = 'initiator';
    record.initiator.socket = ws;
  } else if (record.responder && record.responder.sessionToken === sessionToken) {
    role = 'responder';
    record.responder.socket = ws;
  } else {
    console.log(`[ws] reject session=${sessionId} reason=invalid_session_token token=${sessionToken.slice(0, 8)}`);
    ws.close(1008, 'invalid_session_token');
    return;
  }

  console.log(`[ws] bound session=${sessionId} role=${role}`);
  sendServerFrame(ws, { type: 'bound', sessionId, role });

  ws.on('message', (raw) => {
    const peer = role === 'initiator' ? record.responder?.socket : record.initiator.socket;
    if (peer && peer.readyState === WebSocket.OPEN) {
      const text = Buffer.isBuffer(raw) ? raw.toString('utf8') : String(raw);
      console.log(`[ws] relay session=${sessionId} from=${role} bytes=${text.length}`);
      peer.send(text);
    }
  });

  ws.on('close', () => {
    if (role === 'initiator' && record.initiator.socket === ws) {
      record.initiator.socket = null;
    }
    if (role === 'responder' && record.responder?.socket === ws) {
      record.responder.socket = null;
    }
  });
});

setInterval(() => {
  const cutoff = nowMs();
  for (const [key, value] of sessions.entries()) {
    if (value.expiresAt <= cutoff) {
      try {
        value.initiator.socket?.close(1001, 'session_expired');
      } catch (_) {}
      try {
        value.responder?.socket?.close(1001, 'session_expired');
      } catch (_) {}
      sessions.delete(key);
    }
  }
  for (const [key, value] of challenges.entries()) {
    if (value.expiresAt <= cutoff) {
      challenges.delete(key);
    }
  }
}, 5_000).unref();

server.listen(PORT, HOST, () => {
  console.log(`SkyBridge local compat signaling listening on http://${HOST}:${PORT}`);
  console.log(`WS path: ${SIGNALING_WEBSOCKET_PATH}`);
});
