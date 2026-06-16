'use strict';

const test = require('node:test');
const { before, after } = require('node:test');
const assert = require('node:assert/strict');
const { once } = require('node:events');
const { spawn } = require('node:child_process');
const net = require('node:net');
const { WebSocket } = require('ws');

const SIGNALING_PATH = '/local-compat/ws';
let runtime;

before(async () => {
  runtime = await startLocalCompatServer();
});

after(async () => {
  if (!runtime) return;
  runtime.child.kill('SIGTERM');
  await Promise.race([
    once(runtime.child, 'exit'),
    new Promise((resolve) => setTimeout(resolve, 2_000))
  ]);
});

test('local compat websocket accepts header session token without putting token in the URL', async () => {
  const session = await registerInitiatorSession();
  const wsURL = `${runtime.wsOrigin}${SIGNALING_PATH}?shard=${encodeURIComponent(session.sessionId)}&cv=1.2.3&pv=2`;
  assert.equal(wsURL.includes(session.sessionToken), false);

  const ws = new WebSocket(wsURL, {
    headers: {
      'X-SkyBridge-Session-Id': session.sessionId,
      'X-SkyBridge-Session': session.sessionToken,
      'X-SkyBridge-Client-Version': '1.2.3',
      'X-SkyBridge-Protocol-Version': '2'
    }
  });
  try {
    const bound = await waitForWebSocketMessage(ws, (message) => message.type === 'bound');
    assert.equal(bound.sessionId, session.sessionId);
    assert.equal(bound.role, 'initiator');
  } finally {
    ws.close();
    await waitForWebSocketClose(ws);
  }

  assertNoSecretInLogs(session.sessionToken);
});

test('local compat websocket rejects legacy query session token by default', async () => {
  const session = await registerInitiatorSession();
  const ws = new WebSocket(
    `${runtime.wsOrigin}${SIGNALING_PATH}?shard=${encodeURIComponent(session.sessionId)}&st=${encodeURIComponent(session.sessionToken)}`
  );

  const close = await waitForWebSocketClose(ws);
  assert.equal(close.code, 1008);
  assert.equal(close.reason, 'legacy_query_token_disabled');
  assertNoSecretInLogs(session.sessionToken);
});

test('local compat websocket keeps legacy query compatibility only when explicitly enabled', async () => {
  const legacyRuntime = await startLocalCompatServer({
    SKYBRIDGE_SIGNALING_ALLOW_LEGACY_QUERY_TOKEN: 'true'
  });
  try {
    const session = await registerInitiatorSession(legacyRuntime);
    const ws = new WebSocket(
      `${legacyRuntime.wsOrigin}${SIGNALING_PATH}?shard=${encodeURIComponent(session.sessionId)}&st=${encodeURIComponent(session.sessionToken)}`
    );
    try {
      const bound = await waitForWebSocketMessage(ws, (message) => message.type === 'bound');
      assert.equal(bound.sessionId, session.sessionId);
      assert.equal(bound.role, 'initiator');
    } finally {
      ws.close();
      await waitForWebSocketClose(ws);
    }

    assertNoSecretInLogs(session.sessionToken, legacyRuntime);
  } finally {
    legacyRuntime.child.kill('SIGTERM');
    await Promise.race([
      once(legacyRuntime.child, 'exit'),
      new Promise((resolve) => setTimeout(resolve, 2_000))
    ]);
  }
});

test('local compat websocket rejects mixed header and legacy query session tokens', async () => {
  const session = await registerInitiatorSession();
  const ws = new WebSocket(
    `${runtime.wsOrigin}${SIGNALING_PATH}?shard=${encodeURIComponent(session.sessionId)}&st=${encodeURIComponent(session.sessionToken)}`,
    {
      headers: {
        'X-SkyBridge-Session-Id': session.sessionId,
        'X-SkyBridge-Session': session.sessionToken
      }
    }
  );

  const close = await waitForWebSocketClose(ws);
  assert.equal(close.code, 1008);
  assert.equal(close.reason, 'conflicting_session_credentials');
  assertNoSecretInLogs(session.sessionToken);
});

