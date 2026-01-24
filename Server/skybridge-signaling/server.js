'use strict';

/**
 * SkyBridge Signaling Server (HTTP by default; optional HTTPS via env)
 *
 * Recommended deployment:
 *   Cloudflare (edge TLS) -> Nginx (origin TLS) -> Node (HTTP localhost:8443)
 *
 * Optional Node HTTPS:
 *   export TLS_CERT=/path/fullchain.pem
 *   export TLS_KEY=/path/privkey.pem
 *   node server.js
 */

const http = require('http');
const https = require('https');
const fs = require('fs');
const crypto = require('crypto');

const express = require('express');
const { WebSocketServer } = require('ws');
const { v4: uuidv4 } = require('uuid');

// -------------------- Config --------------------
const PORT = Number(process.env.PORT || 8443);
const HOST = process.env.HOST || '0.0.0.0';

const TRUST_PROXY = /^(1|true|yes)$/i.test(process.env.TRUST_PROXY || 'true'); // behind CF/nginx usually true
const JSON_LIMIT = process.env.JSON_LIMIT || '1mb';

// “人类码”长度：越长越不容易撞库（建议 >= 8）
const CODE_LEN = Number(process.env.CODE_LEN || 8);
const CODE_TTL_MS = Number(process.env.CODE_TTL_MS || 5 * 60_000); // 5 minutes
const SWEEP_INTERVAL_MS = Number(process.env.SWEEP_INTERVAL_MS || 10_000);

const ICE_TTL_MS = Number(process.env.ICE_TTL_MS || 30 * 60_000); // 30 minutes
const ICE_MAX_PER_SESSION = Number(process.env.ICE_MAX_PER_SESSION || 200);

// 兼容旧客户端：允许 lookup/answer 不带 token（建议尽快关掉）
const ALLOW_INSECURE = /^(1|true|yes)$/i.test(process.env.ALLOW_INSECURE || 'true');

// CORS（原生 App 一般无 Origin，Web 端才有）
const CORS_ORIGIN = process.env.CORS_ORIGIN || '*'; // e.g. "https://app.example.com,https://admin.example.com"

// Optional TLS for Node itself
const TLS_CERT = process.env.TLS_CERT || '';
const TLS_KEY = process.env.TLS_KEY || '';
const TLS_CA = process.env.TLS_CA || '';
const USE_NODE_HTTPS = Boolean(TLS_CERT && TLS_KEY);

// -------------------- Small helpers --------------------
function now() { return Date.now(); }

function base64url(buf) {
  // compatible across Node versions
  return buf.toString('base64')
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/g, '');
}

function newToken() {
  return base64url(crypto.randomBytes(32)); // 256-bit
}

function sha256Hex(s) {
  return crypto.createHash('sha256').update(String(s)).digest('hex');
}

const CODE_ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; // no 0/O/1/I
function generateCode(len = CODE_LEN) {
  const bytes = crypto.randomBytes(len);
  let out = '';
  for (let i = 0; i < len; i++) {
    out += CODE_ALPHABET[bytes[i] % CODE_ALPHABET.length];
  }
  return out;
}

function isPlainObject(x) {
  return x && typeof x === 'object' && !Array.isArray(x);
}

function safeUpperCode(x) {
  return String(x || '').trim().toUpperCase();
}

// Simple in-memory rate limiter (per IP)
function rateLimit({ windowMs, max, keyFn }) {
  const hits = new Map(); // key -> {count, resetAt}
  return (req, res, next) => {
    const key = keyFn ? keyFn(req) : (req.ip || req.connection.remoteAddress || 'unknown');
    const t = now();
    let ent = hits.get(key);
    if (!ent || t > ent.resetAt) {
      ent = { count: 0, resetAt: t + windowMs };
      hits.set(key, ent);
    }
    ent.count++;
    if (ent.count > max) {
      res.status(429).json({ error: 'rate_limited' });
      return;
    }
    next();
  };
}

