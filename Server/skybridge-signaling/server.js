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
const os = require('os');

const express = require('express');
const { WebSocketServer } = require('ws');
const { v4: uuidv4 } = require('uuid');
const { createSignalingStateBackend, unique } = require('./lib/signaling_state_backend');

// -------------------- Config --------------------
const PORT = Number(process.env.PORT || 8443);
const HOST = process.env.HOST || '0.0.0.0';
const INSTANCE_ID = String(process.env.INSTANCE_ID || `${os.hostname()}-${process.pid}`).trim();
const SIGNALING_STATE_BACKEND = String(process.env.SIGNALING_STATE_BACKEND || 'memory').trim().toLowerCase();
const SIGNALING_REDIS_URL = String(process.env.SIGNALING_REDIS_URL || process.env.REDIS_URL || '').trim();
const SIGNALING_REDIS_KEY_PREFIX = String(process.env.SIGNALING_REDIS_KEY_PREFIX || 'skybridge:signaling:').trim() || 'skybridge:signaling:';
const SIGNALING_REDIS_CHANNEL_PREFIX = String(process.env.SIGNALING_REDIS_CHANNEL_PREFIX || 'skybridge:signaling:channel:').trim() || 'skybridge:signaling:channel:';
const SIGNALING_REDIS_CONNECT_TIMEOUT_MS = Number(process.env.SIGNALING_REDIS_CONNECT_TIMEOUT_MS || 5_000);

// SECURITY: default to false. If you expose Node directly with trust-proxy enabled, attackers can spoof X-Forwarded-For
// and bypass per-IP rate limits. Only enable when you're definitely behind a trusted reverse proxy (CF/nginx).
const TRUST_PROXY = /^(1|true|yes)$/i.test(process.env.TRUST_PROXY || 'false');
const JSON_LIMIT = process.env.JSON_LIMIT || '1mb';

// “人类码”长度：越长越不容易撞库（建议 >= 8）
const CODE_LEN = Number(process.env.CODE_LEN || 8);
const CODE_TTL_MS = Number(process.env.CODE_TTL_MS || 5 * 60_000); // 5 minutes
const SWEEP_INTERVAL_MS = Number(process.env.SWEEP_INTERVAL_MS || 10_000);

const ICE_TTL_MS = Number(process.env.ICE_TTL_MS || 30 * 60_000); // 30 minutes
const ICE_MAX_PER_SESSION = Number(process.env.ICE_MAX_PER_SESSION || 200);
const ROOM_MEMBERSHIP_TTL_MS = Number(process.env.ROOM_MEMBERSHIP_TTL_MS || 120_000);
const LEGACY_BINDING_TTL_MS = Number(process.env.LEGACY_BINDING_TTL_MS || CODE_TTL_MS);

// 兼容旧客户端：允许 lookup/answer 不带 token（建议尽快关掉）
// SECURITY: default MUST be false in production. If you need legacy compatibility, explicitly set ALLOW_INSECURE=true.
const ALLOW_INSECURE = /^(1|true|yes)$/i.test(process.env.ALLOW_INSECURE || 'false');

// WebSocket envelope hardening (DoS / resource exhaustion protection)
const WS_MAX_MSG_BYTES = Number(process.env.WS_MAX_MSG_BYTES || 64 * 1024); // 64KB
const WS_MAX_MSGS_PER_10S = Number(process.env.WS_MAX_MSGS_PER_10S || 200);
const WS_MAX_CLIENTS_PER_ROOM = Number(process.env.WS_MAX_CLIENTS_PER_ROOM || 4);

// Optional sticky affinity hint cookie.
// This is deployment-facing only: it does not change signaling payloads or protocol semantics.
const ENABLE_STICKY_HINT_COOKIE = /^(1|true|yes)$/i.test(process.env.ENABLE_STICKY_HINT_COOKIE || 'false');
const STICKY_HINT_COOKIE_NAME = String(process.env.STICKY_HINT_COOKIE_NAME || 'skybridge_route').trim() || 'skybridge_route';
const STICKY_HINT_COOKIE_MAX_AGE_SECONDS = Number(process.env.STICKY_HINT_COOKIE_MAX_AGE_SECONDS || Math.max(60, Math.round(CODE_TTL_MS / 1000)));
const STICKY_HINT_COOKIE_SECURE = /^(1|true|yes)$/i.test(process.env.STICKY_HINT_COOKIE_SECURE || 'true');
const STICKY_HINT_COOKIE_SAMESITE = String(process.env.STICKY_HINT_COOKIE_SAMESITE || 'Lax').trim() || 'Lax';

// CORS（原生 App 一般无 Origin，Web 端才有）
// SECURITY: default to deny-by-default (no CORS header). Set explicitly if you have a browser client.
const CORS_ORIGIN = process.env.CORS_ORIGIN || ''; // e.g. "https://app.example.com,https://admin.example.com"

// TURN credential endpoint (RFC 7635-style short-lived credentials)
const TURN_CLIENT_API_KEY = String(process.env.TURN_CLIENT_API_KEY || process.env.SKYBRIDGE_CLIENT_API_KEY || '').trim();
const TURN_ENFORCE_API_KEY = /^(1|true|yes)$/i.test(process.env.TURN_ENFORCE_API_KEY || 'true');
const TURN_CRED_TTL_SECONDS = Number(process.env.TURN_CRED_TTL_SECONDS || 3600);
const TURN_SHARED_SECRET = process.env.TURN_SHARED_SECRET || '';
const TURN_STATIC_USERNAME = process.env.TURN_USERNAME || process.env.SKYBRIDGE_TURN_USERNAME || '';
const TURN_STATIC_PASSWORD = process.env.TURN_PASSWORD || process.env.SKYBRIDGE_TURN_PASSWORD || '';
const TURN_ALLOW_STATIC_FALLBACK = /^(1|true|yes)$/i.test(process.env.TURN_ALLOW_STATIC_FALLBACK || 'false');
const TURN_URIS = (process.env.TURN_URIS || process.env.TURN_URLS || 'turns:54.92.79.99:5349?transport=tcp,turn:54.92.79.99:3478?transport=udp')
  .split(',')
  .map((s) => s.trim())
  .filter((s) => Boolean(s) && /^(turn:|turns:)/i.test(s));

// Brute-force mitigation for /api/lookup (code enumeration)
const LOOKUP_INVALID_WINDOW_MS = Number(process.env.LOOKUP_INVALID_WINDOW_MS || 60_000);
const LOOKUP_INVALID_MAX = Number(process.env.LOOKUP_INVALID_MAX || 20); // per IP per window
const lookupInvalidHits = new Map(); // ip -> {count, resetAt}
const SIGNALING_SERVER_ORIGIN = String(process.env.SIGNALING_SERVER_ORIGIN || '').trim();
const STRICT_DEVICE_ID_RE = /^[A-Za-z0-9._:-]{16,128}$/;
const FINGERPRINT_RE = /^[0-9a-f]{64}$/;
const ALLOWED_PROTOCOL_SIGNING_ALGORITHMS = new Set(['Ed25519', 'ML-DSA-65']);

function recordInvalidLookup(ip) {
  const t = now();
  let ent = lookupInvalidHits.get(ip);
  if (!ent || t > ent.resetAt) {
    ent = { count: 0, resetAt: t + LOOKUP_INVALID_WINDOW_MS };
    lookupInvalidHits.set(ip, ent);
  }
  ent.count++;
  return ent.count;
}