test('local compat websocket rejects empty legacy query token when header credentials are present', async () => {
  const session = await registerInitiatorSession();
  const ws = new WebSocket(
    `${runtime.wsOrigin}${SIGNALING_PATH}?shard=${encodeURIComponent(session.sessionId)}&st=`,
    {
      headers: {
        'X-SkyBridge-Session-Id': session.sessionId,
        'X-SkyBridge-Session': session.sessionToken
      }
    }
  );

  const close = await waitForWebSocketClose(ws);
  assert.equal(close.code, 1008);
  assert.equal(close.reason, 'conflicting_session_credentials');
  assertNoSecretInLogs(session.sessionToken);
});

test('local compat websocket reclaims superseded same-role sockets', async () => {
  const session = await registerInitiatorSession();
  const wsURL = `${runtime.wsOrigin}${SIGNALING_PATH}?shard=${encodeURIComponent(session.sessionId)}`;
  const headers = {
    'X-SkyBridge-Session-Id': session.sessionId,
    'X-SkyBridge-Session': session.sessionToken
  };
  const first = new WebSocket(wsURL, { headers });
  let second = null;

  try {
    const firstBound = await waitForWebSocketMessage(first, (message) => message.type === 'bound');
    assert.equal(firstBound.role, 'initiator');

    const firstClose = waitForWebSocketClose(first);
    second = new WebSocket(wsURL, { headers });
    const secondBound = await waitForWebSocketMessage(second, (message) => message.type === 'bound');
    assert.equal(secondBound.role, 'initiator');

    const close = await firstClose;
    assert.equal(close.code, 1008);
    assert.equal(close.reason, 'reclaimed');
  } finally {
    await closeWebSocket(first);
    await closeWebSocket(second);
  }

  assertNoSecretInLogs(session.sessionToken);
});

test('local compat websocket rejects messages over the configured byte limit', async () => {
  const session = await registerInitiatorSession();
  const ws = new WebSocket(`${runtime.wsOrigin}${SIGNALING_PATH}?shard=${encodeURIComponent(session.sessionId)}`, {
    headers: {
      'X-SkyBridge-Session-Id': session.sessionId,
      'X-SkyBridge-Session': session.sessionToken
    }
  });
  const oversizedPayload = 'x'.repeat(65);

  try {
    const bound = await waitForWebSocketMessage(ws, (message) => message.type === 'bound');
    assert.equal(bound.role, 'initiator');
    const close = waitForWebSocketClose(ws);
    ws.send(oversizedPayload);
    const result = await close;
    assert.equal(result.code, 1009);
    assert.equal(result.reason, 'message_too_large');
  } finally {
    await closeWebSocket(ws);
  }

  assertNoSecretInLogs(session.sessionToken);
  assertNoSecretInLogs(oversizedPayload);
});

async function registerInitiatorSession(targetRuntime = runtime) {
  const challenge = await postJSON('/api/webrtc/admission/challenge', {
    deviceId: `device-${Date.now()}-${Math.random().toString(16).slice(2)}`,
    protocolSigningAlgorithm: 'ED25519',
    protocolPublicKeyFingerprint: randomFingerprint(),
    clientVersion: '1.2.3',
    protocolVersion: '2'
  }, {}, targetRuntime);
  assert.equal(challenge.status, 200);

  const admission = await postJSON('/api/webrtc/admission', {
    challengeId: challenge.json.challengeId,
    protocolPublicKeyBytes: [1, 2, 3, 4]
  }, {}, targetRuntime);
  assert.equal(admission.status, 200);

  const registered = await postJSON('/api/webrtc/register-code', {
    deviceName: 'Compat Test Device'
  }, {
    'X-SkyBridge-Admission': admission.json.admissionToken
  }, targetRuntime);
  assert.equal(registered.status, 200);
  assert.equal(registered.json.wsPath, SIGNALING_PATH);
  assert.ok(registered.json.sessionToken);
  return registered.json;
}

async function postJSON(path, body, headers = {}, targetRuntime = runtime) {
  const response = await fetch(`${targetRuntime.httpOrigin}${path}`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: 'Bearer local-compat-test-token',
      ...headers
    },
    body: JSON.stringify(body)
  });
  const json = await response.json();
  return { status: response.status, json };
}

