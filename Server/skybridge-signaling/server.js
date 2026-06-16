'use strict';

const http = require('http');
const https = require('https');
const fs = require('fs');
const crypto = require('crypto');
const os = require('os');
const { spawn, spawnSync } = require('child_process');

const express = require('express');
const { Webhook } = require('standardwebhooks');
const { WebSocketServer } = require('ws');
const { randomUUID } = require('crypto');

const { AliyunSMSClient } = require('./lib/aliyun_sms');
const { createSignalingStateBackend, unique } = require('./lib/signaling_state_backend');
const { createMediaRelay, createSignedMediaLeaseToken } = require('./lib/media_relay');
const { RegistryStore } = require('./lib/registry_store');
const { buildIdempotencyFingerprint, clientIPForRequest, normalizeClientIP } = require('./lib/request_security');
const {
  allowsLegacyQueryTokenFromEnv,
  extractWebSocketSessionCredentials
} = require('./lib/websocket_credentials');
const packageInfo = require('./package.json');

const PORT = Number(process.env.PORT || 8443);
const HOST = process.env.HOST || '0.0.0.0';
const INSTANCE_ID = String(process.env.INSTANCE_ID || `${os.hostname()}-${process.pid}`).trim();
function readBuildFingerprintFile() {
  const explicitPath = String(process.env.SKYBRIDGE_SIGNALING_BUILD_FINGERPRINT_FILE || '').trim();
  const candidates = [
    explicitPath,
    `${__dirname}/.skybridge-build-fingerprint`
  ].filter(Boolean);
  for (const candidate of candidates) {
    try {
      const value = fs.readFileSync(candidate, 'utf8').trim();
      if (value) return value;
    } catch (_) {}
  }
  return '';
}

function gitBuildFingerprint() {
  try {
    const result = spawnSync('git', ['rev-parse', '--short=12', 'HEAD'], {
      cwd: __dirname,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore']
    });
    const sha = String(result.stdout || '').trim();
    return sha ? `skybridge-signaling/git-${sha}` : '';
  } catch (_) {
    return '';
  }
}

function isGenericBuildFingerprint(value) {
  const normalized = String(value || '').trim();
  if (!normalized) return true;
  return normalized === `skybridge-signaling/${packageInfo.version || 'unknown'}`
    || normalized === 'skybridge-signaling/1.0.0';
}

function resolveServerBuildFingerprint() {
  const envFingerprint = String(
    process.env.SKYBRIDGE_SIGNALING_BUILD_FINGERPRINT ||
    process.env.RENDER_GIT_COMMIT ||
    process.env.VERCEL_GIT_COMMIT_SHA ||
    process.env.GIT_SHA ||
    ''
  ).trim();
  const fileFingerprint = readBuildFingerprintFile();
  const gitFingerprint = gitBuildFingerprint();
  if (envFingerprint && !isGenericBuildFingerprint(envFingerprint)) return envFingerprint;
  if (fileFingerprint && !isGenericBuildFingerprint(fileFingerprint)) return fileFingerprint;
  if (gitFingerprint) return gitFingerprint;
  if (envFingerprint) return `${envFingerprint}+unidentified-build`;
  return `skybridge-signaling/${packageInfo.version || 'unknown'}+unidentified-build`;
}

const SERVER_BUILD_FINGERPRINT = resolveServerBuildFingerprint();
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
const WEBRTC_ACTIVE_SESSION_TTL_MS = Number(process.env.WEBRTC_ACTIVE_SESSION_TTL_MS || 30 * 60_000);

const CHALLENGE_TTL_MS = Number(process.env.CHALLENGE_TTL_MS || 90_000);
const ADMISSION_TOKEN_TTL_MS = Number(process.env.ADMISSION_TOKEN_TTL_MS || 120_000);
const TURN_ADMISSION_TOKEN_TTL_MS = Number(process.env.TURN_ADMISSION_TOKEN_TTL_MS || 60_000);
const TURN_CRED_TTL_SECONDS = Number(process.env.TURN_CRED_TTL_SECONDS || 300);
const MEDIA_ADMISSION_TOKEN_TTL_MS = Number(process.env.MEDIA_ADMISSION_TOKEN_TTL_MS || 120_000);
const MEDIA_RELAY_ENABLED = /^(1|true|yes)$/i.test(process.env.MEDIA_RELAY_ENABLED || 'false');
const MEDIA_RELAY_HOST = String(process.env.MEDIA_RELAY_HOST || '0.0.0.0').trim() || '0.0.0.0';
const MEDIA_RELAY_PUBLIC_HOST = String(process.env.MEDIA_RELAY_PUBLIC_HOST || process.env.MEDIA_RELAY_HOST || '').trim();
const MEDIA_RELAY_UDP_PORT = Number(process.env.MEDIA_RELAY_UDP_PORT || 0);
const MEDIA_RELAY_LEASE_TTL_MS = Number(process.env.MEDIA_RELAY_LEASE_TTL_MS || 60_000);
const MEDIA_RELAY_MAX_PACKET_BYTES = Number(process.env.MEDIA_RELAY_MAX_PACKET_BYTES || 1200);
const MEDIA_RELAY_EXTERNAL_HOST = String(process.env.MEDIA_RELAY_EXTERNAL_HOST || '').trim();
const MEDIA_RELAY_EXTERNAL_UDP_PORT = Number(process.env.MEDIA_RELAY_EXTERNAL_UDP_PORT || 0);
const MEDIA_RELAY_TOKEN_SECRET = String(process.env.MEDIA_RELAY_TOKEN_SECRET || '').trim();
const MEDIA_RELAY_ACCEPT_SIGNED_LEASES = /^(1|true|yes)$/i.test(process.env.MEDIA_RELAY_ACCEPT_SIGNED_LEASES || 'false');

const MAX_CHALLENGES_PER_DEVICE_PER_10M = Number(process.env.MAX_CHALLENGES_PER_DEVICE_PER_10M || 10);
const MAX_CHALLENGES_PER_USER_PER_10M = Number(process.env.MAX_CHALLENGES_PER_USER_PER_10M || 20);
const MAX_CHALLENGES_PER_IP_PER_10M = Number(process.env.MAX_CHALLENGES_PER_IP_PER_10M || 40);
const HTTP_CONTROL_RATE_LIMIT_PER_MIN = Number(process.env.HTTP_CONTROL_RATE_LIMIT_PER_MIN || 60);
const HTTP_LOOKUP_RATE_LIMIT_PER_MIN = Number(process.env.HTTP_LOOKUP_RATE_LIMIT_PER_MIN || 30);
const HTTP_TURN_RATE_LIMIT_PER_MIN = Number(process.env.HTTP_TURN_RATE_LIMIT_PER_MIN || 60);
const HTTP_MEDIA_RATE_LIMIT_PER_MIN = Number(process.env.HTTP_MEDIA_RATE_LIMIT_PER_MIN || 60);
const HTTP_ADMISSION_RATE_LIMIT_PER_MIN = Number(process.env.HTTP_ADMISSION_RATE_LIMIT_PER_MIN || 60);

const WS_MAX_MSG_BYTES = Number(process.env.WS_MAX_MSG_BYTES || 16 * 1024);
const WS_MAX_MSGS_PER_10S = Number(process.env.WS_MAX_MSGS_PER_10S || 60);
const WS_MAX_BYTES_PER_10S = Number(process.env.WS_MAX_BYTES_PER_10S || 128 * 1024);
const WS_MAX_CLIENTS_PER_ROOM = Number(process.env.WS_MAX_CLIENTS_PER_ROOM || 2);
const WS_MAX_BUFFERED_BYTES = Number(process.env.WS_MAX_BUFFERED_BYTES || 512 * 1024);
const WS_HEARTBEAT_INTERVAL_MS = Number(process.env.WS_HEARTBEAT_INTERVAL_MS || 30_000);
const DEFAULT_WS_ALLOW_LEGACY_QUERY_TOKEN = allowsLegacyQueryTokenFromEnv(process.env);
let currentAllowLegacyQueryToken = DEFAULT_WS_ALLOW_LEGACY_QUERY_TOKEN;

const SDP_MAX_BYTES = Number(process.env.SDP_MAX_BYTES || 12 * 1024);
const ICE_CANDIDATE_MAX_BYTES = Number(process.env.ICE_CANDIDATE_MAX_BYTES || 2048);
const ICE_SDP_MID_MAX_BYTES = Number(process.env.ICE_SDP_MID_MAX_BYTES || 64);
const ICE_MAX_PER_SESSION = Number(process.env.ICE_MAX_PER_SESSION || 40);
const ICE_MAX_BYTES_PER_SESSION = Number(process.env.ICE_MAX_BYTES_PER_SESSION || 64 * 1024);
const ICE_MAX_BYTES_PER_PEER_PER_SESSION = Number(process.env.ICE_MAX_BYTES_PER_PEER_PER_SESSION || 32 * 1024);

// 后端用量跟踪（如 Redis）异常时的进程内 ICE 兜底限额。
// 降级期间不得 fail-open：否则攻击者可借故障窗口绕过 ICE 洪泛限制。
// 兜底表有 TTL 与容量上限，防止无界增长；容量耗尽时 fail-closed。
const DEGRADED_ICE_USAGE_TTL_MS = Number(process.env.DEGRADED_ICE_USAGE_TTL_MS || 10 * 60 * 1000);
const DEGRADED_ICE_USAGE_MAX_ENTRIES = Number(process.env.DEGRADED_ICE_USAGE_MAX_ENTRIES || 10_000);
const degradedIceUsageBySessionPeer = new Map();

function trackIceUsageDegraded(sessionId, deviceId, candidateBytes, limits) {
  const now = Date.now();
  const key = `${sessionId}|${deviceId}`;
  if (!degradedIceUsageBySessionPeer.has(key) &&
      degradedIceUsageBySessionPeer.size >= DEGRADED_ICE_USAGE_MAX_ENTRIES) {
    for (const [entryKey, entry] of degradedIceUsageBySessionPeer) {
      if (now - entry.firstAt > DEGRADED_ICE_USAGE_TTL_MS) {
        degradedIceUsageBySessionPeer.delete(entryKey);
      }
    }
    if (degradedIceUsageBySessionPeer.size >= DEGRADED_ICE_USAGE_MAX_ENTRIES) {
      return { accepted: false, duplicate: false, killed: true, degraded: true, reason: 'ice_degraded_capacity' };
    }
  }
  let entry = degradedIceUsageBySessionPeer.get(key);
  if (!entry || now - entry.firstAt > DEGRADED_ICE_USAGE_TTL_MS) {
    entry = { firstAt: now, count: 0, bytes: 0 };
  }
  entry.count += 1;
  entry.bytes += candidateBytes;
  degradedIceUsageBySessionPeer.set(key, entry);
  if (entry.count > limits.maxPerSession || entry.bytes > limits.maxBytesPerPeerPerSession) {
    return { accepted: false, duplicate: false, killed: true, degraded: true, reason: 'ice_limit_degraded' };
  }
  return { accepted: true, duplicate: false, killed: false, degraded: true };
}

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
const REQUIRE_CONFIGURED_SIGNALING_SERVER_ORIGIN = /^(1|true|yes)$/i.test(
  process.env.REQUIRE_CONFIGURED_SIGNALING_SERVER_ORIGIN
  || ((process.env.NODE_ENV || '').trim().toLowerCase() === 'production' ? 'true' : 'false')
);
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
const CLIENT_IP_HASH_SECRET_DEFAULT = 'skybridge-ip-hash';
const CLIENT_IP_HASH_SECRET = String(process.env.CLIENT_IP_HASH_SECRET || process.env.SIGNALING_IP_HASH_SECRET || CLIENT_IP_HASH_SECRET_DEFAULT).trim();
// True when no real secret was configured (empty or the built-in default). The
// IP-hash keys per-IP rate-limit/quota buckets and the stored clientIpHash; a
// publicly-known constant lets an attacker precompute/poison those buckets.
const CLIENT_IP_HASH_SECRET_IS_DEFAULT = (CLIENT_IP_HASH_SECRET === '' || CLIENT_IP_HASH_SECRET === CLIENT_IP_HASH_SECRET_DEFAULT);
const SUPABASE_SEND_SMS_HOOK_SECRET = String(
  process.env.SUPABASE_SEND_SMS_HOOK_SECRET
  || process.env.SEND_SMS_HOOK_SECRET
  || ''
).trim();
const REQUIRE_SMS_AUTH_READY = /^(1|true|yes)$/i.test(process.env.REQUIRE_SMS_AUTH_READY || 'false');
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
const MLDSA_VERIFY_HELPER_MAX_CONCURRENT = Number(process.env.SKYBRIDGE_MLDSA_VERIFY_HELPER_MAX_CONCURRENT || 4);
const TRUSTED_PROXY_MTLS_VERIFY_HEADER = 'x-skybridge-mtls-client-verify';
const TRUSTED_PROXY_MTLS_CERT_HEADER = 'x-skybridge-mtls-client-cert-pem';
const TRUSTED_PROXY_MTLS_CERT_HEADER_MAX_BYTES = 16 * 1024;

function envFlagEnabled(value) {
  return /^(1|true|yes)$/i.test(String(value || '').trim());
}

function isLoopbackHost(host) {
  const normalized = String(host || '').trim().toLowerCase().replace(/^\[|\]$/g, '');
  if (!normalized) return false;
  if (normalized === 'localhost' || normalized === '::1' || normalized === '0:0:0:0:0:0:0:1') {
    return true;
  }
  const octets = normalized.split('.');
  if (octets.length !== 4) return false;
  const values = octets.map((octet) => {
    if (!/^\d{1,3}$/.test(octet)) return NaN;
    const value = Number(octet);
    return value >= 0 && value <= 255 ? value : NaN;
  });
  return values.every(Number.isInteger) && values[0] === 127;
}

function normalizeMTLSClientCertificateSource(value) {
  const normalized = String(value || '').trim().toLowerCase().replace(/-/g, '_');
  if (!normalized || normalized === 'node' || normalized === 'node_tls') return 'node_tls';
  if (normalized === 'trusted_proxy' || normalized === 'trusted_proxy_header' || normalized === 'proxy') {
    return 'trusted_proxy';
  }
  throw new Error('invalid_mtls_client_cert_source');
}

function normalizeTrustedProxyRemoteAddress(value) {
  return normalizeClientIP(value).toLowerCase();
}

