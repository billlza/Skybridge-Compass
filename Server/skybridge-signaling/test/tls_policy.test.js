'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const {
  __test: {
    assertMTLSBindingForRecord,
    buildNodeHTTPSServerTLSOptions,
    mtlsBindingErrorForRecord,
    mtlsClientCertificateFingerprintForRequest,
    parseTrustedProxyClientCertificate,
    resolveNodeHTTPSTransportPolicy,
    resolvePeerCertificateForMTLS
  }
} = require('../server');

function buildTrustedProxyMTLSPolicy(overrides = {}) {
  return resolveNodeHTTPSTransportPolicy({
    HOST: '127.0.0.1',
    TRUST_PROXY: 'true',
    SKYBRIDGE_SIGNALING_MTLS_CLIENT_CERT_SOURCE: 'trusted_proxy',
    ...overrides
  });
}

function trustedProxyMTLSRequest(policy, {
  remoteAddress = '::ffff:127.0.0.1',
  headers = {}
} = {}) {
  return {
    socket: { remoteAddress },
    headers: {
      [policy.trustedProxyMTLS.verifyHeader]: 'SUCCESS',
      [policy.trustedProxyMTLS.certHeader]: 'escaped-cert',
      ...headers
    }
  };
}

test('node HTTPS policy keeps local HTTP mode when TLS is not configured', () => {
  const policy = resolveNodeHTTPSTransportPolicy({});

  assert.equal(policy.mode, 'http');
  assert.equal(policy.useNodeHTTPS, false);
  assert.equal(policy.mtls.required, false);
  assert.equal(policy.mtls.requestCert, false);
  assert.equal(policy.mtls.rejectUnauthorized, false);
});

test('node HTTPS policy rejects partial certificate configuration instead of falling back to HTTP', () => {
  assert.throws(
    () => resolveNodeHTTPSTransportPolicy({ TLS_CERT: '/tmp/server.crt' }),
    /node_https_requires_tls_cert_and_key/
  );
  assert.throws(
    () => resolveNodeHTTPSTransportPolicy({ TLS_KEY: '/tmp/server.key' }),
    /node_https_requires_tls_cert_and_key/
  );
});

test('node HTTPS policy treats TLS_CA as client CA evidence and enables mandatory mTLS', () => {
  const policy = resolveNodeHTTPSTransportPolicy({
    TLS_CERT: '/tmp/server.crt',
    TLS_KEY: '/tmp/server.key',
    TLS_CA: '/tmp/client-ca.crt'
  });

  assert.equal(policy.mode, 'https');
  assert.equal(policy.useNodeHTTPS, true);
  assert.equal(policy.mtls.required, true);
  assert.equal(policy.mtls.requestCert, true);
  assert.equal(policy.mtls.rejectUnauthorized, true);

  const tlsOptions = buildNodeHTTPSServerTLSOptions(policy, (path) => Buffer.from(path));
  assert.equal(String(tlsOptions.cert), '/tmp/server.crt');
  assert.equal(String(tlsOptions.key), '/tmp/server.key');
  assert.equal(String(tlsOptions.ca), '/tmp/client-ca.crt');
  assert.equal(tlsOptions.requestCert, true);
  assert.equal(tlsOptions.rejectUnauthorized, true);
});

test('node HTTPS policy fails closed when mTLS is required without a client CA', () => {
  assert.throws(
    () => resolveNodeHTTPSTransportPolicy({
      TLS_CERT: '/tmp/server.crt',
      TLS_KEY: '/tmp/server.key',
      SKYBRIDGE_SIGNALING_REQUIRE_MTLS: 'true'
    }),
    /mtls_requires_tls_ca/
  );
  assert.throws(
    () => resolveNodeHTTPSTransportPolicy({
      TLS_CA: '/tmp/client-ca.crt',
      SKYBRIDGE_SIGNALING_REQUIRE_MTLS: 'true'
    }),
    /mtls_ca_requires_node_https_tls_cert_key/
  );
});