async function startLocalCompatServer(extraEnv = {}) {
  const port = await allocatePort();
  const child = spawn(process.execPath, ['local_compat_server.js'], {
    cwd: process.cwd(),
    env: {
      ...process.env,
      HOST: '127.0.0.1',
      PORT: String(port),
      SKYBRIDGE_SIGNALING_WEBSOCKET_PATH: SIGNALING_PATH,
      SKYBRIDGE_LOCAL_COMPAT_MAX_WS_MESSAGE_BYTES: '64',
      SKYBRIDGE_LOCAL_COMPAT_MAX_WS_PAYLOAD_BYTES: '1024',
      ...extraEnv
    },
    stdio: ['ignore', 'pipe', 'pipe']
  });
  const logs = [];
  child.stdout.setEncoding('utf8');
  child.stderr.setEncoding('utf8');
  child.stdout.on('data', (chunk) => logs.push(chunk));
  child.stderr.on('data', (chunk) => logs.push(chunk));
  child.on('exit', (code, signal) => {
    if (code !== 0 && signal !== 'SIGTERM') {
      logs.push(`local compat server exited code=${code} signal=${signal}`);
    }
  });

  const httpOrigin = `http://127.0.0.1:${port}`;
  const wsOrigin = `ws://127.0.0.1:${port}`;
  await waitForHealth(httpOrigin, child);
  return { child, httpOrigin, wsOrigin, logs };
}

async function allocatePort() {
  const server = net.createServer();
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const { port } = server.address();
  server.close();
  await once(server, 'close');
  return port;
}

async function waitForHealth(httpOrigin, child) {
  const deadline = Date.now() + 5_000;
  let lastError = null;
  while (Date.now() < deadline) {
    if (child.exitCode !== null) {
      throw new Error(`local compat server exited before health check: ${child.exitCode}`);
    }
    try {
      const response = await fetch(`${httpOrigin}/health`);
      if (response.ok) return;
    } catch (error) {
      lastError = error;
    }
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  throw lastError || new Error('timed out waiting for local compat server health');
}

function waitForWebSocketMessage(ws, predicate, timeoutMs = 1_500) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      cleanup();
      reject(new Error('timed out waiting for websocket message'));
    }, timeoutMs);

    function cleanup() {
      clearTimeout(timer);
      ws.off('message', onMessage);
      ws.off('error', onError);
      ws.off('close', onClose);
    }

    function onMessage(raw) {
      const message = JSON.parse(String(raw));
      if (!predicate || predicate(message)) {
        cleanup();
        resolve(message);
      }
    }

    function onError(error) {
      cleanup();
      reject(error);
    }

    function onClose(code, reasonBuffer) {
      cleanup();
      reject(new Error(`websocket closed before expected message: ${code} ${String(reasonBuffer || '')}`));
    }

    ws.on('message', onMessage);
    ws.on('error', onError);
    ws.on('close', onClose);
  });
}

function waitForWebSocketClose(ws, timeoutMs = 1_500) {
  if (ws.readyState === WebSocket.CLOSED) {
    return Promise.resolve({ code: ws.closeCode, reason: String(ws.closeReason || '') });
  }
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      cleanup();
      reject(new Error('timed out waiting for websocket close'));
    }, timeoutMs);

    function cleanup() {
      clearTimeout(timer);
      ws.off('close', onClose);
      ws.off('error', onError);
    }

    function onClose(code, reasonBuffer) {
      cleanup();
      resolve({ code, reason: String(reasonBuffer || '') });
    }

    function onError(error) {
      cleanup();
      reject(error);
    }

    ws.on('close', onClose);
    ws.on('error', onError);
  });
}

async function closeWebSocket(ws) {
  if (!ws || ws.readyState === WebSocket.CLOSED) return;
  if (ws.readyState === WebSocket.CLOSING) {
    await waitForWebSocketClose(ws).catch(() => {});
    return;
  }
  ws.close();
  await waitForWebSocketClose(ws).catch(() => {});
}

function randomFingerprint() {
  return Buffer.from(cryptoRandomBytes(16)).toString('hex');
}

function cryptoRandomBytes(length) {
  return require('node:crypto').randomBytes(length);
}

function assertNoSecretInLogs(secret) {
  assert.ok(secret, 'secret under test must be non-empty');
  assert.equal(runtime.logs.join('').includes(secret), false, 'local compat logs must not contain raw session tokens');
}
