'use strict';

const crypto = require('crypto');
const { createClient } = require('redis');

function deepClone(value) {
  if (value == null) return value;
  return JSON.parse(JSON.stringify(value));
}

function safeJsonParse(raw, fallback = null) {
  if (raw == null || raw === '') return fallback;
  try {
    return JSON.parse(raw);
  } catch (_) {
    return fallback;
  }
}

function toInteger(raw, fallback = 0) {
  const value = Number(raw);
  return Number.isFinite(value) ? value : fallback;
}

function unique(values) {
  return [...new Set(values.filter(Boolean))];
}

function connectionRecordToStorage(record) {
  return JSON.stringify({
    deviceId: record.deviceId,
    initiatorDeviceName: record.initiatorDeviceName || null,
    initiatorProtocolSigningAlgorithm: record.initiatorProtocolSigningAlgorithm || null,
    initiatorProtocolPublicKeyFingerprint: record.initiatorProtocolPublicKeyFingerprint || null,
    offer: record.offer,
    createdAt: record.createdAt,
    expiresAt: record.expiresAt,
    initiatorTokenHash: record.initiatorTokenHash,
    responderTokenHash: record.responderTokenHash || null,
    qrBootstrapTokenHash: record.qrBootstrapTokenHash || null,
    qrBootstrapConsumedAt: record.qrBootstrapConsumedAt || null,
    roomAuthTokenHash: record.roomAuthTokenHash || null,
    connectionKind: typeof record.connectionKind === 'string' ? record.connectionKind : 'legacy_offer_answer',
    responderId: record.responderId || null,
    responderProtocolSigningAlgorithm: record.responderProtocolSigningAlgorithm || null,
    responderProtocolPublicKeyFingerprint: record.responderProtocolPublicKeyFingerprint || null,
    signalingServerOrigin: record.signalingServerOrigin || null,
    answer: record.answer || null,
    answerFrom: record.answerFrom || null
  });
}

function connectionRecordFromStorage(raw) {
  const parsed = safeJsonParse(raw);
  if (!parsed || typeof parsed !== 'object') return null;
  return {
    deviceId: typeof parsed.deviceId === 'string' ? parsed.deviceId : '',
    initiatorDeviceName: typeof parsed.initiatorDeviceName === 'string' ? parsed.initiatorDeviceName : null,
    initiatorProtocolSigningAlgorithm: typeof parsed.initiatorProtocolSigningAlgorithm === 'string' ? parsed.initiatorProtocolSigningAlgorithm : null,
    initiatorProtocolPublicKeyFingerprint: typeof parsed.initiatorProtocolPublicKeyFingerprint === 'string' ? parsed.initiatorProtocolPublicKeyFingerprint : null,
    offer: parsed.offer && typeof parsed.offer === 'object' ? parsed.offer : null,
    createdAt: toInteger(parsed.createdAt, 0),
    expiresAt: toInteger(parsed.expiresAt, 0),
    initiatorTokenHash: typeof parsed.initiatorTokenHash === 'string' ? parsed.initiatorTokenHash : '',
    responderTokenHash: typeof parsed.responderTokenHash === 'string' ? parsed.responderTokenHash : null,
    qrBootstrapTokenHash: typeof parsed.qrBootstrapTokenHash === 'string' ? parsed.qrBootstrapTokenHash : null,
    qrBootstrapConsumedAt: toInteger(parsed.qrBootstrapConsumedAt, 0),
    roomAuthTokenHash: typeof parsed.roomAuthTokenHash === 'string' ? parsed.roomAuthTokenHash : null,
    connectionKind: typeof parsed.connectionKind === 'string' ? parsed.connectionKind : 'legacy_offer_answer',
    responderId: typeof parsed.responderId === 'string' ? parsed.responderId : null,
    responderProtocolSigningAlgorithm: typeof parsed.responderProtocolSigningAlgorithm === 'string' ? parsed.responderProtocolSigningAlgorithm : null,
    responderProtocolPublicKeyFingerprint: typeof parsed.responderProtocolPublicKeyFingerprint === 'string' ? parsed.responderProtocolPublicKeyFingerprint : null,
    signalingServerOrigin: typeof parsed.signalingServerOrigin === 'string' ? parsed.signalingServerOrigin : null,
    answer: parsed.answer && typeof parsed.answer === 'object' ? parsed.answer : null,
    answerFrom: typeof parsed.answerFrom === 'string' ? parsed.answerFrom : null
  };
}