function parseTrustedProxyRemoteAddresses(env, host) {
  const configured = String(
    env.SKYBRIDGE_SIGNALING_TRUSTED_PROXY_MTLS_REMOTE_ADDRESSES ||
    env.SKYBRIDGE_SIGNALING_MTLS_TRUSTED_PROXY_ADDRESSES ||
    ''
  )
    .split(',')
    .map(normalizeTrustedProxyRemoteAddress)
    .filter(Boolean);
  if (configured.length > 0) return [...new Set(configured)];
  return isLoopbackHost(host) ? ['127.0.0.1', '::1'] : [];
}

function resolveNodeHTTPSTransportPolicy(env = process.env) {
  const certPath = String(env.TLS_CERT || '').trim();
  const keyPath = String(env.TLS_KEY || '').trim();
  const caPath = String(env.TLS_CA || '').trim();
  const host = String(env.HOST || '0.0.0.0').trim() || '0.0.0.0';
  const clientCertificateSource = normalizeMTLSClientCertificateSource(
    env.SKYBRIDGE_SIGNALING_MTLS_CLIENT_CERT_SOURCE ||
    env.SKYBRIDGE_SIGNALING_CLIENT_CERT_SOURCE ||
    ''
  );
  const trustedProxyMTLSEnabled = clientCertificateSource === 'trusted_proxy'
    || envFlagEnabled(
      env.SKYBRIDGE_SIGNALING_TRUSTED_PROXY_MTLS ||
      env.SIGNALING_TRUSTED_PROXY_MTLS ||
      ''
    );
  const requireMTLS = envFlagEnabled(
    env.SKYBRIDGE_SIGNALING_REQUIRE_MTLS ||
    env.SIGNALING_REQUIRE_MTLS ||
    ''
  );

  if ((certPath && !keyPath) || (!certPath && keyPath)) {
    throw new Error('node_https_requires_tls_cert_and_key');
  }
  if (trustedProxyMTLSEnabled) {
    if (!envFlagEnabled(env.TRUST_PROXY || '')) {
      throw new Error('trusted_proxy_mtls_requires_trust_proxy');
    }
    if (caPath) {
      throw new Error('trusted_proxy_mtls_must_not_set_tls_ca');
    }
    const trustedRemoteAddresses = parseTrustedProxyRemoteAddresses(env, host);
    if (trustedRemoteAddresses.length === 0) {
      throw new Error('trusted_proxy_mtls_requires_trusted_remote_addresses');
    }
    const useNodeHTTPS = Boolean(certPath && keyPath);
    return {
      mode: useNodeHTTPS ? 'https' : 'http',
      useNodeHTTPS,
      mtls: {
        required: true,
        source: 'trusted_proxy',
        requestCert: false,
        rejectUnauthorized: false
      },
      trustedProxyMTLS: {
        verifyHeader: TRUSTED_PROXY_MTLS_VERIFY_HEADER,
        certHeader: TRUSTED_PROXY_MTLS_CERT_HEADER,
        trustedRemoteAddresses
      },
      paths: { certPath, keyPath, caPath }
    };
  }
  if (!certPath && !keyPath) {
    if (caPath) {
      throw new Error('mtls_ca_requires_node_https_tls_cert_key');
    }
    if (requireMTLS) {
      throw new Error('mtls_requires_node_https_tls_cert_key');
    }
    return {
      mode: 'http',
      useNodeHTTPS: false,
      mtls: {
        required: false,
        source: 'none',
        requestCert: false,
        rejectUnauthorized: false
      },
      paths: { certPath, keyPath, caPath }
    };
  }

  const mtlsRequired = Boolean(caPath) || requireMTLS;
  if (mtlsRequired && !caPath) {
    throw new Error('mtls_requires_tls_ca');
  }

  return {
    mode: 'https',
    useNodeHTTPS: true,
    mtls: {
      required: mtlsRequired,
      source: mtlsRequired ? 'node_tls' : 'none',
      requestCert: mtlsRequired,
      rejectUnauthorized: mtlsRequired
    },
    paths: { certPath, keyPath, caPath }
  };
}

function buildNodeHTTPSServerTLSOptions(policy, readFileSync = fs.readFileSync) {
  if (!policy?.useNodeHTTPS) {
    throw new Error('node_https_policy_not_enabled');
  }
  const tlsOptions = {
    key: readFileSync(policy.paths.keyPath),
    cert: readFileSync(policy.paths.certPath)
  };
  if (policy.mtls.source === 'node_tls' && policy.mtls.required) {
    tlsOptions.ca = readFileSync(policy.paths.caPath);
    tlsOptions.requestCert = true;
    tlsOptions.rejectUnauthorized = true;
  }
  return tlsOptions;
}

function singleHeaderValue(headers, headerName) {
  const value = headers?.[String(headerName || '').toLowerCase()];
  if (Array.isArray(value)) {
    return { ok: false, error: 'mtls_trusted_proxy_duplicate_header' };
  }
  const text = String(value || '').trim();
  if (text.includes(',') || /[\x00-\x1F\x7F]/.test(text)) {
    return { ok: false, error: 'mtls_trusted_proxy_invalid_header' };
  }
  return { ok: true, value: text };
}

function parseTrustedProxyClientCertificate(escapedPEM) {
  const raw = String(escapedPEM || '').trim();
  if (!raw || Buffer.byteLength(raw, 'utf8') > TRUSTED_PROXY_MTLS_CERT_HEADER_MAX_BYTES) {
    return null;
  }
  let pem;
  try {
    pem = decodeURIComponent(raw);
  } catch (_) {
    return null;
  }
  if (
    !pem.includes('-----BEGIN CERTIFICATE-----') ||
    !pem.includes('-----END CERTIFICATE-----')
  ) {
    return null;
  }
  try {
    const certificate = new crypto.X509Certificate(pem);
    return {
      fingerprint256: certificate.fingerprint256,
      subject: certificate.subject || null,
      issuer: certificate.issuer || null
    };
  } catch (_) {
    return null;
  }
}

function remoteAddressForMTLSTrust(req) {
  return normalizeTrustedProxyRemoteAddress(
    req?.socket?.remoteAddress ||
    req?.connection?.remoteAddress ||
    ''
  );
}

function resolveTrustedProxyPeerCertificate(
  req,
  policy,
  parseCertificate = parseTrustedProxyClientCertificate
) {
  const remoteAddress = remoteAddressForMTLSTrust(req);
  const trustedRemoteAddresses = new Set(
    (policy?.trustedProxyMTLS?.trustedRemoteAddresses || [])
      .map(normalizeTrustedProxyRemoteAddress)
      .filter(Boolean)
  );
  if (!remoteAddress || !trustedRemoteAddresses.has(remoteAddress)) {
    return { ok: false, error: 'mtls_untrusted_proxy_header_source' };
  }
  const verifyHeader = policy?.trustedProxyMTLS?.verifyHeader || TRUSTED_PROXY_MTLS_VERIFY_HEADER;
  const certHeader = policy?.trustedProxyMTLS?.certHeader || TRUSTED_PROXY_MTLS_CERT_HEADER;
  const verify = singleHeaderValue(req?.headers || {}, verifyHeader);
  if (!verify.ok) return verify;
  if (verify.value !== 'SUCCESS') {
    return { ok: false, error: 'mtls_client_certificate_unverified' };
  }
  const cert = singleHeaderValue(req?.headers || {}, certHeader);
  if (!cert.ok) return cert;
  const certificate = parseCertificate(cert.value);
  if (!certificate) {
    return { ok: false, error: 'mtls_client_certificate_required' };
  }
  const fingerprint256 = String(certificate.fingerprint256 || '').trim();
  if (!fingerprint256) {
    return { ok: false, error: 'mtls_client_certificate_missing_fingerprint' };
  }
  return {
    ok: true,
    certificate: {
      fingerprint256,
      subject: certificate.subject || null,
      issuer: certificate.issuer || null
    }
  };
}

function resolvePeerCertificateForMTLS(req, policy, parseTrustedProxyCertificate) {
  if (!policy?.mtls?.required) {
    return { ok: true, certificate: null };
  }
  if (policy.mtls.source === 'trusted_proxy') {
    return resolveTrustedProxyPeerCertificate(req, policy, parseTrustedProxyCertificate);
  }
  const socket = req?.socket;
  if (!socket || socket.authorized !== true) {
    return { ok: false, error: 'mtls_client_certificate_required' };
  }
  const certificate = typeof socket.getPeerCertificate === 'function'
    ? socket.getPeerCertificate()
    : null;
  if (!certificate || Object.keys(certificate).length === 0) {
    return { ok: false, error: 'mtls_client_certificate_required' };
  }
  const fingerprint256 = String(certificate.fingerprint256 || '').trim();
  if (!fingerprint256) {
    return { ok: false, error: 'mtls_client_certificate_missing_fingerprint' };
  }
  return {
    ok: true,
    certificate: {
      fingerprint256,
      subject: certificate.subject || null,
      issuer: certificate.issuer || null
    }
  };
}

const NODE_HTTPS_TRANSPORT_POLICY = resolveNodeHTTPSTransportPolicy(process.env);
const USE_NODE_HTTPS = NODE_HTTPS_TRANSPORT_POLICY.useNodeHTTPS;

function now() { return Date.now(); }

function base64url(buf) {
  return Buffer.from(buf).toString('base64')
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/g, '');
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

function mtlsPeerCertificateStatusCode(errorCode) {
  return String(errorCode || '') === 'mtls_untrusted_proxy_header_source' ? 403 : 401;
}

function mtlsClientCertificateFingerprintForRequest(req, policy = NODE_HTTPS_TRANSPORT_POLICY) {
  const peerCertificate = resolvePeerCertificateForMTLS(req, policy);
  if (!peerCertificate.ok) {
    throw makeError(peerCertificate.error, mtlsPeerCertificateStatusCode(peerCertificate.error));
  }
  return peerCertificate.certificate?.fingerprint256 || null;
}

function mtlsBindingErrorForRecord(record, certificate, label, policy = NODE_HTTPS_TRANSPORT_POLICY) {
  if (!policy?.mtls?.required) {
    return null;
  }
  const actual = String(certificate?.fingerprint256 || '').trim();
  if (!actual) {
    return 'mtls_client_certificate_required';
  }
  const expected = String(record?.mtlsClientCertificateFingerprint256 || '').trim();
  if (!expected) {
    return `${label}_mtls_binding_missing`;
  }
  if (!secureStringEqual(expected, actual)) {
    return `${label}_mtls_certificate_mismatch`;
  }
  return null;
}

function mtlsBindingStatusCode(errorCode) {
  return String(errorCode || '').endsWith('_mismatch') ? 403 : 401;
}

function assertMTLSBindingForRecord(req, record, label, policy = NODE_HTTPS_TRANSPORT_POLICY) {
  const fingerprint256 = mtlsClientCertificateFingerprintForRequest(req, policy);
  const certificate = fingerprint256 ? { fingerprint256 } : null;
  const bindingError = mtlsBindingErrorForRecord(record, certificate, label, policy);
  if (bindingError) {
    throw makeError(bindingError, mtlsBindingStatusCode(bindingError));
  }
  return fingerprint256;
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

function serializeURLHost(host) {
  const normalized = String(host || '').replace(/^\[|\]$/g, '');
  return normalized.includes(':') ? `[${normalized}]` : normalized;
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
  if (scheme === 'http' && !isLoopbackHost(host)) return null;
  if (parsed.pathname && parsed.pathname !== '/') return null;
  if (parsed.search || parsed.hash) return null;
  const port = parsed.port ? Number(parsed.port) : null;
  const serializedHost = serializeURLHost(host);
  if ((scheme === 'https' && (!port || port === 443)) || (scheme === 'http' && (!port || port === 80))) {
    return `${scheme}://${serializedHost}`;
  }
  return `${scheme}://${serializedHost}:${port}`;
}

function resolveSignalingServerOrigin({
  configuredOrigin = SIGNALING_SERVER_ORIGIN,
  requireConfiguredOrigin = REQUIRE_CONFIGURED_SIGNALING_SERVER_ORIGIN,
  forwardedProto = '',
  requestProtocol = 'https',
  host = ''
} = {}) {
  const configuredOriginText = String(configuredOrigin || '').trim();
  if (configuredOriginText) {
    const configured = canonicalizeOrigin(configuredOriginText);
    if (!configured) {
      throw new Error('invalid_signaling_server_origin');
    }
    return configured;
  }
  if (requireConfiguredOrigin) {
    throw new Error('missing_signaling_server_origin');
  }
  const normalizedForwardedProto = String(forwardedProto || '').split(',')[0].trim().toLowerCase();
  const scheme = normalizedForwardedProto || String(requestProtocol || 'https').toLowerCase();
  const derived = canonicalizeOrigin(`${scheme}://${String(host || '').trim()}`);
  if (!derived) {
    throw new Error('invalid_signaling_server_origin');
  }
  return derived;
}

function resolvedSignalingServerOrigin(req) {
  return resolveSignalingServerOrigin({
    forwardedProto: req.get('X-Forwarded-Proto'),
    requestProtocol: req.protocol,
    host: req.get('host')
  });
}

function redactSecretURLForLog(value) {
  const raw = String(value || '').trim();
  if (!raw) return raw;
  try {
    const parsed = new URL(raw);
    if (parsed.username) {
      parsed.username = '***';
    }
    if (parsed.password) {
      parsed.password = '***';
    }
    return parsed.toString();
  } catch (_) {
    return raw.replace(/\/\/([^/@]+)@/, '//***@');
  }
}

const LOG_REDACTED = '<redacted>';

function sessionLogIdForLog(sessionId) {
  const normalized = String(sessionId || '').trim();
  if (!normalized) return LOG_REDACTED;
  return sha256Hex(normalized).slice(0, 16);
}

function safeLogErrorCode(error) {
  return String(error?.code || error?.name || 'Error');
}

function redactedWSMetaForLog(meta) {
  return {
    session: meta?.sessionId ? LOG_REDACTED : null,
    device: meta?.deviceId ? LOG_REDACTED : null,
    role: meta?.role || null
  };
}

function assertConfiguredSignalingServerOrigin() {
  if (!REQUIRE_CONFIGURED_SIGNALING_SERVER_ORIGIN) return;
  const rawConfigured = String(SIGNALING_SERVER_ORIGIN || '').trim();
  if (!rawConfigured) {
    throw new Error('missing_signaling_server_origin');
  }
  const configured = canonicalizeOrigin(rawConfigured);
  if (!configured) {
    throw new Error('invalid_signaling_server_origin');
  }
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

class AsyncConcurrencyGate {
  constructor(maxConcurrent) {
    this.maxConcurrent = Math.max(1, Number(maxConcurrent) || 1);
    this.inFlight = 0;
    this.waiters = [];
  }

  async run(operation) {
    await this.acquire();
    try {
      return await operation();
    } finally {
      this.release();
    }
  }

  acquire() {
    if (this.inFlight < this.maxConcurrent) {
      this.inFlight += 1;
      return Promise.resolve();
    }
    return new Promise((resolve) => {
      this.waiters.push(resolve);
    });
  }

  release() {
    if (this.waiters.length > 0) {
      const next = this.waiters.shift();
      next();
      return;
    }
    this.inFlight = Math.max(0, this.inFlight - 1);
  }
}

const mldsaVerifyHelperGate = new AsyncConcurrencyGate(MLDSA_VERIFY_HELPER_MAX_CONCURRENT);

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

async function runMldsaVerifyHelper(rawPublicKey, signature, challengePayload) {
  const helper = MLDSA_VERIFY_HELPER;
  if (!helper) return false;

  return mldsaVerifyHelperGate.run(() => new Promise((resolve) => {
    const child = spawn(helper, [
      'internal',
      'verify-mldsa',
      '--message-base64', challengePayload.toString('base64'),
      '--signature-base64', signature.toString('base64'),
      '--public-key-base64', rawPublicKey.toString('base64')
    ], {
      stdio: ['ignore', 'pipe', 'pipe']
    });

    let finished = false;
    let stdoutSize = 0;
    let stderrSize = 0;
    let stderr = '';

    const finish = (result) => {
      if (finished) return;
      finished = true;
      clearTimeout(timeoutHandle);
      resolve(result);
    };

    const timeoutHandle = setTimeout(() => {
      child.kill('SIGKILL');
      console.warn('[ML-DSA verify helper] timed out');
      finish(false);
    }, MLDSA_VERIFY_HELPER_TIMEOUT_MS);

    child.on('error', (error) => {
      console.warn('[ML-DSA verify helper] execution failed:', error.message);
      finish(false);
    });

    child.stdout.on('data', (chunk) => {
      stdoutSize += chunk.length;
      if (stdoutSize > 64 * 1024) {
        console.warn('[ML-DSA verify helper] stdout exceeded max buffer');
        child.kill('SIGKILL');
        finish(false);
      }
    });

    child.stderr.on('data', (chunk) => {
      stderrSize += chunk.length;
      if (stderrSize <= 64 * 1024) {
        stderr += chunk.toString('utf8');
      } else {
        console.warn('[ML-DSA verify helper] stderr exceeded max buffer');
        child.kill('SIGKILL');
        finish(false);
      }
    });

    child.on('close', (code, signal) => {
      if (signal) {
        console.warn('[ML-DSA verify helper] terminated by signal:', signal);
        finish(false);
        return;
      }
      if (code !== 0) {
        if (stderr.trim()) {
          console.warn('[ML-DSA verify helper] rejected signature:', stderr.trim());
        }
        finish(false);
        return;
      }
      finish(true);
    });
  }));
}

async function verifyMldsa65ChallengeSignature(rawPublicKey, signature, challenge) {
  const spki = mldsa65RawPublicKeyToSpki(rawPublicKey);
  if (!spki) return false;
  const payload = challengeSignaturePayload(challenge);
  try {
    return crypto.verify(
      null,
      payload,
      { key: spki, format: 'der', type: 'spki' },
      signature
    );
  } catch (_) {
    if (!MLDSA_VERIFY_HELPER) return false;
  }

  return runMldsaVerifyHelper(rawPublicKey, signature, payload);
}

async function verifyChallengeSignature(binding, signatureBase64, challenge) {
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
        const responseBody = { error: errorCode };
        if (error.publicDetails && typeof error.publicDetails === 'object') {
          Object.assign(responseBody, error.publicDetails);
        }
        res.status(statusCode).json(responseBody);
      }
      if (typeof next === 'function') next(error);
    });
  };
}