function invalidLookupLimited(ip) {
  const t = now();
  const ent = lookupInvalidHits.get(ip);
  if (!ent) return false;
  if (t > ent.resetAt) return false;
  return ent.count > LOOKUP_INVALID_MAX;
}

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

function secureStringEqual(left, right) {
  if (typeof left !== 'string' || typeof right !== 'string') return false;
  const leftBuf = Buffer.from(left, 'utf8');
  const rightBuf = Buffer.from(right, 'utf8');
  if (leftBuf.length !== rightBuf.length) return false;
  return crypto.timingSafeEqual(leftBuf, rightBuf);
}

function canonicalizeOrigin(raw) {
  let parsed;
  try {
    parsed = new URL(String(raw || ''));
  } catch (_) {
    return null;
  }
  const scheme = String(parsed.protocol || '').replace(/:$/, '').toLowerCase();
  const host = String(parsed.hostname || '').toLowerCase();
  if (!host || (scheme !== 'https' && scheme !== 'http')) return null;
  if (parsed.pathname && parsed.pathname !== '/') return null;
  if (parsed.search || parsed.hash) return null;
  const port = parsed.port ? Number(parsed.port) : null;
  if ((scheme === 'https' && (!port || port === 443)) || (scheme === 'http' && (!port || port === 80))) {
    return `${scheme}://${host}`;
  }
  return `${scheme}://${host}:${port}`;
}

function resolvedSignalingServerOrigin(req) {
  const configured = canonicalizeOrigin(SIGNALING_SERVER_ORIGIN);
  if (configured) return configured;
  const forwardedProto = String(req.get('X-Forwarded-Proto') || '').split(',')[0].trim().toLowerCase();
  const scheme = forwardedProto || String(req.protocol || 'https').toLowerCase();
  const host = String(req.get('host') || '').trim();
  const derived = canonicalizeOrigin(`${scheme}://${host}`);
  if (!derived) {
    throw new Error('invalid_signaling_server_origin');
  }
  return derived;
}

function isStrictDeviceId(value) {
  return typeof value === 'string' && STRICT_DEVICE_ID_RE.test(value);
}

function normalizeProtocolSigningAlgorithm(raw) {
  const value = String(raw || '').trim();
  if (ALLOWED_PROTOCOL_SIGNING_ALGORITHMS.has(value)) {
    return value;
  }
  const folded = value.toLowerCase().replace(/[^a-z0-9]/g, '');
  switch (folded) {
    case 'ed25519':
      return 'Ed25519';
    case 'mldsa65':
      return 'ML-DSA-65';
    default:
      return '';
  }
}

function normalizeFingerprint(raw) {
  const value = String(raw || '').trim().toLowerCase();
  return FINGERPRINT_RE.test(value) ? value : '';
}

function normalizeIdentityBinding(raw, { requirePublicKey = false } = {}) {
  if (!raw || typeof raw !== 'object') return null;
  const deviceId = normalizeDeviceId(raw.deviceId);
  const protocolSigningAlgorithm = normalizeProtocolSigningAlgorithm(raw.protocolSigningAlgorithm);
  const protocolPublicKeyFingerprint = normalizeFingerprint(raw.protocolPublicKeyFingerprint);
  if (!isStrictDeviceId(deviceId) || !protocolSigningAlgorithm || !protocolPublicKeyFingerprint) {
    return null;
  }
  const binding = {
    deviceId,
    protocolSigningAlgorithm,
    protocolPublicKeyFingerprint
  };
  if (requirePublicKey) {
    binding.protocolPublicKeyBytes = raw.protocolPublicKeyBytes || null;
  }
  return binding;
}

function auditCurrentPath(event, fields = {}) {
  const parts = [
    `event=${event}`,
    `session=${fields.sessionId || '-'}`,
    `role=${fields.role || '-'}`,
    `fingerprint=${fields.protocolPublicKeyFingerprint || '-'}`,
    `failure=${fields.failure || '-'}`,
    `reason=${fields.reason || '-'}`
  ];
  if (fields.boundIdentity) {
    parts.push(`bound=${fields.boundIdentity.deviceId || '-'}:${fields.boundIdentity.protocolPublicKeyFingerprint || '-'}`);
  }
  if (fields.presentedIdentity) {
    parts.push(`presented=${fields.presentedIdentity.deviceId || '-'}:${fields.presentedIdentity.protocolPublicKeyFingerprint || '-'}`);
  }
  console.warn(`[audit.current-path] ${parts.join(' ')}`);
}