test('trusted proxy mTLS policy is explicit and keeps Node HTTP behind Nginx', () => {
  const policy = buildTrustedProxyMTLSPolicy();

  assert.equal(policy.mode, 'http');
  assert.equal(policy.useNodeHTTPS, false);
  assert.equal(policy.mtls.required, true);
  assert.equal(policy.mtls.source, 'trusted_proxy');
  assert.equal(policy.mtls.requestCert, false);
  assert.equal(policy.trustedProxyMTLS.verifyHeader, 'x-skybridge-mtls-client-verify');
  assert.equal(policy.trustedProxyMTLS.certHeader, 'x-skybridge-mtls-client-cert-pem');
  assert.deepEqual(policy.trustedProxyMTLS.trustedRemoteAddresses, ['127.0.0.1', '::1']);
});

test('trusted proxy mTLS policy fails closed on ambiguous or unsafe startup config', () => {
  assert.throws(
    () => resolveNodeHTTPSTransportPolicy({
      HOST: '127.0.0.1',
      SKYBRIDGE_SIGNALING_MTLS_CLIENT_CERT_SOURCE: 'trusted_proxy'
    }),
    /trusted_proxy_mtls_requires_trust_proxy/
  );
  assert.throws(
    () => resolveNodeHTTPSTransportPolicy({
      HOST: '0.0.0.0',
      TRUST_PROXY: 'true',
      SKYBRIDGE_SIGNALING_MTLS_CLIENT_CERT_SOURCE: 'trusted_proxy'
    }),
    /trusted_proxy_mtls_requires_trusted_remote_addresses/
  );
  assert.throws(
    () => resolveNodeHTTPSTransportPolicy({
      HOST: '127.0.0.1',
      TRUST_PROXY: 'true',
      TLS_CA: '/tmp/client-ca.crt',
      SKYBRIDGE_SIGNALING_MTLS_CLIENT_CERT_SOURCE: 'trusted_proxy'
    }),
    /trusted_proxy_mtls_must_not_set_tls_ca/
  );
});

test('trusted proxy mTLS policy accepts explicit Nginx remote addresses for non-loopback hosts', () => {
  const policy = buildTrustedProxyMTLSPolicy({
    HOST: '0.0.0.0',
    SKYBRIDGE_SIGNALING_TRUSTED_PROXY_MTLS_REMOTE_ADDRESSES: '10.0.0.10, ::ffff:10.0.0.11'
  });

  assert.deepEqual(policy.trustedProxyMTLS.trustedRemoteAddresses, ['10.0.0.10', '10.0.0.11']);
});

test('trusted proxy mTLS policy can keep backend Node HTTPS without reading a client CA', () => {
  const policy = buildTrustedProxyMTLSPolicy({
    TLS_CERT: '/tmp/server.crt',
    TLS_KEY: '/tmp/server.key'
  });

  assert.equal(policy.mode, 'https');
  assert.equal(policy.useNodeHTTPS, true);
  assert.equal(policy.mtls.source, 'trusted_proxy');

  const tlsOptions = buildNodeHTTPSServerTLSOptions(policy, (path) => Buffer.from(path));
  assert.equal(String(tlsOptions.cert), '/tmp/server.crt');
  assert.equal(String(tlsOptions.key), '/tmp/server.key');
  assert.equal(tlsOptions.ca, undefined);
  assert.equal(tlsOptions.requestCert, undefined);
  assert.equal(tlsOptions.rejectUnauthorized, undefined);
});

test('node HTTPS policy allows non-mTLS direct HTTPS only when no client CA is configured', () => {
  const policy = resolveNodeHTTPSTransportPolicy({
    TLS_CERT: '/tmp/server.crt',
    TLS_KEY: '/tmp/server.key'
  });

  assert.equal(policy.mode, 'https');
  assert.equal(policy.useNodeHTTPS, true);
  assert.equal(policy.mtls.required, false);

  const tlsOptions = buildNodeHTTPSServerTLSOptions(policy, (path) => Buffer.from(path));
  assert.equal(tlsOptions.requestCert, undefined);
  assert.equal(tlsOptions.rejectUnauthorized, undefined);
  assert.equal(tlsOptions.ca, undefined);
});

