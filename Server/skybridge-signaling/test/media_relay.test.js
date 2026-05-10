'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const dgram = require('node:dgram');

const {
  createMediaRelay,
  createSignedMediaLeaseToken
} = require('../lib/media_relay');

function receiveOnce(socket) {
  return new Promise((resolve) => {
    socket.once('message', (message, rinfo) => resolve({ message, rinfo }));
  });
}

function receiveMaybe(socket, timeoutMs = 80) {
  return new Promise((resolve) => {
    const timeout = setTimeout(() => {
      socket.off('message', onMessage);
      resolve(null);
    }, timeoutMs);
    function onMessage(message, rinfo) {
      clearTimeout(timeout);
      resolve({ message, rinfo });
    }
    socket.once('message', onMessage);
  });
}

function delay(timeoutMs) {
  return new Promise((resolve) => setTimeout(resolve, timeoutMs));
}

function bindSocket() {
  return new Promise((resolve) => {
    const socket = dgram.createSocket('udp4');
    socket.bind(0, '127.0.0.1', () => resolve(socket));
  });
}

function send(socket, message, address) {
  return new Promise((resolve, reject) => {
    socket.send(message, address.port, address.host, (error) => {
      if (error) reject(error);
      else resolve();
    });
  });
}

test('media relay binds two roles and forwards only bound encrypted packets', async () => {
  const relay = createMediaRelay({
    host: '127.0.0.1',
    publicHost: '127.0.0.1',
    port: 0,
    maxPacketBytes: 1200,
    leaseTtlMs: 30_000
  });
  const address = await relay.start();
  const initiatorSocket = await bindSocket();
  const responderSocket = await bindSocket();
  try {
    const initiatorLease = relay.createLease({ sessionId: 'session-a', role: 'initiator' });
    const responderLease = relay.createLease({ sessionId: 'session-a', role: 'responder' });

    await send(initiatorSocket, Buffer.from(JSON.stringify({ type: 'bind', leaseToken: initiatorLease.leaseToken })), address);
    assert.equal(JSON.parse((await receiveOnce(initiatorSocket)).message.toString('utf8')).ok, true);

    await send(responderSocket, Buffer.from(JSON.stringify({ type: 'bind', leaseToken: responderLease.leaseToken })), address);
    assert.equal(JSON.parse((await receiveOnce(responderSocket)).message.toString('utf8')).ok, true);

    const encryptedPacket = Buffer.from([0x53, 0x42, 0x4d, 0x41, 0x01, 0x02, 0x03]);
    await send(initiatorSocket, encryptedPacket, address);
    assert.deepEqual((await receiveOnce(responderSocket)).message, encryptedPacket);
  } finally {
    initiatorSocket.close();
    responderSocket.close();
    await relay.close();
  }
});

test('media relay does not forward when both endpoints bind the same role', async () => {
  const relay = createMediaRelay({
    host: '127.0.0.1',
    publicHost: '127.0.0.1',
    port: 0,
    maxPacketBytes: 1200,
    leaseTtlMs: 30_000
  });
  const address = await relay.start();
  const firstSocket = await bindSocket();
  const secondSocket = await bindSocket();
  try {
    const firstLease = relay.createLease({ sessionId: 'session-same-role', role: 'responder' });
    const secondLease = relay.createLease({ sessionId: 'session-same-role', role: 'responder' });

    await send(firstSocket, Buffer.from(JSON.stringify({ type: 'bind', leaseToken: firstLease.leaseToken })), address);
    assert.equal(JSON.parse((await receiveOnce(firstSocket)).message.toString('utf8')).ok, true);

    await send(secondSocket, Buffer.from(JSON.stringify({ type: 'bind', leaseToken: secondLease.leaseToken })), address);
    assert.equal(JSON.parse((await receiveOnce(secondSocket)).message.toString('utf8')).ok, true);

    const encryptedPacket = Buffer.from([0x53, 0x42, 0x4d, 0x41, 0x09]);
    await send(firstSocket, encryptedPacket, address);
    assert.equal(await receiveMaybe(secondSocket), null);
  } finally {
    firstSocket.close();
    secondSocket.close();
    await relay.close();
  }
});

test('media relay drops packets above the configured datagram cap', async () => {
  const relay = createMediaRelay({
    host: '127.0.0.1',
    publicHost: '127.0.0.1',
    port: 0,
    maxPacketBytes: 128,
    leaseTtlMs: 30_000
  });
  const address = await relay.start();
  const socket = await bindSocket();
  try {
    const lease = relay.createLease({ sessionId: 'session-b', role: 'initiator' });
    await send(socket, Buffer.from(JSON.stringify({ type: 'bind', leaseToken: lease.leaseToken })), address);
    assert.equal(JSON.parse((await receiveOnce(socket)).message.toString('utf8')).ok, true);
    await send(socket, Buffer.alloc(129, 0x61), address);
    assert.equal(relay.snapshot().boundEndpoints, 1);
  } finally {
    socket.close();
    await relay.close();
  }
});