function normalizeActiveMember(member, fallbackDeviceId = null) {
  if (!member || typeof member !== 'object') return null;
  const deviceId = typeof member.deviceId === 'string' && member.deviceId
    ? member.deviceId
    : (typeof fallbackDeviceId === 'string' ? fallbackDeviceId : null);
  const instanceId = typeof member.instanceId === 'string' ? member.instanceId : null;
  if (!deviceId || !instanceId) return null;
  return {
    deviceId,
    instanceId,
    clientId: typeof member.clientId === 'string' ? member.clientId : '',
    updatedAt: toInteger(member.updatedAt, Date.now()),
    expiresAt: toInteger(member.expiresAt, 0)
  };
}

class MemorySignalingStateBackend {
  constructor(options) {
    this.instanceId = options.instanceId;
    this.codeTtlMs = options.codeTtlMs;
    this.iceTtlMs = options.iceTtlMs;
    this.iceMaxPerSession = options.iceMaxPerSession;
    this.roomMembershipTtlMs = options.roomMembershipTtlMs;
    this.legacyBindingTtlMs = options.legacyBindingTtlMs;
    this.connectionCodes = new Map();
    this.iceCandidates = new Map();
    this.roomMembers = new Map();
    this.legacyBindings = new Map();
    this.localMessageHandler = null;
  }

  async init(onInstanceMessage) {
    this.localMessageHandler = onInstanceMessage || null;
  }

  async close() {
    this.localMessageHandler = null;
  }

  async createConnectionCode(generateCode, attempts, record) {
    for (let i = 0; i < attempts; i++) {
      const code = generateCode();
      if (!this.connectionCodes.has(code)) {
        this.connectionCodes.set(code, deepClone(record));
        return code;
      }
    }
    return null;
  }

  async createConnectionRecord(id, record) {
    if (!id || this.connectionCodes.has(id)) {
      return false;
    }
    this.connectionCodes.set(id, deepClone(record));
    return true;
  }

  async getConnection(code) {
    const item = this.connectionCodes.get(code);
    if (!item) return null;
    if (Date.now() > item.expiresAt) {
      await this.deleteConnection(code);
      return null;
    }
    return deepClone(item);
  }

  async bindResponder(code, binding) {
    const item = await this.getConnection(code);
    if (!item) return null;
    if (binding.qrBootstrapTokenHash) {
      if (!item.qrBootstrapTokenHash || item.qrBootstrapTokenHash !== binding.qrBootstrapTokenHash) {
        return { item, issued: false, error: 'bootstrap_token_invalid' };
      }
      if (item.qrBootstrapConsumedAt) {
        return { item, issued: false, error: 'bootstrap_token_consumed' };
      }
    }
    const sameResponder = !item.responderId || item.responderId === binding.responderId;
    const sameFingerprint = !item.responderProtocolPublicKeyFingerprint
      || item.responderProtocolPublicKeyFingerprint === binding.responderProtocolPublicKeyFingerprint;
    if (!sameResponder || !sameFingerprint) {
      return { item, issued: false, error: 'responder_binding_conflict' };
    }
    item.responderTokenHash = binding.responderTokenHash || item.responderTokenHash;
    item.responderId = binding.responderId || item.responderId;
    item.responderProtocolSigningAlgorithm = binding.responderProtocolSigningAlgorithm || item.responderProtocolSigningAlgorithm;
    item.responderProtocolPublicKeyFingerprint = binding.responderProtocolPublicKeyFingerprint || item.responderProtocolPublicKeyFingerprint;
    if (binding.qrBootstrapTokenHash) {
      item.qrBootstrapConsumedAt = Date.now();
    }
    this.connectionCodes.set(code, deepClone(item));
    return { item, issued: Boolean(binding.responderTokenHash), error: null };
  }

  async storeAnswer(code, answer, answerFrom, responderId) {
    const item = await this.getConnection(code);
    if (!item) return null;
    item.answer = deepClone(answer);
    item.answerFrom = answerFrom;
    if (responderId && !item.responderId) {
      item.responderId = responderId;
    }
    this.connectionCodes.set(code, deepClone(item));
    return item;
  }

