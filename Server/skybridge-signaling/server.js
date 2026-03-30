'use strict';

const http = require('http');
const https = require('https');
const fs = require('fs');
const crypto = require('crypto');
const os = require('os');
const { spawnSync } = require('child_process');

const express = require('express');
const { Webhook } = require('standardwebhooks');
const { WebSocketServer } = require('ws');
const { randomUUID } = require('crypto');

const { AliyunSMSClient } = require('./lib/aliyun_sms');
const { createSignalingStateBackend, unique } = require('./lib/signaling_state_backend');
const { RegistryStore } = require('./lib/registry_store');
const { buildIdempotencyFingerprint, clientIPForRequest } = require('./lib/request_security');

const PORT = Number(process.env.PORT || 8443);
const HOST = process.env.HOST || '0.0.0.0';
const INSTANCE_ID = String(process.env.INSTANCE_ID || `${os.hostname()}-${process.pid}`).trim();
const SIGNALING_STATE_BACKEND = String(process.env.SIGNALING_STATE_BACKEND || 'memory').trim().toLowerCase();
const SIGNALING_REDIS_URL = String(process.env.SIGNALING_REDIS_URL || process.env.REDIS_URL || '').trim();
const SIGNALING_REDIS_KEY_PREFIX = String(process.env.SIGNALING_REDIS_KEY_PREFIX || 'skybridge:signaling:').trim() || 'skybridge:signaling:';
const SIGNALING_REDIS_CHANNEL_PREFIX = String(process.env.SIGNALING_REDIS_CHANNEL_PREFIX || 'skybridge:signaling:channel:').trim() || 'skybridge:signaling:channel:';
const SIGNALING_REDIS_CONNECT_TIMEOUT_MS = Number(process.env.SIGNALING_REDIS_CONNECT_TIMEOUT_MS || 5_000);

const TRUST_PROXY = /^(1|true|yes)$/i.test(process.env.TRUST_PROXY || 'false');
const JSON_LIMIT = process.env.JSON_LIMIT || '64kb';
const CORS_ORIGIN = process.env.CORS_ORIGIN || '';

const CODE_LEN = Number(process.env.CODE_LEN || 8);
const CODE_TTL_MS = Number(process.env.CODE_TTL_MS || 5 * 60_000);
const SWEEP_INTERVAL_MS = Number(process.env.SWEEP_INTERVAL_MS || 10_000);
const ROOM_MEMBERSHIP_TTL_MS = Number(process.env.ROOM_MEMBERSHIP_TTL_MS || 120_000);

const REQUIRE_SHARED_STATE_FOR_PUBLIC_CAPABILITIES = !/^(0|false|no)$/i.test(process.env.REQUIRE_SHARED_STATE_FOR_PUBLIC_CAPABILITIES || 'true');
const SESSION_RECLAIM_WINDOW_MS = Number(process.env.SESSION_RECLAIM_WINDOW_MS || 30_000);

const CHALLENGE_TTL_MS = Number(process.env.CHALLENGE_TTL_MS || 90_000);
const ADMISSION_TOKEN_TTL_MS = Number(process.env.ADMISSION_TOKEN_TTL_MS || 120_000);
const TURN_ADMISSION_TOKEN_TTL_MS = Number(process.env.TURN_ADMISSION_TOKEN_TTL_MS || 60_000);
const TURN_CRED_TTL_SECONDS = Number(process.env.TURN_CRED_TTL_SECONDS || 300);

const MAX_CHALLENGES_PER_DEVICE_PER_10M = Number(process.env.MAX_CHALLENGES_PER_DEVICE_PER_10M || 10);
const MAX_CHALLENGES_PER_USER_PER_10M = Number(process.env.MAX_CHALLENGES_PER_USER_PER_10M || 20);
const MAX_CHALLENGES_PER_IP_PER_10M = Number(process.env.MAX_CHALLENGES_PER_IP_PER_10M || 40);

const WS_MAX_MSG_BYTES = Number(process.env.WS_MAX_MSG_BYTES || 16 * 1024);
const WS_MAX_MSGS_PER_10S = Number(process.env.WS_MAX_MSGS_PER_10S || 60);
const WS_MAX_BYTES_PER_10S = Number(process.env.WS_MAX_BYTES_PER_10S || 128 * 1024);
const WS_MAX_CLIENTS_PER_ROOM = Number(process.env.WS_MAX_CLIENTS_PER_ROOM || 2);

const SDP_MAX_BYTES = Number(process.env.SDP_MAX_BYTES || 12 * 1024);
const ICE_CANDIDATE_MAX_BYTES = Number(process.env.ICE_CANDIDATE_MAX_BYTES || 2048);
const ICE_SDP_MID_MAX_BYTES = Number(process.env.ICE_SDP_MID_MAX_BYTES || 64);
const ICE_MAX_PER_SESSION = Number(process.env.ICE_MAX_PER_SESSION || 40);
const ICE_MAX_BYTES_PER_SESSION = Number(process.env.ICE_MAX_BYTES_PER_SESSION || 64 * 1024);
const ICE_MAX_BYTES_PER_PEER_PER_SESSION = Number(process.env.ICE_MAX_BYTES_PER_PEER_PER_SESSION || 32 * 1024);

const GLOBAL_MIN_CLIENT_VERSION = String(process.env.GLOBAL_MIN_CLIENT_VERSION || '0.0.0').trim();
const GLOBAL_MIN_PROTOCOL_VERSION = String(process.env.GLOBAL_MIN_PROTOCOL_VERSION || '0').trim();
const SIGNALING_BOOTSTRAP_TENANT_MODE = String(process.env.SIGNALING_BOOTSTRAP_TENANT_MODE || '').trim().toLowerCase();
const SIGNALING_BOOTSTRAP_TENANT_ID = String(process.env.SIGNALING_BOOTSTRAP_TENANT_ID || '').trim();
const SIGNALING_ALLOW_BOOTSTRAP_TENANT_POLICY = /^(1|true|yes)$/i.test(process.env.SIGNALING_ALLOW_BOOTSTRAP_TENANT_POLICY || 'false');
const SIGNALING_ALLOW_BOOTSTRAP_DEVICE_AUTH = /^(1|true|yes)$/i.test(process.env.SIGNALING_ALLOW_BOOTSTRAP_DEVICE_AUTH || 'false');

const TURN_SHARED_SECRET = String(process.env.TURN_SHARED_SECRET || '').trim();
const TURN_OPAQUE_TAG_SECRET = String(process.env.TURN_OPAQUE_TAG_SECRET || TURN_SHARED_SECRET || '').trim();
const TURN_URIS = (process.env.TURN_URIS || process.env.TURN_URLS || 'turns:54.92.79.99:5349?transport=tcp,turn:54.92.79.99:3478?transport=udp')
  .split(',')
  .map((s) => s.trim())
  .filter((s) => Boolean(s) && /^(turn:|turns:)/i.test(s));

const SIGNALING_SERVER_ORIGIN = String(process.env.SIGNALING_SERVER_ORIGIN || '').trim();
const CLIENT_IP_HASH_SECRET = String(process.env.CLIENT_IP_HASH_SECRET || process.env.SIGNALING_IP_HASH_SECRET || 'skybridge-ip-hash').trim();
const SUPABASE_SEND_SMS_HOOK_SECRET = String(
  process.env.SUPABASE_SEND_SMS_HOOK_SECRET
  || process.env.SEND_SMS_HOOK_SECRET
  || ''
).trim();
const ALLOWLIST_TENANTS = new Set(
  String(process.env.ALLOWLIST_TENANTS || '')
    .split(',')
    .map((item) => item.trim())
    .filter(Boolean)
);

const REDIS_LATENCY_PROTECTION_P95_MS = Number(process.env.REDIS_LATENCY_PROTECTION_P95_MS || 150);
const REDIS_LATENCY_PROTECTION_WINDOW_SAMPLES = Number(process.env.REDIS_LATENCY_PROTECTION_WINDOW_SAMPLES || 6);

const ENV_DISABLE_CHALLENGE_ADMISSION = /^(1|true|yes)$/i.test(process.env.KILL_SWITCH_DISABLE_CHALLENGE_ADMISSION || 'false');
const ENV_DISABLE_TURN_ISSUANCE = /^(1|true|yes)$/i.test(process.env.KILL_SWITCH_DISABLE_TURN_ISSUANCE || 'false');
const ENV_DISABLE_CODE_FLOWS = /^(1|true|yes)$/i.test(process.env.KILL_SWITCH_DISABLE_CODE_FLOWS || 'false');
const ENV_ALLOWLIST_ONLY = /^(1|true|yes)$/i.test(process.env.KILL_SWITCH_ALLOWLIST_ONLY || 'false');

const STRICT_DEVICE_ID_RE = /^[A-Za-z0-9._:-]{16,128}$/;
const FINGERPRINT_RE = /^[0-9a-f]{64}$/;
const ALLOWED_PROTOCOL_SIGNING_ALGORITHMS = new Set(['Ed25519', 'ML-DSA-65']);
const MLDSA65_PUBLIC_KEY_BYTES = 1952;
const MLDSA65_OID_DER = Buffer.from('608648016503040312', 'hex');
const MLDSA_VERIFY_HELPER = String(process.env.SKYBRIDGE_MLDSA_VERIFY_HELPER || '').trim();
const MLDSA_VERIFY_HELPER_TIMEOUT_MS = Number(process.env.SKYBRIDGE_MLDSA_VERIFY_HELPER_TIMEOUT_MS || 2000);

const TLS_CERT = process.env.TLS_CERT || '';
const TLS_KEY = process.env.TLS_KEY || '';
const TLS_CA = process.env.TLS_CA || '';
const USE_NODE_HTTPS = Boolean(TLS_CERT && TLS_KEY);

function now() { return Date.now(); }

function base64url(buf) {
  return Buffer.from(buf).toString('base64')
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/g, '');
}

function base64urlToBuffer(raw) {
  const value = String(raw || '').trim();
  if (!value) return null;
  const normalized = value.replace(/-/g, '+').replace(/_/g, '/');
  const padded = normalized + '='.repeat((4 - (normalized.length % 4 || 4)) % 4);
  try {
    return Buffer.from(padded, 'base64');
  } catch (_) {
    return null;
  }
}

function newOpaqueToken(bytes = 24) {
  return base64url(crypto.randomBytes(bytes));
}

function sha256Hex(value) {
  return crypto.createHash('sha256').update(String(value)).digest('hex');
}

function secureStringEqual(left, right) {
  if (typeof left !== 'string' || typeof right !== 'string') return false;
  const leftBuf = Buffer.from(left, 'utf8');
  const rightBuf = Buffer.from(right, 'utf8');
  if (leftBuf.length !== rightBuf.length) return false;
  return crypto.timingSafeEqual(leftBuf, rightBuf);
}

function isPlainObject(value) {
  return value && typeof value === 'object' && !Array.isArray(value);
}

function safeUpperCode(value) {
  return String(value || '').trim().toUpperCase();
}

function normalizeDeviceId(value) {
  return String(value || '').trim();
}

