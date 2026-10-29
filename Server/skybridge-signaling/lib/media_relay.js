'use strict';

const dgram = require('node:dgram');
const crypto = require('node:crypto');

function endpointKey(rinfo) {
  return `${rinfo.address}:${rinfo.port}`;
}

function oppositeRole(role) {
  return role === 'initiator' ? 'responder' : 'initiator';
}

function isValidRole(role) {
  return role === 'initiator' || role === 'responder';
}

function stableJSONStringify(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    return JSON.stringify(value);
  }
  const ordered = {};
  for (const key of Object.keys(value).sort()) {
    ordered[key] = value[key];
  }
  return JSON.stringify(ordered);
}

function signPayload(payload, secret) {
  return crypto
    .createHmac('sha256', secret)
    .update(payload)
    .digest('base64url');
}

function secureEqual(left, right) {
  const leftBuffer = Buffer.from(String(left));
  const rightBuffer = Buffer.from(String(right));
  if (leftBuffer.length !== rightBuffer.length) return false;
  return crypto.timingSafeEqual(leftBuffer, rightBuffer);
}

function createSignedMediaLeaseToken({
  sessionId,
  role,
  tenantId = '',
  userId = '',
  ttlMs = 60_000,
  now = Date.now(),
  secret,
  jti = crypto.randomUUID()
}) {
  if (!secret || typeof secret !== 'string') {
    throw new Error('missing_media_relay_token_secret');
  }
  if (!sessionId || typeof sessionId !== 'string') {
    throw new Error('invalid_media_session_id');
  }
  if (!isValidRole(role)) {
    throw new Error('invalid_media_role');
  }
  const expiresAt = now + Math.max(1_000, Number(ttlMs || 0));
  const payload = Buffer.from(stableJSONStringify({
    exp: expiresAt,
    jti,
    role,
    sessionId,
    tenantId,
    userId,
    v: 1
  })).toString('base64url');
  return {
    leaseToken: `${payload}.${signPayload(payload, secret)}`,
    expiresAt
  };
}

function verifySignedMediaLeaseToken(token, { secret, now = Date.now() } = {}) {
  if (!secret || typeof secret !== 'string') {
    return { ok: false, error: 'signed_lease_unavailable' };
  }
  if (!token || typeof token !== 'string') {
    return { ok: false, error: 'invalid_lease_token' };
  }
  const parts = token.split('.');
  if (parts.length !== 2 || !parts[0] || !parts[1]) {
    return { ok: false, error: 'invalid_lease_token' };
  }
  const expected = signPayload(parts[0], secret);
  if (!secureEqual(expected, parts[1])) {
    return { ok: false, error: 'invalid_lease_signature' };
  }
  let payload;
  try {
    payload = JSON.parse(Buffer.from(parts[0], 'base64url').toString('utf8'));
  } catch (_) {
    return { ok: false, error: 'invalid_lease_payload' };
  }
  if (payload?.v !== 1 || !payload.sessionId || !isValidRole(payload.role)) {
    return { ok: false, error: 'invalid_lease_payload' };
  }
  const expiresAt = Number(payload.exp || 0);
  if (!Number.isFinite(expiresAt) || expiresAt <= now) {
    return { ok: false, error: 'lease_expired' };
  }
  return {
    ok: true,
    lease: {
      leaseToken: token,
      sessionId: String(payload.sessionId),
      role: payload.role,
      tenantId: String(payload.tenantId || ''),
      userId: String(payload.userId || ''),
      expiresAt,
      endpoint: null
    }
  };
}