  async deleteConnection(code) {
    this.connectionCodes.delete(code);
    this.iceCandidates.delete(code);
    this.legacyBindings.delete(code);
  }

  async appendIceCandidate(sessionId, entry) {
    const now = Date.now();
    const filtered = (this.iceCandidates.get(sessionId) || [])
      .filter((candidate) => (now - candidate.timestamp) <= this.iceTtlMs);
    filtered.push(deepClone(entry));
    if (filtered.length > this.iceMaxPerSession) {
      filtered.splice(0, filtered.length - this.iceMaxPerSession);
    }
    this.iceCandidates.set(sessionId, filtered);
  }

  async listIceCandidates(sessionId, since = 0) {
    const now = Date.now();
    const filtered = (this.iceCandidates.get(sessionId) || [])
      .filter((candidate) => (now - candidate.timestamp) <= this.iceTtlMs);
    if (filtered.length === 0) {
      this.iceCandidates.delete(sessionId);
      return [];
    }
    this.iceCandidates.set(sessionId, filtered);
    return filtered
      .filter((candidate) => !since || candidate.timestamp > since)
      .map((candidate) => deepClone(candidate));
  }

  async upsertRoomMember(sessionId, member) {
    const normalized = normalizeActiveMember(member);
    if (!normalized) return;
    let room = this.roomMembers.get(sessionId);
    if (!room) {
      room = new Map();
      this.roomMembers.set(sessionId, room);
    }
    room.set(normalized.deviceId, normalized);
  }

  async listRoomMembers(sessionId) {
    const room = this.roomMembers.get(sessionId);
    if (!room) return [];
    const now = Date.now();
    const active = [];
    for (const [deviceId, member] of room.entries()) {
      if (member.expiresAt > 0 && now > member.expiresAt) {
        room.delete(deviceId);
        continue;
      }
      if ((now - member.updatedAt) > this.roomMembershipTtlMs) {
        room.delete(deviceId);
        continue;
      }
      active.push(deepClone(member));
    }
    if (room.size === 0) this.roomMembers.delete(sessionId);
    return active;
  }

  async removeRoomMember(sessionId, deviceId, clientId = '') {
    const room = this.roomMembers.get(sessionId);
    if (!room) return;
    const current = room.get(deviceId);
    if (!current) return;
    if (clientId && current.clientId && current.clientId !== clientId) return;
    room.delete(deviceId);
    if (room.size === 0) this.roomMembers.delete(sessionId);
  }

  async upsertLegacyBinding(code, role, binding) {
    const normalized = normalizeActiveMember(binding);
    if (!normalized) return;
    let bindings = this.legacyBindings.get(code);
    if (!bindings) {
      bindings = new Map();
      this.legacyBindings.set(code, bindings);
    }
    bindings.set(role, normalized);
  }

  async getLegacyBinding(code, role) {
    const bindings = this.legacyBindings.get(code);
    if (!bindings) return null;
    const binding = bindings.get(role);
    if (!binding) return null;
    const now = Date.now();
    if (binding.expiresAt > 0 && now > binding.expiresAt) {
      bindings.delete(role);
      if (bindings.size === 0) this.legacyBindings.delete(code);
      return null;
    }
    return deepClone(binding);
  }

  async listLegacyBindings(code) {
    const bindings = this.legacyBindings.get(code);
    if (!bindings) return [];
    const now = Date.now();
    const active = [];
    for (const [role, binding] of bindings.entries()) {
      if (binding.expiresAt > 0 && now > binding.expiresAt) {
        bindings.delete(role);
        continue;
      }
      active.push({ role, ...deepClone(binding) });
    }
    if (bindings.size === 0) this.legacyBindings.delete(code);
    return active;
  }

  async removeLegacyBinding(code, role, clientId = '') {
    const bindings = this.legacyBindings.get(code);
    if (!bindings) return;
    const current = bindings.get(role);
    if (!current) return;
    if (clientId && current.clientId && current.clientId !== clientId) return;
    bindings.delete(role);
    if (bindings.size === 0) this.legacyBindings.delete(code);
  }

