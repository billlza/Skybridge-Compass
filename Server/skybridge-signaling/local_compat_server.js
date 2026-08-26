'use strict';

const http = require('http');
const crypto = require('crypto');
const express = require('express');
const { WebSocketServer, WebSocket } = require('ws');
const {
  allowsLegacyQueryTokenFromEnv,
  extractWebSocketSessionCredentials
} = require('./lib/websocket_credentials');

const PORT = Number(process.env.PORT || 18443);
const HOST = process.env.HOST || '0.0.0.0';
const PUBLIC_HOST = String(process.env.PUBLIC_HOST || '').trim();
const CODE_LEN = Number(process.env.CODE_LEN || 8);
const CODE_TTL_MS = Number(process.env.CODE_TTL_MS || 10 * 60_000);
const WS_MAX_MSG_BYTES = readPositiveIntegerEnv(
  'SKYBRIDGE_LOCAL_COMPAT_MAX_WS_MESSAGE_BYTES',
  'WS_MAX_MSG_BYTES',
  16 * 1024
);
const WS_MAX_PAYLOAD_BYTES = readPositiveIntegerEnv(
  'SKYBRIDGE_LOCAL_COMPAT_MAX_WS_PAYLOAD_BYTES',
  'WS_MAX_PAYLOAD_BYTES',
  WS_MAX_MSG_BYTES
);
const WS_MAX_BUFFERED_BYTES = readPositiveIntegerEnv(
  'SKYBRIDGE_LOCAL_COMPAT_MAX_WS_BUFFERED_BYTES',
  'WS_MAX_BUFFERED_BYTES',
  512 * 1024
);
const WS_MAX_PENDING_FRAMES = readPositiveIntegerEnv(
  'SKYBRIDGE_LOCAL_COMPAT_MAX_PENDING_FRAMES',
  'WS_MAX_PENDING_FRAMES',
  64
);
const WS_ALLOW_LEGACY_QUERY_TOKEN = allowsLegacyQueryTokenFromEnv(process.env);
const HTTP_ALLOW_LEGACY_LOOKUP_IDENTITY_BINDING = allowsLegacyLookupIdentityBindingFromEnv(process.env);
if (WS_MAX_PAYLOAD_BYTES < WS_MAX_MSG_BYTES) {
  throw new Error('invalid_local_compat_resource_limit:SKYBRIDGE_LOCAL_COMPAT_MAX_WS_PAYLOAD_BYTES');
}
const TURN_URIS = String(process.env.TURN_URIS || '')
  .split(',')
  .map((value) => value.trim())
  .filter(Boolean);
const ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
const LOG_REDACTED = '<redacted>';

function readPositiveIntegerEnv(primaryName, fallbackName, defaultValue) {
  const raw = process.env[primaryName] !== undefined ? process.env[primaryName] : process.env[fallbackName];
  const sourceName = process.env[primaryName] !== undefined ? primaryName : fallbackName;
  if (raw === undefined) return defaultValue;
  const valueText = String(raw).trim();
  const value = Number(valueText);
  if (!valueText || !Number.isSafeInteger(value) || value <= 0) {
    throw new Error(`invalid_local_compat_resource_limit:${sourceName}`);
  }
  return value;
}

function allowsLegacyLookupIdentityBindingFromEnv(env) {
  const raw = String(env.SKYBRIDGE_LOCAL_COMPAT_ALLOW_LEGACY_LOOKUP_IDENTITY_BINDING || '').trim().toLowerCase();
  return raw === 'true' || raw === '1';
}

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

function safeErrorCode(error) {
  return String(error?.code || error?.name || 'Error');
}

function sessionLogId(record) {
  return String(record?.logId || LOG_REDACTED);
}

function tokenPresence(value) {
  return String(value || '').trim() ? 'present' : 'missing';
}