test('mTLS peer certificate gate rejects missing or unauthorised client certificates', () => {
  const policy = resolveNodeHTTPSTransportPolicy({
    TLS_CERT: '/tmp/server.crt',
    TLS_KEY: '/tmp/server.key',
    TLS_CA: '/tmp/client-ca.crt'
  });

  assert.deepEqual(
    resolvePeerCertificateForMTLS({ socket: { authorized: false } }, policy),
    { ok: false, error: 'mtls_client_certificate_required' }
  );
  assert.deepEqual(
    resolvePeerCertificateForMTLS({ socket: { authorized: true, getPeerCertificate: () => ({}) } }, policy),
    { ok: false, error: 'mtls_client_certificate_required' }
  );
  assert.deepEqual(
    resolvePeerCertificateForMTLS({
      socket: {
        authorized: true,
        getPeerCertificate: () => ({ subject: { CN: 'client' } })
      }
    }, policy),
    { ok: false, error: 'mtls_client_certificate_missing_fingerprint' }
  );
});

test('mTLS peer certificate gate returns bounded certificate metadata for authorised clients', () => {
  const policy = resolveNodeHTTPSTransportPolicy({
    TLS_CERT: '/tmp/server.crt',
    TLS_KEY: '/tmp/server.key',
    TLS_CA: '/tmp/client-ca.crt'
  });
  const result = resolvePeerCertificateForMTLS({
    socket: {
      authorized: true,
      getPeerCertificate: () => ({
        fingerprint256: 'AA:BB:CC',
        subject: { CN: 'client' },
        issuer: { CN: 'test-ca' },
        raw: Buffer.from('secret-cert-bytes')
      })
    }
  }, policy);

  assert.equal(result.ok, true);
  assert.deepEqual(result.certificate, {
    fingerprint256: 'AA:BB:CC',
    subject: { CN: 'client' },
    issuer: { CN: 'test-ca' }
  });
  assert.equal(Object.hasOwn(result.certificate, 'raw'), false);
});

test('trusted proxy mTLS gate rejects spoofed, duplicate, or unverified header evidence', () => {
  const policy = buildTrustedProxyMTLSPolicy();
  const parseCertificate = () => ({ fingerprint256: 'AA:BB:CC' });

  assert.deepEqual(
    resolvePeerCertificateForMTLS(
      trustedProxyMTLSRequest(policy, { remoteAddress: '203.0.113.10' }),
      policy,
      parseCertificate
    ),
    { ok: false, error: 'mtls_untrusted_proxy_header_source' }
  );
  assert.deepEqual(
    resolvePeerCertificateForMTLS(
      trustedProxyMTLSRequest(policy, {
        headers: { [policy.trustedProxyMTLS.verifyHeader]: 'FAILED:certificate has expired' }
      }),
      policy,
      parseCertificate
    ),
    { ok: false, error: 'mtls_client_certificate_unverified' }
  );
  assert.deepEqual(
    resolvePeerCertificateForMTLS(
      trustedProxyMTLSRequest(policy, {
        headers: { [policy.trustedProxyMTLS.verifyHeader]: ['SUCCESS', 'SUCCESS'] }
      }),
      policy,
      parseCertificate
    ),
    { ok: false, error: 'mtls_trusted_proxy_duplicate_header' }
  );
  assert.deepEqual(
    resolvePeerCertificateForMTLS(
      trustedProxyMTLSRequest(policy, {
        headers: { [policy.trustedProxyMTLS.certHeader]: 'escaped-cert,spoofed-cert' }
      }),
      policy,
      parseCertificate
    ),
    { ok: false, error: 'mtls_trusted_proxy_invalid_header' }
  );
});

test('trusted proxy mTLS gate returns bounded SHA-256 certificate metadata', () => {
  const policy = buildTrustedProxyMTLSPolicy();
  const result = resolvePeerCertificateForMTLS(
    trustedProxyMTLSRequest(policy),
    policy,
    (value) => {
      assert.equal(value, 'escaped-cert');
      return {
        fingerprint256: 'AA:BB:CC',
        subject: { CN: 'proxy-client' },
        issuer: { CN: 'proxy-ca' },
        raw: Buffer.from('secret-cert-bytes')
      };
    }
  );

  assert.equal(result.ok, true);
  assert.deepEqual(result.certificate, {
    fingerprint256: 'AA:BB:CC',
    subject: { CN: 'proxy-client' },
    issuer: { CN: 'proxy-ca' }
  });
  assert.equal(Object.hasOwn(result.certificate, 'raw'), false);
});