  async publishToInstance(instanceId, payload) {
    if (!instanceId || instanceId !== this.instanceId || typeof this.localMessageHandler !== 'function') {
      return;
    }
    queueMicrotask(() => {
      try {
        this.localMessageHandler(payload);
      } catch (_) {}
    });
  }

  async sweepExpired() {
    const now = Date.now();
    for (const [code, record] of this.connectionCodes.entries()) {
      if (now > record.expiresAt) {
        this.connectionCodes.delete(code);
        this.iceCandidates.delete(code);
        this.legacyBindings.delete(code);
      }
    }

    for (const [sessionId, list] of this.iceCandidates.entries()) {
      const filtered = list.filter((candidate) => (now - candidate.timestamp) <= this.iceTtlMs);
      if (filtered.length === 0) this.iceCandidates.delete(sessionId);
      else this.iceCandidates.set(sessionId, filtered);
    }

    for (const [sessionId] of this.roomMembers.entries()) {
      await this.listRoomMembers(sessionId);
    }
    for (const [code] of this.legacyBindings.entries()) {
      await this.listLegacyBindings(code);
    }
  }

  async getHealth() {
    await this.sweepExpired();
    let roomMemberCount = 0;
    for (const room of this.roomMembers.values()) {
      roomMemberCount += room.size;
    }
    let bindingCount = 0;
    for (const bindings of this.legacyBindings.values()) {
      bindingCount += bindings.size;
    }
    return {
      backend: 'memory',
      ready: true,
      redisConnected: false,
      connections: this.connectionCodes.size,
      iceSessions: this.iceCandidates.size,
      roomMembers: roomMemberCount,
      legacyBindings: bindingCount
    };
  }
}

class RedisSignalingStateBackend {
  constructor(options) {
    this.instanceId = options.instanceId;
    this.codeTtlMs = options.codeTtlMs;
    this.iceTtlMs = options.iceTtlMs;
    this.iceMaxPerSession = options.iceMaxPerSession;
    this.roomMembershipTtlMs = options.roomMembershipTtlMs;
    this.legacyBindingTtlMs = options.legacyBindingTtlMs;
    this.redisUrl = options.redisUrl;
    this.redisKeyPrefix = options.redisKeyPrefix;
    this.redisChannelPrefix = options.redisChannelPrefix;
    this.redisConnectTimeoutMs = options.redisConnectTimeoutMs;
    this.log = options.log || console;
    this.command = null;
    this.publisher = null;
    this.subscriber = null;
    this.localMessageHandler = null;
  }

  codeKey(code) { return `${this.redisKeyPrefix}code:${code}`; }
  codeIndexKey() { return `${this.redisKeyPrefix}index:codes`; }
  iceKey(sessionId) { return `${this.redisKeyPrefix}ice:${sessionId}`; }
  iceIndexKey() { return `${this.redisKeyPrefix}index:ice`; }
  roomKey(sessionId) { return `${this.redisKeyPrefix}room:${sessionId}:members`; }
  legacyBindingKey(code) { return `${this.redisKeyPrefix}legacy:${code}:bindings`; }
  instanceChannel(instanceId) { return `${this.redisChannelPrefix}instance:${instanceId}`; }

  createRedisClient() {
    return createClient({
      url: this.redisUrl,
      socket: {
        connectTimeout: this.redisConnectTimeoutMs,
        reconnectStrategy: (retries) => Math.min(1000 * Math.max(1, retries), 5_000)
      }
    });
  }

  async init(onInstanceMessage) {
    if (!this.redisUrl) {
      throw new Error('SIGNALING_STATE_BACKEND=redis 但未配置 SIGNALING_REDIS_URL / REDIS_URL');
    }
    this.localMessageHandler = onInstanceMessage || null;
    this.command = this.createRedisClient();
    this.publisher = this.createRedisClient();
    this.subscriber = this.createRedisClient();

    const logError = (label) => (error) => {
      this.log.error(`[redis] ${label} error: ${error.message}`);
    };
    this.command.on('error', logError('command'));
    this.publisher.on('error', logError('publisher'));
    this.subscriber.on('error', logError('subscriber'));

    await Promise.all([
      this.command.connect(),
      this.publisher.connect(),
      this.subscriber.connect()
    ]);

    await this.subscriber.subscribe(this.instanceChannel(this.instanceId), async (message) => {
      if (typeof this.localMessageHandler !== 'function') return;
      const payload = safeJsonParse(message);
      if (!payload) return;
      try {
        await this.localMessageHandler(payload);
      } catch (error) {
        this.log.error(`[redis] local message handler failed: ${error.message}`);
      }
    });
  }