function rateLimit({ windowMs, max, keyFn }) {
  const hits = new Map();
  const maxTrackedKeys = Math.max(max * 128, 4096);
  let lastPruneAt = 0;

  const pruneHits = (currentTime) => {
    if (hits.size === 0) return;
    if (currentTime - lastPruneAt < Math.min(windowMs, 30_000) && hits.size < maxTrackedKeys) {
      return;
    }
    lastPruneAt = currentTime;
    for (const [trackedKey, trackedEntry] of hits.entries()) {
      if (!trackedEntry || currentTime > trackedEntry.resetAt) {
        hits.delete(trackedKey);
      }
    }
    while (hits.size > maxTrackedKeys) {
      const oldestKey = hits.keys().next().value;
      if (oldestKey === undefined) break;
      hits.delete(oldestKey);
    }
  };

  return (req, res, next) => {
    const key = keyFn ? keyFn(req) : (clientIPForRequest(req, { trustProxy: currentTrustProxy }) || 'unknown');
    const t = now();
    pruneHits(t);
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
let mediaRelay = MEDIA_RELAY_ENABLED
  ? createMediaRelay({
      host: MEDIA_RELAY_HOST,
      publicHost: MEDIA_RELAY_PUBLIC_HOST || MEDIA_RELAY_HOST,
      port: MEDIA_RELAY_UDP_PORT,
      leaseTtlMs: MEDIA_RELAY_LEASE_TTL_MS,
      maxPacketBytes: MEDIA_RELAY_MAX_PACKET_BYTES,
      signedLeaseSecret: MEDIA_RELAY_ACCEPT_SIGNED_LEASES ? MEDIA_RELAY_TOKEN_SECRET : '',
      log: console
    })
  : null;
let currentTrustProxy = TRUST_PROXY;
let currentRequireSharedStateForPublicCapabilities = REQUIRE_SHARED_STATE_FOR_PUBLIC_CAPABILITIES;
let currentAllowBootstrapDeviceAuth = SIGNALING_ALLOW_BOOTSTRAP_DEVICE_AUTH;
const rooms = new Map();
const wsMeta = new WeakMap();
const activeSessionTouchAtBySessionId = new Map();
const securityCounters = new Map();
const smsCounters = new Map();
let lastSMSDeliveryEvent = null;
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

function incrementCounter(counterMap, name) {
  const current = counterMap.get(name) || 0;
  counterMap.set(name, current + 1);
}

function currentCounters(counterMap) {
  return Object.fromEntries([...counterMap.entries()].sort((left, right) => left[0].localeCompare(right[0])));
}

function incrementSecurityCounter(name) {
  incrementCounter(securityCounters, name);
}

function currentSecurityCounters() {
  return currentCounters(securityCounters);
}

function incrementSMSCounter(name) {
  incrementCounter(smsCounters, name);
}

function currentSMSCounters() {
  return currentCounters(smsCounters);
}

function maskedPhoneSuffix(phoneNumber) {
  const digits = String(phoneNumber || '').replace(/\D/g, '');
  return digits.slice(-4) || '';
}

function recordSMSDeliveryEvent(level, fields) {
  const event = {
    timestamp: new Date().toISOString(),
    subsystem: 'supabase_sms_auth',
    ...fields
  };
  lastSMSDeliveryEvent = event;
  const serialized = JSON.stringify(event);
  switch (level) {
    case 'error':
      console.error(serialized);
      break;
    case 'warn':
      console.warn(serialized);
      break;
    default:
      console.log(serialized);
      break;
  }
}

function currentSMSDeliveryEvent() {
  return lastSMSDeliveryEvent ? { ...lastSMSDeliveryEvent } : null;
}

function makeError(code, statusCode = 400, publicDetails = null) {
  const error = new Error(code);
  error.code = code;
  error.statusCode = statusCode;
  if (publicDetails && typeof publicDetails === 'object') {
    error.publicDetails = publicDetails;
  }
  return error;
}

function normalizeSupabaseHookSecret(raw) {
  const value = String(raw || '').trim();
  if (!value) return '';
  return value.replace(/^v1,whsec_/, '');
}

function buildSupabaseSMSHookVerifier(hookSecret = SUPABASE_SEND_SMS_HOOK_SECRET) {
  const normalized = normalizeSupabaseHookSecret(hookSecret);
  if (!normalized) return null;
  return new Webhook(normalized);
}

const supabaseSMSHookVerifier = buildSupabaseSMSHookVerifier();

function collectSMSServiceSnapshot({
  client = smsClient,
  hookSecret = SUPABASE_SEND_SMS_HOOK_SECRET,
  required = REQUIRE_SMS_AUTH_READY
} = {}) {
  const configurationStatus = client?.configurationStatus && typeof client.configurationStatus === 'object'
    ? client.configurationStatus
    : {
      provider: String(client?.provider || 'unknown'),
      providerSupported: false,
      configured: Boolean(client?.configured),
      missingConfiguration: []
    };
  const hookConfigured = Boolean(normalizeSupabaseHookSecret(hookSecret));
  const reasons = [];
  if (!hookConfigured) {
    reasons.push('supabase_send_sms_hook_secret_missing');
  }
  if (!configurationStatus.providerSupported) {
    reasons.push('aliyun_sms_provider_unsupported');
  }
  if (configurationStatus.providerSupported && !configurationStatus.configured) {
    reasons.push('aliyun_sms_provider_not_configured');
  }
  const ready = hookConfigured && configurationStatus.providerSupported && configurationStatus.configured;
  return {
    required: Boolean(required),
    provider: configurationStatus.provider || String(client?.provider || 'unknown'),
    providerSupported: Boolean(configurationStatus.providerSupported),
    hookConfigured,
    providerConfigured: Boolean(configurationStatus.configured),
    ready,
    reasons,
    missingConfiguration: Array.isArray(configurationStatus.missingConfiguration)
      ? [...configurationStatus.missingConfiguration]
      : [],
    counters: currentSMSCounters(),
    lastEvent: currentSMSDeliveryEvent()
  };
}

function classifySMSDeliveryFailure(error) {
  const message = String(error?.message || '').toLowerCase();
  const providerCode = safeUpperCode(error?.response?.code || error?.response?.Code || '');
  const looksLikeTemplateError = (
    message.includes('template')
    || message.includes('templateparam')
    || message.includes('模板')
    || message.includes('模版')
    || providerCode.includes('TEMPLATE')
  );
  const looksLikeSignatureError = (
    message.includes('signature')
    || message.includes('sign')
    || message.includes('签名')
    || providerCode.includes('SIGN')
  );

  if (message.includes('provider_unsupported')) {
    return { reason: 'provider_unsupported', retryable: false, statusCode: 503, errorCode: 'aliyun_sms_provider_unsupported' };
  }
  if (message.includes('not_configured')) {
    return { reason: 'provider_not_configured', retryable: false, statusCode: 503, errorCode: 'aliyun_sms_not_configured' };
  }
  if (message.includes('unsupported_phone_number')) {
    return { reason: 'unsupported_phone_number', retryable: false, statusCode: 400, errorCode: 'unsupported_phone_number' };
  }
  if (message.includes('invalid_otp_code')) {
    return { reason: 'invalid_otp_code', retryable: false, statusCode: 400, errorCode: 'invalid_otp_code' };
  }
  if (
    message.includes('timeout')
    || message.includes('timed out')
    || error?.code === 'ETIMEDOUT'
    || error?.name === 'AbortError'
  ) {
    return { reason: 'provider_timeout', retryable: true, statusCode: 504, errorCode: 'sms_provider_timeout' };
  }
  if (looksLikeTemplateError) {
    return { reason: 'template_rejected', retryable: false, statusCode: 502, errorCode: 'sms_template_rejected' };
  }
  if (looksLikeSignatureError) {
    return { reason: 'signature_rejected', retryable: false, statusCode: 502, errorCode: 'sms_signature_rejected' };
  }
  if (
    message.includes('network')
    || error?.code === 'ECONNRESET'
    || error?.code === 'ENOTFOUND'
    || providerCode.startsWith('HTTP_')
  ) {
    return { reason: 'provider_transport_error', retryable: true, statusCode: 502, errorCode: 'sms_delivery_failed' };
  }
  if (
    providerCode
    || message.includes('rejected')
    || message.includes('denied')
    || message.includes('forbidden')
    || message.includes('invalid')
  ) {
    return { reason: 'provider_rejected', retryable: false, statusCode: 502, errorCode: 'sms_delivery_rejected' };
  }
  return { reason: 'provider_unknown_error', retryable: false, statusCode: 502, errorCode: 'sms_delivery_failed' };
}

// Fail closed in production when the IP-hash secret was never configured, mirroring
// the SMS startup gate. A publicly-known default undermines per-IP rate limiting,
// quota accounting, and the privacy of the stored clientIpHash.
function assertClientIpHashSecretReadiness() {
  const isProduction = (process.env.NODE_ENV || '').trim().toLowerCase() === 'production';
  if (!CLIENT_IP_HASH_SECRET_IS_DEFAULT) {
    return;
  }
  if (isProduction) {
    console.error('[startup] CLIENT_IP_HASH_SECRET is empty or the built-in default in production; refusing to start. Set a strong, unique CLIENT_IP_HASH_SECRET.');
    const error = new Error('client_ip_hash_secret_not_configured');
    error.code = 'client_ip_hash_secret_not_configured';
    error.statusCode = 503;
    throw error;
  }
  console.warn('[startup] CLIENT_IP_HASH_SECRET is using the built-in default; set a strong, unique secret before any production deployment.');
}

function assertSMSStartupReadiness() {
  const sms = collectSMSServiceSnapshot();
  if (sms.ready) {
    console.log(`[startup] SMS auth ready provider=${sms.provider}`);
    return sms;
  }
  console.warn('[startup] SMS auth not ready:', JSON.stringify({
    required: sms.required,
    provider: sms.provider,
    reasons: sms.reasons,
    missingConfiguration: sms.missingConfiguration
  }));
  if (sms.required) {
    const error = new Error('sms_auth_not_ready');
    error.code = 'sms_auth_not_ready';
    error.statusCode = 503;
    error.details = sms;
    throw error;
  }
  return sms;
}

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

function registryAdvertisesCapability(flag) {
  return typeof flag === 'boolean' ? flag : null;
}

function registrySupportsMethod(store, methodName) {
  return Boolean(store && typeof store[methodName] === 'function');
}

function registryCanVerifyAccessTokens(store = registryStore) {
  const advertised = registryAdvertisesCapability(store?.canVerifyAccessToken);
  if (advertised != null) {
    return advertised;
  }
  return registrySupportsMethod(store, 'verifyAccessToken');
}

function registryCanReadTenantPolicy(store = registryStore) {
  const advertised = registryAdvertisesCapability(store?.canAccessRegistry);
  if (advertised != null) {
    return advertised;
  }
  return registrySupportsMethod(store, 'getTenantPolicy');
}

function registryCanReadRegisteredDevices(store = registryStore) {
  const advertised = registryAdvertisesCapability(store?.canAccessRegistry);
  if (advertised != null) {
    return advertised;
  }
  return registrySupportsMethod(store, 'getRegisteredDevice');
}

function registryCanBootstrapRegisterDevices(store = registryStore) {
  const advertised = registryAdvertisesCapability(store?.canAccessRegistry);
  if (advertised != null) {
    return advertised;
  }
  return registrySupportsMethod(store, 'bootstrapRegisterDevice');
}

async function loadAuthenticatedDeviceContext(req, { requireRegisteredDevice = true } = {}) {
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

  const canVerifyAccessToken = registryCanVerifyAccessTokens();
  const user = canVerifyAccessToken
    ? await registryStore.verifyAccessToken(accessToken)
    : null;
  if (!user && !canVerifyAccessToken) {
    throw makeError('registry_not_configured', 503);
  }
  if (!user.id) {
    throw makeError('invalid_user_session', 401);
  }
  if (user.isGuest) {
    throw makeError('guest_forbidden', 403);
  }
  // A client-supplied tenant id (X-SkyBridge-Tenant-Id header / body / query) must
  // never OVERRIDE the JWT-derived tenant. If both are present and disagree, reject:
  // otherwise a forged header could pivot into another tenant — exploitable when
  // SIGNALING_ALLOW_BOOTSTRAP_TENANT_POLICY fabricates a public policy for any tenant.
  // When the JWT carries no tenant (bootstrap), the supplied value is still honored.
  const derivedTenantId = deriveTenantIdFromUser(user);
  const requestedTenantId = tenantIdFromRequest(req);
  if (requestedTenantId && derivedTenantId && requestedTenantId !== derivedTenantId) {
    console.warn('[security] tenant id override rejected: header/body tenant does not match JWT-derived tenant');
    throw makeError('tenant_id_mismatch', 403);
  }
  const tenantId = derivedTenantId || requestedTenantId;
  if (!tenantId) {
    throw makeError('missing_tenant_id', 400);
  }
  const canReadTenantPolicy = registryCanReadTenantPolicy();
  const tenantPolicy = canReadTenantPolicy
    ? await registryStore.getTenantPolicy(tenantId)
    : null;
  const effectiveTenantPolicy = (!tenantPolicy && SIGNALING_ALLOW_BOOTSTRAP_TENANT_POLICY)
    ? syntheticTenantPolicy(tenantId)
    : tenantPolicy;
  if (!effectiveTenantPolicy || !effectiveTenantPolicy.public_signaling_enabled) {
    throw makeError('tenant_public_access_disabled', 403);
  }
  assertVersionGates(clientVersion, protocolVersion, effectiveTenantPolicy);
  let deviceRecord = null;
  if (requireRegisteredDevice) {
    const canReadRegisteredDevices = registryCanReadRegisteredDevices();
    if (canReadRegisteredDevices) {
      deviceRecord = await registryStore.getRegisteredDevice({
        tenantId,
        userId: user.id,
        deviceId: binding.deviceId,
        protocolSigningAlgorithm: binding.protocolSigningAlgorithm,
        protocolPublicKeyFingerprint: binding.protocolPublicKeyFingerprint
      });
    }
    if (!deviceRecord && currentAllowBootstrapDeviceAuth) {
      deviceRecord = syntheticDeviceRecord({
        tenantId,
        user,
        binding
      });
    }
    if (!deviceRecord && !canReadRegisteredDevices) {
      throw makeError('registry_not_configured', 503);
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
  const mtlsClientCertificateFingerprint256 = context.mtlsClientCertificateFingerprint256 || null;
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
      mtlsClientCertificateFingerprint256,
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
      mtlsClientCertificateFingerprint256,
      jti: base64url(crypto.randomBytes(16))
    }
  });
  const mediaAdmissionToken = issueEphemeralTokenRecord({
    kind: 'media_admission_token',
    ttlMs: MEDIA_ADMISSION_TOKEN_TTL_MS,
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
      mtlsClientCertificateFingerprint256
    }
  });
  const sessionCreated = await signalingState.createEphemeral('session_token', sessionToken.tokenHash, sessionToken.record);
  const turnCreated = await signalingState.createEphemeral('turn_admission_token', turnAdmissionToken.tokenHash, turnAdmissionToken.record);
  const mediaCreated = await signalingState.createEphemeral('media_admission_token', mediaAdmissionToken.tokenHash, mediaAdmissionToken.record);
  if (!sessionCreated || !turnCreated || !mediaCreated) {
    throw makeError('token_issue_failed', 500);
  }
  return {
    sessionToken: sessionToken.token,
    sessionTokenHash: sessionToken.tokenHash,
    turnAdmissionToken: turnAdmissionToken.token,
    turnAdmissionTokenHash: turnAdmissionToken.tokenHash,
    mediaAdmissionToken: mediaAdmissionToken.token,
    mediaAdmissionTokenHash: mediaAdmissionToken.tokenHash
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
  initiatorTurnAdmissionTokenHash = null,
  initiatorMediaAdmissionTokenHash = null
}) {
  return {
    deviceId: initiatorContext.binding.deviceId,
    initiatorDeviceName,
    initiatorProtocolSigningAlgorithm: initiatorContext.binding.protocolSigningAlgorithm,
    initiatorProtocolPublicKeyFingerprint: initiatorContext.binding.protocolPublicKeyFingerprint,
    offer: { mode: connectionKind },
    createdAt: now(),
    expiresAt,
    rendezvousExpiresAt: expiresAt,
    activeUntil: expiresAt,
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
    initiatorMediaAdmissionTokenHash,
    responderSessionTokenHash: null,
    responderTurnAdmissionTokenHash: null,
    responderMediaAdmissionTokenHash: null,
    revokedAt: 0
  };
}

