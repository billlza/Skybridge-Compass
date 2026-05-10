'use strict';

const os = require('node:os');

const { createMediaRelay } = require('./lib/media_relay');

const host = String(process.env.MEDIA_RELAY_HOST || '0.0.0.0').trim() || '0.0.0.0';
const publicHost = String(process.env.MEDIA_RELAY_PUBLIC_HOST || process.env.MEDIA_RELAY_HOST || '').trim() || host;
const port = Number(process.env.MEDIA_RELAY_UDP_PORT || 3478);
const maxPacketBytes = Number(process.env.MEDIA_RELAY_MAX_PACKET_BYTES || 1200);
const leaseTtlMs = Number(process.env.MEDIA_RELAY_LEASE_TTL_MS || 60_000);
const diagnosticsIntervalMs = Number(process.env.MEDIA_RELAY_DIAGNOSTICS_INTERVAL_MS || 30_000);
const signedLeaseSecret = String(process.env.MEDIA_RELAY_TOKEN_SECRET || '').trim();
const instanceId = String(process.env.INSTANCE_ID || `${os.hostname()}-${process.pid}`).trim();

if (!signedLeaseSecret) {
  console.error('[media-relay] missing MEDIA_RELAY_TOKEN_SECRET; refusing to start external relay');
  process.exit(1);
}

const relay = createMediaRelay({
  host,
  publicHost,
  port,
  maxPacketBytes,
  leaseTtlMs,
  signedLeaseSecret,
  log: console
});

let diagnosticsTimer = null;

function logDiagnostics() {
  const snapshot = relay.snapshot();
  console.log(`[media-relay] diagnostics ${JSON.stringify({
    instanceId,
    address: snapshot.address,
    leases: snapshot.leases,
    boundEndpoints: snapshot.boundEndpoints,
    sessions: snapshot.sessions,
    maxPacketBytes: snapshot.maxPacketBytes,
    diagnostics: snapshot.diagnostics
  })}`);
}

async function shutdown(signal) {
  console.log(`[media-relay] shutdown requested: ${signal}`);
  if (diagnosticsTimer) {
    clearInterval(diagnosticsTimer);
    diagnosticsTimer = null;
  }
  await relay.close();
}

process.on('SIGINT', () => {
  shutdown('SIGINT').finally(() => process.exit(0));
});
process.on('SIGTERM', () => {
  shutdown('SIGTERM').finally(() => process.exit(0));
});

relay.start()
  .then((address) => {
    console.log('========================================');
    console.log('SkyBridge PQC Media Relay');
    console.log(`Instance: ${instanceId}`);
    console.log(`UDP: ${host}:${port}`);
    console.log(`Public: udp://${address.host}:${address.port}`);
    console.log(`MaxPacketBytes: ${maxPacketBytes}`);
    console.log('Signed leases: enabled');
    if (Number.isFinite(diagnosticsIntervalMs) && diagnosticsIntervalMs > 0) {
      diagnosticsTimer = setInterval(logDiagnostics, diagnosticsIntervalMs);
      diagnosticsTimer.unref?.();
      console.log(`DiagnosticsIntervalMs: ${diagnosticsIntervalMs}`);
    } else {
      console.log('DiagnosticsIntervalMs: disabled');
    }
    console.log('========================================');
  })
  .catch((error) => {
    console.error('[media-relay] failed to start:', error);
    process.exit(1);
  });