  async close() {
    const clients = [this.subscriber, this.publisher, this.command].filter(Boolean);
    this.subscriber = null;
    this.publisher = null;
    this.command = null;
    await Promise.all(clients.map(async (client) => {
      try {
        if (client.isOpen) {
          await client.quit();
        }
      } catch (_) {
        try { client.disconnect(); } catch {}
      }
    }));
  }

  async createConnectionCode(generateCode, attempts, record) {
    for (let i = 0; i < attempts; i++) {
      const code = generateCode();
      const key = this.codeKey(code);
      const reserved = await this.command.set(key, connectionRecordToStorage(record), {
        NX: true,
        PX: Math.max(1, record.expiresAt - Date.now())
      });
      if (reserved !== 'OK') continue;
      await this.command.sAdd(this.codeIndexKey(), code);
      return code;
    }
    return null;
  }

  async createConnectionRecord(id, record) {
    const reserved = await this.command.set(this.codeKey(id), connectionRecordToStorage(record), {
      NX: true,
      PX: Math.max(1, record.expiresAt - Date.now())
    });
    if (reserved !== 'OK') {
      return false;
    }
    await this.command.sAdd(this.codeIndexKey(), id);
    return true;
  }

  async getConnection(code) {
    const raw = await this.command.get(this.codeKey(code));
    if (!raw) {
      await this.command.sRem(this.codeIndexKey(), code);
      return null;
    }
    const item = connectionRecordFromStorage(raw);
    if (!item) {
      await this.deleteConnection(code);
      return null;
    }
    if (Date.now() > item.expiresAt) {
      await this.deleteConnection(code);
      return null;
    }
    return item;
  }

  async updateConnection(code, mutator) {
    const key = this.codeKey(code);
    return this.command.executeIsolated(async (isolated) => {
      for (let attempt = 0; attempt < 5; attempt++) {
        await isolated.watch(key);
        const raw = await isolated.get(key);
        if (!raw) {
          await isolated.unwatch();
          await isolated.sRem(this.codeIndexKey(), code);
          return null;
        }
        const item = connectionRecordFromStorage(raw);
        if (!item || Date.now() > item.expiresAt) {
          const tx = isolated.multi();
          tx.del(key);
          tx.sRem(this.codeIndexKey(), code);
          await tx.exec();
          return null;
        }
        const nextItem = deepClone(item);
        const result = mutator(nextItem);
        if (result === false) {
          await isolated.unwatch();
          return item;
        }
        const execResult = await isolated.multi()
          .set(key, connectionRecordToStorage(nextItem), {
            XX: true,
            PX: Math.max(1, nextItem.expiresAt - Date.now())
          })
          .sAdd(this.codeIndexKey(), code)
          .exec();
        if (execResult) {
          return nextItem;
        }
      }
      throw new Error(`redis optimistic update failed for code=${code}`);
    });
  }

  async bindResponder(code, binding) {
    let issued = false;
    let rejectedError = null;
    const item = await this.updateConnection(code, (nextItem) => {
      if (binding.qrBootstrapTokenHash) {
        if (!nextItem.qrBootstrapTokenHash || nextItem.qrBootstrapTokenHash !== binding.qrBootstrapTokenHash) {
          rejectedError = 'bootstrap_token_invalid';
          return false;
        }
        if (nextItem.qrBootstrapConsumedAt) {
          rejectedError = 'bootstrap_token_consumed';
          return false;
        }
      }
      const sameResponder = !nextItem.responderId || nextItem.responderId === binding.responderId;
      const sameFingerprint = !nextItem.responderProtocolPublicKeyFingerprint
        || nextItem.responderProtocolPublicKeyFingerprint === binding.responderProtocolPublicKeyFingerprint;
      if (!sameResponder || !sameFingerprint) {
        rejectedError = 'responder_binding_conflict';
        return false;
      }
      if (binding.responderTokenHash) {
        nextItem.responderTokenHash = binding.responderTokenHash;
        issued = true;
      }
      if (binding.responderId) {
        nextItem.responderId = binding.responderId;
      }
      if (binding.responderProtocolSigningAlgorithm) {
        nextItem.responderProtocolSigningAlgorithm = binding.responderProtocolSigningAlgorithm;
      }
      if (binding.responderProtocolPublicKeyFingerprint) {
        nextItem.responderProtocolPublicKeyFingerprint = binding.responderProtocolPublicKeyFingerprint;
      }
      if (binding.qrBootstrapTokenHash) {
        nextItem.qrBootstrapConsumedAt = Date.now();
      }
    });
    if (!item) return null;
    return { item, issued, error: rejectedError };
  }

