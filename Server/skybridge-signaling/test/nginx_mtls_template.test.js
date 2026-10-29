'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.resolve(__dirname, '..');
const NGINX_TEMPLATES = [
  'deploy/nginx/skybridge-signaling.conf',
  'deploy/nginx/skybridge-signaling-multi-instance-sticky.conf'
];

function readProjectFile(relativePath) {
  return fs.readFileSync(path.join(ROOT, relativePath), 'utf8');
}

function webSocketLocationBlock(content) {
  const match = content.match(/location\s+(?:=\s*)?\/ws\s*\{[\s\S]*?\n    \}/);
  assert.ok(match, 'template must declare a /ws location');
  return match[0];
}

function assertTrustedProxyMTLSHeaders(config) {
  assert.match(
    config,
    /proxy_set_header X-SkyBridge-MTLS-Client-Verify \$ssl_client_verify;/
  );
  assert.match(
    config,
    /proxy_set_header X-SkyBridge-MTLS-Client-Cert-PEM \$ssl_client_escaped_cert;/
  );
  assert.doesNotMatch(config, /\$ssl_client_fingerprint/);
}

test('Nginx templates document and pass verified client mTLS evidence to Node', () => {
  for (const template of NGINX_TEMPLATES) {
    const config = readProjectFile(template);

    assert.match(config, /skybridge-client-mtls\.conf/);
    assertTrustedProxyMTLSHeaders(config);
    assertTrustedProxyMTLSHeaders(webSocketLocationBlock(config));
  }
});

test('Nginx templates do not forward spoofable proxy identity headers', () => {
  for (const template of NGINX_TEMPLATES) {
    const config = readProjectFile(template);
    const wsBlock = webSocketLocationBlock(config);

    assert.doesNotMatch(config, /proxy_add_x_forwarded_for/);
    assert.match(config, /proxy_set_header X-Forwarded-For \$remote_addr;/);
    assert.match(config, /proxy_set_header CF-Connecting-IP "";/);
    assert.match(wsBlock, /proxy_set_header X-Forwarded-For \$remote_addr;/);
    assert.match(wsBlock, /proxy_set_header CF-Connecting-IP "";/);
  }
});

test('Nginx client mTLS snippet fails closed and requires a client CA', () => {
  const snippet = readProjectFile('deploy/nginx/snippets/skybridge-client-mtls.conf');

  assert.match(snippet, /ssl_client_certificate \/etc\/skybridge-signaling\/client-ca\.pem;/);
  assert.match(snippet, /ssl_verify_client on;/);
  assert.match(snippet, /ssl_verify_depth 2;/);
  assert.doesNotMatch(snippet, /ssl_verify_client\s+optional/);
  assert.doesNotMatch(snippet, /optional_no_ca/);
});

test('production env template keeps direct Node mTLS and trusted proxy mTLS separate', () => {
  const envTemplate = readProjectFile('production.env.example');

  assert.match(envTemplate, /TLS_CA=/);
  assert.match(envTemplate, /SKYBRIDGE_SIGNALING_REQUIRE_MTLS=false/);
  assert.match(envTemplate, /SKYBRIDGE_SIGNALING_MTLS_CLIENT_CERT_SOURCE=/);
  assert.match(envTemplate, /SKYBRIDGE_SIGNALING_TRUSTED_PROXY_MTLS_REMOTE_ADDRESSES=127\.0\.0\.1,::1/);
  assert.match(envTemplate, /Keep TLS_CA empty here/);
});
