'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const { waitForReady } = require('../deploy/scripts/wait_ready');

const expected = 'skybridge-signaling/reviewed-test';
const ready = { status: 'ready', serverBuildFingerprint: expected };

async function serve(t, reply) {
  let requests = 0;
  const server = http.createServer((request, response) => {
    requests += 1;
    const value = reply(request, requests);
    response.writeHead(value.status, { 'Content-Type': 'application/json' });
    response.end(typeof value.body === 'string' ? value.body : JSON.stringify(value.body));
  });
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
  t.after(async () => {
    server.closeAllConnections();
    await new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
  });
  return { url: `http://127.0.0.1:${server.address().port}`, requests: () => requests };
}

test('readiness waits through startup 503 then requires the reviewed release', async (t) => {
  const server = await serve(t, (request, count) => {
    assert.equal(request.url, '/readyz');
    return count < 3 ? { status: 503, body: { ready: false } } : { status: 200, body: ready };
  });
  await waitForReady(server.url, expected, { timeoutMs: 1000, retryDelayMs: 5 });
  assert.equal(server.requests(), 3);
});

for (const [name, response, pattern] of [
  ['different release', { status: 200, body: { ...ready, serverBuildFingerprint: 'other-release' } }, /fingerprint/],
  ['false readiness', { status: 200, body: { ...ready, status: 'not_ready' } }, /ready contract/],
  ['malformed JSON', { status: 200, body: 'not JSON' }, /valid JSON/],
  ['unexpected authorization failure', { status: 401, body: {} }, /HTTP 401/],
  ['unexpected internal failure', { status: 500, body: {} }, /HTTP 500/]
]) {
  test(`readiness rejects ${name} without retrying it into success`, async (t) => {
    const server = await serve(t, (_request, count) => count === 1 ? response : { status: 200, body: ready });
    await assert.rejects(waitForReady(server.url, expected, { timeoutMs: 1000, retryDelayMs: 5 }), pattern);
    assert.equal(server.requests(), 1);
  });
}

test('readiness has a finite deadline when the service never becomes ready', async (t) => {
  const server = await serve(t, () => ({ status: 503, body: { ready: false } }));
  await assert.rejects(waitForReady(server.url, expected, { timeoutMs: 100, retryDelayMs: 5 }), /timed out/);
  const stoppedAt = server.requests();
  await new Promise((resolve) => setTimeout(resolve, 30));
  assert.equal(server.requests(), stoppedAt, 'No background retry remains after failure');
});

test('readiness retries connection refusal until the listener starts', async (t) => {
  const reservation = http.createServer();
  await new Promise((resolve) => reservation.listen(0, '127.0.0.1', resolve));
  const port = reservation.address().port;
  await new Promise((resolve) => reservation.close(resolve));
  const server = http.createServer((_request, response) => response.end(JSON.stringify(ready)));
  const started = new Promise((resolve, reject) => {
    server.once('error', reject);
    setTimeout(() => server.listen(port, '127.0.0.1', resolve), 80);
  });
  t.after(async () => {
    await started;
    server.closeAllConnections();
    await new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
  });
  await waitForReady(`http://127.0.0.1:${port}`, expected, { timeoutMs: 1500, retryDelayMs: 5 });
});