  async storeAnswer(code, answer, answerFrom, responderId) {
    return this.updateConnection(code, (nextItem) => {
      nextItem.answer = deepClone(answer);
      nextItem.answerFrom = answerFrom;
      if (responderId && !nextItem.responderId) {
        nextItem.responderId = responderId;
      }
    });
  }

  async deleteConnection(code) {
    await Promise.all([
      this.command.del(this.codeKey(code)),
      this.command.del(this.legacyBindingKey(code)),
      this.command.del(this.iceKey(code)),
      this.command.sRem(this.codeIndexKey(), code),
      this.command.sRem(this.iceIndexKey(), code)
    ]);
  }

  async appendIceCandidate(sessionId, entry) {
    const key = this.iceKey(sessionId);
    const encoded = JSON.stringify({ ...deepClone(entry), id: crypto.randomUUID() });
    await this.command.zAdd(key, [{ score: entry.timestamp, value: encoded }]);
    await this.command.pExpire(key, this.iceTtlMs);
    await this.command.sAdd(this.iceIndexKey(), sessionId);
    const count = await this.command.zCard(key);
    if (count > this.iceMaxPerSession) {
      await this.command.zRemRangeByRank(key, 0, count - this.iceMaxPerSession - 1);
    }
  }

  async listIceCandidates(sessionId, since = 0) {
    const key = this.iceKey(sessionId);
    const cutoff = Date.now() - this.iceTtlMs;
    await this.command.zRemRangeByScore(key, 0, cutoff);
    const minScore = since && Number.isFinite(since) ? since + 1 : cutoff;
    const values = await this.command.zRangeByScore(key, minScore, '+inf');
    if (!values.length) {
      const exists = await this.command.exists(key);
      if (!exists) await this.command.sRem(this.iceIndexKey(), sessionId);
      return [];
    }
    return values
      .map((raw) => safeJsonParse(raw))
      .filter(Boolean)
      .map(({ id, ...candidate }) => candidate);
  }

  async upsertRoomMember(sessionId, member) {
    const normalized = normalizeActiveMember(member);
    if (!normalized) return;
    normalized.expiresAt = normalized.updatedAt + this.roomMembershipTtlMs;
    const key = this.roomKey(sessionId);
    await this.command.hSet(key, normalized.deviceId, JSON.stringify(normalized));
    await this.command.pExpire(key, this.roomMembershipTtlMs);
  }

  async listRoomMembers(sessionId) {
    const key = this.roomKey(sessionId);
    const entries = await this.command.hGetAll(key);
    const staleFields = [];
    const active = [];
    const now = Date.now();
    for (const [deviceId, raw] of Object.entries(entries)) {
      const parsed = normalizeActiveMember(safeJsonParse(raw), deviceId);
      if (!parsed) {
        staleFields.push(deviceId);
        continue;
      }
      if (parsed.expiresAt > 0 && now > parsed.expiresAt) {
        staleFields.push(deviceId);
        continue;
      }
      if ((now - parsed.updatedAt) > this.roomMembershipTtlMs) {
        staleFields.push(deviceId);
        continue;
      }
      active.push(parsed);
    }
    if (staleFields.length) {
      await this.command.hDel(key, staleFields);
    }
    return active;
  }

  async removeRoomMember(sessionId, deviceId, clientId = '') {
    const key = this.roomKey(sessionId);
    if (!clientId) {
      await this.command.hDel(key, deviceId);
      return;
    }
    const current = normalizeActiveMember(safeJsonParse(await this.command.hGet(key, deviceId)), deviceId);
    if (!current) return;
    if (current.clientId && current.clientId !== clientId) return;
    await this.command.hDel(key, deviceId);
  }