const CODE_ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; // no 0/O/1/I
function normalizeCodePrefixes(raw) {
  const text = String(raw || '').trim().toUpperCase();
  if (!text) return '';
  const seen = new Set();
  let out = '';
  for (const ch of text) {
    if (!CODE_ALPHABET.includes(ch) || seen.has(ch)) continue;
    seen.add(ch);
    out += ch;
  }
  return out;
}
const INSTANCE_CODE_PREFIXES = normalizeCodePrefixes(process.env.INSTANCE_CODE_PREFIXES || '');
function generateCode(len = CODE_LEN) {
  const bytes = crypto.randomBytes(len);
  if (len <= 0) return '';
  let out = INSTANCE_CODE_PREFIXES
    ? INSTANCE_CODE_PREFIXES[bytes[0] % INSTANCE_CODE_PREFIXES.length]
    : CODE_ALPHABET[bytes[0] % CODE_ALPHABET.length];
  for (let i = 1; i < len; i++) {
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

function normalizeRecordId(x) {
  return String(x || '').trim();
}

function safeClientTag(x) {
  const normalized = String(x || '').trim().replace(/[^a-zA-Z0-9._:-]/g, '');
  if (!normalized) return 'anon';
  return normalized.slice(0, 64);
}

function issueStickyHintCookie(res, shardKey, maxAgeSeconds = STICKY_HINT_COOKIE_MAX_AGE_SECONDS) {
  if (!ENABLE_STICKY_HINT_COOKIE || !res || !shardKey) return;
  res.cookie(STICKY_HINT_COOKIE_NAME, String(shardKey), {
    httpOnly: true,
    secure: STICKY_HINT_COOKIE_SECURE,
    sameSite: STICKY_HINT_COOKIE_SAMESITE,
    path: '/',
    maxAge: Math.max(1, Number(maxAgeSeconds || 0)) * 1000
  });
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

function asyncRoute(handler) {
  return (req, res, next) => {
    Promise.resolve(handler(req, res, next)).catch((error) => {
      console.error(`[HTTP] ${req.method} ${req.originalUrl} failed:`, error);
      if (!res.headersSent) {
        res.status(500).json({ error: 'internal_error' });
      }
      if (typeof next === 'function') next(error);
    });
  };
}

// -------------------- Shared state backend --------------------
const signalingState = createSignalingStateBackend({
  backendName: SIGNALING_STATE_BACKEND,
  instanceId: INSTANCE_ID,
  codeTtlMs: CODE_TTL_MS,
  iceTtlMs: ICE_TTL_MS,
  iceMaxPerSession: ICE_MAX_PER_SESSION,
  roomMembershipTtlMs: ROOM_MEMBERSHIP_TTL_MS,
  legacyBindingTtlMs: LEGACY_BINDING_TTL_MS,
  redisUrl: SIGNALING_REDIS_URL,
  redisKeyPrefix: SIGNALING_REDIS_KEY_PREFIX,
  redisChannelPrefix: SIGNALING_REDIS_CHANNEL_PREFIX,
  redisConnectTimeoutMs: SIGNALING_REDIS_CONNECT_TIMEOUT_MS,
  log: console
});

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
const legacyBindings = new Map(); // code -> { initiator?: ws, responder?: ws }

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
  if (typeof msg.sentAt !== 'undefined' && typeof msg.sentAt !== 'number') return false;
  if (typeof msg.authToken !== 'undefined' && typeof msg.authToken !== 'string') return false;
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

function getOrCreateLegacyBindings(code) {
  const key = safeUpperCode(code);
  if (!key) return null;
  let bindings = legacyBindings.get(key);
  if (!bindings) {
    bindings = { initiator: null, responder: null };
    legacyBindings.set(key, bindings);
  }
  return bindings;
}

function setLocalLegacyBinding(code, role, ws) {
  const bindings = getOrCreateLegacyBindings(code);
  if (!bindings) return;
  bindings[role] = ws;
}

function getLocalLegacyBinding(code, role) {
  const bindings = legacyBindings.get(safeUpperCode(code));
  return bindings ? bindings[role] : null;
}

function clearLocalLegacyBinding(code, role, ws) {
  const key = safeUpperCode(code);
  const bindings = legacyBindings.get(key);
  if (!bindings) return;
  if (!ws || bindings[role] === ws) {
    bindings[role] = null;
  }
  if (!bindings.initiator && !bindings.responder) {
    legacyBindings.delete(key);
  }
}

async function removeFromAllRooms(ws) {
  const meta = wsMeta.get(ws) || null;
  const clientId = meta?.clientId || '';
  for (const [sid, room] of rooms.entries()) {
    if (!room.clients.has(ws)) continue;
    room.clients.delete(ws);
    const removedDeviceIds = [];
    for (const [deviceId, boundWs] of room.clientsByDeviceId.entries()) {
      if (boundWs !== ws) continue;
      room.clientsByDeviceId.delete(deviceId);
      removedDeviceIds.push(deviceId);
    }
    for (const deviceId of removedDeviceIds) {
      await signalingState.removeRoomMember(sid, deviceId, clientId);
    }
    if (room.clients.size === 0) {
      rooms.delete(sid);
    }
  }
}

function wsSendRaw(ws, obj) {
  if (!ws || ws.readyState !== ws.OPEN) return false;
  ws.send(JSON.stringify(obj));
  return true;
}

function makeWebRTCError(error, sessionId = null) {
  const payload = { type: 'error', error };
  if (sessionId) payload.sessionId = sessionId;
  return payload;
}

function sanitizeEnvelopeForPeer(msg, overrideFrom = null) {
  return {
    sessionId: normalizeSessionId(msg.sessionId),
    from: normalizeDeviceId(overrideFrom || msg.from),
    to: typeof msg.to === 'string' ? normalizeDeviceId(msg.to) || undefined : undefined,
    type: msg.type,
    payload: isPlainObject(msg.payload) ? msg.payload : null,
    sentAt: typeof msg.sentAt === 'number' ? msg.sentAt : Math.floor(now() / 1000)
  };
}

function deliverEnvelopeLocally(ws, msg) {
  const sid = normalizeSessionId(msg.sessionId);
  const room = rooms.get(sid);
  if (!room) return false;
  const sanitized = sanitizeEnvelopeForPeer(msg);
  const to = typeof msg.to === 'string' ? normalizeDeviceId(msg.to) : '';
  if (to) {
    const target = room.clientsByDeviceId.get(to);
    if (target && target !== ws) {
      wsSendRaw(target, sanitized);
      return true;
    }
    return false;
  }

  for (const peer of room.clients) {
    if (peer === ws) continue;
    wsSendRaw(peer, sanitized);
  }
  return true;
}

function remoteInstanceIdsForMembers(members, excludeInstanceId) {
  return unique(
    members
      .map((member) => member.instanceId)
      .filter((instanceId) => instanceId && instanceId !== excludeInstanceId)
  );
}

async function forwardEnvelopeToRemoteInstances(msg) {
  const to = typeof msg.to === 'string' ? normalizeDeviceId(msg.to) : '';
  const members = await signalingState.listRoomMembers(msg.sessionId);
  const sanitized = sanitizeEnvelopeForPeer(msg);
  let targetInstances;
  if (to) {
    const directedMember = members.find((member) => member.deviceId === to);
    targetInstances = directedMember ? [directedMember.instanceId] : [];
  } else {
    targetInstances = remoteInstanceIdsForMembers(members, INSTANCE_ID);
  }
  await Promise.all(targetInstances.map((instanceId) => signalingState.publishToInstance(instanceId, {
    kind: 'webrtc-envelope',
    envelope: sanitized
  })));
}

function authMatchesHash(token, hash) {
  if (typeof token !== 'string' || typeof hash !== 'string' || !hash) return false;
  return secureStringEqual(sha256Hex(token), hash);
}

function boundIdentityForRole(item, role) {
  if (role === 'initiator') {
    return {
      deviceId: item.deviceId || null,
      protocolSigningAlgorithm: item.initiatorProtocolSigningAlgorithm || null,
      protocolPublicKeyFingerprint: item.initiatorProtocolPublicKeyFingerprint || null
    };
  }
  if (role === 'responder') {
    return {
      deviceId: item.responderId || null,
      protocolSigningAlgorithm: item.responderProtocolSigningAlgorithm || null,
      protocolPublicKeyFingerprint: item.responderProtocolPublicKeyFingerprint || null
    };
  }
  return null;
}

function authWebRTCEnvelope(item, msg) {
  const token = typeof msg.authToken === 'string' ? msg.authToken : '';
  if (authMatchesHash(token, item.initiatorTokenHash)) {
    return { ok: true, role: 'initiator', boundIdentity: boundIdentityForRole(item, 'initiator') };
  }
  if (authMatchesHash(token, item.responderTokenHash)) {
    return { ok: true, role: 'responder', boundIdentity: boundIdentityForRole(item, 'responder') };
  }
  return { ok: false, role: null, boundIdentity: null };
}

async function handleWebRTCEnvelope(ws, msg) {
  const sid = normalizeSessionId(msg.sessionId);
  const from = normalizeDeviceId(msg.from);
  if (!sid || !from) return wsSendRaw(ws, makeWebRTCError('bad_envelope', sid || null));

  const item = await signalingState.getConnection(sid);
  if (!item) {
    wsSendRaw(ws, makeWebRTCError('unknown_session', sid));
    try { ws.close(1008, 'unknown_session'); } catch {}
    return;
  }
  if (item.connectionKind !== 'webrtc_room_code' && item.connectionKind !== 'webrtc_room_session') {
    wsSendRaw(ws, makeWebRTCError('session_mode_mismatch', sid));
    try { ws.close(1008, 'session_mode_mismatch'); } catch {}
    return;
  }

  const authResult = authWebRTCEnvelope(item, msg);
  if (!authResult.ok && !ALLOW_INSECURE) {
    auditCurrentPath('webrtc-envelope-rejected', {
      sessionId: sid,
      failure: 'authTokenRejected',
      reason: 'token_not_bound'
    });
    wsSendRaw(ws, makeWebRTCError('unauthorized', sid));
    try { ws.close(1008, 'unauthorized'); } catch {}
    return;
  }
  const boundIdentity = authResult.boundIdentity;
  if (boundIdentity?.deviceId && boundIdentity.deviceId !== from) {
    auditCurrentPath('webrtc-envelope-rejected', {
      sessionId: sid,
      role: authResult.role,
      protocolPublicKeyFingerprint: boundIdentity.protocolPublicKeyFingerprint,
      failure: 'identityConflict',
      reason: 'presented_from_mismatch',
      boundIdentity,
      presentedIdentity: {
        deviceId: from,
        protocolPublicKeyFingerprint: boundIdentity.protocolPublicKeyFingerprint
      }
    });
    wsSendRaw(ws, makeWebRTCError('device_mismatch', sid));
    try { ws.close(1008, 'device_mismatch'); } catch {}
    return;
  }

  const room = getOrCreateRoom(sid);
  if (!room) return wsSendRaw(ws, makeWebRTCError('bad_sessionId', sid));

  const meta = wsMeta.get(ws) || { code: null, role: null, clientId: uuidv4(), rate: { t0: now(), c: 0 } };
  const authoritativeFrom = boundIdentity?.deviceId || from;
  if ((meta.sessionId && meta.sessionId !== sid) || (meta.deviceId && meta.deviceId !== authoritativeFrom)) {
    await removeFromAllRooms(ws);
  }

  if (!room.clients.has(ws)) {
    if (room.clients.size >= WS_MAX_CLIENTS_PER_ROOM) {
      return wsSendRaw(ws, makeWebRTCError('room_full', sid));
    }
    room.clients.add(ws);
  }
  const existingClient = room.clientsByDeviceId.get(authoritativeFrom);
  if (existingClient && existingClient !== ws) {
    if (existingClient.readyState === existingClient.OPEN) {
      return wsSendRaw(ws, makeWebRTCError('device_conflict', sid));
    }
    room.clients.delete(existingClient);
    room.clientsByDeviceId.delete(authoritativeFrom);
  }
  room.clientsByDeviceId.set(authoritativeFrom, ws);
  wsMeta.set(ws, { ...meta, sessionId: sid, deviceId: authoritativeFrom, webrtcAuthMode: authResult.role });

  const updatedAt = now();
  await signalingState.upsertRoomMember(sid, {
    deviceId: authoritativeFrom,
    instanceId: INSTANCE_ID,
    clientId: meta.clientId,
    updatedAt,
    expiresAt: updatedAt + ROOM_MEMBERSHIP_TTL_MS
  });

  if (msg.type === 'leave') {
    await signalingState.removeRoomMember(sid, authoritativeFrom, meta.clientId || '');
    room.clients.delete(ws);
    if (room.clientsByDeviceId.get(authoritativeFrom) === ws) {
      room.clientsByDeviceId.delete(authoritativeFrom);
    }
    if (room.clients.size === 0) rooms.delete(sid);
  }

  const sanitized = sanitizeEnvelopeForPeer(msg, authoritativeFrom);
  deliverEnvelopeLocally(ws, sanitized);
  await forwardEnvelopeToRemoteInstances(sanitized);
}

async function handleBackendInstanceMessage(payload) {
  if (!payload || typeof payload !== 'object') return;
  switch (payload.kind) {
    case 'webrtc-envelope':
      if (payload.envelope && typeof payload.envelope === 'object') {
        deliverEnvelopeLocally(null, payload.envelope);
      }
      break;
    case 'legacy-forward': {
      const target = getLocalLegacyBinding(payload.code, payload.targetRole);
      if (target && payload.message && typeof payload.message === 'object') {
        wsSendRaw(target, payload.message);
      }
      break;
    }
    case 'drop-code': {
      const code = safeUpperCode(payload.code);
      const bindings = legacyBindings.get(code);
      if (!bindings) return;
      for (const role of ['initiator', 'responder']) {
        const ws = bindings[role];
        if (!ws) continue;
        try { ws.close(1000, payload.reason || 'remote_cleanup'); } catch {}
      }
      legacyBindings.delete(code);
      break;
    }
    default:
      break;
  }
}

// -------------------- App --------------------
const app = express();
if (TRUST_PROXY) app.set('trust proxy', 1);

app.disable('x-powered-by');
app.use((req, res, next) => {
  res.setHeader('X-SkyBridge-Instance', INSTANCE_ID);
  res.setHeader('X-SkyBridge-State-Backend', SIGNALING_STATE_BACKEND);
  if (INSTANCE_CODE_PREFIXES) {
    res.setHeader('X-SkyBridge-Code-Prefixes', INSTANCE_CODE_PREFIXES);
  }
  next();
});
app.use(express.json({ limit: JSON_LIMIT }));

// CORS + basic security headers (lightweight)
app.use((req, res, next) => {
  // CORS
  const origin = req.headers.origin;
  if (origin && CORS_ORIGIN) {
    const allowList = CORS_ORIGIN.split(',').map(s => s.trim()).filter(Boolean);
    if (allowList.includes(origin)) res.setHeader('Access-Control-Allow-Origin', origin);
  }
  res.setHeader('Access-Control-Allow-Methods', 'GET,POST,OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization, X-API-Key');
  if (req.method === 'OPTIONS') return res.sendStatus(204);

  // Simple hardening
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('Content-Security-Policy', "default-src 'none'");
  next();
});

// -------------------- Health & Root --------------------
app.get('/', asyncRoute(async (req, res) => {
  const backendHealth = await signalingState.getHealth();
  // 之前你 curl -I https://api... 之所以 404，就是没这个路由
  res.status(200).json({
    ok: true,
    service: 'skybridge-signaling',
    time: new Date().toISOString(),
    instanceId: INSTANCE_ID,
    stateBackend: SIGNALING_STATE_BACKEND,
    stickyHintCookieEnabled: ENABLE_STICKY_HINT_COOKIE,
    instanceCodePrefixes: INSTANCE_CODE_PREFIXES || null,
    backendHealth,
    endpoints: [
      '/health',
      '/healthz',
      '/api/register',
      '/api/lookup/:code',
      '/api/answer/:code',
      '/api/ice/:sessionId',
      '/api/turn/credentials',
      '/api/webrtc/register-code',
      '/api/webrtc/lookup/:code',
      '/api/webrtc/register-session',
      '/api/webrtc/redeem-session',
      '/ws'
    ]
  });
}));

app.get('/health', asyncRoute(async (req, res) => {
  const backendHealth = await signalingState.getHealth();
  res.json({
    status: 'ok',
    connections: backendHealth.connections,
    iceSessions: backendHealth.iceSessions,
    wsClients: wss ? wss.clients.size : 0,
    instanceId: INSTANCE_ID,
    stateBackend: SIGNALING_STATE_BACKEND,
    stickyHintCookieEnabled: ENABLE_STICKY_HINT_COOKIE,
    instanceCodePrefixes: INSTANCE_CODE_PREFIXES || null,
    roomMembers: backendHealth.roomMembers,
    legacyBindings: backendHealth.legacyBindings,
    backendReady: backendHealth.ready,
    redisConnected: backendHealth.redisConnected
  });
}));

app.get('/healthz', (req, res) => res.status(200).send('ok'));

// -------------------- API rate limits --------------------
const rlRegister = rateLimit({ windowMs: 60_000, max: 30 });
// Lower default for lookup to reduce code enumeration pressure.
const rlLookup   = rateLimit({ windowMs: 60_000, max: 30 });
const rlAnswer   = rateLimit({ windowMs: 60_000, max: 60 });
const rlIce      = rateLimit({ windowMs: 60_000, max: 240 });
const rlTurn     = rateLimit({ windowMs: 60_000, max: 120 });

function clampSessionTtlMs(rawSeconds, fallbackMs = CODE_TTL_MS) {
  const seconds = Number(rawSeconds);
  if (!Number.isFinite(seconds)) return fallbackMs;
  return Math.max(60_000, Math.min(24 * 3600_000, Math.trunc(seconds * 1000)));
}

function buildConnectionRecord({
  initiatorBinding,
  deviceId = null,
  initiatorDeviceName = null,
  offer = null,
  expiresAt,
  initiatorTokenHash = '',
  responderTokenHash = null,
  qrBootstrapTokenHash = null,
  roomAuthTokenHash = null,
  responderId = null,
  responderProtocolSigningAlgorithm = null,
  responderProtocolPublicKeyFingerprint = null,
  signalingServerOrigin = null,
  connectionKind = 'legacy_offer_answer'
}) {
  const effectiveDeviceId = initiatorBinding?.deviceId || deviceId || '';
  return {
    deviceId: effectiveDeviceId,
    initiatorDeviceName,
    initiatorProtocolSigningAlgorithm: initiatorBinding?.protocolSigningAlgorithm || null,
    initiatorProtocolPublicKeyFingerprint: initiatorBinding?.protocolPublicKeyFingerprint || null,
    offer,
    createdAt: now(),
    expiresAt,
    initiatorTokenHash,
    responderTokenHash,
    qrBootstrapTokenHash,
    qrBootstrapConsumedAt: 0,
    roomAuthTokenHash,
    responderId,
    responderProtocolSigningAlgorithm,
    responderProtocolPublicKeyFingerprint,
    signalingServerOrigin,
    answer: null,
    answerFrom: null,
    connectionKind
  };
}

function assertUniqueSessionParticipant(item, responderBinding) {
  if (item.deviceId === responderBinding.deviceId) {
    return 'device_id_conflict';
  }
  if (item.initiatorProtocolPublicKeyFingerprint === responderBinding.protocolPublicKeyFingerprint) {
    return 'identity_conflict';
  }
  return null;
}

// -------------------- REST API: dynamic TURN credentials --------------------
app.get('/api/turn/credentials', rlTurn, (req, res) => {
  if (TURN_ENFORCE_API_KEY) {
    if (!TURN_CLIENT_API_KEY) {
      return res.status(503).json({ error: 'turn_api_key_not_configured' });
    }
    const apiKey = String(req.get('X-API-Key') || '').trim();
    if (!secureStringEqual(apiKey, TURN_CLIENT_API_KEY)) {
      return res.status(401).json({ error: 'unauthorized' });
    }
  }

  const ttl = Math.max(60, Math.min(24 * 3600, Math.trunc(TURN_CRED_TTL_SECONDS || 3600)));
  if (!TURN_URIS.length) {
    return res.status(503).json({ error: 'turn_uris_not_configured' });
  }

  // Preferred mode: generate short-lived TURN REST credentials from shared secret.
  if (TURN_SHARED_SECRET) {
    const clientTag = safeClientTag(req.get('X-Device-Id') || req.query.deviceId || req.ip);
    const expiresAtEpoch = Math.floor(now() / 1000) + ttl;
    const username = `${expiresAtEpoch}:${clientTag}`;
    const password = crypto.createHmac('sha1', TURN_SHARED_SECRET).update(username).digest('base64');
    return res.json({
      username,
      password,
      ttl,
      expiresAt: expiresAtEpoch,
      uris: TURN_URIS,
      mode: 'shared_secret_hmac'
    });
  }

  // Optional fallback mode: static long-term credentials.
  // Disabled by default to avoid accidentally shipping long-lived shared credentials.
  if (TURN_ALLOW_STATIC_FALLBACK && TURN_STATIC_USERNAME && TURN_STATIC_PASSWORD) {
    return res.json({
      username: TURN_STATIC_USERNAME,
      password: TURN_STATIC_PASSWORD,
      ttl,
      expiresAt: null,
      uris: TURN_URIS,
      mode: 'static_fallback'
    });
  }

  if (!TURN_SHARED_SECRET && TURN_STATIC_USERNAME && TURN_STATIC_PASSWORD && !TURN_ALLOW_STATIC_FALLBACK) {
    return res.status(503).json({ error: 'turn_static_fallback_disabled' });
  }

  return res.status(503).json({ error: 'turn_credentials_not_configured' });
});

// -------------------- REST API: current WebRTC room flow --------------------
app.post('/api/webrtc/register-code', rlRegister, asyncRoute(async (req, res) => {
  const initiatorBinding = normalizeIdentityBinding(req.body || {});
  const deviceName = typeof req.body?.deviceName === 'string' ? req.body.deviceName.slice(0, 128) : null;
  const ttlSeconds = req.body?.ttlSeconds;
  if (!initiatorBinding) {
    return res.status(400).json({ error: 'bad_deviceId' });
  }
  const initiatorToken = newToken();
  const expiresAt = now() + clampSessionTtlMs(ttlSeconds, CODE_TTL_MS);
  const signalingServerOrigin = resolvedSignalingServerOrigin(req);
  const code = await signalingState.createConnectionCode(generateCode, 10, buildConnectionRecord({
    initiatorBinding,
    initiatorDeviceName: deviceName,
    offer: {
      mode: 'webrtc_room_code',
      deviceName
    },
    expiresAt,
    initiatorTokenHash: sha256Hex(initiatorToken),
    signalingServerOrigin,
    connectionKind: 'webrtc_room_code'
  }));
  if (!code) {
    return res.status(500).json({ error: 'code_generation_failed' });
  }
  issueStickyHintCookie(res, code, Math.max(60, Math.round((expiresAt - now()) / 1000)));
  res.json({
    code,
    sessionId: code,
    initiatorToken,
    expiresIn: Math.max(0, Math.round((expiresAt - now()) / 1000)),
    signalingServerOrigin,
    wsPath: '/ws'
  });
}));

app.get('/api/webrtc/lookup/:code', rlLookup, asyncRoute(async (req, res) => {
  const ip = (req.ip || req.connection.remoteAddress || 'unknown');
  if (invalidLookupLimited(ip)) {
    return res.status(429).json({ error: 'rate_limited' });
  }
  const code = safeUpperCode(req.params.code);
  const responderBinding = normalizeIdentityBinding({
    deviceId: req.query.deviceId,
    protocolSigningAlgorithm: req.query.protocolSigningAlgorithm,
    protocolPublicKeyFingerprint: req.query.protocolPublicKeyFingerprint
  });
  if (!responderBinding) {
    return res.status(400).json({ error: 'bad_deviceId' });
  }
  const existing = await signalingState.getConnection(code);
  if (!existing || existing.connectionKind !== 'webrtc_room_code') {
    recordInvalidLookup(ip);
    return res.status(404).json({ found: false });
  }
  const uniquenessError = assertUniqueSessionParticipant(existing, responderBinding);
  if (uniquenessError) {
    auditCurrentPath('lookup-rejected', {
      sessionId: code,
      role: 'responder',
      protocolPublicKeyFingerprint: responderBinding.protocolPublicKeyFingerprint,
      failure: uniquenessError === 'identity_conflict' ? 'identityConflict' : 'deviceIdMigrationRequired',
      reason: uniquenessError,
      boundIdentity: boundIdentityForRole(existing, 'initiator'),
      presentedIdentity: responderBinding
    });
    return res.status(409).json({ error: uniquenessError });
  }
  const responderToken = newToken();
  const result = await signalingState.bindResponder(code, {
    responderTokenHash: sha256Hex(responderToken),
    responderId: responderBinding.deviceId,
    responderProtocolSigningAlgorithm: responderBinding.protocolSigningAlgorithm,
    responderProtocolPublicKeyFingerprint: responderBinding.protocolPublicKeyFingerprint
  });
  if (!result?.item) {
    recordInvalidLookup(ip);
    return res.status(404).json({ found: false });
  }
  if (result.error) {
    return res.status(409).json({ error: result.error });
  }
  const { item } = result;
  issueStickyHintCookie(res, code, Math.max(60, Math.round((item.expiresAt - now()) / 1000)));
  res.json({
    found: true,
    sessionId: code,
    initiatorDeviceId: item.deviceId,
    initiatorProtocolSigningAlgorithm: item.initiatorProtocolSigningAlgorithm,
    initiatorProtocolPublicKeyFingerprint: item.initiatorProtocolPublicKeyFingerprint,
    initiatorDeviceName: item.initiatorDeviceName,
    responderToken,
    expiresIn: Math.max(0, Math.round((item.expiresAt - now()) / 1000))
    ,
    signalingServerOrigin: item.signalingServerOrigin || resolvedSignalingServerOrigin(req)
  });
}));

app.post('/api/webrtc/register-session', rlRegister, asyncRoute(async (req, res) => {
  const requestedSessionId = normalizeRecordId(req.body?.sessionId);
  const initiatorBinding = normalizeIdentityBinding(req.body || {});
  const ttlMs = clampSessionTtlMs(req.body?.ttlSeconds, CODE_TTL_MS);
  if (!initiatorBinding) {
    return res.status(400).json({ error: 'bad_deviceId' });
  }
  const sessionId = (SIGNALING_STATE_BACKEND === 'redis' && requestedSessionId)
    ? requestedSessionId
    : generateCode(Math.max(CODE_LEN + 8, 16));
  if (!sessionId || sessionId.length > 160) {
    return res.status(400).json({ error: 'bad_sessionId' });
  }
  const initiatorSignalingToken = newToken();
  const qrBootstrapToken = newToken();
  const expiresAt = now() + ttlMs;
  const signalingServerOrigin = resolvedSignalingServerOrigin(req);
  const created = await signalingState.createConnectionRecord(sessionId, buildConnectionRecord({
    initiatorBinding,
    offer: { mode: 'webrtc_room_session' },
    expiresAt,
    initiatorTokenHash: sha256Hex(initiatorSignalingToken),
    qrBootstrapTokenHash: sha256Hex(qrBootstrapToken),
    signalingServerOrigin,
    connectionKind: 'webrtc_room_session'
  }));
  if (!created) {
    return res.status(409).json({ error: 'session_exists' });
  }
  issueStickyHintCookie(res, sessionId, Math.max(60, Math.round((expiresAt - now()) / 1000)));
  res.json({
    sessionId,
    initiatorSignalingToken,
    qrBootstrapToken,
    expiresIn: Math.max(0, Math.round((expiresAt - now()) / 1000)),
    signalingServerOrigin,
    wsPath: '/ws'
  });
}));

app.post('/api/webrtc/redeem-session', rlRegister, asyncRoute(async (req, res) => {
  const sessionId = normalizeSessionId(req.body?.sessionId);
  const qrBootstrapToken = typeof req.body?.qrBootstrapToken === 'string' ? req.body.qrBootstrapToken.trim() : '';
  const responderBinding = normalizeIdentityBinding(req.body || {});
  if (!sessionId) {
    return res.status(400).json({ error: 'bad_sessionId' });
  }
  if (!qrBootstrapToken) {
    return res.status(400).json({ error: 'bad_qrBootstrapToken' });
  }
  if (!responderBinding) {
    return res.status(400).json({ error: 'bad_deviceId' });
  }
  const item = await signalingState.getConnection(sessionId);
  if (!item || item.connectionKind !== 'webrtc_room_session') {
    return res.status(404).json({ error: 'session_expired' });
  }
  const uniquenessError = assertUniqueSessionParticipant(item, responderBinding);
  if (uniquenessError) {
    auditCurrentPath('redeem-session-rejected', {
      sessionId,
      role: 'responder',
      protocolPublicKeyFingerprint: responderBinding.protocolPublicKeyFingerprint,
      failure: uniquenessError === 'identity_conflict' ? 'identityConflict' : 'deviceIdMigrationRequired',
      reason: uniquenessError,
      boundIdentity: boundIdentityForRole(item, 'initiator'),
      presentedIdentity: responderBinding
    });
    return res.status(409).json({ error: uniquenessError });
  }
  const responderSignalingToken = newToken();
  const result = await signalingState.bindResponder(sessionId, {
    qrBootstrapTokenHash: sha256Hex(qrBootstrapToken),
    responderTokenHash: sha256Hex(responderSignalingToken),
    responderId: responderBinding.deviceId,
    responderProtocolSigningAlgorithm: responderBinding.protocolSigningAlgorithm,
    responderProtocolPublicKeyFingerprint: responderBinding.protocolPublicKeyFingerprint
  });
  if (!result?.item) {
    return res.status(404).json({ error: 'session_expired' });
  }
  if (result.error === 'bootstrap_token_consumed') {
    return res.status(409).json({ error: 'bootstrap_token_consumed' });
  }
  if (result.error === 'bootstrap_token_invalid') {
    return res.status(401).json({ error: 'auth_token_rejected' });
  }
  if (result.error) {
    return res.status(409).json({ error: result.error });
  }
  res.json({
    sessionId,
    responderSignalingToken,
    expiresIn: Math.max(0, Math.round((result.item.expiresAt - now()) / 1000)),
    signalingServerOrigin: result.item.signalingServerOrigin || resolvedSignalingServerOrigin(req),
    initiatorDeviceId: result.item.deviceId,
    initiatorProtocolSigningAlgorithm: result.item.initiatorProtocolSigningAlgorithm,
    initiatorProtocolPublicKeyFingerprint: result.item.initiatorProtocolPublicKeyFingerprint
  });
}));

// -------------------- REST API: register --------------------
app.post('/api/register', rlRegister, asyncRoute(async (req, res) => {
  const { deviceId, offer } = req.body || {};

  if (typeof deviceId !== 'string' || deviceId.length < 1 || deviceId.length > 128) {
    return res.status(400).json({ error: 'bad_deviceId' });
  }
  if (!isPlainObject(offer)) {
    return res.status(400).json({ error: 'bad_offer' });
  }

  const initiatorToken = newToken();
  const expiresAt = now() + CODE_TTL_MS;

  const code = await signalingState.createConnectionCode(generateCode, 10, buildConnectionRecord({
    deviceId,
    offer,
    expiresAt,
    initiatorTokenHash: sha256Hex(initiatorToken),
    connectionKind: 'legacy_offer_answer'
  }));
  if (!code) return res.status(500).json({ error: 'code_generation_failed' });

  console.log(`[Register] ${deviceId} code=${code} ttl=${Math.round(CODE_TTL_MS / 1000)}s`);
  issueStickyHintCookie(res, code, Math.round(CODE_TTL_MS / 1000));
  res.json({
    code,
    initiatorToken,
    expiresIn: Math.round(CODE_TTL_MS / 1000),
    wsPath: '/ws'
  });
}));

// -------------------- REST API: lookup --------------------
app.get('/api/lookup/:code', rlLookup, asyncRoute(async (req, res) => {
  const ip = (req.ip || req.connection.remoteAddress || 'unknown');
  if (invalidLookupLimited(ip)) {
    return res.status(429).json({ error: 'rate_limited' });
  }
  const code = safeUpperCode(req.params.code);
  const responderId = (typeof req.query.deviceId === 'string' && req.query.deviceId.length <= 128)
    ? req.query.deviceId
    : null;

  const responderToken = newToken();
  const result = await signalingState.bindResponder(code, {
    responderTokenHash: sha256Hex(responderToken),
    responderId
  });
  if (!result?.item) {
    recordInvalidLookup(ip);
    return res.status(404).json({ found: false });
  }
  const { item } = result;

  issueStickyHintCookie(res, code, Math.max(60, Math.round((item.expiresAt - now()) / 1000)));
  res.json({
    found: true,
    deviceId: item.deviceId,
    offer: item.offer,
    // 新增字段（安全模式用）
    sessionId: code,
    responderToken: result.issued ? responderToken : null,
    expiresIn: Math.max(0, Math.round((item.expiresAt - now()) / 1000))
  });
}));

// -------------------- REST API: answer --------------------
app.post('/api/answer/:code', rlAnswer, asyncRoute(async (req, res) => {
  const code = safeUpperCode(req.params.code);
  const item = await signalingState.getConnection(code);
  if (!item) {
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
  const tokenOk = authMatchesHash(token, item.responderTokenHash);
  if (!tokenOk && !ALLOW_INSECURE) {
    return res.status(401).json({ success: false, error: 'unauthorized' });
  }

  const updated = await signalingState.storeAnswer(code, answer, deviceId, deviceId);
  if (!updated) {
    return res.status(404).json({ success: false, error: 'Code not found' });
  }

  const answerMessage = { type: 'answer', code, answer, from: deviceId };
  const localInitiator = getLocalLegacyBinding(code, 'initiator');
  if (localInitiator && localInitiator.readyState === localInitiator.OPEN) {
    localInitiator.send(JSON.stringify(answerMessage));
  } else {
    const initiatorBinding = await signalingState.getLegacyBinding(code, 'initiator');
    if (initiatorBinding?.instanceId && initiatorBinding.instanceId !== INSTANCE_ID) {
      await signalingState.publishToInstance(initiatorBinding.instanceId, {
        kind: 'legacy-forward',
        code,
        targetRole: 'initiator',
        message: answerMessage
      });
    }
  }

  console.log(`[Answer] code=${code} from=${deviceId} tokenOk=${tokenOk}`);
  issueStickyHintCookie(res, code, Math.max(60, Math.round((updated.expiresAt - now()) / 1000)));
  res.json({ success: true });
}));

// -------------------- REST API: ICE candidates (legacy sessionId) --------------------
app.post('/api/ice/:sessionId', rlIce, asyncRoute(async (req, res) => {
  const sessionId = safeUpperCode(req.params.sessionId);
  const { candidate, from, token } = req.body || {};

  if (typeof from !== 'string' || from.length < 1 || from.length > 128) {
    return res.status(400).json({ success: false, error: 'bad_from' });
  }
  if (!isPlainObject(candidate)) {
    return res.status(400).json({ success: false, error: 'bad_candidate' });
  }

  // 如果 sessionId 就是 code，则可做 token 校验（可选）
  const item = await signalingState.getConnection(sessionId);
  if (item) {
    const okInitiator = authMatchesHash(token, item.initiatorTokenHash);
    const okResponder = authMatchesHash(token, item.responderTokenHash);
    if (!okInitiator && !okResponder && !ALLOW_INSECURE) {
      return res.status(401).json({ success: false, error: 'unauthorized' });
    }
  }

  await signalingState.appendIceCandidate(sessionId, { candidate, from, timestamp: now() });

  issueStickyHintCookie(res, sessionId, Math.max(60, Math.round(ICE_TTL_MS / 1000)));
  res.json({ success: true });
}));

app.get('/api/ice/:sessionId', rlIce, asyncRoute(async (req, res) => {
  const sessionId = safeUpperCode(req.params.sessionId);
  const since = req.query.since ? Number(req.query.since) : 0;

  // SECURITY: if this sessionId corresponds to an active code, require a valid token in secure mode.
  // This prevents anyone who guesses a sessionId from polling ICE candidates.
  const item = await signalingState.getConnection(sessionId);
  if (item) {
    const token = (typeof req.query.token === 'string') ? req.query.token : null;
    const okInitiator = authMatchesHash(token, item.initiatorTokenHash);
    const okResponder = authMatchesHash(token, item.responderTokenHash);
    if (!okInitiator && !okResponder && !ALLOW_INSECURE) {
      return res.status(401).json({ success: false, error: 'unauthorized' });
    }
  }

  const candidates = await signalingState.listIceCandidates(sessionId, since);
  issueStickyHintCookie(res, sessionId, Math.max(60, Math.round(ICE_TTL_MS / 1000)));
  res.json({ candidates });
}));

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

async function getItemByCode(code) {
  const c = safeUpperCode(code);
  return signalingState.getConnection(c);
}

async function dropCode(code, reason) {
  const key = safeUpperCode(code);
  const bindings = await signalingState.listLegacyBindings(key);
  for (const binding of bindings) {
    if (binding.instanceId && binding.instanceId !== INSTANCE_ID) {
      await signalingState.publishToInstance(binding.instanceId, {
        kind: 'drop-code',
        code: key,
        reason
      });
    }
  }
  const local = legacyBindings.get(key);
  if (local) {
    for (const role of ['initiator', 'responder']) {
      const ws = local[role];
      if (!ws) continue;
      try { ws.close(1000, reason); } catch {}
    }
    legacyBindings.delete(key);
  }
  await signalingState.deleteConnection(key);
  console.log(`[Cleanup] code=${code} reason=${reason}`);
}

function wsSend(ws, obj) {
  if (!ws || ws.readyState !== ws.OPEN) return false;
  ws.send(JSON.stringify(obj));
  return true;
}

function authWsBind(item, role, token) {
  if (role === 'initiator') {
    return authMatchesHash(token, item.initiatorTokenHash);
  }
  if (role === 'responder') {
    return authMatchesHash(token, item.responderTokenHash);
  }
  return false;
}

wss.on('connection', (ws, req) => {
  const clientId = uuidv4();
  ws.isAlive = true;
  wsMeta.set(ws, { code: null, role: null, clientId, sessionId: null, deviceId: null, rate: { t0: now(), c: 0 } });

  ws.on('pong', () => { ws.isAlive = true; });

  ws.on('message', (raw) => {
    void (async () => {
    // Basic WS message size cap (prevents memory spikes).
    try {
      const buf = Buffer.isBuffer(raw) ? raw : Buffer.from(raw);
      if (buf.length > WS_MAX_MSG_BYTES) {
        wsSend(ws, { type: 'error', error: 'msg_too_large' });
        ws.close(1009, 'message_too_large');
        return;
      }
    } catch (_) {
      // If we cannot measure it, fail closed.
      ws.close(1009, 'message_too_large');
      return;
    }

    // Per-connection rate limiter (10s sliding-ish window).
    const meta0 = wsMeta.get(ws) || { code: null, role: null, clientId };
    const r = meta0.rate || { t0: now(), c: 0 };
    const t = now();
    if ((t - r.t0) > 10_000) {
      r.t0 = t;
      r.c = 0;
    }
    r.c++;
    wsMeta.set(ws, { ...meta0, rate: r });
    if (r.c > WS_MAX_MSGS_PER_10S) {
      wsSend(ws, { type: 'error', error: 'ws_rate_limited' });
      ws.close(1013, 'rate_limited');
      return;
    }

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
        await handleWebRTCEnvelope(ws, msg);
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
        const item = await getItemByCode(code);
        if (!item) return wsSend(ws, { type: 'error', error: 'code_not_found' });

        const ok = authWsBind(item, role, msg.token);
        if (!ok && !ALLOW_INSECURE) {
          ws.close(1008, 'unauthorized');
          return;
        }

        setLocalLegacyBinding(code, role, ws);

        const updatedMeta = { ...meta, code, role };
        wsMeta.set(ws, updatedMeta);
        await signalingState.upsertLegacyBinding(code, role, {
          deviceId: role,
          instanceId: INSTANCE_ID,
          clientId,
          updatedAt: now(),
          expiresAt: now() + LEGACY_BINDING_TTL_MS
        });

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
        const item = await getItemByCode(meta.code);
        if (!item) return wsSend(ws, { type: 'error', error: 'code_not_found' });

        const targetRole = msg.targetRole === 'initiator' ? 'initiator' : 'responder';
        const target = getLocalLegacyBinding(meta.code, targetRole);
        const forwarded = { type: 'signal', code: meta.code, data: msg.data, from: meta.role, fromClientId: clientId };
        if (target) {
          wsSend(target, forwarded);
        } else {
          const binding = await signalingState.getLegacyBinding(meta.code, targetRole);
          if (binding?.instanceId && binding.instanceId !== INSTANCE_ID) {
            await signalingState.publishToInstance(binding.instanceId, {
              kind: 'legacy-forward',
              code: meta.code,
              targetRole,
              message: forwarded
            });
          }
        }
        break;
      }

      case 'ice': {
        // { type:'ice', candidate, targetRole }
        if (!meta.code || !meta.role) return wsSend(ws, { type: 'error', error: 'not_bound' });
        const item = await getItemByCode(meta.code);
        if (!item) return wsSend(ws, { type: 'error', error: 'code_not_found' });

        const targetRole = msg.targetRole === 'initiator' ? 'initiator' : 'responder';
        const target = getLocalLegacyBinding(meta.code, targetRole);
        const forwarded = { type: 'ice', code: meta.code, candidate: msg.candidate, from: meta.role };
        if (target) {
          wsSend(target, forwarded);
        } else {
          const binding = await signalingState.getLegacyBinding(meta.code, targetRole);
          if (binding?.instanceId && binding.instanceId !== INSTANCE_ID) {
            await signalingState.publishToInstance(binding.instanceId, {
              kind: 'legacy-forward',
              code: meta.code,
              targetRole,
              message: forwarded
            });
          }
        }
        break;
      }

      case 'answer': {
        // WS 也允许发 answer（可选）
        // { type:'answer', answer, deviceId }
        if (!meta.code || !meta.role) return wsSend(ws, { type: 'error', error: 'not_bound' });
        if (meta.role !== 'responder') return wsSend(ws, { type: 'error', error: 'bad_role' });

        const item = await getItemByCode(meta.code);
        if (!item) return wsSend(ws, { type: 'error', error: 'code_not_found' });
        if (!isPlainObject(msg.answer)) return wsSend(ws, { type: 'error', error: 'bad_answer' });

        const answerFrom = (typeof msg.deviceId === 'string' && msg.deviceId.length <= 128) ? msg.deviceId : 'responder';
        await signalingState.storeAnswer(meta.code, msg.answer, answerFrom, answerFrom);

        const forwarded = { type: 'answer', code: meta.code, answer: msg.answer, from: answerFrom };
        const target = getLocalLegacyBinding(meta.code, 'initiator');
        if (target) {
          wsSend(target, forwarded);
        } else {
          const binding = await signalingState.getLegacyBinding(meta.code, 'initiator');
          if (binding?.instanceId && binding.instanceId !== INSTANCE_ID) {
            await signalingState.publishToInstance(binding.instanceId, {
              kind: 'legacy-forward',
              code: meta.code,
              targetRole: 'initiator',
              message: forwarded
            });
          }
        }
        wsSend(ws, { type: 'ok', what: 'answer_saved' });
        break;
      }

      default:
        wsSend(ws, { type: 'error', error: 'unknown_type' });
    }
    })().catch((error) => {
      console.error('[WS] message handling failed:', error);
      try { wsSend(ws, { type: 'error', error: 'server_error' }); } catch {}
    });
  });

  ws.on('close', () => {
    void (async () => {
    const meta = wsMeta.get(ws);
    // Cleanup room membership for the new envelope protocol.
    await removeFromAllRooms(ws);
    if (meta && meta.code) {
      if (meta.role === 'initiator' || meta.role === 'responder') {
        clearLocalLegacyBinding(meta.code, meta.role, ws);
        await signalingState.removeLegacyBinding(meta.code, meta.role, meta.clientId || '');
      }
    }
    })().catch((error) => {
      console.error('[WS] close cleanup failed:', error);
    });
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
  void signalingState.sweepExpired().catch((error) => {
    console.error('[sweeper] failed:', error);
  });
}, SWEEP_INTERVAL_MS);

let shuttingDown = false;
async function shutdown() {
  if (shuttingDown) return;
  shuttingDown = true;
  clearInterval(heartbeatTimer);
  clearInterval(sweepTimer);
  await signalingState.close().catch((error) => {
    console.error('[shutdown] backend close failed:', error);
  });
  server.close(() => process.exit(0));
}

process.on('SIGINT', () => {
  void shutdown();
});
process.on('SIGTERM', () => {
  void shutdown();
});

// -------------------- Start --------------------
(async () => {
  await signalingState.init(handleBackendInstanceMessage);
  server.listen(PORT, HOST, () => {
    console.log('========================================');
    console.log('SkyBridge Signaling Server');
    console.log(`Mode: ${USE_NODE_HTTPS ? 'HTTPS' : 'HTTP'}  listening on ${HOST}:${PORT}`);
    console.log(`Instance: ${INSTANCE_ID}  stateBackend=${SIGNALING_STATE_BACKEND}  stickyHintCookie=${ENABLE_STICKY_HINT_COOKIE ? STICKY_HINT_COOKIE_NAME : 'disabled'}  codePrefixes=${INSTANCE_CODE_PREFIXES || 'auto-any'}`);
    if (SIGNALING_STATE_BACKEND === 'redis') {
      console.log(`Redis: ${SIGNALING_REDIS_URL}  keyPrefix=${SIGNALING_REDIS_KEY_PREFIX}  channelPrefix=${SIGNALING_REDIS_CHANNEL_PREFIX}`);
    }
    console.log(`WS:   ${USE_NODE_HTTPS ? 'wss' : 'ws'}://<host>:${PORT}/ws`);
    console.log(`TTL:  code=${Math.round(CODE_TTL_MS / 1000)}s  ice=${Math.round(ICE_TTL_MS / 1000)}s  room=${Math.round(ROOM_MEMBERSHIP_TTL_MS / 1000)}s`);
    console.log(`Security: ALLOW_INSECURE=${ALLOW_INSECURE} WS_MAX_MSG_BYTES=${WS_MAX_MSG_BYTES} WS_MAX_MSGS_PER_10S=${WS_MAX_MSGS_PER_10S} WS_MAX_CLIENTS_PER_ROOM=${WS_MAX_CLIENTS_PER_ROOM}`);
    console.log('========================================');
  });
})().catch((error) => {
  console.error('[startup] failed:', error);
  process.exit(1);
});