function normalizeProtocolSigningAlgorithm(raw) {
  const value = String(raw || '').trim();
  if (ALLOWED_PROTOCOL_SIGNING_ALGORITHMS.has(value)) return value;
  const folded = value.toLowerCase().replace(/[^a-z0-9]/g, '');
  if (folded === 'ed25519') return 'Ed25519';
  if (folded === 'mldsa65') return 'ML-DSA-65';
  return '';
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
  if (!STRICT_DEVICE_ID_RE.test(deviceId) || !protocolSigningAlgorithm || !protocolPublicKeyFingerprint) {
    return null;
  }
  const binding = {
    deviceId,
    protocolSigningAlgorithm,
    protocolPublicKeyFingerprint
  };
  if (requirePublicKey) {
    const publicKeyBytes = decodePublicKeyBytes(raw.protocolPublicKeyBytes);
    if (!publicKeyBytes) {
      return null;
    }
    binding.protocolPublicKeyBytes = publicKeyBytes;
  }
  return binding;
}

function decodePublicKeyBytes(value) {
  if (Buffer.isBuffer(value)) return value;
  if (value instanceof Uint8Array) return Buffer.from(value);
  if (typeof value !== 'string') return null;
  try {
    return Buffer.from(value, 'base64');
  } catch (_) {
    return null;
  }
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

function normalizeVersion(value, fallback = '0') {
  const normalized = String(value || '').trim();
  return normalized || fallback;
}

function compareVersions(left, right) {
  const leftParts = String(left || '0').split('.').map((item) => Number(item));
  const rightParts = String(right || '0').split('.').map((item) => Number(item));
  const length = Math.max(leftParts.length, rightParts.length);
  for (let index = 0; index < length; index += 1) {
    const leftValue = Number.isFinite(leftParts[index]) ? leftParts[index] : 0;
    const rightValue = Number.isFinite(rightParts[index]) ? rightParts[index] : 0;
    if (leftValue > rightValue) return 1;
    if (leftValue < rightValue) return -1;
  }
  return 0;
}

function effectiveMinVersion(globalMin, tenantMin) {
  if (!tenantMin) return globalMin;
  return compareVersions(tenantMin, globalMin) > 0 ? tenantMin : globalMin;
}

function assertVersionGates(clientVersion, protocolVersion, tenantPolicy) {
  const minClientVersion = effectiveMinVersion(GLOBAL_MIN_CLIENT_VERSION, tenantPolicy?.min_supported_client_version || null);
  const minProtocolVersion = effectiveMinVersion(GLOBAL_MIN_PROTOCOL_VERSION, tenantPolicy?.min_supported_protocol_version || null);
  if (compareVersions(clientVersion, minClientVersion) < 0) {
    const error = new Error('client_version_too_old');
    error.statusCode = 426;
    throw error;
  }
  if (compareVersions(protocolVersion, minProtocolVersion) < 0) {
    const error = new Error('protocol_version_too_old');
    error.statusCode = 426;
    throw error;
  }
}

function clampSessionTtlMs(rawSeconds, fallbackMs = CODE_TTL_MS) {
  const seconds = Number(rawSeconds);
  if (!Number.isFinite(seconds)) return fallbackMs;
  return Math.max(60_000, Math.min(24 * 3600_000, Math.trunc(seconds * 1000)));
}

function payloadByteSize(payload) {
  return Buffer.byteLength(JSON.stringify(payload || {}), 'utf8');
}

function makeIPHash(ip) {
  return crypto.createHmac('sha256', CLIENT_IP_HASH_SECRET).update(String(ip || '')).digest('hex');
}

function challengeSignaturePayload(challenge) {
  return Buffer.from([
    'SkyBridge-Admission-Challenge',
    challenge.challengeId,
    challenge.nonce,
    challenge.tenantId,
    challenge.userId,
    challenge.deviceId,
    challenge.clientVersion,
    challenge.protocolVersion
  ].join('\n'), 'utf8');
}

function ed25519RawPublicKeyToSpki(rawKey) {
  if (!Buffer.isBuffer(rawKey) || rawKey.length !== 32) {
    return null;
  }
  const prefix = Buffer.from('302a300506032b6570032100', 'hex');
  return Buffer.concat([prefix, rawKey]);
}

function encodeDerLength(length) {
  if (!Number.isInteger(length) || length < 0) return null;
  if (length < 0x80) return Buffer.from([length]);
  if (length <= 0xff) return Buffer.from([0x81, length]);
  if (length <= 0xffff) return Buffer.from([0x82, (length >> 8) & 0xff, length & 0xff]);
  if (length <= 0xffffff) return Buffer.from([0x83, (length >> 16) & 0xff, (length >> 8) & 0xff, length & 0xff]);
  return null;
}

function rawPublicKeyToSpki(rawKey, algorithmOidDer) {
  if (!Buffer.isBuffer(rawKey) || !Buffer.isBuffer(algorithmOidDer) || !algorithmOidDer.length) {
    return null;
  }
  const oidLength = encodeDerLength(algorithmOidDer.length);
  if (!oidLength) return null;
  const algorithmBody = Buffer.concat([
    Buffer.from([0x06]),
    oidLength,
    algorithmOidDer
  ]);
  const algorithmIdentifierLength = encodeDerLength(algorithmBody.length);
  if (!algorithmIdentifierLength) return null;
  const algorithmIdentifier = Buffer.concat([
    Buffer.from([0x30]),
    algorithmIdentifierLength,
    algorithmBody
  ]);

  const bitStringPayload = Buffer.concat([Buffer.from([0x00]), rawKey]);
  const bitStringLength = encodeDerLength(bitStringPayload.length);
  if (!bitStringLength) return null;
  const subjectPublicKey = Buffer.concat([
    Buffer.from([0x03]),
    bitStringLength,
    bitStringPayload
  ]);

  const spkiBody = Buffer.concat([algorithmIdentifier, subjectPublicKey]);
  const spkiLength = encodeDerLength(spkiBody.length);
  if (!spkiLength) return null;
  return Buffer.concat([
    Buffer.from([0x30]),
    spkiLength,
    spkiBody
  ]);
}

function mldsa65RawPublicKeyToSpki(rawKey) {
  if (!Buffer.isBuffer(rawKey) || rawKey.length !== MLDSA65_PUBLIC_KEY_BYTES) {
    return null;
  }
  return rawPublicKeyToSpki(rawKey, MLDSA65_OID_DER);
}

function verifyMldsa65ChallengeSignature(rawPublicKey, signature, challenge) {
  const spki = mldsa65RawPublicKeyToSpki(rawPublicKey);
  if (!spki) return false;
  try {
    return crypto.verify(
      null,
      challengeSignaturePayload(challenge),
      { key: spki, format: 'der', type: 'spki' },
      signature
    );
  } catch (_) {
    if (!MLDSA_VERIFY_HELPER) return false;
  }

  const helper = MLDSA_VERIFY_HELPER;
  if (!helper) return false;
  try {
    const result = spawnSync(helper, [
      'internal',
      'verify-mldsa',
      '--message-base64', challengeSignaturePayload(challenge).toString('base64'),
      '--signature-base64', signature.toString('base64'),
      '--public-key-base64', rawPublicKey.toString('base64')
    ], {
      encoding: 'utf8',
      timeout: MLDSA_VERIFY_HELPER_TIMEOUT_MS,
      maxBuffer: 64 * 1024
    });
    if (result.error) {
      console.warn('[ML-DSA verify helper] execution failed:', result.error.message);
      return false;
    }
    if (result.status !== 0) {
      if (result.stderr) {
        console.warn('[ML-DSA verify helper] rejected signature:', result.stderr.trim());
      }
      return false;
    }
    return true;
  } catch (error) {
    console.warn('[ML-DSA verify helper] unexpected failure:', error.message);
    return false;
  }
}

function verifyChallengeSignature(binding, signatureBase64, challenge) {
  const signature = Buffer.from(String(signatureBase64 || '').trim(), 'base64');
  if (!signature.length || !binding.protocolPublicKeyBytes) {
    return false;
  }
  if (binding.protocolSigningAlgorithm === 'Ed25519') {
    const spki = ed25519RawPublicKeyToSpki(binding.protocolPublicKeyBytes);
    if (!spki) return false;
    try {
      return crypto.verify(
        null,
        challengeSignaturePayload(challenge),
        { key: spki, format: 'der', type: 'spki' },
        signature
      );
    } catch (_) {
      return false;
    }
  } else if (binding.protocolSigningAlgorithm === 'ML-DSA-65') {
    return verifyMldsa65ChallengeSignature(binding.protocolPublicKeyBytes, signature, challenge);
  } else {
    return false;
  }
}

function normalizeCodePrefixes(raw) {
  const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  const text = String(raw || '').trim().toUpperCase();
  if (!text) return '';
  const seen = new Set();
  let out = '';
  for (const ch of text) {
    if (!alphabet.includes(ch) || seen.has(ch)) continue;
    seen.add(ch);
    out += ch;
  }
  return out;
}

const CODE_ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
const INSTANCE_CODE_PREFIXES = normalizeCodePrefixes(process.env.INSTANCE_CODE_PREFIXES || '');
function generateCode(len = CODE_LEN) {
  const bytes = crypto.randomBytes(len);
  if (len <= 0) return '';
  let out = INSTANCE_CODE_PREFIXES
    ? INSTANCE_CODE_PREFIXES[bytes[0] % INSTANCE_CODE_PREFIXES.length]
    : CODE_ALPHABET[bytes[0] % CODE_ALPHABET.length];
  for (let i = 1; i < len; i += 1) {
    out += CODE_ALPHABET[bytes[i] % CODE_ALPHABET.length];
  }
  return out;
}

function asyncRoute(handler) {
  return (req, res, next) => {
    Promise.resolve(handler(req, res, next)).catch((error) => {
      const statusCode = Number(error.statusCode || error.status || 500);
      const errorCode = String(error.code || error.message || 'internal_error');
      console.error(`[HTTP] ${req.method} ${req.path} failed:`, errorCode);
      if (!res.headersSent) {
        res.status(statusCode).json({ error: errorCode });
      }
      if (typeof next === 'function') next(error);
    });
  };
}

function rateLimit({ windowMs, max, keyFn }) {
  const hits = new Map();
  return (req, res, next) => {
    const key = keyFn ? keyFn(req) : (clientIPForRequest(req, { trustProxy: currentTrustProxy }) || 'unknown');
    const t = now();
    let entry = hits.get(key);
    if (!entry || t > entry.resetAt) {
      entry = { count: 0, resetAt: t + windowMs };
      hits.set(key, entry);
    }
    entry.count += 1;
    if (entry.count > max) {
      incrementSecurityCounter('http_rate_limited');
      res.status(429).json({ error: 'rate_limited' });
      return;
    }
    next();
  };
}

let signalingState = createSignalingStateBackend({
  backendName: SIGNALING_STATE_BACKEND,
  instanceId: INSTANCE_ID,
  codeTtlMs: CODE_TTL_MS,
  iceTtlMs: CODE_TTL_MS,
  iceMaxPerSession: ICE_MAX_PER_SESSION,
  roomMembershipTtlMs: ROOM_MEMBERSHIP_TTL_MS,
  legacyBindingTtlMs: CODE_TTL_MS,
  redisUrl: SIGNALING_REDIS_URL,
  redisKeyPrefix: SIGNALING_REDIS_KEY_PREFIX,
  redisChannelPrefix: SIGNALING_REDIS_CHANNEL_PREFIX,
  redisConnectTimeoutMs: SIGNALING_REDIS_CONNECT_TIMEOUT_MS,
  log: console
});

let registryStore = new RegistryStore();
let smsClient = new AliyunSMSClient();
let currentTrustProxy = TRUST_PROXY;
let currentRequireSharedStateForPublicCapabilities = REQUIRE_SHARED_STATE_FOR_PUBLIC_CAPABILITIES;
let currentAllowBootstrapDeviceAuth = SIGNALING_ALLOW_BOOTSTRAP_DEVICE_AUTH;
const rooms = new Map();
const wsMeta = new WeakMap();
const securityCounters = new Map();
const runtimeProtection = {
  redisAllowlistOnly: false,
  lastControlFlags: {
    allowlistOnly: false,
    disableChallengeAdmission: false,
    disableTurnIssuance: false,
    disableCodeFlows: false,
    allowlistTenants: []
  },
  redisLatencySamples: []
};

function incrementSecurityCounter(name) {
  const current = securityCounters.get(name) || 0;
  securityCounters.set(name, current + 1);
}

function currentSecurityCounters() {
  return Object.fromEntries([...securityCounters.entries()].sort((left, right) => left[0].localeCompare(right[0])));
}

function makeError(code, statusCode = 400) {
  const error = new Error(code);
  error.code = code;
  error.statusCode = statusCode;
  return error;
}

function normalizeSupabaseHookSecret(raw) {
  const value = String(raw || '').trim();
  if (!value) return '';
  return value.replace(/^v1,whsec_/, '');
}

const supabaseSMSHookVerifier = (() => {
  const normalized = normalizeSupabaseHookSecret(SUPABASE_SEND_SMS_HOOK_SECRET);
  if (!normalized) return null;
  return new Webhook(normalized);
})();

function hookHeaderMap(req) {
  return Object.fromEntries(
    Object.entries(req.headers || {}).map(([key, value]) => {
      if (Array.isArray(value)) {
        return [key, value.join(',')];
      }
      return [key, String(value || '')];
    })
  );
}

function appControlFlags() {
  return {
    allowlistOnly: ENV_ALLOWLIST_ONLY || runtimeProtection.lastControlFlags.allowlistOnly || runtimeProtection.redisAllowlistOnly,
    disableChallengeAdmission: ENV_DISABLE_CHALLENGE_ADMISSION || runtimeProtection.lastControlFlags.disableChallengeAdmission,
    disableTurnIssuance: ENV_DISABLE_TURN_ISSUANCE || runtimeProtection.lastControlFlags.disableTurnIssuance,
    disableCodeFlows: ENV_DISABLE_CODE_FLOWS || runtimeProtection.lastControlFlags.disableCodeFlows,
    allowlistTenants: unique([...ALLOWLIST_TENANTS, ...(runtimeProtection.lastControlFlags.allowlistTenants || [])])
  };
}

function isTenantAllowlisted(tenantId) {
  if (!tenantId) return false;
  return appControlFlags().allowlistTenants.includes(tenantId);
}

async function refreshRuntimeProtection() {
  try {
    runtimeProtection.lastControlFlags = await signalingState.readControlFlags();
  } catch (error) {
    console.error('[ops] failed to refresh control flags:', error.message);
  }
  if (SIGNALING_STATE_BACKEND !== 'redis') {
    runtimeProtection.redisAllowlistOnly = false;
    runtimeProtection.redisLatencySamples = [];
    return;
  }
  try {
    const latencyMs = await signalingState.measureLatency();
    runtimeProtection.redisLatencySamples.push(latencyMs);
    if (runtimeProtection.redisLatencySamples.length > REDIS_LATENCY_PROTECTION_WINDOW_SAMPLES) {
      runtimeProtection.redisLatencySamples.shift();
    }
    const sorted = [...runtimeProtection.redisLatencySamples].sort((left, right) => left - right);
    const p95Index = Math.max(0, Math.ceil(sorted.length * 0.95) - 1);
    const p95 = sorted[p95Index] || 0;
    runtimeProtection.redisAllowlistOnly = sorted.length >= REDIS_LATENCY_PROTECTION_WINDOW_SAMPLES && p95 > REDIS_LATENCY_PROTECTION_P95_MS;
  } catch (error) {
    console.error('[ops] failed to measure redis latency:', error.message);
    runtimeProtection.redisAllowlistOnly = true;
  }
}

async function assertPublicCapabilityAvailable(action, tenantId) {
  const health = await signalingState.getHealth();
  if (currentRequireSharedStateForPublicCapabilities) {
    if (SIGNALING_STATE_BACKEND !== 'redis' || !health.ready || !health.redisConnected) {
      incrementSecurityCounter(`fail_closed_${action}`);
      throw makeError('shared_state_unavailable', 503);
    }
  }
  if (appControlFlags().allowlistOnly && !isTenantAllowlisted(tenantId)) {
    incrementSecurityCounter(`allowlist_only_${action}`);
    throw makeError('allowlist_only_mode', 503);
  }
}

function getBearerToken(req) {
  const header = String(req.get('Authorization') || '').trim();
  if (!header.toLowerCase().startsWith('bearer ')) return '';
  return header.slice(7).trim();
}

function getOpaqueHeader(req, name) {
  return String(req.get(name) || '').trim();
}

function tenantIdFromRequest(req) {
  const headerTenant = String(req.get('X-SkyBridge-Tenant-Id') || '').trim();
  if (headerTenant) return headerTenant;
  if (typeof req.body?.tenantId === 'string' && req.body.tenantId.trim()) return req.body.tenantId.trim();
  if (typeof req.query?.tenantId === 'string' && req.query.tenantId.trim()) return req.query.tenantId.trim();
  return '';
}

function deriveTenantIdFromUser(user) {
  const candidates = [
    user?.appMetadata?.tenant_id,
    user?.appMetadata?.tenantId,
    user?.appMetadata?.org_id,
    user?.appMetadata?.workspace_id,
    user?.userMetadata?.tenant_id,
    user?.userMetadata?.tenantId,
    user?.userMetadata?.org_id,
    user?.userMetadata?.workspace_id,
    SIGNALING_BOOTSTRAP_TENANT_ID
  ];
  for (const candidate of candidates) {
    const value = String(candidate || '').trim();
    if (value) return value;
  }
  if (SIGNALING_BOOTSTRAP_TENANT_MODE === 'user_id') {
    const userID = String(user?.id || '').trim();
    if (userID) return userID;
  }
  return '';
}

function syntheticTenantPolicy(tenantId) {
  return {
    tenant_id: tenantId,
    public_signaling_enabled: true,
    allowlist_only: false,
    min_supported_client_version: GLOBAL_MIN_CLIENT_VERSION,
    min_supported_protocol_version: GLOBAL_MIN_PROTOCOL_VERSION,
    synthetic: true
  };
}

function syntheticDeviceRecord(ctx) {
  return {
    tenant_id: ctx.tenantId,
    user_id: ctx.user.id,
    device_id: ctx.binding.deviceId,
    protocol_signing_algorithm: ctx.binding.protocolSigningAlgorithm,
    protocol_public_key_fingerprint: ctx.binding.protocolPublicKeyFingerprint,
    status: 'active',
    synthetic: true
  };
}

async function loadAuthenticatedDeviceContext(req, { requireRegisteredDevice = true } = {}) {
  if (!registryStore.configured) {
    throw makeError('registry_not_configured', 503);
  }
  const accessToken = getBearerToken(req);
  if (!accessToken) {
    throw makeError('missing_bearer_token', 401);
  }
  const binding = normalizeIdentityBinding(req.body || req.query || {}, { requirePublicKey: false });
  if (!binding) {
    throw makeError('bad_device_binding', 400);
  }
  const clientVersion = normalizeVersion(req.body?.clientVersion || req.query?.clientVersion || req.get('X-SkyBridge-Client-Version') || '0.0.0');
  const protocolVersion = normalizeVersion(req.body?.protocolVersion || req.query?.protocolVersion || req.get('X-SkyBridge-Protocol-Version') || '0');

  const user = await registryStore.verifyAccessToken(accessToken);
  if (!user.id) {
    throw makeError('invalid_user_session', 401);
  }
  if (user.isGuest) {
    throw makeError('guest_forbidden', 403);
  }
  const tenantId = tenantIdFromRequest(req) || deriveTenantIdFromUser(user);
  if (!tenantId) {
    throw makeError('missing_tenant_id', 400);
  }
  const tenantPolicy = await registryStore.getTenantPolicy(tenantId);
  const effectiveTenantPolicy = (!tenantPolicy && SIGNALING_ALLOW_BOOTSTRAP_TENANT_POLICY)
    ? syntheticTenantPolicy(tenantId)
    : tenantPolicy;
  if (!effectiveTenantPolicy || !effectiveTenantPolicy.public_signaling_enabled) {
    throw makeError('tenant_public_access_disabled', 403);
  }
  assertVersionGates(clientVersion, protocolVersion, effectiveTenantPolicy);
  let deviceRecord = null;
  if (requireRegisteredDevice) {
    deviceRecord = await registryStore.getRegisteredDevice({
      tenantId,
      userId: user.id,
      deviceId: binding.deviceId,
      protocolSigningAlgorithm: binding.protocolSigningAlgorithm,
      protocolPublicKeyFingerprint: binding.protocolPublicKeyFingerprint
    });
    if (!deviceRecord && currentAllowBootstrapDeviceAuth) {
      deviceRecord = syntheticDeviceRecord({
        tenantId,
        user,
        binding
      });
    }
    if (!deviceRecord) {
      throw makeError('device_not_registered', 403);
    }
    if (deviceRecord.status === 'revoked') {
      throw makeError('device_revoked', 403);
    }
    if (deviceRecord.status === 'frozen') {
      throw makeError('device_frozen', 403);
    }
  }
  return {
    accessToken,
    tenantId,
    user,
    tenantPolicy: effectiveTenantPolicy,
    deviceRecord,
    binding,
    clientVersion,
    protocolVersion,
    ipHash: makeIPHash(clientIPForRequest(req, { trustProxy: currentTrustProxy }) || 'unknown')
  };
}

async function enforceChallengeQuotas(ctx) {
  const windowMs = 10 * 60_000;
  const [deviceCount, userCount, ipCount] = await Promise.all([
    signalingState.incrementWindowCounter(`challenge:device:${ctx.tenantId}:${ctx.binding.deviceId}`, windowMs),
    signalingState.incrementWindowCounter(`challenge:user:${ctx.tenantId}:${ctx.user.id}`, windowMs),
    signalingState.incrementWindowCounter(`challenge:ip:${ctx.ipHash}`, windowMs)
  ]);
  if (deviceCount.count > MAX_CHALLENGES_PER_DEVICE_PER_10M) throw makeError('challenge_device_rate_limited', 429);
  if (userCount.count > MAX_CHALLENGES_PER_USER_PER_10M) throw makeError('challenge_user_rate_limited', 429);
  if (ipCount.count > MAX_CHALLENGES_PER_IP_PER_10M) throw makeError('challenge_ip_rate_limited', 429);
}

async function createIdempotencyGuard(action, key, fingerprint) {
  if (!key) return null;
  const scopedKey = `${action}:${key}`;
  const existing = await signalingState.getEphemeral('idempotency', scopedKey);
  if (existing?.fingerprint && existing.fingerprint !== fingerprint) {
    throw makeError('idempotency_key_reused', 409);
  }
  if (existing?.state === 'completed') {
    return { existing };
  }
  const created = await signalingState.createEphemeral('idempotency', scopedKey, {
    state: 'in_progress',
    action,
    fingerprint,
    issuedAt: now(),
    expiresAt: now() + 10 * 60_000
  });
  if (!created) {
    const latest = await signalingState.getEphemeral('idempotency', scopedKey);
    if (latest?.fingerprint && latest.fingerprint !== fingerprint) {
      throw makeError('idempotency_key_reused', 409);
    }
    if (latest?.state === 'completed') {
      return { existing: latest };
    }
    throw makeError('idempotency_in_progress', 409);
  }
  return { id: scopedKey };
}

async function completeIdempotencyGuard(guard, responseBody) {
  if (!guard?.id) return;
  await signalingState.updateEphemeral('idempotency', guard.id, (record) => {
    record.state = 'completed';
    record.responseBody = responseBody;
    record.completedAt = now();
  });
}

async function cancelIdempotencyGuard(guard) {
  if (!guard?.id) return;
  await signalingState.deleteEphemeral('idempotency', guard.id);
}

function issueEphemeralTokenRecord({ kind, ttlMs, payload }) {
  const token = newOpaqueToken(kind === 'turn_admission_token' ? 24 : 32);
  const tokenHash = sha256Hex(token);
  return {
    token,
    tokenHash,
    record: {
      kind,
      state: 'issued',
      tokenHashPrefix: tokenHash.slice(0, 12),
      issuedAt: now(),
      expiresAt: now() + ttlMs,
      ...payload
    }
  };
}

async function issueSessionArtifacts({ sessionId, role, context, expiresAt }) {
  const deviceSynthetic = Boolean(context.deviceSynthetic || context.deviceRecord?.synthetic);
  const sessionToken = issueEphemeralTokenRecord({
    kind: 'session_token',
    ttlMs: Math.max(1, expiresAt - now()),
    payload: {
      sessionId,
      role,
      tenantId: context.tenantId,
      userId: context.user.id,
      deviceId: context.binding.deviceId,
      protocolSigningAlgorithm: context.binding.protocolSigningAlgorithm,
      protocolPublicKeyFingerprint: context.binding.protocolPublicKeyFingerprint,
      deviceSynthetic,
      clientVersion: context.clientVersion,
      protocolVersion: context.protocolVersion,
      reclaimWindowMs: SESSION_RECLAIM_WINDOW_MS
    }
  });
  const turnAdmissionToken = issueEphemeralTokenRecord({
    kind: 'turn_admission_token',
    ttlMs: TURN_ADMISSION_TOKEN_TTL_MS,
    payload: {
      sessionId,
      role,
      tenantId: context.tenantId,
      userId: context.user.id,
      deviceId: context.binding.deviceId,
      protocolSigningAlgorithm: context.binding.protocolSigningAlgorithm,
      protocolPublicKeyFingerprint: context.binding.protocolPublicKeyFingerprint,
      deviceSynthetic,
      clientVersion: context.clientVersion,
      protocolVersion: context.protocolVersion,
      jti: base64url(crypto.randomBytes(16))
    }
  });
  const sessionCreated = await signalingState.createEphemeral('session_token', sessionToken.tokenHash, sessionToken.record);
  const turnCreated = await signalingState.createEphemeral('turn_admission_token', turnAdmissionToken.tokenHash, turnAdmissionToken.record);
  if (!sessionCreated || !turnCreated) {
    throw makeError('token_issue_failed', 500);
  }
  return {
    sessionToken: sessionToken.token,
    sessionTokenHash: sessionToken.tokenHash,
    turnAdmissionToken: turnAdmissionToken.token,
    turnAdmissionTokenHash: turnAdmissionToken.tokenHash
  };
}

function buildConnectionRecord({
  initiatorContext,
  initiatorDeviceName = null,
  expiresAt,
  qrBootstrapTokenHash = null,
  signalingServerOrigin,
  connectionKind,
  initiatorSessionTokenHash = null,
  initiatorTurnAdmissionTokenHash = null
}) {
  return {
    deviceId: initiatorContext.binding.deviceId,
    initiatorDeviceName,
    initiatorProtocolSigningAlgorithm: initiatorContext.binding.protocolSigningAlgorithm,
    initiatorProtocolPublicKeyFingerprint: initiatorContext.binding.protocolPublicKeyFingerprint,
    offer: { mode: connectionKind },
    createdAt: now(),
    expiresAt,
    initiatorTokenHash: '',
    responderTokenHash: null,
    qrBootstrapTokenHash,
    qrBootstrapConsumedAt: 0,
    roomAuthTokenHash: null,
    connectionKind,
    responderId: null,
    responderProtocolSigningAlgorithm: null,
    responderProtocolPublicKeyFingerprint: null,
    signalingServerOrigin,
    answer: null,
    answerFrom: null,
    tenantId: initiatorContext.tenantId,
    userId: initiatorContext.user.id,
    initiatorSessionTokenHash,
    initiatorTurnAdmissionTokenHash,
    responderSessionTokenHash: null,
    responderTurnAdmissionTokenHash: null,
    revokedAt: 0
  };
}

function assertUniqueSessionParticipant(item, binding) {
  if (item.deviceId === binding.deviceId) {
    return 'device_id_conflict';
  }
  if (item.initiatorProtocolPublicKeyFingerprint === binding.protocolPublicKeyFingerprint) {
    return 'identity_conflict';
  }
  return null;
}

function wsSendRaw(ws, obj) {
  if (!ws || ws.readyState !== ws.OPEN) return false;
  ws.send(JSON.stringify(obj));
  return true;
}

function getOrCreateRoom(sessionId) {
  let room = rooms.get(sessionId);
  if (!room) {
    room = { clients: new Set(), clientsByDeviceId: new Map() };
    rooms.set(sessionId, room);
  }
  return room;
}

function sanitizeEnvelopeForPeer(message, authoritativeFrom) {
  return {
    sessionId: String(message.sessionId || ''),
    from: authoritativeFrom,
    to: typeof message.to === 'string' ? message.to : undefined,
    type: message.type,
    payload: isPlainObject(message.payload) ? message.payload : null,
    sentAt: typeof message.sentAt === 'number' ? message.sentAt : Math.floor(now() / 1000)
  };
}

function isWebRTCEnvelope(message) {
  if (!isPlainObject(message)) return false;
  if (typeof message.sessionId !== 'string') return false;
  if (typeof message.from !== 'string') return false;
  if (typeof message.type !== 'string') return false;
  if (typeof message.sentAt !== 'undefined' && typeof message.sentAt !== 'number') return false;
  return ['join', 'offer', 'answer', 'iceCandidate', 'leave'].includes(message.type);
}

function validateEnvelopeSchema(message) {
  const sessionId = String(message.sessionId || '').trim();
  const from = normalizeDeviceId(message.from);
  if (!sessionId || sessionId.length > 160) return 'bad_session_id';
  if (!STRICT_DEVICE_ID_RE.test(from)) return 'bad_from';
  if (typeof message.to === 'string' && message.to && !STRICT_DEVICE_ID_RE.test(message.to)) return 'bad_to';
  if (!['join', 'offer', 'answer', 'iceCandidate', 'leave'].includes(message.type)) return 'bad_type';
  if (message.payload != null && !isPlainObject(message.payload)) return 'bad_payload';
  if (!message.payload) return null;
  const payload = message.payload;
  if ((message.type === 'offer' || message.type === 'answer')) {
    if (typeof payload.sdp !== 'string' || Buffer.byteLength(payload.sdp, 'utf8') > SDP_MAX_BYTES) {
      return 'bad_sdp';
    }
  }
  if (message.type === 'iceCandidate') {
    if (typeof payload.candidate !== 'string' || Buffer.byteLength(payload.candidate, 'utf8') > ICE_CANDIDATE_MAX_BYTES) {
      return 'bad_candidate';
    }
    if (typeof payload.sdpMid === 'string' && Buffer.byteLength(payload.sdpMid, 'utf8') > ICE_SDP_MID_MAX_BYTES) {
      return 'bad_sdp_mid';
    }
  }
  return null;
}

function remoteInstanceIdsForMembers(members, excludeInstanceId) {
  return unique(
    members
      .map((member) => member.instanceId)
      .filter((instanceId) => instanceId && instanceId !== excludeInstanceId)
  );
}

function iceCandidateHash(from, payload) {
  return sha256Hex(`${from}|${payload.sdpMid || ''}|${payload.sdpMLineIndex || ''}|${payload.candidate || ''}`);
}

async function forwardEnvelopeToRemoteInstances(message) {
  const members = await signalingState.listRoomMembers(message.sessionId);
  const to = typeof message.to === 'string' ? message.to : '';
  let targetInstances = [];
  if (to) {
    const target = members.find((member) => member.deviceId === to);
    targetInstances = target ? [target.instanceId] : [];
  } else {
    targetInstances = remoteInstanceIdsForMembers(members, INSTANCE_ID);
  }
  await Promise.all(targetInstances.map((instanceId) => signalingState.publishToInstance(instanceId, {
    kind: 'webrtc-envelope',
    envelope: message
  })));
}

function deliverEnvelopeLocally(sourceWs, message) {
  const room = rooms.get(message.sessionId);
  if (!room) return;
  if (typeof message.to === 'string' && message.to) {
    const target = room.clientsByDeviceId.get(message.to);
    if (target && target !== sourceWs) {
      wsSendRaw(target, message);
    }
    return;
  }
  for (const peer of room.clients) {
    if (peer === sourceWs) continue;
    wsSendRaw(peer, message);
  }
}

async function removeFromRooms(ws) {
  const meta = wsMeta.get(ws);
  if (!meta?.sessionId || !meta?.deviceId) return;
  const room = rooms.get(meta.sessionId);
  if (room) {
    room.clients.delete(ws);
    if (room.clientsByDeviceId.get(meta.deviceId) === ws) {
      room.clientsByDeviceId.delete(meta.deviceId);
    }
    if (room.clients.size === 0) {
      rooms.delete(meta.sessionId);
    }
  }
  await signalingState.removeRoomMember(meta.sessionId, meta.deviceId, meta.clientId || '');
}

async function dropLocalClientById(clientId, reason = 'remote_reclaim') {
  if (!wss) return;
  for (const client of wss.clients) {
    const meta = wsMeta.get(client);
    if (!meta || meta.clientId !== clientId) continue;
    try {
      client.close(1008, reason);
    } catch (_) {}
  }
}

async function revokeEphemeralIfPresent(kind, tokenHash) {
  if (!tokenHash) return;
  await signalingState.updateEphemeral(kind, tokenHash, (record) => {
    record.state = 'revoked';
    record.revokedAt = now();
  });
}

async function killSession(sessionId, reason) {
  const record = await signalingState.updateConnection(sessionId, (item) => {
    item.revokedAt = now();
  });
  if (record) {
    await Promise.all([
      revokeEphemeralIfPresent('session_token', record.initiatorSessionTokenHash),
      revokeEphemeralIfPresent('session_token', record.responderSessionTokenHash),
      revokeEphemeralIfPresent('turn_admission_token', record.initiatorTurnAdmissionTokenHash),
      revokeEphemeralIfPresent('turn_admission_token', record.responderTurnAdmissionTokenHash)
    ]);
  }
  const room = rooms.get(sessionId);
  if (room) {
    for (const ws of room.clients) {
      try {
        ws.close(1008, reason);
      } catch (_) {}
    }
    rooms.delete(sessionId);
  }
  const members = await signalingState.listRoomMembers(sessionId);
  await Promise.all(members.map((member) => {
    if (member.instanceId && member.instanceId !== INSTANCE_ID) {
      return signalingState.publishToInstance(member.instanceId, {
        kind: 'close-session',
        sessionId,
        reason
      });
    }
    return Promise.resolve();
  }));
}

async function consumeAdmissionToken(req, action) {
  const rawToken = getOpaqueHeader(req, 'X-SkyBridge-Admission');
  if (!rawToken) {
    throw makeError('missing_admission_token', 401);
  }
  const tokenHash = sha256Hex(rawToken);
  let consumeError = null;
  const record = await signalingState.updateEphemeral('admission_token', tokenHash, (current) => {
    if (current.state !== 'issued') {
      consumeError = 'admission_token_consumed';
      return false;
    }
    current.state = 'consumed';
    current.consumedAt = now();
    current.consumedBy = action;
  });
  if (!record) throw makeError('admission_token_expired', 401);
  if (consumeError) throw makeError(consumeError, 409);
  return record;
}

function deriveTurnOpaqueTag(label, value, bytes = 12) {
  if (!TURN_OPAQUE_TAG_SECRET) {
    throw makeError('turn_tag_secret_not_configured', 503);
  }
  return base64url(
    crypto.createHmac('sha256', TURN_OPAQUE_TAG_SECRET)
      .update(`${label}:${value}`)
      .digest()
      .subarray(0, bytes)
  );
}

async function getTurnTokenRecord(req) {
  const rawToken = getOpaqueHeader(req, 'X-SkyBridge-Turn-Admission');
  if (!rawToken) {
    throw makeError('missing_turn_admission_token', 401);
  }
  const tokenHash = sha256Hex(rawToken);
  let consumeError = null;
  const record = await signalingState.updateEphemeral('turn_admission_token', tokenHash, (current) => {
    if (current.state !== 'issued') {
      consumeError = 'turn_admission_token_consumed';
      return false;
    }
    current.state = 'consumed';
    current.consumedAt = now();
  });
  if (!record) throw makeError('turn_admission_token_expired', 401);
  if (consumeError) throw makeError(consumeError, 409);
  return record;
}

async function handleBackendInstanceMessage(payload) {
  if (!payload || typeof payload !== 'object') return;
  switch (payload.kind) {
    case 'webrtc-envelope':
      if (payload.envelope && typeof payload.envelope === 'object') {
        deliverEnvelopeLocally(null, payload.envelope);
      }
      break;
    case 'close-session':
      await killSession(payload.sessionId, payload.reason || 'remote_kill');
      break;
    case 'drop-client':
      await dropLocalClientById(payload.clientId, payload.reason || 'remote_reclaim');
      break;
    default:
      break;
  }
}

const app = express();
if (TRUST_PROXY) app.set('trust proxy', 1);
app.disable('x-powered-by');
app.use((req, res, next) => {
  res.setHeader('X-SkyBridge-Instance', INSTANCE_ID);
  res.setHeader('X-SkyBridge-State-Backend', SIGNALING_STATE_BACKEND);
  next();
});
app.use(express.json({
  limit: JSON_LIMIT,
  verify: (req, res, buf) => {
    req.rawBody = buf.toString('utf8');
  }
}));

app.use((req, res, next) => {
  const origin = req.headers.origin;
  if (origin && CORS_ORIGIN) {
    const allowList = CORS_ORIGIN.split(',').map((item) => item.trim()).filter(Boolean);
    if (allowList.includes(origin)) {
      res.setHeader('Access-Control-Allow-Origin', origin);
    }
  }
  res.setHeader('Access-Control-Allow-Methods', 'GET,POST,OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization, Idempotency-Key, X-SkyBridge-Tenant-Id, X-SkyBridge-Admission, X-SkyBridge-Turn-Admission, X-SkyBridge-Client-Version, X-SkyBridge-Protocol-Version');
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('Content-Security-Policy', "default-src 'none'");
  if (req.method === 'OPTIONS') return res.sendStatus(204);
  next();
});

const rlControl = rateLimit({ windowMs: 60_000, max: 60 });
const rlLookup = rateLimit({ windowMs: 60_000, max: 30 });
const rlTurn = rateLimit({ windowMs: 60_000, max: 60 });
const rlAdmission = rateLimit({ windowMs: 60_000, max: 60 });

app.get('/', asyncRoute(async (req, res) => {
  const backendHealth = await signalingState.getHealth();
  res.status(200).json({
    ok: true,
    service: 'skybridge-signaling',
    time: new Date().toISOString(),
    instanceId: INSTANCE_ID,
    stateBackend: SIGNALING_STATE_BACKEND,
    smsProvider: smsClient.provider,
    backendHealth,
    protection: {
      ...appControlFlags(),
      redisLatencySamples: runtimeProtection.redisLatencySamples
    },
    endpoints: [
      '/health',
      '/healthz',
      '/api/hooks/supabase/send-sms',
      '/api/webrtc/admission/challenge',
      '/api/webrtc/admission',
      '/api/webrtc/register-code',
      '/api/webrtc/lookup/:code',
      '/api/webrtc/register-session',
      '/api/webrtc/redeem-session',
      '/api/turn/credentials',
      '/api/devices/enroll/first',
      '/api/devices/enroll/confirm',
      '/ws?shard=<session_id>&st=<session_token>'
    ]
  });
}));

app.get('/health', asyncRoute(async (req, res) => {
  const backendHealth = await signalingState.getHealth();
  res.json({
    status: 'ok',
    instanceId: INSTANCE_ID,
    stateBackend: SIGNALING_STATE_BACKEND,
    smsProvider: smsClient.provider,
    backendHealth,
    protection: {
      ...appControlFlags(),
      redisLatencySamples: runtimeProtection.redisLatencySamples
    },
    counters: currentSecurityCounters(),
    wsClients: wss ? wss.clients.size : 0
  });
}));

app.get('/healthz', (req, res) => res.status(200).send('ok'));

app.post('/api/hooks/supabase/send-sms', asyncRoute(async (req, res) => {
  if (!supabaseSMSHookVerifier) {
    throw makeError('supabase_send_sms_hook_not_configured', 503);
  }
  if (!smsClient.configured) {
    throw makeError('aliyun_sms_not_configured', 503);
  }

  const payload = typeof req.rawBody === 'string' && req.rawBody.length > 0
    ? req.rawBody
    : JSON.stringify(req.body || {});

  let hookPayload;
  try {
    hookPayload = supabaseSMSHookVerifier.verify(payload, hookHeaderMap(req));
  } catch (error) {
    incrementSecurityCounter('supabase_send_sms_hook_verify_failed');
    console.error('[hook] Supabase send_sms verification failed:', error.message);
    throw makeError('supabase_send_sms_hook_invalid', 401);
  }

  const otp = String(hookPayload?.sms?.otp || '').trim();
  const phoneNumber = String(hookPayload?.user?.phone || '').trim();
  if (!otp || !phoneNumber) {
    throw makeError('bad_send_sms_payload', 400);
  }

  try {
    const result = await smsClient.sendVerificationCode({ phoneNumber, otp });
    console.log(`[hook] send_sms delivered phone=${phoneNumber.slice(-4)} requestId=${result.requestId || 'n/a'} bizId=${result.bizId || 'n/a'}`);
    res.status(200).json({});
  } catch (error) {
    incrementSecurityCounter('supabase_send_sms_delivery_failed');
    console.error('[hook] Aliyun SMS delivery failed:', error.message);
    throw makeError('sms_delivery_failed', 502);
  }
}));

app.post('/api/webrtc/admission/challenge', rlAdmission, asyncRoute(async (req, res) => {
  const context = await loadAuthenticatedDeviceContext(req, { requireRegisteredDevice: true });
  await assertPublicCapabilityAvailable('challenge', context.tenantId);
  if (appControlFlags().disableChallengeAdmission) {
    throw makeError('challenge_disabled', 503);
  }
  await enforceChallengeQuotas(context);
  const challengeId = randomUUID();
  const challenge = {
    challengeId,
    nonce: newOpaqueToken(32),
    tenantId: context.tenantId,
    userId: context.user.id,
    deviceId: context.binding.deviceId,
    clientIpHash: context.ipHash,
    clientVersion: context.clientVersion,
    protocolVersion: context.protocolVersion,
    state: 'issued',
    issuedAt: now(),
    expiresAt: now() + CHALLENGE_TTL_MS
  };
  const created = await signalingState.createEphemeral('challenge', challengeId, challenge);
  if (!created) {
    throw makeError('challenge_issue_failed', 500);
  }
  res.json(challenge);
}));

app.post('/api/webrtc/admission', rlAdmission, asyncRoute(async (req, res) => {
  const context = await loadAuthenticatedDeviceContext(req, { requireRegisteredDevice: true });
  await assertPublicCapabilityAvailable('admission', context.tenantId);
  if (appControlFlags().disableChallengeAdmission) {
    throw makeError('admission_disabled', 503);
  }
  const challengeId = String(req.body?.challengeId || '').trim();
  const signature = String(req.body?.signature || '').trim();
  const publicBinding = normalizeIdentityBinding(req.body || {}, { requirePublicKey: true });
  if (!challengeId || !signature || !publicBinding) {
    throw makeError('bad_admission_request', 400);
  }
  if (!secureStringEqual(publicBinding.protocolPublicKeyFingerprint, context.binding.protocolPublicKeyFingerprint)) {
    throw makeError('public_key_fingerprint_mismatch', 400);
  }
  let consumeError = null;
  const challenge = await signalingState.updateEphemeral('challenge', challengeId, (current) => {
    if (current.state !== 'issued') {
      consumeError = 'challenge_consumed';
      return false;
    }
    if (
      current.tenantId !== context.tenantId
      || current.userId !== context.user.id
      || current.deviceId !== context.binding.deviceId
      || current.clientIpHash !== context.ipHash
      || current.clientVersion !== context.clientVersion
      || current.protocolVersion !== context.protocolVersion
    ) {
      consumeError = 'challenge_context_mismatch';
      return false;
    }
    current.state = 'consumed';
    current.consumedAt = now();
  });
  if (!challenge) throw makeError('challenge_expired', 401);
  if (consumeError) throw makeError(consumeError, 409);
  if (!verifyChallengeSignature(publicBinding, signature, challenge)) {
    incrementSecurityCounter('admission_signature_rejected');
    throw makeError('admission_signature_invalid', 401);
  }
  const admission = issueEphemeralTokenRecord({
    kind: 'admission_token',
    ttlMs: ADMISSION_TOKEN_TTL_MS,
    payload: {
      tenantId: context.tenantId,
      userId: context.user.id,
      deviceId: context.binding.deviceId,
      protocolSigningAlgorithm: context.binding.protocolSigningAlgorithm,
      protocolPublicKeyFingerprint: context.binding.protocolPublicKeyFingerprint,
      deviceSynthetic: Boolean(context.deviceRecord?.synthetic),
      clientVersion: context.clientVersion,
      protocolVersion: context.protocolVersion,
      challengeId
    }
  });
  const created = await signalingState.createEphemeral('admission_token', admission.tokenHash, admission.record);
  if (!created) throw makeError('admission_issue_failed', 500);
  res.json({
    admissionToken: admission.token,
    state: 'issued',
    issuedAt: admission.record.issuedAt,
    expiresAt: admission.record.expiresAt
  });
}));

app.post('/api/webrtc/register-code', rlControl, asyncRoute(async (req, res) => {
  const admission = await consumeAdmissionToken(req, 'register-code');
  await assertPublicCapabilityAvailable('register_code', admission.tenantId);
  if (appControlFlags().disableCodeFlows) {
    throw makeError('code_flows_disabled', 503);
  }
  const deviceName = typeof req.body?.deviceName === 'string' ? req.body.deviceName.slice(0, 128) : null;
  const expiresAt = now() + clampSessionTtlMs(req.body?.ttlSeconds, CODE_TTL_MS);
  const context = {
    tenantId: admission.tenantId,
    user: { id: admission.userId },
    binding: {
      deviceId: admission.deviceId,
      protocolSigningAlgorithm: admission.protocolSigningAlgorithm,
      protocolPublicKeyFingerprint: admission.protocolPublicKeyFingerprint
    },
    deviceSynthetic: Boolean(admission.deviceSynthetic),
    clientVersion: admission.clientVersion,
    protocolVersion: admission.protocolVersion
  };
  const artifacts = await issueSessionArtifacts({ sessionId: '', role: 'initiator', context, expiresAt });
  const code = await signalingState.createConnectionCode(generateCode, 10, buildConnectionRecord({
    initiatorContext: context,
    initiatorDeviceName: deviceName,
    expiresAt,
    signalingServerOrigin: resolvedSignalingServerOrigin(req),
    connectionKind: 'webrtc_room_code',
    initiatorSessionTokenHash: artifacts.sessionTokenHash,
    initiatorTurnAdmissionTokenHash: artifacts.turnAdmissionTokenHash
  }));
  if (!code) throw makeError('code_generation_failed', 500);
  await signalingState.updateEphemeral('session_token', artifacts.sessionTokenHash, (record) => {
    record.sessionId = code;
  });
  await signalingState.updateEphemeral('turn_admission_token', artifacts.turnAdmissionTokenHash, (record) => {
    record.sessionId = code;
  });
  res.json({
    code,
    sessionId: code,
    sessionToken: artifacts.sessionToken,
    turnAdmissionToken: artifacts.turnAdmissionToken,
    expiresIn: Math.max(0, Math.round((expiresAt - now()) / 1000)),
    signalingServerOrigin: resolvedSignalingServerOrigin(req),
    wsPath: '/ws'
  });
}));

app.get('/api/webrtc/lookup/:code', rlLookup, asyncRoute(async (req, res) => {
  const admission = await consumeAdmissionToken(req, 'lookup-code');
  await assertPublicCapabilityAvailable('lookup_code', admission.tenantId);
  if (appControlFlags().disableCodeFlows) {
    throw makeError('code_flows_disabled', 503);
  }
  const code = safeUpperCode(req.params.code);
  const item = await signalingState.getConnection(code);
  if (!item || item.connectionKind !== 'webrtc_room_code') {
    incrementSecurityCounter('lookup_not_found');
    return res.status(404).json({ found: false });
  }
  const binding = {
    deviceId: admission.deviceId,
    protocolSigningAlgorithm: admission.protocolSigningAlgorithm,
    protocolPublicKeyFingerprint: admission.protocolPublicKeyFingerprint
  };
  const uniquenessError = assertUniqueSessionParticipant(item, binding);
  if (uniquenessError) {
    throw makeError(uniquenessError, 409);
  }
  const context = {
    tenantId: admission.tenantId,
    user: { id: admission.userId },
    binding,
    deviceSynthetic: Boolean(admission.deviceSynthetic),
    clientVersion: admission.clientVersion,
    protocolVersion: admission.protocolVersion
  };
  const artifacts = await issueSessionArtifacts({ sessionId: code, role: 'responder', context, expiresAt: item.expiresAt });
  const result = await signalingState.bindResponder(code, {
    responderId: binding.deviceId,
    responderProtocolSigningAlgorithm: binding.protocolSigningAlgorithm,
    responderProtocolPublicKeyFingerprint: binding.protocolPublicKeyFingerprint,
    responderSessionTokenHash: artifacts.sessionTokenHash,
    responderTurnAdmissionTokenHash: artifacts.turnAdmissionTokenHash
  });
  if (!result?.item) {
    return res.status(404).json({ found: false });
  }
  if (result.error) {
    throw makeError(result.error, 409);
  }
  res.json({
    found: true,
    sessionId: code,
    initiatorDeviceId: result.item.deviceId,
    initiatorProtocolSigningAlgorithm: result.item.initiatorProtocolSigningAlgorithm,
    initiatorProtocolPublicKeyFingerprint: result.item.initiatorProtocolPublicKeyFingerprint,
    initiatorDeviceName: result.item.initiatorDeviceName,
    sessionToken: artifacts.sessionToken,
    turnAdmissionToken: artifacts.turnAdmissionToken,
    expiresIn: Math.max(0, Math.round((result.item.expiresAt - now()) / 1000)),
    signalingServerOrigin: result.item.signalingServerOrigin || resolvedSignalingServerOrigin(req)
  });
}));

app.post('/api/webrtc/register-session', rlControl, asyncRoute(async (req, res) => {
  const idempotencyKey = String(req.get('Idempotency-Key') || req.get('X-SkyBridge-Idempotency-Key') || '').trim();
  const registerSessionFingerprint = buildIdempotencyFingerprint({
    action: 'register-session',
    body: req.body || {},
    admissionToken: getOpaqueHeader(req, 'X-SkyBridge-Admission'),
    backendName: SIGNALING_STATE_BACKEND,
    fallbackTtlMs: CODE_TTL_MS
  });
  const idempotency = await createIdempotencyGuard('register-session', idempotencyKey, registerSessionFingerprint);
  if (idempotency?.existing?.responseBody) {
    return res.json(idempotency.existing.responseBody);
  }
  try {
    const admission = await consumeAdmissionToken(req, 'register-session');
    await assertPublicCapabilityAvailable('register_session', admission.tenantId);
    if (appControlFlags().disableCodeFlows) {
      throw makeError('code_flows_disabled', 503);
    }
    const requestedSessionId = String(req.body?.sessionId || '').trim();
    const sessionId = (SIGNALING_STATE_BACKEND === 'redis' && requestedSessionId) ? requestedSessionId : generateCode(Math.max(CODE_LEN + 8, 16));
    const expiresAt = now() + clampSessionTtlMs(req.body?.ttlSeconds, CODE_TTL_MS);
    const context = {
      tenantId: admission.tenantId,
      user: { id: admission.userId },
      binding: {
        deviceId: admission.deviceId,
        protocolSigningAlgorithm: admission.protocolSigningAlgorithm,
        protocolPublicKeyFingerprint: admission.protocolPublicKeyFingerprint
      },
      deviceSynthetic: Boolean(admission.deviceSynthetic),
      clientVersion: admission.clientVersion,
      protocolVersion: admission.protocolVersion
    };
    const artifacts = await issueSessionArtifacts({ sessionId, role: 'initiator', context, expiresAt });
    const qrBootstrapToken = newOpaqueToken(24);
    const created = await signalingState.createConnectionRecord(sessionId, buildConnectionRecord({
      initiatorContext: context,
      expiresAt,
      qrBootstrapTokenHash: sha256Hex(qrBootstrapToken),
      signalingServerOrigin: resolvedSignalingServerOrigin(req),
      connectionKind: 'webrtc_room_session',
      initiatorSessionTokenHash: artifacts.sessionTokenHash,
      initiatorTurnAdmissionTokenHash: artifacts.turnAdmissionTokenHash
    }));
    if (!created) throw makeError('session_exists', 409);
    const responseBody = {
      sessionId,
      sessionToken: artifacts.sessionToken,
      qrBootstrapToken,
      turnAdmissionToken: artifacts.turnAdmissionToken,
      expiresIn: Math.max(0, Math.round((expiresAt - now()) / 1000)),
      signalingServerOrigin: resolvedSignalingServerOrigin(req),
      wsPath: '/ws'
    };
    await completeIdempotencyGuard(idempotency, responseBody);
    res.json(responseBody);
  } catch (error) {
    await cancelIdempotencyGuard(idempotency);
    throw error;
  }
}));

app.post('/api/webrtc/redeem-session', rlControl, asyncRoute(async (req, res) => {
  const idempotencyKey = String(req.get('Idempotency-Key') || req.get('X-SkyBridge-Idempotency-Key') || '').trim();
  const redeemSessionFingerprint = buildIdempotencyFingerprint({
    action: 'redeem-session',
    body: req.body || {},
    admissionToken: getOpaqueHeader(req, 'X-SkyBridge-Admission'),
    backendName: SIGNALING_STATE_BACKEND,
    fallbackTtlMs: CODE_TTL_MS
  });
  const idempotency = await createIdempotencyGuard('redeem-session', idempotencyKey, redeemSessionFingerprint);
  if (idempotency?.existing?.responseBody) {
    return res.json(idempotency.existing.responseBody);
  }
  try {
    const admission = await consumeAdmissionToken(req, 'redeem-session');
    await assertPublicCapabilityAvailable('redeem_session', admission.tenantId);
    if (appControlFlags().disableCodeFlows) {
      throw makeError('code_flows_disabled', 503);
    }
    const sessionId = String(req.body?.sessionId || '').trim();
    const qrBootstrapToken = String(req.body?.qrBootstrapToken || '').trim();
    if (!sessionId || !qrBootstrapToken) {
      throw makeError('bad_redeem_request', 400);
    }
    const item = await signalingState.getConnection(sessionId);
    if (!item || item.connectionKind !== 'webrtc_room_session') {
      throw makeError('session_expired', 404);
    }
    const binding = {
      deviceId: admission.deviceId,
      protocolSigningAlgorithm: admission.protocolSigningAlgorithm,
      protocolPublicKeyFingerprint: admission.protocolPublicKeyFingerprint
    };
    const uniquenessError = assertUniqueSessionParticipant(item, binding);
    if (uniquenessError) {
      throw makeError(uniquenessError, 409);
    }
    const context = {
      tenantId: admission.tenantId,
      user: { id: admission.userId },
      binding,
      deviceSynthetic: Boolean(admission.deviceSynthetic),
      clientVersion: admission.clientVersion,
      protocolVersion: admission.protocolVersion
    };
    const artifacts = await issueSessionArtifacts({ sessionId, role: 'responder', context, expiresAt: item.expiresAt });
    const result = await signalingState.bindResponder(sessionId, {
      qrBootstrapTokenHash: sha256Hex(qrBootstrapToken),
      responderId: binding.deviceId,
      responderProtocolSigningAlgorithm: binding.protocolSigningAlgorithm,
      responderProtocolPublicKeyFingerprint: binding.protocolPublicKeyFingerprint,
      responderSessionTokenHash: artifacts.sessionTokenHash,
      responderTurnAdmissionTokenHash: artifacts.turnAdmissionTokenHash
    });
    if (!result?.item) throw makeError('session_expired', 404);
    if (result.error) {
      throw makeError(result.error === 'bootstrap_token_invalid' ? 'bootstrap_token_invalid' : result.error, result.error === 'bootstrap_token_invalid' ? 401 : 409);
    }
    const responseBody = {
      sessionId,
      sessionToken: artifacts.sessionToken,
      turnAdmissionToken: artifacts.turnAdmissionToken,
      expiresIn: Math.max(0, Math.round((result.item.expiresAt - now()) / 1000)),
      signalingServerOrigin: result.item.signalingServerOrigin || resolvedSignalingServerOrigin(req),
      initiatorDeviceId: result.item.deviceId,
      initiatorProtocolSigningAlgorithm: result.item.initiatorProtocolSigningAlgorithm,
      initiatorProtocolPublicKeyFingerprint: result.item.initiatorProtocolPublicKeyFingerprint
    };
    await completeIdempotencyGuard(idempotency, responseBody);
    res.json(responseBody);
  } catch (error) {
    await cancelIdempotencyGuard(idempotency);
    throw error;
  }
}));

app.get('/api/turn/credentials', rlTurn, asyncRoute(async (req, res) => {
  if (appControlFlags().disableTurnIssuance) {
    throw makeError('turn_issuance_disabled', 503);
  }
  const turnToken = await getTurnTokenRecord(req);
  await assertPublicCapabilityAvailable('turn', turnToken.tenantId);
  if (!TURN_SHARED_SECRET || !TURN_URIS.length) {
    throw makeError('turn_credentials_not_configured', 503);
  }
  let deviceRecord = await registryStore.getRegisteredDevice({
    tenantId: turnToken.tenantId,
    userId: turnToken.userId,
    deviceId: turnToken.deviceId,
    protocolSigningAlgorithm: turnToken.protocolSigningAlgorithm,
    protocolPublicKeyFingerprint: turnToken.protocolPublicKeyFingerprint
  });
  if (!deviceRecord && turnToken.deviceSynthetic) {
    deviceRecord = syntheticDeviceRecord({
      tenantId: turnToken.tenantId,
      user: { id: turnToken.userId },
      binding: {
        deviceId: turnToken.deviceId,
        protocolSigningAlgorithm: turnToken.protocolSigningAlgorithm,
        protocolPublicKeyFingerprint: turnToken.protocolPublicKeyFingerprint
      }
    });
  }
  if (!deviceRecord || deviceRecord.status !== 'active') {
    throw makeError('device_not_active', 403);
  }
  const session = await signalingState.getConnection(turnToken.sessionId);
  if (!session || session.revokedAt) {
    throw makeError('session_inactive', 403);
  }
  const ttl = Math.max(60, Math.min(600, Math.trunc(TURN_CRED_TTL_SECONDS)));
  const expiresAtEpoch = Math.floor(now() / 1000) + ttl;
  const username = `${expiresAtEpoch}:${deriveTurnOpaqueTag('tenant', turnToken.tenantId)}.${deriveTurnOpaqueTag('device', turnToken.deviceId)}.${deriveTurnOpaqueTag('session', turnToken.sessionId)}.${turnToken.jti}`;
  const password = crypto.createHmac('sha1', TURN_SHARED_SECRET).update(username).digest('base64');
  incrementSecurityCounter('turn_issued');
  res.json({
    username,
    password,
    ttl,
    expiresAt: expiresAtEpoch,
    uris: TURN_URIS,
    mode: 'shared_secret_hmac'
  });
}));

app.post('/api/devices/enroll/first', rlControl, asyncRoute(async (req, res) => {
  const context = await loadAuthenticatedDeviceContext(req, { requireRegisteredDevice: false });
  await assertPublicCapabilityAvailable('enroll_first', context.tenantId);
  const inviteToken = String(req.body?.inviteToken || '').trim();
  const deviceName = typeof req.body?.deviceName === 'string' ? req.body.deviceName.slice(0, 128) : '';
  if (!inviteToken) {
    throw makeError('missing_invite_token', 400);
  }
  const result = await registryStore.enrollFirstDevice({
    p_invite_token_hash: sha256Hex(inviteToken),
    p_tenant_id: context.tenantId,
    p_target_user_id: context.user.id,
    p_device_id: context.binding.deviceId,
    p_protocol_signing_algorithm: context.binding.protocolSigningAlgorithm,
    p_protocol_public_key_fingerprint: context.binding.protocolPublicKeyFingerprint,
    p_device_name: deviceName
  });
  res.json({ enrolled: true, device: result });
}));

app.post('/api/devices/register-current', rlControl, asyncRoute(async (req, res) => {
  const context = await loadAuthenticatedDeviceContext(req, { requireRegisteredDevice: false });
  await assertPublicCapabilityAvailable('register_current_device', context.tenantId);
  const deviceName = typeof req.body?.deviceName === 'string' ? req.body.deviceName.slice(0, 128) : '';
  const existing = await registryStore.getRegisteredDevice({
    tenantId: context.tenantId,
    userId: context.user.id,
    deviceId: context.binding.deviceId,
    protocolSigningAlgorithm: context.binding.protocolSigningAlgorithm,
    protocolPublicKeyFingerprint: context.binding.protocolPublicKeyFingerprint
  });
  if (!existing && !currentAllowBootstrapDeviceAuth) {
    throw makeError('device_not_registered', 403);
  }
  const result = await registryStore.bootstrapRegisterDevice({
    p_tenant_id: context.tenantId,
    p_user_id: context.user.id,
    p_device_id: context.binding.deviceId,
    p_protocol_signing_algorithm: context.binding.protocolSigningAlgorithm,
    p_protocol_public_key_fingerprint: context.binding.protocolPublicKeyFingerprint,
    p_device_name: deviceName
  });
  res.json({ registered: true, activated: !existing, device: result });
}));

app.post('/api/devices/enroll/confirm', rlControl, asyncRoute(async (req, res) => {
  const context = await loadAuthenticatedDeviceContext(req, { requireRegisteredDevice: true });
  await assertPublicCapabilityAvailable('enroll_confirm', context.tenantId);
  const pending = normalizeIdentityBinding({
    deviceId: req.body?.pendingDeviceId,
    protocolSigningAlgorithm: req.body?.pendingProtocolSigningAlgorithm,
    protocolPublicKeyFingerprint: req.body?.pendingProtocolPublicKeyFingerprint
  });
  if (!pending) {
    throw makeError('bad_pending_device_binding', 400);
  }
  const deviceName = typeof req.body?.deviceName === 'string' ? req.body.deviceName.slice(0, 128) : '';
  const result = await registryStore.confirmDeviceEnrollment({
    p_tenant_id: context.tenantId,
    p_user_id: context.user.id,
    p_approver_device_id: context.binding.deviceId,
    p_approver_protocol_signing_algorithm: context.binding.protocolSigningAlgorithm,
    p_approver_protocol_public_key_fingerprint: context.binding.protocolPublicKeyFingerprint,
    p_pending_device_id: pending.deviceId,
    p_pending_protocol_signing_algorithm: pending.protocolSigningAlgorithm,
    p_pending_protocol_public_key_fingerprint: pending.protocolPublicKeyFingerprint,
    p_device_name: deviceName
  });
  res.json({ confirmed: true, device: result });
}));

for (const path of ['/api/register', '/api/lookup/:code', '/api/answer/:code', '/api/ice/:sessionId']) {
  app.all(path, (req, res) => res.status(410).json({ error: 'legacy_endpoint_removed' }));
}

const server = (() => {
  if (!USE_NODE_HTTPS) return http.createServer(app);
  const tlsOptions = {
    key: fs.readFileSync(TLS_KEY),
    cert: fs.readFileSync(TLS_CERT)
  };
  if (TLS_CA) tlsOptions.ca = fs.readFileSync(TLS_CA);
  return https.createServer(tlsOptions, app);
})();

let wss = null;
wss = new WebSocketServer({
  server,
  path: '/ws',
  maxPayload: WS_MAX_MSG_BYTES,
  perMessageDeflate: false
});

wss.on('connection', (ws, req) => {
  void (async () => {
    const requestURL = new URL(req.url, 'http://skybridge.local');
    const sessionId = String(requestURL.searchParams.get('shard') || '').trim();
    const sessionToken = String(requestURL.searchParams.get('st') || '').trim();
    const clientVersion = normalizeVersion(requestURL.searchParams.get('cv') || '0.0.0');
    const protocolVersion = normalizeVersion(requestURL.searchParams.get('pv') || '0');
    if (!sessionId || !sessionToken) {
      incrementSecurityCounter('ws_1008_missing_token');
      ws.close(1008, 'missing_session_token');
      return;
    }
    const tokenHash = sha256Hex(sessionToken);
    const tokenPreview = await signalingState.getEphemeral('session_token', tokenHash);
    if (!tokenPreview) {
      incrementSecurityCounter('ws_1008_expired_token');
      ws.close(1008, 'session_token_expired');
      return;
    }
    const tenantPolicy = await registryStore.getTenantPolicy(tokenPreview.tenantId);
    assertVersionGates(
      clientVersion,
      protocolVersion,
      (!tenantPolicy && SIGNALING_ALLOW_BOOTSTRAP_TENANT_POLICY)
        ? syntheticTenantPolicy(tokenPreview.tenantId)
        : tenantPolicy
    );
    await assertPublicCapabilityAvailable('ws', tokenPreview.tenantId);
    const clientId = randomUUID();
    let bindError = null;
    let reclaimTarget = null;
    const boundToken = await signalingState.updateEphemeral('session_token', tokenHash, (record) => {
      if (record.sessionId !== sessionId) {
        bindError = 'session_scope_mismatch';
        return false;
      }
      if (record.state === 'issued') {
        record.state = 'bound';
        record.boundAt = now();
        record.boundInstanceId = INSTANCE_ID;
        record.boundClientId = clientId;
        record.handshakeClientVersion = clientVersion;
        record.handshakeProtocolVersion = protocolVersion;
        return;
      }
      if (record.state === 'bound') {
        const withinWindow = now() - Number(record.boundAt || 0) <= SESSION_RECLAIM_WINDOW_MS;
        const sameScope = record.sessionId === sessionId
          && record.deviceId
          && record.protocolPublicKeyFingerprint
          && record.role;
        if (withinWindow && sameScope) {
          reclaimTarget = {
            instanceId: record.boundInstanceId,
            clientId: record.boundClientId
          };
          record.boundAt = now();
          record.boundInstanceId = INSTANCE_ID;
          record.boundClientId = clientId;
          record.handshakeClientVersion = clientVersion;
          record.handshakeProtocolVersion = protocolVersion;
          return;
        }
        bindError = 'session_token_already_bound';
        return false;
      }
      bindError = 'session_token_not_issuable';
      return false;
    });
    if (!boundToken) {
      incrementSecurityCounter('ws_1008_missing_state');
      ws.close(1008, 'session_token_missing');
      return;
    }
    if (bindError) {
      incrementSecurityCounter('ws_1008_bind_rejected');
      ws.close(1008, bindError);
      return;
    }
    if (reclaimTarget?.clientId && reclaimTarget.instanceId) {
      if (reclaimTarget.instanceId === INSTANCE_ID) {
        await dropLocalClientById(reclaimTarget.clientId, 'reclaimed');
      } else {
        await signalingState.publishToInstance(reclaimTarget.instanceId, {
          kind: 'drop-client',
          clientId: reclaimTarget.clientId,
          reason: 'reclaimed'
        });
      }
    }
    ws.isAlive = true;
    wsMeta.set(ws, {
      clientId,
      sessionId,
      deviceId: boundToken.deviceId,
      role: boundToken.role,
      protocolPublicKeyFingerprint: boundToken.protocolPublicKeyFingerprint,
      tenantId: boundToken.tenantId,
      userId: boundToken.userId,
      tokenHash,
      rate: { t0: now(), count: 0, bytes: 0 }
    });
    const room = getOrCreateRoom(sessionId);
    room.clients.add(ws);
    room.clientsByDeviceId.set(boundToken.deviceId, ws);
    await signalingState.upsertRoomMember(sessionId, {
      deviceId: boundToken.deviceId,
      role: boundToken.role,
      protocolPublicKeyFingerprint: boundToken.protocolPublicKeyFingerprint,
      sessionId,
      instanceId: INSTANCE_ID,
      clientId,
      updatedAt: now(),
      expiresAt: now() + ROOM_MEMBERSHIP_TTL_MS
    });
    wsSendRaw(ws, { type: 'bound', sessionId, role: boundToken.role, clientId });
  })().catch((error) => {
    console.error('[WS] handshake failed:', error.message);
    incrementSecurityCounter('ws_1008_handshake_failed');
    try { ws.close(1008, 'handshake_failed'); } catch (_) {}
  });

  ws.on('pong', () => { ws.isAlive = true; });

  ws.on('message', (raw) => {
    void (async () => {
      const meta = wsMeta.get(ws);
      if (!meta) {
        incrementSecurityCounter('ws_1008_unbound_message');
        ws.close(1008, 'not_bound');
        return;
      }
      const buffer = Buffer.isBuffer(raw) ? raw : Buffer.from(raw);
      const rate = meta.rate || { t0: now(), count: 0, bytes: 0 };
      if ((now() - rate.t0) > 10_000) {
        rate.t0 = now();
        rate.count = 0;
        rate.bytes = 0;
      }
      rate.count += 1;
      rate.bytes += buffer.length;
      meta.rate = rate;
      wsMeta.set(ws, meta);
      if (rate.count > WS_MAX_MSGS_PER_10S) {
        incrementSecurityCounter('ws_1013_rate_limited');
        ws.close(1013, 'rate_limited');
        return;
      }
      if (rate.bytes > WS_MAX_BYTES_PER_10S) {
        incrementSecurityCounter('ws_1009_bytes_limited');
        ws.close(1009, 'bytes_limited');
        return;
      }

      let message;
      try {
        message = JSON.parse(buffer.toString('utf8'));
      } catch (_) {
        incrementSecurityCounter('ws_bad_json');
        wsSendRaw(ws, { type: 'error', error: 'bad_json' });
        return;
      }
      if (!isWebRTCEnvelope(message)) {
        wsSendRaw(ws, { type: 'error', error: 'bad_envelope' });
        return;
      }
      const schemaError = validateEnvelopeSchema(message);
      if (schemaError) {
        wsSendRaw(ws, { type: 'error', error: schemaError, sessionId: meta.sessionId });
        if (schemaError === 'bad_sdp' || schemaError === 'bad_candidate') {
          incrementSecurityCounter('ws_1009_schema_limit');
          ws.close(1009, schemaError);
        }
        return;
      }
      if (message.sessionId !== meta.sessionId || message.from !== meta.deviceId) {
        incrementSecurityCounter('ws_1008_scope_violation');
        ws.close(1008, 'scope_violation');
        return;
      }
      if (message.type === 'iceCandidate') {
        let usage;
        try {
          usage = await signalingState.trackIceUsage(
            meta.sessionId,
            meta.deviceId,
            iceCandidateHash(meta.deviceId, message.payload || {}),
            payloadByteSize(message.payload),
            {
              maxPerSession: ICE_MAX_PER_SESSION,
              maxBytesPerSession: ICE_MAX_BYTES_PER_SESSION,
              maxBytesPerPeerPerSession: ICE_MAX_BYTES_PER_PEER_PER_SESSION
            }
          );
        } catch (error) {
          console.warn('[WS] ICE usage tracking degraded:', {
            sessionId: meta.sessionId,
            deviceId: meta.deviceId,
            reason: error?.message || String(error)
          });
          usage = { accepted: true, duplicate: false, killed: false, degraded: true };
        }
        if (usage.killed) {
          incrementSecurityCounter('ice_killed_session');
          await killSession(meta.sessionId, usage.reason || 'ice_limit');
          return;
        }
        if (usage.duplicate) {
          incrementSecurityCounter('ice_duplicate_dropped');
          return;
        }
      }
      const room = getOrCreateRoom(meta.sessionId);
      if (!room.clients.has(ws)) {
        room.clients.add(ws);
      }
      room.clientsByDeviceId.set(meta.deviceId, ws);
      await signalingState.upsertRoomMember(meta.sessionId, {
        deviceId: meta.deviceId,
        role: meta.role,
        protocolPublicKeyFingerprint: meta.protocolPublicKeyFingerprint,
        sessionId: meta.sessionId,
        instanceId: INSTANCE_ID,
        clientId: meta.clientId,
        updatedAt: now(),
        expiresAt: now() + ROOM_MEMBERSHIP_TTL_MS
      });
      const outbound = sanitizeEnvelopeForPeer(message, meta.deviceId);
      deliverEnvelopeLocally(ws, outbound);
      await forwardEnvelopeToRemoteInstances(outbound);
      if (message.type === 'leave') {
        await removeFromRooms(ws);
      }
    })().catch((error) => {
      const meta = wsMeta.get(ws);
      console.error('[WS] message failed:', {
        sessionId: meta?.sessionId || null,
        deviceId: meta?.deviceId || null,
        role: meta?.role || null,
        message: error?.message || String(error),
        stack: error?.stack || null
      });
      incrementSecurityCounter('ws_server_error');
      try { wsSendRaw(ws, { type: 'error', error: 'server_error' }); } catch (_) {}
    });
  });

  ws.on('close', () => {
    void removeFromRooms(ws).catch((error) => {
      console.error('[WS] close cleanup failed:', error.message);
    });
  });

  ws.on('error', () => {});
});

const heartbeatTimer = setInterval(() => {
  if (!wss) return;
  for (const ws of wss.clients) {
    if (ws.isAlive === false) {
      try { ws.terminate(); } catch (_) {}
      continue;
    }
    ws.isAlive = false;
    try { ws.ping(); } catch (_) {}
  }
}, 30_000);

const sweepTimer = setInterval(() => {
  void signalingState.sweepExpired().catch((error) => {
    console.error('[sweeper] failed:', error.message);
  });
}, SWEEP_INTERVAL_MS);

const protectionTimer = setInterval(() => {
  void refreshRuntimeProtection();
}, 5_000);

let shuttingDown = false;
async function shutdown({ exitProcess = false } = {}) {
  if (shuttingDown) return;
  shuttingDown = true;
  clearInterval(heartbeatTimer);
  clearInterval(sweepTimer);
  clearInterval(protectionTimer);
  await signalingState.close().catch((error) => {
    console.error('[shutdown] backend close failed:', error.message);
  });
  await new Promise((resolve) => {
    server.close(() => {
      if (exitProcess) process.exit(0);
      resolve();
    });
  });
}

async function startRuntime({ port = PORT, host = HOST } = {}) {
  await signalingState.init(handleBackendInstanceMessage);
  await refreshRuntimeProtection();
  return await new Promise((resolve, reject) => {
    const onError = (error) => {
      server.off('error', onError);
      reject(error);
    };
    server.once('error', onError);
    server.listen(port, host, () => {
      server.off('error', onError);
      console.log('========================================');
      console.log('SkyBridge Signaling Server');
      console.log(`Mode: ${USE_NODE_HTTPS ? 'HTTPS' : 'HTTP'} listening on ${host}:${port}`);
      console.log(`Instance: ${INSTANCE_ID} stateBackend=${SIGNALING_STATE_BACKEND}`);
      if (SIGNALING_STATE_BACKEND === 'redis') {
        console.log(`Redis: ${SIGNALING_REDIS_URL} keyPrefix=${SIGNALING_REDIS_KEY_PREFIX}`);
      }
      console.log(`WS: ${USE_NODE_HTTPS ? 'wss' : 'ws'}://<host>:${port}/ws?shard=<session_id>&st=<session_token>`);
      console.log(`Security: maxPayload=${WS_MAX_MSG_BYTES} maxMsgs10s=${WS_MAX_MSGS_PER_10S} maxBytes10s=${WS_MAX_BYTES_PER_10S} perMessageDeflate=false`);
      console.log('========================================');
      resolve(server.address());
    });
  });
}

function createRuntime(options = {}) {
  const {
    signalingStateOverride,
    registryStoreOverride,
    smsClientOverride,
    trustProxy = TRUST_PROXY,
    requireSharedStateForPublicCapabilities = REQUIRE_SHARED_STATE_FOR_PUBLIC_CAPABILITIES,
    allowBootstrapDeviceAuth = SIGNALING_ALLOW_BOOTSTRAP_DEVICE_AUTH
  } = options;
  if (signalingStateOverride) {
    signalingState = signalingStateOverride;
  }
  if (registryStoreOverride) {
    registryStore = registryStoreOverride;
  }
  if (smsClientOverride) {
    smsClient = smsClientOverride;
  }
  currentTrustProxy = trustProxy;
  currentRequireSharedStateForPublicCapabilities = requireSharedStateForPublicCapabilities;
  currentAllowBootstrapDeviceAuth = allowBootstrapDeviceAuth;
  app.set('trust proxy', trustProxy ? 1 : false);
  rooms.clear();
  securityCounters.clear();
  runtimeProtection.redisAllowlistOnly = false;
  runtimeProtection.lastControlFlags = {
    allowlistOnly: false,
    disableChallengeAdmission: false,
    disableTurnIssuance: false,
    disableCodeFlows: false,
    allowlistTenants: []
  };
  runtimeProtection.redisLatencySamples = [];

  return {
    app,
    server,
    start: () => startRuntime(options),
    shutdown: () => shutdown({ exitProcess: false })
  };
}

process.on('SIGINT', () => { void shutdown({ exitProcess: true }); });
process.on('SIGTERM', () => { void shutdown({ exitProcess: true }); });

if (require.main === module) {
  startRuntime().catch((error) => {
    console.error('[startup] failed:', error);
    process.exit(1);
  });
}

module.exports = {
  createRuntime
};