test('media relay accepts externally signed lease tokens for remote relay mode', async () => {
  const secret = 'test-media-relay-secret';
  const relay = createMediaRelay({
    host: '127.0.0.1',
    publicHost: '127.0.0.1',
    port: 0,
    maxPacketBytes: 1200,
    leaseTtlMs: 30_000,
    signedLeaseSecret: secret
  });
  const address = await relay.start();
  const initiatorSocket = await bindSocket();
  const responderSocket = await bindSocket();
  try {
    const initiatorLease = createSignedMediaLeaseToken({
      sessionId: 'external-session',
      role: 'initiator',
      ttlMs: 30_000,
      secret
    });
    const responderLease = createSignedMediaLeaseToken({
      sessionId: 'external-session',
      role: 'responder',
      ttlMs: 30_000,
      secret
    });

    await send(initiatorSocket, Buffer.from(JSON.stringify({ type: 'bind', leaseToken: initiatorLease.leaseToken })), address);
    assert.equal(JSON.parse((await receiveOnce(initiatorSocket)).message.toString('utf8')).ok, true);

    await send(responderSocket, Buffer.from(JSON.stringify({ type: 'bind', leaseToken: responderLease.leaseToken })), address);
    assert.equal(JSON.parse((await receiveOnce(responderSocket)).message.toString('utf8')).ok, true);

    const encryptedPacket = Buffer.from([0x53, 0x42, 0x4d, 0x41, 0x04, 0x05, 0x06]);
    await send(responderSocket, encryptedPacket, address);
    assert.deepEqual((await receiveOnce(initiatorSocket)).message, encryptedPacket);
  } finally {
    initiatorSocket.close();
    responderSocket.close();
    await relay.close();
  }
});

test('media relay preserves a refreshed endpoint binding when the prior signed lease expires', async () => {
  const secret = 'test-media-relay-secret';
  let currentNow = 100_000;
  const relay = createMediaRelay({
    host: '127.0.0.1',
    publicHost: '127.0.0.1',
    port: 0,
    maxPacketBytes: 1200,
    leaseTtlMs: 30_000,
    signedLeaseSecret: secret,
    now: () => currentNow
  });
  const address = await relay.start();
  const initiatorSocket = await bindSocket();
  const responderSocket = await bindSocket();
  try {
    const oldInitiatorLease = createSignedMediaLeaseToken({
      sessionId: 'external-refresh-session',
      role: 'initiator',
      ttlMs: 2_000,
      now: currentNow,
      secret
    });
    const responderLease = createSignedMediaLeaseToken({
      sessionId: 'external-refresh-session',
      role: 'responder',
      ttlMs: 60_000,
      now: currentNow,
      secret
    });

    await send(initiatorSocket, Buffer.from(JSON.stringify({ type: 'bind', leaseToken: oldInitiatorLease.leaseToken })), address);
    assert.equal(JSON.parse((await receiveOnce(initiatorSocket)).message.toString('utf8')).ok, true);

    await send(responderSocket, Buffer.from(JSON.stringify({ type: 'bind', leaseToken: responderLease.leaseToken })), address);
    assert.equal(JSON.parse((await receiveOnce(responderSocket)).message.toString('utf8')).ok, true);

    currentNow += 500;
    const refreshedInitiatorLease = createSignedMediaLeaseToken({
      sessionId: 'external-refresh-session',
      role: 'initiator',
      ttlMs: 60_000,
      now: currentNow,
      secret
    });
    await send(initiatorSocket, Buffer.from(JSON.stringify({ type: 'bind', leaseToken: refreshedInitiatorLease.leaseToken })), address);
    assert.equal(JSON.parse((await receiveOnce(initiatorSocket)).message.toString('utf8')).ok, true);

    currentNow = oldInitiatorLease.expiresAt + 1;
    const encryptedPacket = Buffer.from([0x53, 0x42, 0x4d, 0x41, 0x07, 0x08, 0x09]);
    await send(initiatorSocket, encryptedPacket, address);
    assert.deepEqual((await receiveOnce(responderSocket)).message, encryptedPacket);
  } finally {
    initiatorSocket.close();
    responderSocket.close();
    await relay.close();
  }
});