// -------------------- State --------------------
/**
 * connectionCodes: code -> {
 *   deviceId, offer,
 *   createdAt, expiresAt,
 *   initiatorTokenHash, responderTokenHash,
 *   responderId,
 *   wsInitiator, wsResponder,
 *   answer, answerFrom
 * }
 */
const connectionCodes = new Map();

/**
 * iceCandidates: sessionId -> [{ candidate, from, timestamp }]
 */
const iceCandidates = new Map();

/**
 * WebRTC envelope rooms (new protocol):
 * rooms: sessionId -> { clients:Set<ws>, clientsByDeviceId:Map<string, ws> }
 *
 * This supports the app-side `WebRTCSignalingEnvelope`:
 * - { sessionId, from, to?, type: join|offer|answer|iceCandidate|leave, payload?, sentAt }
 *
 * We keep the legacy “connection code + bind/role” protocol for backward compatibility.
 */
const rooms = new Map();

// ws metadata
const wsMeta = new WeakMap(); // ws -> { code, role, clientId }

function normalizeSessionId(x) {
  return String(x || '').trim();
}

function normalizeDeviceId(x) {
  return String(x || '').trim();
}

function isWebRTCEnvelope(msg) {
  if (!isPlainObject(msg)) return false;
  if (typeof msg.sessionId !== 'string') return false;
  if (typeof msg.from !== 'string') return false;
  if (typeof msg.type !== 'string') return false;
  const t = msg.type;
  return t === 'join' || t === 'offer' || t === 'answer' || t === 'iceCandidate' || t === 'leave';
}

function getOrCreateRoom(sessionId) {
  const sid = normalizeSessionId(sessionId);
  if (!sid) return null;
  let room = rooms.get(sid);
  if (!room) {
    room = { clients: new Set(), clientsByDeviceId: new Map() };
    rooms.set(sid, room);
  }
  return room;
}

function removeFromAllRooms(ws) {
  const meta = wsMeta.get(ws);
  if (!meta || !meta.sessionId) return;
  const sid = meta.sessionId;
  const room = rooms.get(sid);
  if (!room) return;
  room.clients.delete(ws);
  if (meta.deviceId && room.clientsByDeviceId.get(meta.deviceId) === ws) {
    room.clientsByDeviceId.delete(meta.deviceId);
  }
  if (room.clients.size === 0) rooms.delete(sid);
}

function wsSendRaw(ws, obj) {
  if (!ws || ws.readyState !== ws.OPEN) return false;
  ws.send(JSON.stringify(obj));
  return true;
}

function handleWebRTCEnvelope(ws, msg) {
  const sid = normalizeSessionId(msg.sessionId);
  const from = normalizeDeviceId(msg.from);
  if (!sid || !from) return wsSendRaw(ws, { type: 'error', error: 'bad_envelope' });

  // Ensure membership
  const room = getOrCreateRoom(sid);
  if (!room) return wsSendRaw(ws, { type: 'error', error: 'bad_sessionId' });

  // Attach metadata (so we can cleanup on close)
  const legacyMeta = wsMeta.get(ws) || { code: null, role: null, clientId: uuidv4() };
  wsMeta.set(ws, { ...legacyMeta, sessionId: sid, deviceId: from });

  if (msg.type === 'join') {
    room.clients.add(ws);
    room.clientsByDeviceId.set(from, ws);
    return; // no ack needed
  }

  // For non-join messages, if the sender forgot to join, auto-join.
  if (!room.clients.has(ws)) {
    room.clients.add(ws);
    room.clientsByDeviceId.set(from, ws);
  }

  // Route:
  // - if `to` present and we have an active ws for it, deliver only to it
  // - else broadcast to room (excluding sender)
  const to = typeof msg.to === 'string' ? normalizeDeviceId(msg.to) : '';
  if (to) {
    const target = room.clientsByDeviceId.get(to);
    if (target && target !== ws) {
      wsSendRaw(target, msg);
      return;
    }
    // If `to` is unknown, fall back to broadcast (helps when peers don't have stable ids yet)
  }

  for (const peer of room.clients) {
    if (peer === ws) continue;
    wsSendRaw(peer, msg);
  }
}

