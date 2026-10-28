'use strict';

const { performance } = require('node:perf_hooks');

const retryableNetworkErrors = new Set([
  'ECONNREFUSED', 'ECONNRESET', 'ETIMEDOUT', 'EAI_AGAIN',
  'UND_ERR_CONNECT_TIMEOUT', 'UND_ERR_HEADERS_TIMEOUT', 'UND_ERR_SOCKET'
]);

async function waitForReady(baseURL, expectedBuild, { timeoutMs = 30_000, retryDelayMs = 250 } = {}) {
  const base = new URL(baseURL);
  if (!['http:', 'https:'].includes(base.protocol) || base.username || base.password || base.search || base.hash
      || typeof expectedBuild !== 'string' || !expectedBuild || expectedBuild.length > 256
      || /[\u0000-\u001f\u007f]/.test(expectedBuild)
      || !Number.isInteger(timeoutMs) || timeoutMs < 1 || timeoutMs > 60_000
      || !Number.isInteger(retryDelayMs) || retryDelayMs < 1 || retryDelayMs > 1_000) {
    throw new Error('Invalid readiness probe arguments');
  }
  const url = new URL('/readyz', base);
  const deadline = performance.now() + timeoutMs;
  let lastState = 'not_started';
  while (performance.now() < deadline) {
    try {
      const response = await fetch(url, {
        redirect: 'error',
        signal: AbortSignal.timeout(Math.max(1, Math.ceil(Math.min(2_000, deadline - performance.now()))))
      });
      if (response.status === 503) {
        lastState = 'http_503';
        await response.body?.cancel();
      } else {
        if (response.status !== 200) {
          await response.body?.cancel();
          throw new Error(`Readiness returned unexpected HTTP ${response.status}`);
        }
        if (!response.body) throw new Error('Readiness response is empty');
        const chunks = [];
        let size = 0;
        for await (const chunk of response.body) {
          size += chunk.length;
          if (size > 1_048_576) throw new Error('Readiness response exceeds the size limit');
          chunks.push(chunk);
        }
        let body;
        try { body = JSON.parse(Buffer.concat(chunks).toString('utf8')); }
        catch { throw new Error('Readiness response is not valid JSON'); }
        if (!body || body.serverBuildFingerprint !== expectedBuild) {
          throw new Error('Readiness build fingerprint does not match the reviewed release');
        }
        if (body.status !== 'ready') throw new Error('Readiness response violates the ready contract');
        if (performance.now() >= deadline) throw new Error(`Readiness timed out after ${timeoutMs} ms`);
        return;
      }
    } catch (error) {
      const code = error?.cause?.code || error?.code;
      if (error?.name !== 'TimeoutError' && !retryableNetworkErrors.has(code)) throw error;
      lastState = error?.name === 'TimeoutError' ? 'request_timeout' : code;
    }
    const remaining = deadline - performance.now();
    if (remaining > 0) await new Promise((resolve) => setTimeout(resolve, Math.min(retryDelayMs, remaining)));
  }
  throw new Error(`Readiness timed out after ${timeoutMs} ms; last state=${lastState}`);
}

module.exports = { waitForReady };

if (require.main === module) {
  waitForReady(process.argv[2], process.argv[3]).then(() => {
    console.log('[ready] Reviewed release is ready');
  }, (error) => {
    console.error('[ready] ' + error.message);
    process.exitCode = 1;
  });
}
