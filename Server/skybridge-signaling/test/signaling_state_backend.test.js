'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const {
  createSignalingStateBackend,
  __test: {
    RedisSignalingStateBackend,
    isRetryableRedisWatchError
  }
} = require('../lib/signaling_state_backend');

function makeBackend() {
  return new RedisSignalingStateBackend({
    instanceId: 'unit-test',
    codeTtlMs: 300_000,
    iceTtlMs: 300_000,
    iceMaxPerSession: 50,
    roomMembershipTtlMs: 120_000,
    legacyBindingTtlMs: 300_000,
    redisUrl: 'redis://127.0.0.1:6379',
    redisKeyPrefix: 'skybridge:test:',
    redisChannelPrefix: 'skybridge:test:',
    redisConnectTimeoutMs: 1_000,
    log: console
  });
}

function makeRetryableWatchError() {
  const error = new Error('Watched keys has been changed');
  error.name = 'WatchError';
  return error;
}

function makeRetryingIsolated({ initialValue = null, failWatchTimes = 1 }) {
  let currentValue = initialValue;
  let watchCalls = 0;
  let unwatchCalls = 0;

  function makePipeline() {
    const operations = [];
    const pipeline = {
      set(key, value) {
        operations.push({ type: 'set', key, value });
        return pipeline;
      },
      sAdd(key, value) {
        operations.push({ type: 'sAdd', key, value });
        return pipeline;
      },
      del(key) {
        operations.push({ type: 'del', key });
        return pipeline;
      },
      async exec() {
        for (const operation of operations) {
          if (operation.type === 'set') {
            currentValue = operation.value;
          } else if (operation.type === 'del') {
            currentValue = null;
          }
        }
        return true;
      }
    };
    return pipeline;
  }

  return {
    get watchCalls() {
      return watchCalls;
    },
    get unwatchCalls() {
      return unwatchCalls;
    },
    async watch() {
      watchCalls += 1;
      if (watchCalls <= failWatchTimes) {
        throw makeRetryableWatchError();
      }
    },
    async get() {
      return currentValue;
    },
    async unwatch() {
      unwatchCalls += 1;
    },
    async sRem() {},
    multi() {
      return makePipeline();
    }
  };
}

test('isRetryableRedisWatchError recognizes redis watch conflicts', () => {
  assert.equal(isRetryableRedisWatchError(makeRetryableWatchError()), true);
  assert.equal(isRetryableRedisWatchError(new Error('plain failure')), false);
});

test('updateConnection retries once after a redis watch conflict', async () => {
  const backend = makeBackend();
  const record = JSON.stringify({
    deviceId: 'device-1',
    offer: { type: 'offer', sdp: 'v=0' },
    createdAt: Date.now(),
    expiresAt: Date.now() + 60_000,
    rendezvousExpiresAt: Date.now() - 1_000,
    activeUntil: Date.now() + 120_000,
    initiatorTokenHash: 'token-hash',
    initiatorMediaAdmissionTokenHash: 'initiator-media-hash',
    responderMediaAdmissionTokenHash: 'responder-media-hash'
  });
  const isolated = makeRetryingIsolated({ initialValue: record, failWatchTimes: 1 });
  backend.executeIsolated = async (fn) => fn(isolated);

  const updated = await backend.updateConnection('ABCD', (nextItem) => {
    nextItem.answerFrom = 'responder-1';
  });

  assert.equal(updated.deviceId, 'device-1');
  assert.equal(updated.answerFrom, 'responder-1');
  assert.equal(updated.initiatorMediaAdmissionTokenHash, 'initiator-media-hash');
  assert.equal(updated.responderMediaAdmissionTokenHash, 'responder-media-hash');
  assert.ok(updated.activeUntil > Date.now());
  assert.equal(isolated.watchCalls, 2);
  assert.equal(isolated.unwatchCalls, 1);
});

test('memory backend sweep keeps active sessions after rendezvous expiry', async () => {
  const backend = createSignalingStateBackend({
    backendName: 'memory',
    instanceId: 'unit-test-memory',
    codeTtlMs: 300_000,
    iceTtlMs: 300_000,
    iceMaxPerSession: 50,
    roomMembershipTtlMs: 120_000,
    legacyBindingTtlMs: 300_000
  });
  const activeUntil = Date.now() + 120_000;
  const created = await backend.createConnectionRecord('SESSION-ACTIVE', {
    deviceId: 'device-1',
    offer: { type: 'offer', sdp: 'v=0' },
    createdAt: Date.now() - 120_000,
    expiresAt: Date.now() - 1_000,
    rendezvousExpiresAt: Date.now() - 1_000,
    activeUntil,
    initiatorTokenHash: 'token-hash'
  });

  assert.equal(created, true);
  await backend.sweepExpired();
  const record = await backend.getConnection('SESSION-ACTIVE');

  assert.equal(record.deviceId, 'device-1');
  assert.equal(record.activeUntil, activeUntil);
});