// -------------------- App --------------------
const app = express();
if (TRUST_PROXY) app.set('trust proxy', 1);

app.disable('x-powered-by');
app.use(express.json({ limit: JSON_LIMIT }));

// CORS + basic security headers (lightweight)
app.use((req, res, next) => {
  // CORS
  const origin = req.headers.origin;
  if (CORS_ORIGIN === '*') {
    res.setHeader('Access-Control-Allow-Origin', '*');
  } else if (origin) {
    const allowList = CORS_ORIGIN.split(',').map(s => s.trim()).filter(Boolean);
    if (allowList.includes(origin)) res.setHeader('Access-Control-Allow-Origin', origin);
  }
  res.setHeader('Access-Control-Allow-Methods', 'GET,POST,OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization');
  if (req.method === 'OPTIONS') return res.sendStatus(204);

  // Simple hardening
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('Content-Security-Policy', "default-src 'none'");
  next();
});

// -------------------- Health & Root --------------------
app.get('/', (req, res) => {
  // 之前你 curl -I https://api... 之所以 404，就是没这个路由
  res.status(200).json({
    ok: true,
    service: 'skybridge-signaling',
    time: new Date().toISOString(),
    endpoints: ['/health', '/healthz', '/api/register', '/api/lookup/:code', '/api/answer/:code', '/api/ice/:sessionId', '/ws']
  });
});

app.get('/health', (req, res) => {
  res.json({
    status: 'ok',
    connections: connectionCodes.size,
    iceSessions: iceCandidates.size,
    wsClients: wss ? wss.clients.size : 0
  });
});

app.get('/healthz', (req, res) => res.status(200).send('ok'));

// -------------------- API rate limits --------------------
const rlRegister = rateLimit({ windowMs: 60_000, max: 30 });
const rlLookup   = rateLimit({ windowMs: 60_000, max: 60 });
const rlAnswer   = rateLimit({ windowMs: 60_000, max: 60 });
const rlIce      = rateLimit({ windowMs: 60_000, max: 240 });

// -------------------- REST API: register --------------------
app.post('/api/register', rlRegister, (req, res) => {
  const { deviceId, offer } = req.body || {};

  if (typeof deviceId !== 'string' || deviceId.length < 1 || deviceId.length > 128) {
    return res.status(400).json({ error: 'bad_deviceId' });
  }
  if (!isPlainObject(offer)) {
    return res.status(400).json({ error: 'bad_offer' });
  }

  let code;
  for (let i = 0; i < 10; i++) {
    const c = generateCode();
    if (!connectionCodes.has(c)) { code = c; break; }
  }
  if (!code) return res.status(500).json({ error: 'code_generation_failed' });

  const initiatorToken = newToken();
  const createdAt = now();
  const expiresAt = createdAt + CODE_TTL_MS;

  connectionCodes.set(code, {
    deviceId,
    offer,
    createdAt,
    expiresAt,
    initiatorTokenHash: sha256Hex(initiatorToken),
    responderTokenHash: null,
    responderId: null,
    wsInitiator: null,
    wsResponder: null,
    answer: null,
    answerFrom: null
  });

  console.log(`[Register] ${deviceId} code=${code} ttl=${Math.round(CODE_TTL_MS / 1000)}s`);
  res.json({
    code,
    initiatorToken,
    expiresIn: Math.round(CODE_TTL_MS / 1000),
    wsPath: '/ws'
  });
});

// -------------------- REST API: lookup --------------------
app.get('/api/lookup/:code', rlLookup, (req, res) => {
  const code = safeUpperCode(req.params.code);
  const item = connectionCodes.get(code);
  if (!item || now() > item.expiresAt) {
    if (item) connectionCodes.delete(code);
    return res.status(404).json({ found: false });
  }

  // 给 responder 发一个 token（即使你旧客户端不用，也不影响）
  let responderToken = null;
  if (!item.responderTokenHash) {
    responderToken = newToken();
    item.responderTokenHash = sha256Hex(responderToken);
  }

  // 可选：记录 responderId（如果传了）
  const responderId = (typeof req.query.deviceId === 'string' && req.query.deviceId.length <= 128)
    ? req.query.deviceId
    : null;
  if (responderId && !item.responderId) item.responderId = responderId;

  res.json({
    found: true,
    deviceId: item.deviceId,
    offer: item.offer,
    // 新增字段（安全模式用）
    sessionId: code,
    responderToken,
    expiresIn: Math.max(0, Math.round((item.expiresAt - now()) / 1000))
  });
});

