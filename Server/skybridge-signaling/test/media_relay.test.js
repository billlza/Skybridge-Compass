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
