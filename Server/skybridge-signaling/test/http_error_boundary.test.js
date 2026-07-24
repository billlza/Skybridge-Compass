'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const {
  __test: { asyncRoute, makeError }
} = require('../server');

function responseRecorder() {
  return {
    headersSent: false,
    statusCode: null,
    body: null,
    status(value) {
      this.statusCode = value;
      return this;
    },
    json(value) {
      this.body = value;
      this.headersSent = true;
      return this;
    }
  };
}

async function captureErrorLog(operation) {
  const original = console.error;
  const lines = [];
  console.error = (...parts) => {
    lines.push(parts.map(String).join(' '));
  };
  try {
    await operation();
  } finally {
    console.error = original;
  }
  return lines.join('\n');
}

test('HTTP error boundary redacts unknown 5xx messages from response and logs', async () => {
  const response = responseRecorder();
  const secret = 'secret-token-must-not-leak';
  const logs = await captureErrorLog(async () => {
    await asyncRoute(async () => {
      throw new Error(secret);
    })({ method: 'POST', path: '/test/unknown-error' }, response);
  });

  assert.equal(response.statusCode, 500);
  assert.deepEqual(response.body, { error: 'internal_error' });
  assert.doesNotMatch(JSON.stringify(response.body), new RegExp(secret));
  assert.doesNotMatch(logs, new RegExp(secret));
  assert.match(logs, /code=internal_error status=500 diagnostic=Error/);
});

test('HTTP error boundary preserves explicitly public stable errors and details', async () => {
  const response = responseRecorder();
  await captureErrorLog(async () => {
    await asyncRoute(async () => {
      throw makeError('stable_public_error', 409, { retryable: false });
    })({ method: 'POST', path: '/test/public-error' }, response);
  });

  assert.equal(response.statusCode, 409);
  assert.deepEqual(response.body, {
    error: 'stable_public_error',
    retryable: false
  });
});

test('HTTP error boundary maps unmarked 4xx failures to request_failed', async () => {
  const response = responseRecorder();
  const error = new Error('private-validation-detail');
  error.statusCode = 422;
  await captureErrorLog(async () => {
    await asyncRoute(async () => {
      throw error;
    })({ method: 'POST', path: '/test/private-client-error' }, response);
  });

  assert.equal(response.statusCode, 422);
  assert.deepEqual(response.body, { error: 'request_failed' });
});