test('trusted proxy mTLS request helper rejects untrusted remote sources with a 403', () => {
  const policy = buildTrustedProxyMTLSPolicy();

  assert.throws(
    () => mtlsClientCertificateFingerprintForRequest(
      trustedProxyMTLSRequest(policy, { remoteAddress: '203.0.113.10' }),
      policy
    ),
    (error) => {
      assert.equal(error.code, 'mtls_untrusted_proxy_header_source');
      assert.equal(error.statusCode, 403);
      return true;
    }
  );
});

test('trusted proxy escaped client certificate parser fails closed on malformed input', () => {
  assert.equal(parseTrustedProxyClientCertificate(''), null);
  assert.equal(parseTrustedProxyClientCertificate('%E0%A4%A'), null);
  assert.equal(parseTrustedProxyClientCertificate(encodeURIComponent('not a certificate')), null);
});

test('mTLS request fingerprint helper is a no-op outside mTLS mode', () => {
  const policy = resolveNodeHTTPSTransportPolicy({});

  assert.equal(mtlsClientCertificateFingerprintForRequest({}, policy), null);
  assert.equal(mtlsBindingErrorForRecord({}, null, 'session_token', policy), null);
});

test('mTLS token binding accepts the same certificate fingerprint', () => {
  const policy = resolveNodeHTTPSTransportPolicy({
    TLS_CERT: '/tmp/server.crt',
    TLS_KEY: '/tmp/server.key',
    TLS_CA: '/tmp/client-ca.crt'
  });
  const record = { mtlsClientCertificateFingerprint256: 'AA:BB:CC' };
  const certificate = { fingerprint256: 'AA:BB:CC' };

  assert.equal(mtlsBindingErrorForRecord(record, certificate, 'session_token', policy), null);
});

test('mTLS token binding rejects missing binding evidence', () => {
  const policy = resolveNodeHTTPSTransportPolicy({
    TLS_CERT: '/tmp/server.crt',
    TLS_KEY: '/tmp/server.key',
    TLS_CA: '/tmp/client-ca.crt'
  });

  assert.equal(
    mtlsBindingErrorForRecord({}, { fingerprint256: 'AA:BB:CC' }, 'session_token', policy),
    'session_token_mtls_binding_missing'
  );
});

test('mTLS token binding rejects certificate fingerprint mismatch', () => {
  const policy = resolveNodeHTTPSTransportPolicy({
    TLS_CERT: '/tmp/server.crt',
    TLS_KEY: '/tmp/server.key',
    TLS_CA: '/tmp/client-ca.crt'
  });

  assert.equal(
    mtlsBindingErrorForRecord(
      { mtlsClientCertificateFingerprint256: 'AA:BB:CC' },
      { fingerprint256: 'DD:EE:FF' },
      'session_token',
      policy
    ),
    'session_token_mtls_certificate_mismatch'
  );
});

test('mTLS record assertion throws explicit HTTP status codes', () => {
  const policy = resolveNodeHTTPSTransportPolicy({
    TLS_CERT: '/tmp/server.crt',
    TLS_KEY: '/tmp/server.key',
    TLS_CA: '/tmp/client-ca.crt'
  });
  const req = {
    socket: {
      authorized: true,
      getPeerCertificate: () => ({ fingerprint256: 'DD:EE:FF' })
    }
  };

  assert.throws(
    () => assertMTLSBindingForRecord(
      req,
      { mtlsClientCertificateFingerprint256: 'AA:BB:CC' },
      'admission_token',
      policy
    ),
    (error) => {
      assert.equal(error.code, 'admission_token_mtls_certificate_mismatch');
      assert.equal(error.statusCode, 403);
      return true;
    }
  );
});