function requestHasAdmissionToken(req) {
  return String(req.get('X-SkyBridge-Admission') || '').trim() !== '';
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
  const userId = String(
    claims.sub || `user-${sha256Hex(bearer).slice(0, 16)}`
  ).trim();
  const protectedTenantIds = new Set([
    appMetadata.tenant_id,
    appMetadata.tenantId,
    appMetadata.org_id,
    appMetadata.workspace_id,
    claims.tenant_id,
    claims.tenantId,
    claims.org_id,
    claims.workspace_id
  ].map((value) => String(value || '').trim()).filter(Boolean));
  if (protectedTenantIds.size > 1) {
    const error = new Error('conflicting_tenant_claims');
    error.statusCode = 401;
    throw error;
  }
  const tenantId = protectedTenantIds.size === 1
    ? protectedTenantIds.values().next().value
    : userId;
  const requestedTenantId = String(req.get('X-SkyBridge-Tenant-Id') || '').trim();
  if (requestedTenantId && requestedTenantId !== tenantId) {
    const error = new Error('tenant_id_mismatch');
    error.statusCode = 403;
    throw error;
  }
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

function socketForRole(record, role) {
  return role === 'initiator' ? record.initiator.socket : record.responder?.socket || null;
}

function setSocketForRole(record, role, ws) {
  const binding = role === 'initiator' ? record.initiator : record.responder;
  if (!binding) {
    throw new Error('missing_role_binding');
  }
  const previous = binding.socket;
  binding.socket = ws;
  return previous;
}

function isCurrentRoleSocket(record, role, ws) {
  return socketForRole(record, role) === ws;
}

function peerRoleFor(role) {
  return role === 'initiator' ? 'responder' : 'initiator';
}

function pendingRelayForRole(record, role) {
  if (!record.pendingRelay) {
    record.pendingRelay = {
      initiator: { frames: [], bytes: 0 },
      responder: { frames: [], bytes: 0 }
    };
  }
  return record.pendingRelay[role];
}

function clearPendingFramesFromRole(record, fromRole) {
  if (!record?.pendingRelay) return;
  for (const role of ['initiator', 'responder']) {
    const pending = pendingRelayForRole(record, role);
    const kept = pending.frames.filter((frame) => frame.fromRole !== fromRole);
    if (kept.length === pending.frames.length) continue;
    pending.frames = kept;
    pending.bytes = kept.reduce((total, frame) => total + frame.bytes, 0);
    console.log(`[ws] pending cleared sessionLogId=${sessionLogId(record)} session=${LOG_REDACTED} from=${fromRole} for=${role}`);
  }
}

function enqueuePendingRelayFrame(record, targetRole, fromRole, text, bytes, sourceSocket) {
  const pending = pendingRelayForRole(record, targetRole);
  if (
    pending.frames.length >= WS_MAX_PENDING_FRAMES
    || pending.bytes + bytes > WS_MAX_BUFFERED_BYTES
  ) {
    console.log(
      `[ws] pending reject sessionLogId=${sessionLogId(record)} session=${LOG_REDACTED} from=${fromRole} for=${targetRole} bytes=${bytes}`
    );
    closeWebSocketWithReason(sourceSocket, 1013, 'pending_backpressure', `pending:${fromRole}->${targetRole}`);
    return false;
  }
  pending.frames.push({ fromRole, text, bytes });
  pending.bytes += bytes;
  console.log(
    `[ws] pending queued sessionLogId=${sessionLogId(record)} session=${LOG_REDACTED} from=${fromRole} for=${targetRole} bytes=${bytes} frames=${pending.frames.length}`
  );
  return true;
}

function flushPendingRelayFrames(record, targetRole, targetSocket) {
  const pending = pendingRelayForRole(record, targetRole);
  while (pending.frames.length > 0) {
    const frame = pending.frames.shift();
    pending.bytes = Math.max(0, pending.bytes - frame.bytes);
    console.log(
      `[ws] pending relay sessionLogId=${sessionLogId(record)} session=${LOG_REDACTED} from=${frame.fromRole} to=${targetRole} bytes=${frame.bytes}`
    );
    if (!sendTextFrame(targetSocket, frame.text, `pending:${frame.fromRole}->${targetRole}`)) {
      console.warn(
        `[ws] pending relay failed sessionLogId=${sessionLogId(record)} session=${LOG_REDACTED} from=${frame.fromRole} to=${targetRole}`
      );
      pending.frames = [];
      pending.bytes = 0;
      return false;
    }
  }
  return true;
}

function closeWebSocketWithReason(ws, code, reason, context) {
  if (!ws || (ws.readyState !== WebSocket.OPEN && ws.readyState !== WebSocket.CONNECTING)) {
    return false;
  }
  try {
    ws.close(code, reason);
    return true;
  } catch (error) {
    console.warn(`[ws] close failed context=${context} error=${safeErrorCode(error)}`);
    return false;
  }
}

function webSocketMessageByteLength(raw) {
  if (Buffer.isBuffer(raw)) return raw.length;
  if (raw instanceof ArrayBuffer) return raw.byteLength;
  if (ArrayBuffer.isView(raw)) return raw.byteLength;
  return Buffer.byteLength(String(raw), 'utf8');
}

function webSocketMessageToText(raw) {
  if (Buffer.isBuffer(raw)) return raw.toString('utf8');
  if (raw instanceof ArrayBuffer) return Buffer.from(raw).toString('utf8');
  if (ArrayBuffer.isView(raw)) return Buffer.from(raw.buffer, raw.byteOffset, raw.byteLength).toString('utf8');
  return String(raw);
}

function sendTextFrame(ws, text, context) {
  if (!ws || ws.readyState !== WebSocket.OPEN) return false;
  const payload = String(text);
  const bytes = Buffer.byteLength(payload, 'utf8');
  const bufferedAmount = Number(ws.bufferedAmount || 0);
  if (bufferedAmount >= WS_MAX_BUFFERED_BYTES || bufferedAmount + bytes > WS_MAX_BUFFERED_BYTES) {
    closeWebSocketWithReason(ws, 1013, 'backpressure', context);
    return false;
  }
  ws.send(payload, (error) => {
    if (!error) return;
    console.warn(`[ws] send failed context=${context} error=${safeErrorCode(error)}`);
    closeWebSocketWithReason(ws, 1011, 'send_failed', context);
  });
  return true;
}

function sendServerFrame(ws, frame) {
  return sendTextFrame(ws, JSON.stringify(frame), 'server_frame');
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
    ],
    allowLegacyLookupIdentityBinding: HTTP_ALLOW_LEGACY_LOOKUP_IDENTITY_BINDING
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
    logId: randomToken(9),
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
  console.log(`[http] register-code sessionLogId=${sessionLogId(record)} code=${LOG_REDACTED} initiator=${LOG_REDACTED}`);
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
  } catch (error) {
    if (!HTTP_ALLOW_LEGACY_LOOKUP_IDENTITY_BINDING || requestHasAdmissionToken(req)) {
      console.log(`[http] lookup denied sessionLogId=${sessionLogId(record)} code=${LOG_REDACTED} reason=${safeErrorCode(error)}`);
      return res.status(error.statusCode || 401).json({ error: error.message });
    }
    binding = legacyBindingFromRequest(req);
  }
  if (!binding) {
    console.log(`[http] lookup denied sessionLogId=${sessionLogId(record)} code=${LOG_REDACTED} reason=missing_identity_binding`);
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
    console.log(`[http] lookup denied sessionLogId=${sessionLogId(record)} code=${LOG_REDACTED} reason=session_peer_mismatch responder=${LOG_REDACTED}`);
    return res.status(409).json({ error: 'session_peer_mismatch' });
  }
  sessions.set(sessionId, record);
  console.log(`[http] lookup sessionLogId=${sessionLogId(record)} code=${LOG_REDACTED} responder=${LOG_REDACTED}`);
  res.json(sessionResponse(record, 'responder'));
});