// -------------------- REST API: answer --------------------
app.post('/api/answer/:code', rlAnswer, (req, res) => {
  const code = safeUpperCode(req.params.code);
  const item = connectionCodes.get(code);
  if (!item || now() > item.expiresAt) {
    if (item) connectionCodes.delete(code);
    return res.status(404).json({ success: false, error: 'Code not found' });
  }

  const { answer, deviceId, token } = req.body || {};
  if (typeof deviceId !== 'string' || deviceId.length < 1 || deviceId.length > 128) {
    return res.status(400).json({ success: false, error: 'bad_deviceId' });
  }
  if (!isPlainObject(answer)) {
    return res.status(400).json({ success: false, error: 'bad_answer' });
  }

  // token 校验（强烈建议用；兼容旧客户端可关闭）
  const tokenOk = (typeof token === 'string' && item.responderTokenHash && sha256Hex(token) === item.responderTokenHash);
  if (!tokenOk && !ALLOW_INSECURE) {
    return res.status(401).json({ success: false, error: 'unauthorized' });
  }

  item.answer = answer;
  item.answerFrom = deviceId;
  if (!item.responderId) item.responderId = deviceId;

  // WS 通知 initiator
  if (item.wsInitiator && item.wsInitiator.readyState === item.wsInitiator.OPEN) {
    item.wsInitiator.send(JSON.stringify({ type: 'answer', code, answer, from: deviceId }));
  }

  console.log(`[Answer] code=${code} from=${deviceId} tokenOk=${tokenOk}`);
  res.json({ success: true });
});

// -------------------- REST API: ICE candidates (legacy sessionId) --------------------
app.post('/api/ice/:sessionId', rlIce, (req, res) => {
  const sessionId = safeUpperCode(req.params.sessionId);
  const { candidate, from, token } = req.body || {};

  if (typeof from !== 'string' || from.length < 1 || from.length > 128) {
    return res.status(400).json({ success: false, error: 'bad_from' });
  }
  if (!isPlainObject(candidate)) {
    return res.status(400).json({ success: false, error: 'bad_candidate' });
  }

  // 如果 sessionId 就是 code，则可做 token 校验（可选）
  const item = connectionCodes.get(sessionId);
  if (item) {
    const okInitiator = typeof token === 'string' && sha256Hex(token) === item.initiatorTokenHash;
    const okResponder = typeof token === 'string' && item.responderTokenHash && sha256Hex(token) === item.responderTokenHash;
    if (!okInitiator && !okResponder && !ALLOW_INSECURE) {
      return res.status(401).json({ success: false, error: 'unauthorized' });
    }
  }

  if (!iceCandidates.has(sessionId)) iceCandidates.set(sessionId, []);
  const arr = iceCandidates.get(sessionId);
  arr.push({ candidate, from, timestamp: now() });

  // 上限：丢旧的
  if (arr.length > ICE_MAX_PER_SESSION) {
    arr.splice(0, arr.length - ICE_MAX_PER_SESSION);
  }

  res.json({ success: true });
});

app.get('/api/ice/:sessionId', rlIce, (req, res) => {
  const sessionId = safeUpperCode(req.params.sessionId);
  const since = req.query.since ? Number(req.query.since) : 0;

  let candidates = iceCandidates.get(sessionId) || [];
  if (since && Number.isFinite(since)) {
    candidates = candidates.filter(c => c.timestamp > since);
  }
  res.json({ candidates });
});