function numericTimestamp(value, fallback = 0) {
  const number = Number(value);
  return Number.isFinite(number) ? number : fallback;
}

function connectionRendezvousExpiresAt(record) {
  return numericTimestamp(record?.rendezvousExpiresAt, numericTimestamp(record?.expiresAt, 0));
}

function connectionActiveUntil(record) {
  return numericTimestamp(record?.activeUntil, numericTimestamp(record?.expiresAt, 0));
}

function nextActiveUntil(record, at = now()) {
  return Math.max(
    connectionActiveUntil(record),
    connectionRendezvousExpiresAt(record),
    at + Math.max(60_000, WEBRTC_ACTIVE_SESSION_TTL_MS)
  );
}

function extendConnectionActiveUntil(record, at = now()) {
  record.activeUntil = nextActiveUntil(record, at);
  record.expiresAt = Math.max(numericTimestamp(record?.expiresAt, 0), record.activeUntil);
  return record.activeUntil;
}

function isRendezvousExpired(record, at = now()) {
  return at > connectionRendezvousExpiresAt(record);
}

function logSessionLifecycle(sessionId, event, fields = {}) {
  const suffix = Object.entries(fields)
    .filter(([, value]) => value !== undefined && value !== null && value !== '')
    .map(([key, value]) => `${key}=${value}`)
    .join(' ');
  console.info(
    `[session] sessionLifecycle=${event} sessionLogId=${sessionLogIdForLog(sessionId)} ` +
    `session=${LOG_REDACTED}${suffix ? ` ${suffix}` : ''}`
  );
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

function admissionOwnsSession(item, admission) {
  if (item.tenantId && item.tenantId !== admission.tenantId) {
    return false;
  }
  if (item.userId && item.userId !== admission.userId) {
    return false;
  }
  return true;
}

function contextFromAdmission(admission) {
  return {
    tenantId: admission.tenantId,
    user: { id: admission.userId },
    binding: {
      deviceId: admission.deviceId,
      protocolSigningAlgorithm: admission.protocolSigningAlgorithm,
      protocolPublicKeyFingerprint: admission.protocolPublicKeyFingerprint
    },
    deviceSynthetic: Boolean(admission.deviceSynthetic),
    clientVersion: admission.clientVersion,
    protocolVersion: admission.protocolVersion,
    mtlsClientCertificateFingerprint256: admission.mtlsClientCertificateFingerprint256 || null
  };
}

function roleParticipantBinding(record, role) {
  if (!record || (role !== 'initiator' && role !== 'responder')) return null;
  if (role === 'initiator') {
    return {
      deviceId: record.deviceId,
      protocolSigningAlgorithm: record.initiatorProtocolSigningAlgorithm,
      protocolPublicKeyFingerprint: record.initiatorProtocolPublicKeyFingerprint
    };
  }
  return {
    deviceId: record.responderId,
    protocolSigningAlgorithm: record.responderProtocolSigningAlgorithm,
    protocolPublicKeyFingerprint: record.responderProtocolPublicKeyFingerprint
  };
}

function bindingMatches(left, right) {
  return Boolean(
    left?.deviceId
    && right?.deviceId
    && left.deviceId === right.deviceId
    && left.protocolSigningAlgorithm === right.protocolSigningAlgorithm
    && left.protocolPublicKeyFingerprint === right.protocolPublicKeyFingerprint
  );
}

function setConnectionRoleTokenHashes(record, role, artifacts) {
  if (role === 'initiator') {
    record.initiatorSessionTokenHash = artifacts.sessionTokenHash;
    record.initiatorTurnAdmissionTokenHash = artifacts.turnAdmissionTokenHash;
    record.initiatorMediaAdmissionTokenHash = artifacts.mediaAdmissionTokenHash;
    return;
  }
  record.responderSessionTokenHash = artifacts.sessionTokenHash;
  record.responderTurnAdmissionTokenHash = artifacts.turnAdmissionTokenHash;
  record.responderMediaAdmissionTokenHash = artifacts.mediaAdmissionTokenHash;
}

function roleHasActiveTokenHashes(record, role) {
  return Boolean(
    connectionRoleTokenHash(record, role, 'session_token')
    || connectionRoleTokenHash(record, role, 'turn_admission_token')
    || connectionRoleTokenHash(record, role, 'media_admission_token')
  );
}

async function revokeSessionArtifactsIfPresent(artifacts, reason = 'superseded') {
  await Promise.all([
    revokeSupersededSessionTokenIfPresent(artifacts?.sessionTokenHash, reason),
    revokeEphemeralIfPresent('turn_admission_token', artifacts?.turnAdmissionTokenHash, reason),
    revokeEphemeralIfPresent('media_admission_token', artifacts?.mediaAdmissionTokenHash, reason)
  ]);
}

function closeSlowConsumer(ws, reason = 'backpressure') {
  incrementSecurityCounter('ws_1013_backpressure');
  try {
    ws.close(1013, reason);
  } catch (_) {}
}

function wsSendRaw(ws, obj) {
  if (!ws || ws.readyState !== ws.OPEN) return false;
  const bufferedAmount = Number(ws.bufferedAmount || 0);
  if (bufferedAmount >= WS_MAX_BUFFERED_BYTES) {
    closeSlowConsumer(ws);
    return false;
  }
  const payload = JSON.stringify(obj);
  if ((bufferedAmount + Buffer.byteLength(payload, 'utf8')) > WS_MAX_BUFFERED_BYTES) {
    closeSlowConsumer(ws);
    return false;
  }
  ws.send(payload, (error) => {
    if (!error) return;
    console.warn('[WS] send failed:', error.message);
    try { ws.close(1011, 'send_failed'); } catch (_) {}
  });
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

async function renewRoomMembershipLease(ws, overrideMeta = null) {
  const meta = overrideMeta || wsMeta.get(ws);
  if (!meta?.sessionId || !meta?.deviceId) return false;
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
  return true;
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

async function revokeEphemeralIfPresent(kind, tokenHash, reason = 'revoked') {
  if (!tokenHash) return;
  return signalingState.updateEphemeral(kind, tokenHash, (record) => {
    record.state = 'revoked';
    record.revokedAt = now();
    record.revokedReason = reason;
  });
}

function connectionRoleTokenHash(record, role, kind) {
  if (!record || !role) return null;
  if (kind === 'session_token') {
    return role === 'initiator' ? record.initiatorSessionTokenHash : record.responderSessionTokenHash;
  }
  if (kind === 'turn_admission_token') {
    return role === 'initiator' ? record.initiatorTurnAdmissionTokenHash : record.responderTurnAdmissionTokenHash;
  }
  if (kind === 'media_admission_token') {
    return role === 'initiator' ? record.initiatorMediaAdmissionTokenHash : record.responderMediaAdmissionTokenHash;
  }
  return null;
}

function tokenGenerationPrefix(tokenHash) {
  return typeof tokenHash === 'string' && tokenHash.length > 0 ? tokenHash.slice(0, 16) : null;
}

function mediaTokenRejectReason({
  tokenRecord = null,
  sessionPresent = null,
  expectedHash = null,
  sessionRejectReason = null
} = {}) {
  if (typeof tokenRecord?.revokedReason === 'string' && tokenRecord.revokedReason.trim()) {
    return tokenRecord.revokedReason.trim();
  }
  if (tokenRecord?.state === 'revoked') {
    return 'revoked';
  }
  if (sessionRejectReason) {
    return sessionRejectReason;
  }
  if (sessionPresent === false) {
    return 'missingRecord';
  }
  if (!expectedHash) {
    return 'expectedTokenMissing';
  }
  return undefined;
}

function mediaTokenDiagnostics({
  requestHash,
  expectedHash,
  tokenRecord = null,
  sessionPresent = null,
  sessionRecordPresent = null,
  sessionRejectReason = null,
  sessionRevokedReason = null,
  tokenState = null,
  leaseCount = null
}) {
  const requestGeneration = tokenGenerationPrefix(requestHash);
  const expectedGeneration = tokenGenerationPrefix(expectedHash);
  const rejectReason = mediaTokenRejectReason({ tokenRecord, sessionPresent, expectedHash, sessionRejectReason });
  return {
    serverBuildFingerprint: SERVER_BUILD_FINGERPRINT,
    supportsMediaAdmissionRefresh: true,
    mediaTokenGeneration: requestGeneration,
    mediaTokenRequestGeneration: requestGeneration,
    mediaTokenExpectedGeneration: expectedGeneration,
    mediaTokenExpectedPresent: Boolean(expectedHash),
    mediaTokenSessionPresent: sessionPresent === null ? undefined : Boolean(sessionPresent),
    mediaTokenSessionRecordPresent: sessionRecordPresent === null ? undefined : Boolean(sessionRecordPresent),
    mediaTokenSessionRejectReason: sessionRejectReason || undefined,
    mediaTokenSessionRevokedReason: sessionRevokedReason || undefined,
    mediaTokenState: tokenState || tokenRecord?.state || undefined,
    mediaTokenRevokedReason: tokenRecord?.revokedReason || undefined,
    rejectReason,
    mediaTokenLeaseCount: Number.isFinite(Number(leaseCount ?? tokenRecord?.leaseCount))
      ? Number(leaseCount ?? tokenRecord?.leaseCount)
      : undefined
  };
}

function stripUndefinedFields(value) {
  return Object.fromEntries(Object.entries(value).filter(([, fieldValue]) => fieldValue !== undefined));
}

async function peekConnectionForDiagnostics(sessionId) {
  if (!sessionId) return null;
  if (typeof signalingState.peekConnection === 'function') {
    return signalingState.peekConnection(sessionId);
  }
  return signalingState.getConnection(sessionId);
}

function connectionRejectReasonForDiagnostics(connection) {
  if (!connection) return 'missingRecord';
  if (connection.revokedAt) return connection.revokedReason || 'revoked';
  if (now() > connectionActiveUntil(connection)) return 'activeExpired';
  return null;
}

async function mediaTokenMismatchDiagnostics(tokenRecord, tokenHash) {
  const session = await peekConnectionForDiagnostics(tokenRecord?.sessionId);
  const sessionRejectReason = connectionRejectReasonForDiagnostics(session);
  const sessionActive = Boolean(session && !sessionRejectReason);
  return stripUndefinedFields(mediaTokenDiagnostics({
    requestHash: tokenHash,
    expectedHash: sessionActive
      ? connectionRoleTokenHash(session, tokenRecord?.role, 'media_admission_token')
      : null,
    tokenRecord,
    sessionPresent: sessionActive,
    sessionRecordPresent: Boolean(session),
    sessionRejectReason,
    sessionRevokedReason: session?.revokedReason || undefined
  }));
}

async function isEphemeralTokenCurrent(kind, tokenRecord, tokenHash) {
  if (!tokenRecord?.sessionId || !tokenRecord?.role || !tokenHash) {
    return false;
  }
  const connection = await peekConnectionForDiagnostics(tokenRecord.sessionId);
  if (!connection || connectionRejectReasonForDiagnostics(connection)) {
    return false;
  }
  return connectionRoleTokenHash(connection, tokenRecord.role, kind) === tokenHash;
}

async function issueMediaAdmissionArtifact({ sessionId, role, context }) {
  const mediaAdmissionToken = issueEphemeralTokenRecord({
    kind: 'media_admission_token',
    ttlMs: MEDIA_ADMISSION_TOKEN_TTL_MS,
    payload: {
      sessionId,
      role,
      tenantId: context.tenantId,
      userId: context.userId,
      deviceId: context.deviceId,
      protocolSigningAlgorithm: context.protocolSigningAlgorithm,
      protocolPublicKeyFingerprint: context.protocolPublicKeyFingerprint,
      deviceSynthetic: context.deviceSynthetic,
      clientVersion: context.clientVersion,
      protocolVersion: context.protocolVersion,
      mtlsClientCertificateFingerprint256: context.mtlsClientCertificateFingerprint256 || null
    }
  });
  const created = await signalingState.createEphemeral(
    'media_admission_token',
    mediaAdmissionToken.tokenHash,
    mediaAdmissionToken.record
  );
  if (!created) {
    throw makeError('token_issue_failed', 500);
  }
  return {
    mediaAdmissionToken: mediaAdmissionToken.token,
    mediaAdmissionTokenHash: mediaAdmissionToken.tokenHash,
    expiresAt: mediaAdmissionToken.record.expiresAt
  };
}

async function bindResponderArtifactsStrict(sessionId, {
  binding,
  artifacts,
  qrBootstrapTokenHash = null
}) {
  let rejectedError = null;
  let bound = false;
  const item = await signalingState.updateConnection(sessionId, (nextItem) => {
    if (qrBootstrapTokenHash) {
      if (!nextItem.qrBootstrapTokenHash || nextItem.qrBootstrapTokenHash !== qrBootstrapTokenHash) {
        rejectedError = 'bootstrap_token_invalid';
        return false;
      }
      if (nextItem.qrBootstrapConsumedAt) {
        rejectedError = 'responder_already_bound';
        return false;
      }
    }
    const sameResponder = !nextItem.responderId || nextItem.responderId === binding.deviceId;
    const sameFingerprint = !nextItem.responderProtocolPublicKeyFingerprint
      || nextItem.responderProtocolPublicKeyFingerprint === binding.protocolPublicKeyFingerprint;
    if (!sameResponder || !sameFingerprint) {
      rejectedError = 'responder_binding_conflict';
      return false;
    }
    if (roleHasActiveTokenHashes(nextItem, 'responder')) {
      rejectedError = 'responder_already_bound';
      return false;
    }
    nextItem.responderId = binding.deviceId;
    nextItem.responderProtocolSigningAlgorithm = binding.protocolSigningAlgorithm;
    nextItem.responderProtocolPublicKeyFingerprint = binding.protocolPublicKeyFingerprint;
    if (qrBootstrapTokenHash) {
      nextItem.qrBootstrapConsumedAt = now();
    }
    setConnectionRoleTokenHashes(nextItem, 'responder', artifacts);
    extendConnectionActiveUntil(nextItem);
    bound = true;
  });
  if (!item) return null;
  if (bound) {
    logSessionLifecycle(sessionId, 'redeemed', {
      role: 'responder',
      activeUntil: item.activeUntil
    });
  }
  return { item, bound, error: rejectedError };
}

async function refreshSessionArtifactsForRole({ sessionId, role, admission }) {
  const current = await signalingState.getConnection(sessionId);
  if (!current) {
    logSessionLifecycle(sessionId, 'refreshRejected', { role, rejectReason: 'missingRecord' });
    throw makeError('session_inactive', 403, { rejectReason: 'missingRecord' });
  }
  if (!admissionOwnsSession(current, admission)) {
    logSessionLifecycle(sessionId, 'refreshRejected', { role, rejectReason: 'scopeMismatch' });
    throw makeError('session_scope_mismatch', 403);
  }
  const context = contextFromAdmission(admission);
  if (!bindingMatches(roleParticipantBinding(current, role), context.binding)) {
    logSessionLifecycle(sessionId, 'refreshRejected', { role, rejectReason: 'scopeMismatch' });
    throw makeError('session_scope_mismatch', 403);
  }

  const targetActiveUntil = nextActiveUntil(current);
  const artifacts = await issueSessionArtifacts({ sessionId, role, context, expiresAt: targetActiveUntil });
  let previousSessionTokenHash = null;
  let previousTurnAdmissionTokenHash = null;
  let previousMediaAdmissionTokenHash = null;
  let updateError = null;
  let rotated = false;
  const updated = await signalingState.updateConnection(sessionId, (connection) => {
    if (!connection || connection.revokedAt) {
      updateError = 'session_inactive';
      return false;
    }
    if (!admissionOwnsSession(connection, admission)) {
      updateError = 'session_scope_mismatch';
      return false;
    }
    if (!bindingMatches(roleParticipantBinding(connection, role), context.binding)) {
      updateError = 'session_scope_mismatch';
      return false;
    }
    previousSessionTokenHash = connectionRoleTokenHash(connection, role, 'session_token');
    previousTurnAdmissionTokenHash = connectionRoleTokenHash(connection, role, 'turn_admission_token');
    previousMediaAdmissionTokenHash = connectionRoleTokenHash(connection, role, 'media_admission_token');
    setConnectionRoleTokenHashes(connection, role, artifacts);
    extendConnectionActiveUntil(connection);
    rotated = true;
  });

  if (!updated || !rotated) {
    await revokeSessionArtifactsIfPresent(artifacts, 'session_refresh_aborted');
    logSessionLifecycle(sessionId, 'refreshRejected', {
      role,
      rejectReason: updateError || 'missingRecord'
    });
    throw makeError(updateError || 'session_inactive', 403, {
      rejectReason: updateError || 'missingRecord'
    });
  }

  await Promise.all([
    previousSessionTokenHash && previousSessionTokenHash !== artifacts.sessionTokenHash
      ? revokeSupersededSessionTokenIfPresent(previousSessionTokenHash, 'session_token_refreshed')
      : null,
    previousTurnAdmissionTokenHash && previousTurnAdmissionTokenHash !== artifacts.turnAdmissionTokenHash
      ? revokeEphemeralIfPresent('turn_admission_token', previousTurnAdmissionTokenHash, 'session_token_refreshed')
      : null,
    previousMediaAdmissionTokenHash && previousMediaAdmissionTokenHash !== artifacts.mediaAdmissionTokenHash
      ? revokeEphemeralIfPresent('media_admission_token', previousMediaAdmissionTokenHash, 'session_token_refreshed')
      : null
  ]);

  return {
    artifacts,
    expiresAt: connectionActiveUntil(updated)
  };
}

async function touchConnectionActiveSession(sessionId, reason, options = {}) {
  const minIntervalMs = Number.isFinite(options.minIntervalMs) ? options.minIntervalMs : 30_000;
  const at = now();
  const lastTouchedAt = activeSessionTouchAtBySessionId.get(sessionId) || 0;
  if (minIntervalMs > 0 && at - lastTouchedAt < minIntervalMs) {
    return null;
  }
  let extended = false;
  const updated = await signalingState.updateConnection(sessionId, (connection) => {
    if (!connection || connection.revokedAt) {
      return false;
    }
    const previous = connectionActiveUntil(connection);
    const next = extendConnectionActiveUntil(connection, at);
    extended = next > previous;
  });
  if (!updated) {
    activeSessionTouchAtBySessionId.delete(sessionId);
    return null;
  }
  activeSessionTouchAtBySessionId.set(sessionId, at);
  if (extended || minIntervalMs === 0) {
    logSessionLifecycle(sessionId, 'activeExtended', {
      reason,
      activeUntil: connectionActiveUntil(updated)
    });
  }
  return updated;
}

async function revokeSupersededSessionTokenIfPresent(tokenHash, reason = 'superseded') {
  const revoked = await revokeEphemeralIfPresent('session_token', tokenHash, reason);
  if (!revoked?.boundClientId || !revoked?.boundInstanceId) {
    return;
  }
  if (revoked.boundInstanceId === INSTANCE_ID) {
    await dropLocalClientById(revoked.boundClientId, reason);
    return;
  }
  await signalingState.publishToInstance(revoked.boundInstanceId, {
    kind: 'drop-client',
    clientId: revoked.boundClientId,
    reason
  });
}

async function killSession(sessionId, reason) {
  const normalizedReason = reason || 'session_killed';
  const record = await signalingState.updateConnection(sessionId, (item) => {
    item.revokedAt = now();
    item.revokedReason = normalizedReason;
  });
  if (record) {
    await Promise.all([
      revokeEphemeralIfPresent('session_token', record.initiatorSessionTokenHash, normalizedReason),
      revokeEphemeralIfPresent('session_token', record.responderSessionTokenHash, normalizedReason),
      revokeEphemeralIfPresent('turn_admission_token', record.initiatorTurnAdmissionTokenHash, normalizedReason),
      revokeEphemeralIfPresent('turn_admission_token', record.responderTurnAdmissionTokenHash, normalizedReason),
      revokeEphemeralIfPresent('media_admission_token', record.initiatorMediaAdmissionTokenHash, normalizedReason),
      revokeEphemeralIfPresent('media_admission_token', record.responderMediaAdmissionTokenHash, normalizedReason)
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
  const preview = await signalingState.getEphemeral('admission_token', tokenHash);
  if (!preview) throw makeError('admission_token_expired', 401);
  assertMTLSBindingForRecord(req, preview, 'admission_token');
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
  assertMTLSBindingForRecord(req, record, 'admission_token');
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
  const preview = await signalingState.getEphemeral('turn_admission_token', tokenHash);
  if (!preview) throw makeError('turn_admission_token_expired', 401);
  assertMTLSBindingForRecord(req, preview, 'turn_admission_token');
  if (!(await isEphemeralTokenCurrent('turn_admission_token', preview, tokenHash))) {
    throw makeError('turn_admission_token_superseded', 401);
  }
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
  assertMTLSBindingForRecord(req, record, 'turn_admission_token');
  return record;
}

async function getMediaAdmissionRecord(req) {
  const rawToken = getOpaqueHeader(req, 'X-SkyBridge-Media-Admission');
  if (!rawToken) {
    throw makeError('missing_media_admission_token', 401);
  }
  const tokenHash = sha256Hex(rawToken);
  const preview = await signalingState.getEphemeral('media_admission_token', tokenHash);
  if (!preview) throw makeError('media_admission_token_expired', 401);
  assertMTLSBindingForRecord(req, preview, 'media_admission_token');
  if (!(await isEphemeralTokenCurrent('media_admission_token', preview, tokenHash))) {
    const diagnostics = await mediaTokenMismatchDiagnostics(preview, tokenHash);
    console.warn(
      `[media] admission token superseded before lease ` +
      `sessionLogId=${sessionLogIdForLog(preview.sessionId)} session=${LOG_REDACTED} role=${preview.role || '-'} ` +
      `requestGeneration=${diagnostics.mediaTokenRequestGeneration || '-'} ` +
      `expectedGeneration=${diagnostics.mediaTokenExpectedGeneration || '-'} ` +
      `expectedPresent=${diagnostics.mediaTokenExpectedPresent ? '1' : '0'} ` +
      `tokenState=${diagnostics.mediaTokenState || '-'} ` +
      `rejectReason=${diagnostics.rejectReason || '-'} serverBuild=${SERVER_BUILD_FINGERPRINT}`
    );
    throw makeError('media_admission_token_superseded', 401, diagnostics);
  }
  let updateError = null;
  const record = await signalingState.updateEphemeral('media_admission_token', tokenHash, (current) => {
    if (current.state !== 'issued' && current.state !== 'leased') {
      updateError = 'media_admission_token_consumed';
      return false;
    }
    current.state = 'leased';
    current.leasedAt = now();
    current.leaseCount = Number(current.leaseCount || 0) + 1;
    if (current.leaseCount > 4) {
      updateError = 'media_admission_token_lease_limit';
      return false;
    }
  });
  if (!record) throw makeError('media_admission_token_expired', 401);
  if (updateError) throw makeError(updateError, updateError === 'media_admission_token_lease_limit' ? 429 : 409);
  assertMTLSBindingForRecord(req, record, 'media_admission_token');
  return record;
}

function hasExternalMediaRelay() {
  return Boolean(MEDIA_RELAY_EXTERNAL_HOST && MEDIA_RELAY_EXTERNAL_UDP_PORT > 0);
}

async function issueMediaRelayLease(mediaToken) {
  if (hasExternalMediaRelay()) {
    const lease = createSignedMediaLeaseToken({
      sessionId: mediaToken.sessionId,
      role: mediaToken.role,
      tenantId: mediaToken.tenantId,
      userId: mediaToken.userId,
      ttlMs: MEDIA_RELAY_LEASE_TTL_MS,
      secret: MEDIA_RELAY_TOKEN_SECRET
    });
    return {
      endpoint: {
        host: MEDIA_RELAY_EXTERNAL_HOST,
        port: MEDIA_RELAY_EXTERNAL_UDP_PORT,
        protocol: 'udp'
      },
      lease
    };
  }
  if (!mediaRelay) {
    throw makeError('media_relay_not_enabled', 503);
  }
  const relayAddress = mediaRelay.snapshot().address || await mediaRelay.start();
  const lease = mediaRelay.createLease({
    sessionId: mediaToken.sessionId,
    role: mediaToken.role,
    tenantId: mediaToken.tenantId,
    userId: mediaToken.userId,
    ttlMs: MEDIA_RELAY_LEASE_TTL_MS
  });
  return {
    endpoint: {
      host: relayAddress.host,
      port: relayAddress.port,
      protocol: 'udp'
    },
    lease
  };
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
  // 反射式 ACAO 必须配合 Vary: Origin，否则共享/CDN 缓存可能把某一 origin 的
  // Access-Control-Allow-Origin 复用给其他 origin，造成跨源缓存投毒。
  res.setHeader('Vary', 'Origin');
  if (origin && CORS_ORIGIN) {
    const allowList = CORS_ORIGIN.split(',').map((item) => item.trim()).filter(Boolean);
    if (allowList.includes(origin)) {
      res.setHeader('Access-Control-Allow-Origin', origin);
    }
  }
  res.setHeader('Access-Control-Allow-Methods', 'GET,POST,OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization, Idempotency-Key, X-SkyBridge-Tenant-Id, X-SkyBridge-Admission, X-SkyBridge-Turn-Admission, X-SkyBridge-Media-Admission, X-SkyBridge-Session-Id, X-SkyBridge-Session, X-SkyBridge-Client-Version, X-SkyBridge-Protocol-Version');
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('Content-Security-Policy', "default-src 'none'");
  if (req.method === 'OPTIONS') return res.sendStatus(204);
  next();
});

const rlControl = rateLimit({ windowMs: 60_000, max: HTTP_CONTROL_RATE_LIMIT_PER_MIN });
const rlLookup = rateLimit({ windowMs: 60_000, max: HTTP_LOOKUP_RATE_LIMIT_PER_MIN });
const rlTurn = rateLimit({ windowMs: 60_000, max: HTTP_TURN_RATE_LIMIT_PER_MIN });
const rlMedia = rateLimit({ windowMs: 60_000, max: HTTP_MEDIA_RATE_LIMIT_PER_MIN });
const rlAdmission = rateLimit({ windowMs: 60_000, max: HTTP_ADMISSION_RATE_LIMIT_PER_MIN });

function evaluateServiceHealth({
  backendHealth,
  smsHealth = collectSMSServiceSnapshot(),
  stateBackend = SIGNALING_STATE_BACKEND,
  requireSharedStateForPublicCapabilities = currentRequireSharedStateForPublicCapabilities,
  requireSMSAuthReady = REQUIRE_SMS_AUTH_READY
} = {}) {
  const normalizedBackendHealth = backendHealth && typeof backendHealth === 'object'
    ? backendHealth
    : { ready: false, redisConnected: false };
  const backendReady = Boolean(normalizedBackendHealth.ready);
  const redisConnected = Boolean(normalizedBackendHealth.redisConnected);
  const sharedStateReady = stateBackend === 'redis' && backendReady && redisConnected;
  const reasons = [];

  if (!backendReady) {
    reasons.push('state_backend_unready');
  }
  if (requireSharedStateForPublicCapabilities) {
    if (stateBackend !== 'redis') {
      reasons.push('shared_state_backend_required');
    } else if (!redisConnected) {
      reasons.push('shared_state_unavailable');
    }
  }
  if (requireSMSAuthReady && !smsHealth.ready) {
    reasons.push(...smsHealth.reasons);
  }

  const ready = unique(reasons).length === 0;
  return {
    status: ready ? 'ok' : 'degraded',
    ready,
    httpStatus: ready ? 200 : 503,
    reasons: unique(reasons),
    backendHealth: normalizedBackendHealth,
    backendReady,
    sharedStateReady,
    stateBackend,
    requiresSharedStateForPublicCapabilities: Boolean(requireSharedStateForPublicCapabilities),
    requiresSMSAuthReady: Boolean(requireSMSAuthReady),
    sms: smsHealth
  };
}

async function collectServiceHealthSnapshot() {
  const backendHealth = await signalingState.getHealth();
  const smsHealth = collectSMSServiceSnapshot();
  return evaluateServiceHealth({ backendHealth, smsHealth });
}

function collectMediaRelaySnapshot() {
  if (mediaRelay) {
    return {
      enabled: true,
      external: false,
      ...mediaRelay.snapshot()
    };
  }
  if (hasExternalMediaRelay()) {
    return {
      enabled: true,
      external: true,
      address: {
        host: MEDIA_RELAY_EXTERNAL_HOST,
        port: MEDIA_RELAY_EXTERNAL_UDP_PORT
      },
      maxPacketBytes: MEDIA_RELAY_MAX_PACKET_BYTES
    };
  }
  return {
    enabled: false,
    external: false
  };
}

app.get('/', asyncRoute(async (req, res) => {
  const health = await collectServiceHealthSnapshot();
  res.status(200).json({
    ok: true,
    service: 'skybridge-signaling',
    time: new Date().toISOString(),
    instanceId: INSTANCE_ID,
    serverBuildFingerprint: SERVER_BUILD_FINGERPRINT,
    stateBackend: SIGNALING_STATE_BACKEND,
    smsProvider: health.sms.provider,
    smsHookConfigured: health.sms.hookConfigured,
    smsProviderConfigured: health.sms.providerConfigured,
    smsReady: health.sms.ready,
    smsReadinessReasons: health.sms.reasons,
    sms: health.sms,
    backendHealth: health.backendHealth,
    mediaRelay: collectMediaRelaySnapshot(),
    ready: health.ready,
    readiness: {
      status: health.status,
      reasons: health.reasons,
      requiresSharedStateForPublicCapabilities: health.requiresSharedStateForPublicCapabilities,
      sharedStateReady: health.sharedStateReady,
      requiresSMSAuthReady: health.requiresSMSAuthReady
    },
    protection: {
      ...appControlFlags(),
      redisLatencySamples: runtimeProtection.redisLatencySamples
    },
    endpoints: [
      '/health',
      '/healthz',
      '/readyz',
      '/api/hooks/supabase/send-sms',
      '/api/webrtc/admission/challenge',
      '/api/webrtc/admission',
      '/api/webrtc/register-code',
      '/api/webrtc/lookup/:code',
      '/api/webrtc/register-session',
      '/api/webrtc/redeem-session',
      '/api/webrtc/session/refresh',
      '/api/turn/credentials',
      '/api/media/admission/refresh',
      '/api/media/lease',
      '/api/devices/enroll/first',
      '/api/devices/enroll/confirm',
      `${SIGNALING_WEBSOCKET_PATH}?shard=<session_id> with X-SkyBridge-Session-Id/X-SkyBridge-Session headers`
    ]
  });
}));

app.get('/health', asyncRoute(async (req, res) => {
  const health = await collectServiceHealthSnapshot();
  res.status(health.httpStatus).json({
    status: health.status,
    ready: health.ready,
    instanceId: INSTANCE_ID,
    serverBuildFingerprint: SERVER_BUILD_FINGERPRINT,
    supportsMediaAdmissionRefresh: true,
    stateBackend: SIGNALING_STATE_BACKEND,
    smsProvider: health.sms.provider,
    smsHookConfigured: health.sms.hookConfigured,
    smsProviderConfigured: health.sms.providerConfigured,
    smsReady: health.sms.ready,
    smsReadinessReasons: health.sms.reasons,
    sms: health.sms,
    backendHealth: health.backendHealth,
    mediaRelay: collectMediaRelaySnapshot(),
    reasons: health.reasons,
    requiresSharedStateForPublicCapabilities: health.requiresSharedStateForPublicCapabilities,
    requiresSMSAuthReady: health.requiresSMSAuthReady,
    sharedStateReady: health.sharedStateReady,
    protection: {
      ...appControlFlags(),
      redisLatencySamples: runtimeProtection.redisLatencySamples
    },
    counters: currentSecurityCounters(),
    wsClients: wss ? wss.clients.size : 0
  });
}));

app.get('/healthz', (req, res) => res.status(200).send('ok'));

app.get('/readyz', asyncRoute(async (req, res) => {
  const health = await collectServiceHealthSnapshot();
  res.status(health.httpStatus).json({
    status: health.ready ? 'ready' : 'not_ready',
    instanceId: INSTANCE_ID,
    serverBuildFingerprint: SERVER_BUILD_FINGERPRINT,
    supportsMediaAdmissionRefresh: true,
    stateBackend: SIGNALING_STATE_BACKEND,
    reasons: health.reasons,
    requiresSharedStateForPublicCapabilities: health.requiresSharedStateForPublicCapabilities,
    requiresSMSAuthReady: health.requiresSMSAuthReady,
    sharedStateReady: health.sharedStateReady,
    smsProvider: health.sms.provider,
    smsHookConfigured: health.sms.hookConfigured,
    smsProviderConfigured: health.sms.providerConfigured,
    smsReady: health.sms.ready,
    smsReadinessReasons: health.sms.reasons,
    sms: health.sms
  });
}));

app.post('/api/hooks/supabase/send-sms', asyncRoute(async (req, res) => {
  incrementSMSCounter('hook_requests_total');
  const smsHealth = collectSMSServiceSnapshot();
  if (!supabaseSMSHookVerifier || !smsHealth.hookConfigured) {
    incrementSMSCounter('hook_rejected_missing_secret');
    recordSMSDeliveryEvent('error', {
      event: 'supabase_send_sms_hook_rejected',
      provider: smsHealth.provider,
      reason: 'missing_hook_secret'
    });
    throw makeError('supabase_send_sms_hook_not_configured', 503);
  }
  if (!smsHealth.providerSupported || !smsHealth.providerConfigured) {
    incrementSMSCounter('hook_rejected_provider_not_ready');
    recordSMSDeliveryEvent('error', {
      event: 'supabase_send_sms_hook_rejected',
      provider: smsHealth.provider,
      reason: smsHealth.providerSupported ? 'provider_not_configured' : 'provider_unsupported',
      missingConfiguration: smsHealth.missingConfiguration
    });
    throw makeError(smsHealth.providerSupported ? 'aliyun_sms_not_configured' : 'aliyun_sms_provider_unsupported', 503);
  }

  const payload = typeof req.rawBody === 'string' && req.rawBody.length > 0
    ? req.rawBody
    : JSON.stringify(req.body || {});

  let hookPayload;
  try {
    hookPayload = supabaseSMSHookVerifier.verify(payload, hookHeaderMap(req));
  } catch (error) {
    incrementSecurityCounter('supabase_send_sms_hook_verify_failed');
    incrementSMSCounter('hook_verify_failed');
    recordSMSDeliveryEvent('warn', {
      event: 'supabase_send_sms_hook_verify_failed',
      provider: smsHealth.provider,
      reason: 'invalid_signature',
      message: error.message
    });
    throw makeError('supabase_send_sms_hook_invalid', 401);
  }

  const otp = String(hookPayload?.sms?.otp || '').trim();
  const phoneNumber = String(hookPayload?.user?.phone || '').trim();
  if (!otp || !phoneNumber) {
    incrementSMSCounter('hook_bad_payload');
    recordSMSDeliveryEvent('warn', {
      event: 'supabase_send_sms_hook_bad_payload',
      provider: smsHealth.provider,
      reason: 'missing_phone_or_otp'
    });
    throw makeError('bad_send_sms_payload', 400);
  }

  try {
    const result = await smsClient.sendVerificationCode({ phoneNumber, otp });
    incrementSMSCounter('delivery_success');
    incrementSMSCounter(`delivery_success_${smsHealth.provider}`);
    recordSMSDeliveryEvent('info', {
      event: 'supabase_send_sms_delivered',
      provider: smsHealth.provider,
      phoneSuffix: maskedPhoneSuffix(phoneNumber),
      requestId: result.requestId || null,
      bizId: result.bizId || null
    });
    res.status(200).json({});
  } catch (error) {
    const classification = classifySMSDeliveryFailure(error);
    incrementSecurityCounter('supabase_send_sms_delivery_failed');
    incrementSMSCounter('delivery_failed');
    incrementSMSCounter(`delivery_failed_${classification.reason}`);
    if (classification.retryable) {
      incrementSMSCounter('delivery_failed_retryable');
    } else {
      incrementSMSCounter('delivery_failed_non_retryable');
    }
    recordSMSDeliveryEvent('error', {
      event: 'supabase_send_sms_delivery_failed',
      provider: smsHealth.provider,
      phoneSuffix: maskedPhoneSuffix(phoneNumber),
      reason: classification.reason,
      retryable: classification.retryable,
      message: error.message,
      providerCode: safeUpperCode(error?.response?.code || error?.response?.Code || '')
    });
    throw makeError(classification.errorCode, classification.statusCode);
  }
}));

app.post('/api/webrtc/admission/challenge', rlAdmission, asyncRoute(async (req, res) => {
  const context = await loadAuthenticatedDeviceContext(req, { requireRegisteredDevice: true });
  await assertPublicCapabilityAvailable('challenge', context.tenantId);
  if (appControlFlags().disableChallengeAdmission) {
    throw makeError('challenge_disabled', 503);
  }
  await enforceChallengeQuotas(context);
  const mtlsClientCertificateFingerprint256 = mtlsClientCertificateFingerprintForRequest(req);
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
    expiresAt: now() + CHALLENGE_TTL_MS,
    ...(mtlsClientCertificateFingerprint256 ? { mtlsClientCertificateFingerprint256 } : {})
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
  const mtlsClientCertificateFingerprint256 = mtlsClientCertificateFingerprintForRequest(req);
  const mtlsCertificate = mtlsClientCertificateFingerprint256
    ? { fingerprint256: mtlsClientCertificateFingerprint256 }
    : null;
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
    const mtlsBindingError = mtlsBindingErrorForRecord(current, mtlsCertificate, 'challenge');
    if (mtlsBindingError) {
      consumeError = mtlsBindingError;
      return false;
    }
    current.state = 'consumed';
    current.consumedAt = now();
  });
  if (!challenge) throw makeError('challenge_expired', 401);
  if (consumeError) {
    throw makeError(
      consumeError,
      consumeError.includes('_mtls_') ? mtlsBindingStatusCode(consumeError) : 409
    );
  }
  if (!await verifyChallengeSignature(publicBinding, signature, challenge)) {
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
      challengeId,
      mtlsClientCertificateFingerprint256
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
  const context = contextFromAdmission(admission);
  const artifacts = await issueSessionArtifacts({ sessionId: '', role: 'initiator', context, expiresAt });
  const code = await signalingState.createConnectionCode(generateCode, 10, buildConnectionRecord({
    initiatorContext: context,
    initiatorDeviceName: deviceName,
    expiresAt,
    signalingServerOrigin: resolvedSignalingServerOrigin(req),
    connectionKind: 'webrtc_room_code',
    initiatorSessionTokenHash: artifacts.sessionTokenHash,
    initiatorTurnAdmissionTokenHash: artifacts.turnAdmissionTokenHash,
    initiatorMediaAdmissionTokenHash: artifacts.mediaAdmissionTokenHash
  }));
  if (!code) throw makeError('code_generation_failed', 500);
  logSessionLifecycle(code, 'registered', {
    kind: 'webrtc_room_code',
    rendezvousExpiresAt: expiresAt
  });
  await signalingState.updateEphemeral('session_token', artifacts.sessionTokenHash, (record) => {
    record.sessionId = code;
  });
  await signalingState.updateEphemeral('turn_admission_token', artifacts.turnAdmissionTokenHash, (record) => {
    record.sessionId = code;
  });
  await signalingState.updateEphemeral('media_admission_token', artifacts.mediaAdmissionTokenHash, (record) => {
    record.sessionId = code;
  });
  res.json({
    code,
    sessionId: code,
    sessionToken: artifacts.sessionToken,
    turnAdmissionToken: artifacts.turnAdmissionToken,
    mediaAdmissionToken: artifacts.mediaAdmissionToken,
    expiresIn: Math.max(0, Math.round((expiresAt - now()) / 1000)),
    signalingServerOrigin: resolvedSignalingServerOrigin(req),
    wsPath: SIGNALING_WEBSOCKET_PATH
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
  if (isRendezvousExpired(item)) {
    incrementSecurityCounter('lookup_not_found');
    logSessionLifecycle(code, 'refreshRejected', { rejectReason: 'rendezvousExpired' });
    return res.status(404).json({ found: false });
  }
  if (!admissionOwnsSession(item, admission)) {
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
  const context = contextFromAdmission(admission);
  const artifacts = await issueSessionArtifacts({ sessionId: code, role: 'responder', context, expiresAt: nextActiveUntil(item) });
  const result = await bindResponderArtifactsStrict(code, { binding, artifacts });
  if (!result?.item || result.error || !result.bound) {
    await revokeSessionArtifactsIfPresent(artifacts, 'responder_bind_rejected');
    if (!result?.item) {
      return res.status(404).json({ found: false });
    }
    throw makeError(result.error || 'responder_binding_conflict', 409);
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
    mediaAdmissionToken: artifacts.mediaAdmissionToken,
    expiresIn: Math.max(0, Math.round((connectionActiveUntil(result.item) - now()) / 1000)),
    signalingServerOrigin: result.item.signalingServerOrigin || resolvedSignalingServerOrigin(req),
    wsPath: SIGNALING_WEBSOCKET_PATH
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
    const context = contextFromAdmission(admission);
    const artifacts = await issueSessionArtifacts({ sessionId, role: 'initiator', context, expiresAt });
    const qrBootstrapToken = newOpaqueToken(24);
    const created = await signalingState.createConnectionRecord(sessionId, buildConnectionRecord({
      initiatorContext: context,
      expiresAt,
      qrBootstrapTokenHash: sha256Hex(qrBootstrapToken),
      signalingServerOrigin: resolvedSignalingServerOrigin(req),
      connectionKind: 'webrtc_room_session',
      initiatorSessionTokenHash: artifacts.sessionTokenHash,
      initiatorTurnAdmissionTokenHash: artifacts.turnAdmissionTokenHash,
      initiatorMediaAdmissionTokenHash: artifacts.mediaAdmissionTokenHash
    }));
    if (!created) throw makeError('session_exists', 409);
    logSessionLifecycle(sessionId, 'registered', {
      kind: 'webrtc_room_session',
      rendezvousExpiresAt: expiresAt
    });
    const responseBody = {
      sessionId,
      sessionToken: artifacts.sessionToken,
      qrBootstrapToken,
      turnAdmissionToken: artifacts.turnAdmissionToken,
      mediaAdmissionToken: artifacts.mediaAdmissionToken,
      expiresIn: Math.max(0, Math.round((expiresAt - now()) / 1000)),
      signalingServerOrigin: resolvedSignalingServerOrigin(req),
      wsPath: SIGNALING_WEBSOCKET_PATH
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
    if (isRendezvousExpired(item)) {
      logSessionLifecycle(sessionId, 'refreshRejected', { rejectReason: 'rendezvousExpired' });
      throw makeError('session_expired', 404);
    }
    if (!admissionOwnsSession(item, admission)) {
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
    const context = contextFromAdmission(admission);
    const artifacts = await issueSessionArtifacts({ sessionId, role: 'responder', context, expiresAt: nextActiveUntil(item) });
    const result = await bindResponderArtifactsStrict(sessionId, {
      binding,
      artifacts,
      qrBootstrapTokenHash: sha256Hex(qrBootstrapToken)
    });
    if (!result?.item || result.error || !result.bound) {
      await revokeSessionArtifactsIfPresent(artifacts, 'responder_bind_rejected');
      if (!result?.item) throw makeError('session_expired', 404);
      throw makeError(
        result.error === 'bootstrap_token_invalid' ? 'bootstrap_token_invalid' : (result.error || 'responder_binding_conflict'),
        result.error === 'bootstrap_token_invalid' ? 401 : 409
      );
    }
    const responseBody = {
      sessionId,
      sessionToken: artifacts.sessionToken,
      turnAdmissionToken: artifacts.turnAdmissionToken,
      mediaAdmissionToken: artifacts.mediaAdmissionToken,
      expiresIn: Math.max(0, Math.round((connectionActiveUntil(result.item) - now()) / 1000)),
      signalingServerOrigin: result.item.signalingServerOrigin || resolvedSignalingServerOrigin(req),
      wsPath: SIGNALING_WEBSOCKET_PATH,
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

app.post('/api/webrtc/session/refresh', rlControl, asyncRoute(async (req, res) => {
  const sessionId = String(req.body?.sessionId || '').trim();
  const role = String(req.body?.role || '').trim();
  if (!sessionId || (role !== 'initiator' && role !== 'responder')) {
    throw makeError('invalid_session_refresh_request', 400);
  }
  const admission = await consumeAdmissionToken(req, 'session-refresh');
  await assertPublicCapabilityAvailable('session_refresh', admission.tenantId);
  const { artifacts, expiresAt } = await refreshSessionArtifactsForRole({ sessionId, role, admission });
  logSessionLifecycle(sessionId, 'refreshAccepted', {
    role,
    activeUntil: expiresAt
  });
  res.json({
    sessionId,
    role,
    sessionToken: artifacts.sessionToken,
    turnAdmissionToken: artifacts.turnAdmissionToken,
    mediaAdmissionToken: artifacts.mediaAdmissionToken,
    expiresIn: Math.max(0, Math.round((expiresAt - now()) / 1000)),
    signalingServerOrigin: resolvedSignalingServerOrigin(req),
    wsPath: SIGNALING_WEBSOCKET_PATH,
    serverBuildFingerprint: SERVER_BUILD_FINGERPRINT,
    supportsSessionRefresh: true,
    sessionTokenGeneration: artifacts.sessionTokenHash.slice(0, 16),
    mediaTokenGeneration: artifacts.mediaAdmissionTokenHash.slice(0, 16)
  });
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
  let deviceRecord = null;
  const canReadRegisteredDevices = registryCanReadRegisteredDevices();
  if (canReadRegisteredDevices) {
    deviceRecord = await registryStore.getRegisteredDevice({
      tenantId: turnToken.tenantId,
      userId: turnToken.userId,
      deviceId: turnToken.deviceId,
      protocolSigningAlgorithm: turnToken.protocolSigningAlgorithm,
      protocolPublicKeyFingerprint: turnToken.protocolPublicKeyFingerprint
    });
  }
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
  if (!deviceRecord && !canReadRegisteredDevices) {
    throw makeError('registry_not_configured', 503);
  }
  if (!deviceRecord || deviceRecord.status !== 'active') {
    throw makeError('device_not_active', 403);
  }
  const session = await signalingState.getConnection(turnToken.sessionId);
  if (!session || session.revokedAt) {
    throw makeError('session_inactive', 403);
  }
  await touchConnectionActiveSession(turnToken.sessionId, 'turnCredentials', { minIntervalMs: 30_000 });
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

app.post('/api/media/admission/refresh', rlMedia, asyncRoute(async (req, res) => {
  const sessionId = String(req.body?.sessionId || '').trim();
  const role = String(req.body?.role || '').trim();
  if (!sessionId || (role !== 'initiator' && role !== 'responder')) {
    throw makeError('invalid_media_admission_refresh_request', 400);
  }

  const rawSessionToken = getOpaqueHeader(req, 'X-SkyBridge-Session');
  if (!rawSessionToken) {
    throw makeError('missing_session_token', 401);
  }
  const idempotencyKey = String(req.get('Idempotency-Key') || req.get('X-SkyBridge-Idempotency-Key') || '').trim();
  const refreshFingerprint = buildIdempotencyFingerprint({
    action: 'media-admission-refresh',
    body: req.body || {},
    admissionToken: rawSessionToken,
    backendName: SIGNALING_STATE_BACKEND,
    fallbackTtlMs: MEDIA_ADMISSION_TOKEN_TTL_MS
  });
  const idempotency = await createIdempotencyGuard('media-admission-refresh', idempotencyKey, refreshFingerprint);
  if (idempotency?.existing?.responseBody) {
    return res.json(idempotency.existing.responseBody);
  }
  try {
    const sessionTokenHash = sha256Hex(rawSessionToken);
    const sessionToken = await signalingState.getEphemeral('session_token', sessionTokenHash);
    if (!sessionToken) {
      throw makeError('session_token_expired', 401);
    }
    assertMTLSBindingForRecord(req, sessionToken, 'session_token');
    if (!(await isEphemeralTokenCurrent('session_token', sessionToken, sessionTokenHash))) {
      throw makeError('session_token_superseded', 401);
    }
    if (sessionToken.sessionId !== sessionId || sessionToken.role !== role) {
      throw makeError('session_scope_mismatch', 403);
    }

    await assertPublicCapabilityAvailable('media_relay', sessionToken.tenantId);
    const artifacts = await issueMediaAdmissionArtifact({
      sessionId,
      role,
      context: sessionToken
    });

    let previousMediaAdmissionTokenHash = null;
    let updatedConnection = false;
    const updated = await signalingState.updateConnection(sessionId, (connection) => {
      if (!connection || connection.revokedAt) {
        return false;
      }
      const currentSessionTokenHash = connectionRoleTokenHash(connection, role, 'session_token');
      if (!currentSessionTokenHash || currentSessionTokenHash !== sessionTokenHash) {
        return false;
      }
      previousMediaAdmissionTokenHash = connectionRoleTokenHash(connection, role, 'media_admission_token');
      if (role === 'initiator') {
        connection.initiatorMediaAdmissionTokenHash = artifacts.mediaAdmissionTokenHash;
      } else {
        connection.responderMediaAdmissionTokenHash = artifacts.mediaAdmissionTokenHash;
      }
      extendConnectionActiveUntil(connection);
      updatedConnection = true;
    });

    if (!updated || !updatedConnection) {
      await revokeEphemeralIfPresent('media_admission_token', artifacts.mediaAdmissionTokenHash, 'media_admission_refresh_aborted');
      throw makeError('session_inactive', 403, { rejectReason: 'missingRecord' });
    }
    if (previousMediaAdmissionTokenHash && previousMediaAdmissionTokenHash !== artifacts.mediaAdmissionTokenHash) {
      await revokeEphemeralIfPresent('media_admission_token', previousMediaAdmissionTokenHash, 'media_admission_refreshed');
    }
    logSessionLifecycle(sessionId, 'activeExtended', {
      reason: 'mediaAdmissionRefresh',
      activeUntil: connectionActiveUntil(updated)
    });

    const expectedHashAfterRefresh = connectionRoleTokenHash(updated, role, 'media_admission_token');
    const diagnostics = stripUndefinedFields(mediaTokenDiagnostics({
      requestHash: artifacts.mediaAdmissionTokenHash,
      expectedHash: expectedHashAfterRefresh,
      tokenRecord: { state: 'issued', leaseCount: 0 }
    }));
    console.log(
      `[media] admission refresh accepted ` +
      `sessionLogId=${sessionLogIdForLog(sessionId)} session=${LOG_REDACTED} role=${role} ` +
      `refreshedGeneration=${diagnostics.mediaTokenGeneration || '-'} ` +
      `expectedGeneration=${diagnostics.mediaTokenExpectedGeneration || '-'} ` +
      `expectedPresent=${diagnostics.mediaTokenExpectedPresent ? '1' : '0'} ` +
      `idempotency=${idempotencyKey ? '1' : '0'} serverBuild=${SERVER_BUILD_FINGERPRINT}`
    );

    const responseBody = {
      sessionId,
      role,
      mediaAdmissionToken: artifacts.mediaAdmissionToken,
      expiresIn: Math.max(0, Math.round((artifacts.expiresAt - now()) / 1000)),
      serverBuildFingerprint: SERVER_BUILD_FINGERPRINT,
      supportsMediaAdmissionRefresh: true,
      mediaTokenGeneration: artifacts.mediaAdmissionTokenHash.slice(0, 16),
      mediaTokenRequestGeneration: diagnostics.mediaTokenRequestGeneration,
      mediaTokenExpectedGeneration: diagnostics.mediaTokenExpectedGeneration,
      mediaTokenExpectedPresent: diagnostics.mediaTokenExpectedPresent
    };
    await completeIdempotencyGuard(idempotency, responseBody);
    res.json(responseBody);
  } catch (error) {
    await cancelIdempotencyGuard(idempotency);
    throw error;
  }
}));

app.post('/api/media/lease', rlMedia, asyncRoute(async (req, res) => {
  const rawMediaAdmissionToken = getOpaqueHeader(req, 'X-SkyBridge-Media-Admission');
  const requestMediaAdmissionTokenHash = rawMediaAdmissionToken ? sha256Hex(rawMediaAdmissionToken) : null;
  const mediaToken = await getMediaAdmissionRecord(req);
  await assertPublicCapabilityAvailable('media_relay', mediaToken.tenantId);
  if (!mediaRelay && !hasExternalMediaRelay()) {
    throw makeError('media_relay_not_enabled', 503);
  }
  if (hasExternalMediaRelay() && !MEDIA_RELAY_TOKEN_SECRET) {
    throw makeError('media_relay_token_secret_missing', 503);
  }
  const session = await signalingState.getConnection(mediaToken.sessionId);
  if (!session || session.revokedAt) {
    throw makeError('session_inactive', 403, {
      rejectReason: session?.revokedAt ? 'revoked' : 'missingRecord'
    });
  }
  const expectedHash = connectionRoleTokenHash(session, mediaToken.role, 'media_admission_token');
  if (!expectedHash || !requestMediaAdmissionTokenHash || !secureStringEqual(expectedHash, requestMediaAdmissionTokenHash)) {
    const diagnostics = stripUndefinedFields(mediaTokenDiagnostics({
      requestHash: requestMediaAdmissionTokenHash,
      expectedHash,
      tokenRecord: mediaToken,
      sessionPresent: true
    }));
    console.warn(
      `[media] admission token superseded at lease ` +
      `sessionLogId=${sessionLogIdForLog(mediaToken.sessionId)} session=${LOG_REDACTED} role=${mediaToken.role || '-'} ` +
      `requestGeneration=${diagnostics.mediaTokenRequestGeneration || '-'} ` +
      `expectedGeneration=${diagnostics.mediaTokenExpectedGeneration || '-'} ` +
      `expectedPresent=${diagnostics.mediaTokenExpectedPresent ? '1' : '0'} ` +
      `tokenState=${diagnostics.mediaTokenState || '-'} rejectReason=${diagnostics.rejectReason || '-'} ` +
      `leaseCount=${diagnostics.mediaTokenLeaseCount ?? '-'} ` +
      `serverBuild=${SERVER_BUILD_FINGERPRINT}`
    );
    throw makeError('media_admission_token_superseded', 401, diagnostics);
  }
  await touchConnectionActiveSession(mediaToken.sessionId, 'mediaLease', { minIntervalMs: 0 });
  const relayLease = await issueMediaRelayLease(mediaToken);
  const diagnostics = stripUndefinedFields(mediaTokenDiagnostics({
    requestHash: requestMediaAdmissionTokenHash,
    expectedHash,
    tokenRecord: mediaToken,
    sessionPresent: true
  }));
  res.json({
    mode: 'skybridge-pqc-media-v1',
    endpoint: relayLease.endpoint,
    leaseToken: relayLease.lease.leaseToken,
    role: mediaToken.role,
    sessionId: mediaToken.sessionId,
    expiresAt: Math.floor(relayLease.lease.expiresAt / 1000),
    ttl: Math.max(1, Math.round((relayLease.lease.expiresAt - now()) / 1000)),
    maxPacketBytes: MEDIA_RELAY_MAX_PACKET_BYTES,
    serverBuildFingerprint: SERVER_BUILD_FINGERPRINT,
    supportsMediaAdmissionRefresh: true,
    mediaTokenGeneration: diagnostics.mediaTokenGeneration,
    mediaTokenRequestGeneration: diagnostics.mediaTokenRequestGeneration,
    mediaTokenExpectedGeneration: diagnostics.mediaTokenExpectedGeneration,
    mediaTokenExpectedPresent: diagnostics.mediaTokenExpectedPresent,
    bindMessage: { type: 'bind', leaseToken: relayLease.lease.leaseToken },
    media: {
      codec: 'opus',
      sampleRate: 48_000,
      channels: 2,
      packetDurationMs: 20,
      encryptedPacket: 'SBMA-v1-AES-GCM'
    }
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
  const canReadRegisteredDevices = registryCanReadRegisteredDevices();
  const existing = canReadRegisteredDevices
    ? await registryStore.getRegisteredDevice({
      tenantId: context.tenantId,
      userId: context.user.id,
      deviceId: context.binding.deviceId,
      protocolSigningAlgorithm: context.binding.protocolSigningAlgorithm,
      protocolPublicKeyFingerprint: context.binding.protocolPublicKeyFingerprint
    })
    : null;
  if (!existing && !currentAllowBootstrapDeviceAuth) {
    throw makeError('device_not_registered', 403);
  }
  if (!registryCanBootstrapRegisterDevices()) {
    throw makeError('registry_not_configured', 503);
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
  return https.createServer(
    buildNodeHTTPSServerTLSOptions(NODE_HTTPS_TRANSPORT_POLICY),
    app
  );
})();

let wss = null;
wss = new WebSocketServer({
  server,
  path: SIGNALING_WEBSOCKET_PATH,
  maxPayload: WS_MAX_MSG_BYTES,
  perMessageDeflate: false
});

wss.on('connection', (ws, req) => {
  void (async () => {
    const peerCertificate = resolvePeerCertificateForMTLS(req, NODE_HTTPS_TRANSPORT_POLICY);
    if (!peerCertificate.ok) {
      incrementSecurityCounter(`ws_1008_${peerCertificate.error}`);
      ws.close(1008, peerCertificate.error);
      return;
    }
    const requestURL = new URL(req.url, 'http://skybridge.local');
    const credentials = extractWebSocketSessionCredentials(req, requestURL, {
      allowLegacyQueryToken: currentAllowLegacyQueryToken
    });
    if (credentials.error) {
      incrementSecurityCounter(`ws_1008_${credentials.error}`);
      ws.close(1008, credentials.error);
      return;
    }
    const {
      sessionId,
      sessionToken,
      clientVersion: rawClientVersion,
      protocolVersion: rawProtocolVersion
    } = credentials;
    const clientVersion = normalizeVersion(rawClientVersion);
    const protocolVersion = normalizeVersion(rawProtocolVersion);
    const tokenHash = sha256Hex(sessionToken);
    const tokenPreview = await signalingState.getEphemeral('session_token', tokenHash);
    if (!tokenPreview) {
      incrementSecurityCounter('ws_1008_expired_token');
      ws.close(1008, 'session_token_expired');
      return;
    }
    const previewMTLSBindingError = mtlsBindingErrorForRecord(tokenPreview, peerCertificate.certificate, 'session_token');
    if (previewMTLSBindingError) {
      incrementSecurityCounter(`ws_1008_${previewMTLSBindingError}`);
      ws.close(1008, previewMTLSBindingError);
      return;
    }
    if (!(await isEphemeralTokenCurrent('session_token', tokenPreview, tokenHash))) {
      incrementSecurityCounter('ws_1008_superseded_token');
      ws.close(1008, 'session_token_superseded');
      return;
    }
    const tenantPolicy = registryCanReadTenantPolicy()
      ? await registryStore.getTenantPolicy(tokenPreview.tenantId)
      : null;
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
      const recordMTLSBindingError = mtlsBindingErrorForRecord(record, peerCertificate.certificate, 'session_token');
      if (recordMTLSBindingError) {
        bindError = recordMTLSBindingError;
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
      clientCertificateFingerprint256: peerCertificate.certificate?.fingerprint256 || null,
      tenantId: boundToken.tenantId,
      userId: boundToken.userId,
      tokenHash,
      rate: { t0: now(), count: 0, bytes: 0 }
    });
    const room = getOrCreateRoom(sessionId);
    room.clients.add(ws);
    room.clientsByDeviceId.set(boundToken.deviceId, ws);
    await touchConnectionActiveSession(sessionId, 'wsBound', { minIntervalMs: 0 });
    await renewRoomMembershipLease(ws, {
      clientId,
      sessionId,
      deviceId: boundToken.deviceId,
      role: boundToken.role,
      protocolPublicKeyFingerprint: boundToken.protocolPublicKeyFingerprint
    });
    wsSendRaw(ws, { type: 'bound', sessionId, role: boundToken.role, clientId });
  })().catch((error) => {
    console.error('[WS] handshake failed:', safeLogErrorCode(error));
    incrementSecurityCounter('ws_1008_handshake_failed');
    try { ws.close(1008, 'handshake_failed'); } catch (_) {}
  });

  ws.on('pong', () => {
    ws.isAlive = true;
    void renewRoomMembershipLease(ws).catch((error) => {
      const meta = wsMeta.get(ws);
      console.warn('[WS] heartbeat lease refresh failed:', {
        ...redactedWSMetaForLog(meta),
        error: safeLogErrorCode(error)
      });
    });
  });

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
      await touchConnectionActiveSession(meta.sessionId, 'signalingEnvelope');
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
            ...redactedWSMetaForLog(meta),
            reason: safeLogErrorCode(error)
          });
          incrementSecurityCounter('ice_usage_tracking_degraded');
          // 降级期间用进程内兜底限额，不得无条件接受（fail-open）。
          usage = trackIceUsageDegraded(
            meta.sessionId,
            meta.deviceId,
            payloadByteSize(message.payload),
            {
              maxPerSession: ICE_MAX_PER_SESSION,
              maxBytesPerPeerPerSession: ICE_MAX_BYTES_PER_PEER_PER_SESSION
            }
          );
        }
        if (usage.killed) {
          const reason = usage.reason || 'ice_limit';
          incrementSecurityCounter('ice_candidate_dropped');
          console.warn('[WS] ICE candidate dropped without revoking session:', {
            ...redactedWSMetaForLog(meta),
            reason
          });
          wsSendRaw(ws, {
            type: 'error',
            error: 'ice_candidate_dropped',
            reason,
            sessionId: meta.sessionId
          });
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
      await renewRoomMembershipLease(ws, meta);
      const outbound = sanitizeEnvelopeForPeer(message, meta.deviceId);
      deliverEnvelopeLocally(ws, outbound);
      await forwardEnvelopeToRemoteInstances(outbound);
      if (message.type === 'leave') {
        await removeFromRooms(ws);
      }
    })().catch((error) => {
      const meta = wsMeta.get(ws);
      console.error('[WS] message failed:', {
        ...redactedWSMetaForLog(meta),
        error: safeLogErrorCode(error)
      });
      incrementSecurityCounter('ws_server_error');
      try { wsSendRaw(ws, { type: 'error', error: 'server_error' }); } catch (_) {}
    });
  });

  ws.on('close', () => {
    void removeFromRooms(ws).catch((error) => {
      console.error('[WS] close cleanup failed:', safeLogErrorCode(error));
    });
  });

  ws.on('error', (error) => {
    const meta = wsMeta.get(ws);
    console.warn('[WS] transport error:', {
      ...redactedWSMetaForLog(meta),
      error: safeLogErrorCode(error)
    });
  });
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
}, WS_HEARTBEAT_INTERVAL_MS);
heartbeatTimer.unref?.();

const sweepTimer = setInterval(() => {
  void signalingState.sweepExpired().catch((error) => {
    console.error('[sweeper] failed:', error.message);
  });
}, SWEEP_INTERVAL_MS);
sweepTimer.unref?.();

const protectionTimer = setInterval(() => {
  void refreshRuntimeProtection();
}, 5_000);
protectionTimer.unref?.();

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
  if (mediaRelay) {
    await mediaRelay.close().catch((error) => {
      console.error('[shutdown] media relay close failed:', error.message);
    });
  }
  await new Promise((resolve) => {
    server.close(() => {
      if (exitProcess) process.exit(0);
      resolve();
    });
  });
}

async function startRuntime({ port = PORT, host = HOST } = {}) {
  assertConfiguredSignalingServerOrigin();
  await signalingState.init(handleBackendInstanceMessage);
  await refreshRuntimeProtection();
  const mediaRelayAddress = mediaRelay ? await mediaRelay.start() : null;
  assertClientIpHashSecretReadiness();
  const smsStartup = assertSMSStartupReadiness();
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
        console.log(`Redis: ${redactSecretURLForLog(SIGNALING_REDIS_URL)} keyPrefix=${SIGNALING_REDIS_KEY_PREFIX}`);
      } else {
        console.warn('[startup] memory state backend is single-instance only; do not deploy behind a multi-instance load balancer');
      }
      console.log(`SMS: provider=${smsStartup.provider} ready=${smsStartup.ready} hookConfigured=${smsStartup.hookConfigured} providerConfigured=${smsStartup.providerConfigured} required=${smsStartup.required}`);
      console.log(`WS: ${USE_NODE_HTTPS ? 'wss' : 'ws'}://<host>:${port}${SIGNALING_WEBSOCKET_PATH}?shard=<session_id> headers=X-SkyBridge-Session-Id,X-SkyBridge-Session`);
      if (mediaRelayAddress) {
        console.log(`Media relay: udp://${mediaRelayAddress.host}:${mediaRelayAddress.port} maxPacketBytes=${MEDIA_RELAY_MAX_PACKET_BYTES}`);
      } else if (hasExternalMediaRelay()) {
        console.log(`Media relay: external udp://${MEDIA_RELAY_EXTERNAL_HOST}:${MEDIA_RELAY_EXTERNAL_UDP_PORT} maxPacketBytes=${MEDIA_RELAY_MAX_PACKET_BYTES}`);
      } else {
        console.log('Media relay: disabled');
      }
      console.log(`Security: maxPayload=${WS_MAX_MSG_BYTES} maxMsgs10s=${WS_MAX_MSGS_PER_10S} maxBytes10s=${WS_MAX_BYTES_PER_10S} maxBufferedBytes=${WS_MAX_BUFFERED_BYTES} heartbeatMs=${WS_HEARTBEAT_INTERVAL_MS} perMessageDeflate=false`);
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
    allowBootstrapDeviceAuth = SIGNALING_ALLOW_BOOTSTRAP_DEVICE_AUTH,
    allowLegacyQueryToken = DEFAULT_WS_ALLOW_LEGACY_QUERY_TOKEN
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
  currentAllowLegacyQueryToken = allowLegacyQueryToken === true;
  app.set('trust proxy', trustProxy ? 1 : false);
  rooms.clear();
  securityCounters.clear();
  smsCounters.clear();
  lastSMSDeliveryEvent = null;
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
  createRuntime,
  __test: {
    assertMTLSBindingForRecord,
    buildNodeHTTPSServerTLSOptions,
    buildSupabaseSMSHookVerifier,
    classifySMSDeliveryFailure,
    closeSlowConsumer,
    collectSMSServiceSnapshot,
    evaluateServiceHealth,
    mtlsBindingErrorForRecord,
    mtlsClientCertificateFingerprintForRequest,
    parseTrustedProxyClientCertificate,
    redactSecretURLForLog,
    resolveNodeHTTPSTransportPolicy,
    resolvePeerCertificateForMTLS,
    resolveSignalingServerOrigin,
    renewRoomMembershipLease,
    wsSendRaw,
    WS_MAX_BUFFERED_BYTES
  }
};