app.get('/api/turn/credentials', (req, res) => {
  res.json({
    mode: 'compat',
    username: 'local',
    // The production control plane names this field `password`; the Rust
    // client requires it. `credential` is kept for older local callers.
    password: 'local',
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
const wss = new WebSocketServer({
  server,
  path: SIGNALING_WEBSOCKET_PATH,
  maxPayload: WS_MAX_PAYLOAD_BYTES,
  perMessageDeflate: false
});

wss.on('connection', (ws, req) => {
  let connectionRecord = null;
  let connectionRole = 'unbound';
  ws.on('error', (error) => {
    console.warn(`[ws] socket error sessionLogId=${sessionLogId(connectionRecord)} role=${connectionRole} error=${safeErrorCode(error)}`);
  });

  const url = new URL(req.url, 'http://127.0.0.1');
  const credentials = extractWebSocketSessionCredentials(req, url, {
    allowLegacyQueryToken: WS_ALLOW_LEGACY_QUERY_TOKEN
  });
  if (credentials.error) {
    console.log(`[ws] reject session=${LOG_REDACTED} reason=${credentials.error} token=missing`);
    ws.close(1008, credentials.error);
    return;
  }
  const sessionId = normalizeSessionID(credentials.sessionId);
  const sessionToken = credentials.sessionToken;
  const record = sessions.get(sessionId);
  connectionRecord = record;
  if (!record) {
    console.log(`[ws] reject session=${LOG_REDACTED} reason=unknown_session token=${tokenPresence(sessionToken)}`);
    ws.close(1008, 'unknown_session');
    return;
  }

  let role = null;
  if (record.initiator.sessionToken === sessionToken) {
    role = 'initiator';
  } else if (record.responder && record.responder.sessionToken === sessionToken) {
    role = 'responder';
  } else {
    console.log(`[ws] reject sessionLogId=${sessionLogId(record)} session=${LOG_REDACTED} reason=invalid_session_token token=${tokenPresence(sessionToken)}`);
    ws.close(1008, 'invalid_session_token');
    return;
  }
  connectionRole = role;

  const previousSocket = setSocketForRole(record, role, ws);
  if (previousSocket && previousSocket !== ws) {
    console.log(`[ws] reclaim sessionLogId=${sessionLogId(record)} session=${LOG_REDACTED} role=${role}`);
    clearPendingFramesFromRole(record, role);
    closeWebSocketWithReason(previousSocket, 1008, 'reclaimed', `reclaim:${role}`);
  }

  console.log(`[ws] bound sessionLogId=${sessionLogId(record)} session=${LOG_REDACTED} role=${role}`);
  sendServerFrame(ws, { type: 'bound', sessionId, role });
  flushPendingRelayFrames(record, role, ws);

  ws.on('message', (raw, isBinary) => {
    if (!isCurrentRoleSocket(record, role, ws)) {
      closeWebSocketWithReason(ws, 1008, 'reclaimed', `stale:${role}`);
      return;
    }
    if (isBinary) {
      console.log(`[ws] reject sessionLogId=${sessionLogId(record)} session=${LOG_REDACTED} role=${role} reason=unsupported_data`);
      closeWebSocketWithReason(ws, 1003, 'unsupported_data', `binary:${role}`);
      return;
    }
    const bytes = webSocketMessageByteLength(raw);
    if (bytes > WS_MAX_MSG_BYTES) {
      console.log(`[ws] reject sessionLogId=${sessionLogId(record)} session=${LOG_REDACTED} role=${role} reason=message_too_large bytes=${bytes}`);
      closeWebSocketWithReason(ws, 1009, 'message_too_large', `message_size:${role}`);
      return;
    }
    const peerRole = peerRoleFor(role);
    const peer = socketForRole(record, peerRole);
    const text = webSocketMessageToText(raw);
    if (peer && peer.readyState === WebSocket.OPEN) {
      console.log(`[ws] relay sessionLogId=${sessionLogId(record)} session=${LOG_REDACTED} from=${role} bytes=${bytes}`);
      sendTextFrame(peer, text, `relay:${role}`);
    } else {
      enqueuePendingRelayFrame(record, peerRole, role, text, bytes, ws);
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
      } catch (error) {
        console.warn(`[ws] close expired socket failed sessionLogId=${sessionLogId(value)} role=initiator error=${safeErrorCode(error)}`);
      }
      try {
        value.responder?.socket?.close(1001, 'session_expired');
      } catch (error) {
        console.warn(`[ws] close expired socket failed sessionLogId=${sessionLogId(value)} role=responder error=${safeErrorCode(error)}`);
      }
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