test('memory backend peekConnection preserves revoked tombstone diagnostics', async () => {
  const backend = createSignalingStateBackend({
    backendName: 'memory',
    instanceId: 'unit-test-memory',
    codeTtlMs: 300_000,
    iceTtlMs: 300_000,
    iceMaxPerSession: 50,
    roomMembershipTtlMs: 120_000,
    legacyBindingTtlMs: 300_000
  });
  const sessionId = 'SESSION-REVOKED-PEEK';
  const created = await backend.createConnectionRecord(sessionId, {
    deviceId: 'device-1',
    offer: { type: 'offer', sdp: 'v=0' },
    createdAt: Date.now(),
    expiresAt: Date.now() + 60_000,
    rendezvousExpiresAt: Date.now() - 1_000,
    activeUntil: Date.now() + 120_000,
    initiatorTokenHash: 'token-hash'
  });
  assert.equal(created, true);

  await backend.updateConnection(sessionId, (record) => {
    record.revokedAt = Date.now();
    record.revokedReason = 'remote_kill';
  });

  const peeked = await backend.peekConnection(sessionId);
  assert.equal(peeked.revokedReason, 'remote_kill');

  const active = await backend.getConnection(sessionId);
  assert.equal(active, null);
});

test(
  'redis backend persists refreshed media admission hashes across getConnection',
  { skip: !process.env.SIGNALING_TEST_REDIS_URL },
  async () => {
    const prefix = `skybridge:test:${Date.now()}:${Math.random().toString(16).slice(2)}:`;
    const backend = new RedisSignalingStateBackend({
      instanceId: 'redis-media-generation-test',
      codeTtlMs: 300_000,
      iceTtlMs: 300_000,
      iceMaxPerSession: 50,
      roomMembershipTtlMs: 120_000,
      legacyBindingTtlMs: 300_000,
      redisUrl: process.env.SIGNALING_TEST_REDIS_URL,
      redisKeyPrefix: prefix,
      redisChannelPrefix: prefix,
      redisConnectTimeoutMs: 1_000,
      log: console
    });

    await backend.init();
    try {
      const sessionId = 'SESSION-MEDIA-HASH';
      const created = await backend.createConnectionRecord(sessionId, {
        deviceId: 'device-1',
        offer: { type: 'offer', sdp: 'v=0' },
        createdAt: Date.now(),
        expiresAt: Date.now() + 60_000,
        rendezvousExpiresAt: Date.now() - 1_000,
        activeUntil: Date.now() + 120_000,
        initiatorTokenHash: 'token-hash',
        initiatorMediaAdmissionTokenHash: 'old-media-hash'
      });
      assert.equal(created, true);

      const updated = await backend.updateConnection(sessionId, (record) => {
        record.initiatorMediaAdmissionTokenHash = 'new-media-hash';
      });
      assert.equal(updated.initiatorMediaAdmissionTokenHash, 'new-media-hash');

      const roundTrip = await backend.getConnection(sessionId);
      assert.equal(roundTrip.initiatorMediaAdmissionTokenHash, 'new-media-hash');
    } finally {
      await backend.deleteConnection('SESSION-MEDIA-HASH').catch(() => {});
      await backend.close();
    }
  }
);

test('trackIceUsage retries once after a redis watch conflict', async () => {
  const backend = makeBackend();
  const isolated = makeRetryingIsolated({ initialValue: null, failWatchTimes: 1 });
  backend.executeIsolated = async (fn) => fn(isolated);

  const usage = await backend.trackIceUsage(
    'session-1',
    'peer-1',
    'candidate-hash',
    120,
    {
      maxPerSession: 10,
      maxBytesPerSession: 10_000,
      maxBytesPerPeerPerSession: 1_000
    }
  );

  assert.equal(usage.accepted, true);
  assert.equal(usage.killed, false);
  assert.equal(usage.totalCount, 1);
  assert.equal(usage.peerBytes, 120);
  assert.equal(isolated.watchCalls, 2);
  assert.equal(isolated.unwatchCalls, 1);
});

test('updateEphemeral retries once after a redis watch conflict', async () => {
  const backend = makeBackend();
  const isolated = makeRetryingIsolated({
    initialValue: JSON.stringify({
      expiresAt: Date.now() + 60_000,
      value: 1
    }),
    failWatchTimes: 1
  });
  backend.executeIsolated = async (fn) => fn(isolated);

  const updated = await backend.updateEphemeral('admission', 'id-1', (nextRecord) => {
    nextRecord.value += 1;
  });

  assert.equal(updated.value, 2);
  assert.equal(isolated.watchCalls, 2);
  assert.equal(isolated.unwatchCalls, 1);
});