test('media relay rejects tampered signed lease tokens', async () => {
  const relay = createMediaRelay({
    host: '127.0.0.1',
    publicHost: '127.0.0.1',
    port: 0,
    maxPacketBytes: 1200,
    signedLeaseSecret: 'test-media-relay-secret'
  });
  const address = await relay.start();
  const socket = await bindSocket();
  try {
    const lease = createSignedMediaLeaseToken({
      sessionId: 'external-session',
      role: 'initiator',
      ttlMs: 30_000,
      secret: 'test-media-relay-secret'
    });
    const tampered = `${lease.leaseToken.slice(0, -1)}x`;
    await send(socket, Buffer.from(JSON.stringify({ type: 'bind', leaseToken: tampered })), address);
    const response = JSON.parse((await receiveOnce(socket)).message.toString('utf8'));
    assert.equal(response.ok, false);
    assert.equal(response.error, 'lease_expired');
    assert.equal(relay.snapshot().boundEndpoints, 0);
  } finally {
    socket.close();
    await relay.close();
  }
});

test('media relay diagnostics records bind rejections and malformed packet drops', async () => {
  const relay = createMediaRelay({
    host: '127.0.0.1',
    publicHost: '127.0.0.1',
    port: 0,
    maxPacketBytes: 128,
    leaseTtlMs: 30_000
  });
  const address = await relay.start();
  const socket = await bindSocket();
  try {
    await send(socket, Buffer.from(JSON.stringify({ type: 'bind', leaseToken: 123 })), address);
    await send(socket, Buffer.from(JSON.stringify({ type: 'bind', leaseToken: 'not-a-lease-token' })), address);
    const response = JSON.parse((await receiveOnce(socket)).message.toString('utf8'));
    assert.equal(response.ok, false);
    assert.equal(response.error, 'lease_expired');

    await send(socket, Buffer.from('{bad-json'), address);
    await send(socket, Buffer.alloc(129, 0x61), address);
    await send(socket, Buffer.from([0x53, 0x42, 0x4d, 0x41]), address);
    await delay(20);

    const diagnostics = relay.snapshot().diagnostics;
    assert.equal(diagnostics.bindRequests, 1);
    assert.equal(diagnostics.bindAccepted, 0);
    assert.equal(diagnostics.bindRejected.lease_expired, 1);
    assert.equal(diagnostics.drops.invalid_bind_message, 1);
    assert.equal(diagnostics.drops.invalid_json, 1);
    assert.equal(diagnostics.drops.packet_oversize, 1);
    assert.equal(diagnostics.drops.unbound_source, 1);
  } finally {
    socket.close();
    await relay.close();
  }
});

test('media relay diagnostics records peer-missing drops and successful forwards', async () => {
  const relay = createMediaRelay({
    host: '127.0.0.1',
    publicHost: '127.0.0.1',
    port: 0,
    maxPacketBytes: 1200,
    leaseTtlMs: 30_000
  });
  const address = await relay.start();
  const initiatorSocket = await bindSocket();
  const responderSocket = await bindSocket();
  try {
    const initiatorLease = relay.createLease({ sessionId: 'diagnostics-session', role: 'initiator' });
    const responderLease = relay.createLease({ sessionId: 'diagnostics-session', role: 'responder' });

    await send(initiatorSocket, Buffer.from(JSON.stringify({ type: 'bind', leaseToken: initiatorLease.leaseToken })), address);
    assert.equal(JSON.parse((await receiveOnce(initiatorSocket)).message.toString('utf8')).ok, true);

    const encryptedPacket = Buffer.from([0x53, 0x42, 0x4d, 0x41, 0x11, 0x12]);
    await send(initiatorSocket, encryptedPacket, address);
    await delay(20);
    assert.equal(relay.snapshot().diagnostics.drops.peer_lease_missing, 1);

    await send(responderSocket, Buffer.from(JSON.stringify({ type: 'bind', leaseToken: responderLease.leaseToken })), address);
    assert.equal(JSON.parse((await receiveOnce(responderSocket)).message.toString('utf8')).ok, true);

    await send(initiatorSocket, encryptedPacket, address);
    assert.deepEqual((await receiveOnce(responderSocket)).message, encryptedPacket);

    const diagnostics = relay.snapshot().diagnostics;
    assert.equal(diagnostics.bindRequests, 2);
    assert.equal(diagnostics.bindAccepted, 2);
    assert.equal(diagnostics.forwardedPackets, 1);
    assert.equal(diagnostics.forwardedBytes, encryptedPacket.length);
  } finally {
    initiatorSocket.close();
    responderSocket.close();
    await relay.close();
  }
});