  async upsertLegacyBinding(code, role, binding) {
    const normalized = normalizeActiveMember(binding);
    if (!normalized) return;
    normalized.expiresAt = normalized.updatedAt + this.legacyBindingTtlMs;
    const key = this.legacyBindingKey(code);
    await this.command.hSet(key, role, JSON.stringify(normalized));
    await this.command.pExpire(key, this.legacyBindingTtlMs);
  }

  async getLegacyBinding(code, role) {
    const raw = await this.command.hGet(this.legacyBindingKey(code), role);
    const parsed = normalizeActiveMember(safeJsonParse(raw));
    if (!parsed) return null;
    const now = Date.now();
    if (parsed.expiresAt > 0 && now > parsed.expiresAt) {
      await this.command.hDel(this.legacyBindingKey(code), role);
      return null;
    }
    return parsed;
  }

  async listLegacyBindings(code) {
    const key = this.legacyBindingKey(code);
    const entries = await this.command.hGetAll(key);
    const staleRoles = [];
    const active = [];
    const now = Date.now();
    for (const [role, raw] of Object.entries(entries)) {
      const parsed = normalizeActiveMember(safeJsonParse(raw));
      if (!parsed) {
        staleRoles.push(role);
        continue;
      }
      if (parsed.expiresAt > 0 && now > parsed.expiresAt) {
        staleRoles.push(role);
        continue;
      }
      active.push({ role, ...parsed });
    }
    if (staleRoles.length) {
      await this.command.hDel(key, staleRoles);
    }
    return active;
  }

  async removeLegacyBinding(code, role, clientId = '') {
    const key = this.legacyBindingKey(code);
    if (!clientId) {
      await this.command.hDel(key, role);
      return;
    }
    const current = await this.getLegacyBinding(code, role);
    if (!current) return;
    if (current.clientId && current.clientId !== clientId) return;
    await this.command.hDel(key, role);
  }

  async publishToInstance(instanceId, payload) {
    if (!instanceId || instanceId === this.instanceId) return;
    await this.publisher.publish(this.instanceChannel(instanceId), JSON.stringify(payload));
  }

  async sweepExpired() {
    // Redis key expiry is the primary cleanup. We only prune lightweight indexes here.
    const codeEntries = await this.command.sMembers(this.codeIndexKey());
    if (codeEntries.length) {
      const pipeline = this.command.multi();
      for (const code of codeEntries) {
        pipeline.exists(this.codeKey(code));
      }
      const results = await pipeline.exec();
      const stale = [];
      results.forEach((result, index) => {
        const exists = Array.isArray(result) ? result[1] : result;
        if (!exists) stale.push(codeEntries[index]);
      });
      if (stale.length) {
        await this.command.sRem(this.codeIndexKey(), stale);
      }
    }

    const iceEntries = await this.command.sMembers(this.iceIndexKey());
    if (iceEntries.length) {
      const pipeline = this.command.multi();
      for (const sessionId of iceEntries) {
        pipeline.exists(this.iceKey(sessionId));
      }
      const results = await pipeline.exec();
      const stale = [];
      results.forEach((result, index) => {
        const exists = Array.isArray(result) ? result[1] : result;
        if (!exists) stale.push(iceEntries[index]);
      });
      if (stale.length) {
        await this.command.sRem(this.iceIndexKey(), stale);
      }
    }
  }

  async getHealth() {
    await this.sweepExpired();
    const [connections, iceSessions] = await Promise.all([
      this.command.sCard(this.codeIndexKey()),
      this.command.sCard(this.iceIndexKey())
    ]);
    return {
      backend: 'redis',
      ready: this.command?.isOpen && this.publisher?.isOpen && this.subscriber?.isOpen,
      redisConnected: this.command?.isOpen && this.publisher?.isOpen && this.subscriber?.isOpen,
      connections,
      iceSessions,
      roomMembers: null,
      legacyBindings: null
    };
  }
}

function createSignalingStateBackend(options) {
  const backendName = String(options.backendName || 'memory').trim().toLowerCase();
  if (backendName === 'redis') {
    return new RedisSignalingStateBackend(options);
  }
  return new MemorySignalingStateBackend(options);
}

module.exports = {
  createSignalingStateBackend,
  normalizeActiveMember,
  unique
};