// -------------------- Create server (HTTP or HTTPS) --------------------
const server = (() => {
  if (!USE_NODE_HTTPS) return http.createServer(app);

  const tlsOptions = {
    key: fs.readFileSync(TLS_KEY),
    cert: fs.readFileSync(TLS_CERT),
  };
  if (TLS_CA) tlsOptions.ca = fs.readFileSync(TLS_CA);
  return https.createServer(tlsOptions, app);
})();

// -------------------- WebSocket --------------------
let wss = null;

wss = new WebSocketServer({ server, path: '/ws' });

function getItemByCode(code) {
  const c = safeUpperCode(code);
  const item = connectionCodes.get(c);
  if (!item) return null;
  if (now() > item.expiresAt) {
    dropCode(c, 'expired');
    return null;
  }
  return item;
}

function dropCode(code, reason) {
  const item = connectionCodes.get(code);
  if (!item) return;
  try { if (item.wsInitiator) item.wsInitiator.close(1000, reason); } catch {}
  try { if (item.wsResponder) item.wsResponder.close(1000, reason); } catch {}
  connectionCodes.delete(code);
  iceCandidates.delete(code);
  console.log(`[Cleanup] code=${code} reason=${reason}`);
}

function wsSend(ws, obj) {
  if (!ws || ws.readyState !== ws.OPEN) return false;
  ws.send(JSON.stringify(obj));
  return true;
}

function authWsBind(item, role, token) {
  if (role === 'initiator') {
    return typeof token === 'string' && sha256Hex(token) === item.initiatorTokenHash;
  }
  if (role === 'responder') {
    return typeof token === 'string' && item.responderTokenHash && sha256Hex(token) === item.responderTokenHash;
  }
  return false;
}

wss.on('connection', (ws, req) => {
  const clientId = uuidv4();
  ws.isAlive = true;
  wsMeta.set(ws, { code: null, role: null, clientId, sessionId: null, deviceId: null });

  ws.on('pong', () => { ws.isAlive = true; });

  ws.on('message', (raw) => {
    let msg;
    try {
      msg = JSON.parse(raw.toString());
    } catch (e) {
      return wsSend(ws, { type: 'error', error: 'bad_json' });
    }

    // New WebRTC envelope protocol (sessionId-based room routing).
    // This is used by iOS/macOS `WebRTCSignalingEnvelope`.
    if (isWebRTCEnvelope(msg)) {
      try {
        handleWebRTCEnvelope(ws, msg);
      } catch (e) {
        wsSend(ws, { type: 'error', error: 'envelope_failed' });
      }
      return;
    }

    const meta = wsMeta.get(ws) || { code: null, role: null, clientId };

    switch (msg.type) {
      case 'bind': {
        // { type:'bind', code, role:'initiator'|'responder', token }
        const code = safeUpperCode(msg.code);
        const role = msg.role === 'responder' ? 'responder' : 'initiator';
        const item = getItemByCode(code);
        if (!item) return wsSend(ws, { type: 'error', error: 'code_not_found' });

        const ok = authWsBind(item, role, msg.token);
        if (!ok && !ALLOW_INSECURE) {
          ws.close(1008, 'unauthorized');
          return;
        }

        // 绑定
        if (role === 'initiator') item.wsInitiator = ws;
        else item.wsResponder = ws;

        wsMeta.set(ws, { code, role, clientId });

        wsSend(ws, { type: 'bound', code, role, clientId });

        // 如果 answer 已经先通过 REST 到了，也推一下
        if (role === 'initiator' && item.answer) {
          wsSend(ws, { type: 'answer', code, answer: item.answer, from: item.answerFrom });
        }
        console.log(`[WS] bind client=${clientId} role=${role} code=${code} ok=${ok}`);
        break;
      }

      case 'signal': {
        // { type:'signal', data, targetRole:'initiator'|'responder' }
        if (!meta.code || !meta.role) return wsSend(ws, { type: 'error', error: 'not_bound' });
        const item = getItemByCode(meta.code);
        if (!item) return wsSend(ws, { type: 'error', error: 'code_not_found' });

        const targetRole = msg.targetRole === 'initiator' ? 'initiator' : 'responder';
        const target = targetRole === 'initiator' ? item.wsInitiator : item.wsResponder;

        wsSend(target, { type: 'signal', code: meta.code, data: msg.data, from: meta.role, fromClientId: clientId });
        break;
      }

      case 'ice': {
        // { type:'ice', candidate, targetRole }
        if (!meta.code || !meta.role) return wsSend(ws, { type: 'error', error: 'not_bound' });
        const item = getItemByCode(meta.code);
        if (!item) return wsSend(ws, { type: 'error', error: 'code_not_found' });

        const targetRole = msg.targetRole === 'initiator' ? 'initiator' : 'responder';
        const target = targetRole === 'initiator' ? item.wsInitiator : item.wsResponder;

        wsSend(target, { type: 'ice', code: meta.code, candidate: msg.candidate, from: meta.role });
        break;
      }

      case 'answer': {
        // WS 也允许发 answer（可选）
        // { type:'answer', answer, deviceId }
        if (!meta.code || !meta.role) return wsSend(ws, { type: 'error', error: 'not_bound' });
        if (meta.role !== 'responder') return wsSend(ws, { type: 'error', error: 'bad_role' });

        const item = getItemByCode(meta.code);
        if (!item) return wsSend(ws, { type: 'error', error: 'code_not_found' });
        if (!isPlainObject(msg.answer)) return wsSend(ws, { type: 'error', error: 'bad_answer' });

        item.answer = msg.answer;
        item.answerFrom = (typeof msg.deviceId === 'string' && msg.deviceId.length <= 128) ? msg.deviceId : 'responder';

        wsSend(item.wsInitiator, { type: 'answer', code: meta.code, answer: item.answer, from: item.answerFrom });
        wsSend(ws, { type: 'ok', what: 'answer_saved' });
        break;
      }

      default:
        wsSend(ws, { type: 'error', error: 'unknown_type' });
    }
  });

  ws.on('close', () => {
    const meta = wsMeta.get(ws);
    // Cleanup room membership for the new envelope protocol.
    removeFromAllRooms(ws);
    if (meta && meta.code) {
      const item = connectionCodes.get(meta.code);
      if (item) {
        if (item.wsInitiator === ws) item.wsInitiator = null;
        if (item.wsResponder === ws) item.wsResponder = null;
      }
    }
  });

  ws.on('error', () => {});
});