function createMediaRelay(options = {}) {
  const host = options.host || '0.0.0.0';
  const publicHost = options.publicHost || options.host || '127.0.0.1';
  const port = Number(options.port || 0);
  const maxPacketBytes = Number(options.maxPacketBytes || 1200);
  const leaseTtlMs = Number(options.leaseTtlMs || 60_000);
  const signedLeaseSecret = String(options.signedLeaseSecret || '').trim();
  const now = options.now || (() => Date.now());
  const log = options.log || console;

  let socket = null;
  let address = null;
  const leases = new Map();
  const endpoints = new Map();
  const sessions = new Map();
  const diagnostics = {
    receivedPackets: 0,
    receivedBytes: 0,
    forwardedPackets: 0,
    forwardedBytes: 0,
    bindRequests: 0,
    bindAccepted: 0,
    bindRejected: {},
    drops: {},
    sendErrors: {}
  };

  function incrementDiagnosticCounter(bucket, reason) {
    bucket[reason] = (bucket[reason] || 0) + 1;
  }

  function recordDrop(reason) {
    incrementDiagnosticCounter(diagnostics.drops, reason);
  }

  function recordSendError(reason) {
    incrementDiagnosticCounter(diagnostics.sendErrors, reason);
  }

  function createLease({ sessionId, role, tenantId = '', userId = '', ttlMs = leaseTtlMs }) {
    if (!isValidRole(role)) {
      throw new Error('invalid_media_role');
    }
    const leaseToken = crypto.randomBytes(32).toString('base64url');
    const expiresAt = now() + Math.max(1_000, ttlMs);
    leases.set(leaseToken, {
      leaseToken,
      sessionId,
      role,
      tenantId,
      userId,
      expiresAt,
      endpoint: null
    });
    return {
      leaseToken,
      expiresAt
    };
  }

  function resolveLease(leaseToken) {
    const existing = leases.get(leaseToken);
    if (existing) return existing;
    if (!signedLeaseSecret) return null;
    const result = verifySignedMediaLeaseToken(leaseToken, {
      secret: signedLeaseSecret,
      now: now()
    });
    if (!result.ok) return null;
    leases.set(leaseToken, result.lease);
    return result.lease;
  }

  function bindLease(leaseToken, rinfo) {
    const lease = resolveLease(leaseToken);
    if (!lease || lease.expiresAt <= now()) {
      return { ok: false, error: 'lease_expired' };
    }
    const key = endpointKey(rinfo);
    if (lease.endpoint && lease.endpoint !== key) {
      return { ok: false, error: 'lease_already_bound' };
    }
    lease.endpoint = key;
    lease.rinfo = { address: rinfo.address, port: rinfo.port, family: rinfo.family };
    endpoints.set(key, leaseToken);
    let session = sessions.get(lease.sessionId);
    if (!session) {
      session = { initiator: null, responder: null };
      sessions.set(lease.sessionId, session);
    }
    session[lease.role] = leaseToken;
    return { ok: true, sessionId: lease.sessionId, role: lease.role, expiresAt: lease.expiresAt };
  }

  function sweepExpired() {
    const cutoff = now();
    for (const [token, lease] of leases.entries()) {
      if (lease.expiresAt > cutoff) continue;
      leases.delete(token);
      if (lease.endpoint && endpoints.get(lease.endpoint) === token) {
        endpoints.delete(lease.endpoint);
      }
      const session = sessions.get(lease.sessionId);
      if (session && session[lease.role] === token) {
        session[lease.role] = null;
      }
      if (session && !session.initiator && !session.responder) {
        sessions.delete(lease.sessionId);
      }
    }
  }

  function sendJSON(rinfo, payload) {
    if (!socket) return;
    const encoded = Buffer.from(JSON.stringify(payload));
    socket.send(encoded, rinfo.port, rinfo.address, (error) => {
      if (error) recordSendError(`json_${payload?.type || 'message'}`);
    });
  }

  function forwardPacket(message, rinfo) {
    const sourceToken = endpoints.get(endpointKey(rinfo));
    if (!sourceToken) {
      recordDrop('unbound_source');
      return;
    }
    const sourceLease = leases.get(sourceToken);
    if (!sourceLease) {
      recordDrop('source_lease_missing');
      return;
    }
    if (sourceLease.expiresAt <= now()) {
      recordDrop('source_lease_expired');
      return;
    }
    const session = sessions.get(sourceLease.sessionId);
    if (!session) {
      recordDrop('session_missing');
      return;
    }
    const peerToken = session[oppositeRole(sourceLease.role)];
    const peerLease = peerToken ? leases.get(peerToken) : null;
    if (!peerToken || !peerLease) {
      recordDrop('peer_lease_missing');
      return;
    }
    if (!peerLease.rinfo) {
      recordDrop('peer_unbound');
      return;
    }
    if (peerLease.expiresAt <= now()) {
      recordDrop('peer_lease_expired');
      return;
    }
    diagnostics.forwardedPackets += 1;
    diagnostics.forwardedBytes += message.length;
    socket.send(message, peerLease.rinfo.port, peerLease.rinfo.address, (error) => {
      if (error) recordSendError('forward_packet');
    });
  }

  function handleMessage(message, rinfo) {
    diagnostics.receivedPackets += 1;
    diagnostics.receivedBytes += message.length;
    if (message.length > maxPacketBytes) {
      recordDrop('packet_oversize');
      return;
    }
    sweepExpired();
    if (message[0] === 0x7b) {
      let payload;
      try {
        payload = JSON.parse(message.toString('utf8'));
      } catch (_) {
        recordDrop('invalid_json');
        return;
      }
      if (payload?.type !== 'bind' || typeof payload.leaseToken !== 'string') {
        recordDrop('invalid_bind_message');
        return;
      }
      diagnostics.bindRequests += 1;
      const result = bindLease(payload.leaseToken, rinfo);
      if (result.ok) {
        diagnostics.bindAccepted += 1;
      } else {
        incrementDiagnosticCounter(diagnostics.bindRejected, result.error || 'unknown');
      }
      sendJSON(rinfo, {
        type: 'bind-result',
        ...result
      });
      return;
    }
    forwardPacket(message, rinfo);
  }

  async function start() {
    if (socket) return address;
    socket = dgram.createSocket('udp4');
    socket.on('message', handleMessage);
    socket.on('error', (error) => {
      log.error?.('[media-relay] udp error:', error.message);
    });
    await new Promise((resolve, reject) => {
      socket.once('error', reject);
      socket.bind(port, host, () => {
        socket.off('error', reject);
        const bound = socket.address();
        address = {
          host: publicHost,
          port: bound.port
        };
        resolve();
      });
    });
    return address;
  }

  async function close() {
    const current = socket;
    socket = null;
    address = null;
    leases.clear();
    endpoints.clear();
    sessions.clear();
    if (!current) return;
    await new Promise((resolve) => current.close(resolve));
  }

  function snapshot() {
    return {
      address,
      leases: leases.size,
      boundEndpoints: endpoints.size,
      sessions: sessions.size,
      maxPacketBytes,
      diagnostics: {
        receivedPackets: diagnostics.receivedPackets,
        receivedBytes: diagnostics.receivedBytes,
        forwardedPackets: diagnostics.forwardedPackets,
        forwardedBytes: diagnostics.forwardedBytes,
        bindRequests: diagnostics.bindRequests,
        bindAccepted: diagnostics.bindAccepted,
        bindRejected: { ...diagnostics.bindRejected },
        drops: { ...diagnostics.drops },
        sendErrors: { ...diagnostics.sendErrors }
      }
    };
  }

  return {
    start,
    close,
    createLease,
    snapshot,
    _handleMessageForTest: handleMessage
  };
}

module.exports = {
  createMediaRelay,
  createSignedMediaLeaseToken,
  verifySignedMediaLeaseToken
};