// WS heartbeat to kill dead connections
const heartbeatTimer = setInterval(() => {
  for (const ws of wss.clients) {
    if (ws.isAlive === false) {
      try { ws.terminate(); } catch {}
      continue;
    }
    ws.isAlive = false;
    try { ws.ping(); } catch {}
  }
}, 30_000);

// -------------------- Sweeper --------------------
const sweepTimer = setInterval(() => {
  const t = now();

  // expire codes
  for (const [code, item] of connectionCodes) {
    if (t > item.expiresAt) dropCode(code, 'expired');
  }

  // expire ICE sessions
  for (const [sid, arr] of iceCandidates) {
    const kept = arr.filter(x => (t - x.timestamp) <= ICE_TTL_MS);
    if (kept.length === 0) iceCandidates.delete(sid);
    else iceCandidates.set(sid, kept);
  }
}, SWEEP_INTERVAL_MS);

process.on('SIGINT', () => {
  clearInterval(heartbeatTimer);
  clearInterval(sweepTimer);
  server.close(() => process.exit(0));
});

// -------------------- Start --------------------
server.listen(PORT, HOST, () => {
  console.log('========================================');
  console.log('SkyBridge Signaling Server');
  console.log(`Mode: ${USE_NODE_HTTPS ? 'HTTPS' : 'HTTP'}  listening on ${HOST}:${PORT}`);
  console.log(`WS:   ${USE_NODE_HTTPS ? 'wss' : 'ws'}://<host>:${PORT}/ws`);
  console.log(`TTL:  code=${Math.round(CODE_TTL_MS / 1000)}s  ice=${Math.round(ICE_TTL_MS / 1000)}s`);
  console.log('========================================');
});

