'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const {
  AliyunSMSClient,
  normalizeMainlandChinaPhone
} = require('../lib/aliyun_sms');

test('normalizeMainlandChinaPhone accepts local and +86 formats', () => {
  assert.equal(normalizeMainlandChinaPhone('13800138000'), '13800138000');
  assert.equal(normalizeMainlandChinaPhone('+8613800138000'), '13800138000');
  assert.equal(normalizeMainlandChinaPhone('8613800138000'), '13800138000');
  assert.equal(normalizeMainlandChinaPhone('+1 650 555 0100'), null);
});

test('AliyunSMSClient builds signed POST request with mainland phone payload', async () => {
  let captured = null;
  const client = new AliyunSMSClient({
    provider: 'dysms',
    accessKeyId: 'test-ak',
    accessKeySecret: 'test-sk',
    signName: 'SkyBridge',
    templateCode: 'SMS_TEST_001',
    fetchImpl: async (url, request) => {
      captured = { url, request };
      return {
        ok: true,
        status: 200,
        async text() {
          return JSON.stringify({
            Code: 'OK',
            RequestId: 'req-1',
            BizId: 'biz-1'
          });
        }
      };
    }
  });

  const result = await client.sendVerificationCode({
    phoneNumber: '+8613800138000',
    otp: '123456'
  });

  assert.equal(result.success, true);
  assert.equal(captured.url, 'https://dysmsapi.aliyuncs.com/');
  assert.equal(captured.request.method, 'POST');
  assert.match(captured.request.headers.Authorization, /^ACS3-HMAC-SHA256 Credential=test-ak,/);
  assert.equal(captured.request.headers['x-acs-action'], 'SendSms');
  const payload = JSON.parse(captured.request.body);
  assert.equal(payload.PhoneNumbers, '13800138000');
  assert.equal(payload.SignName, 'SkyBridge');
  assert.equal(payload.TemplateCode, 'SMS_TEST_001');
  assert.deepEqual(JSON.parse(payload.TemplateParam), { code: '123456' });
});

test('AliyunSMSClient derives min template param for PNVS standard verification template', async () => {
  let capturedRequest = null;
  const client = new AliyunSMSClient({
    provider: 'pnvs',
    accessKeyId: 'test-ak',
    accessKeySecret: 'test-sk',
    signName: '速通互联验证码',
    templateCode: '100001',
    endpoint: 'dypnsapi.aliyuncs.com',
    regionId: 'ap-southeast-1',
    otpExpirySeconds: 60,
    pnvsClient: {
      async sendSmsVerifyCode(request) {
        capturedRequest = request;
        return {
          body: {
            code: 'OK',
            success: true,
            requestId: 'req-2',
            model: {
              bizId: 'biz-2'
            }
          }
        };
      }
    }
  });

  const result = await client.sendVerificationCode({
    phoneNumber: '13800138000',
    otp: '654321'
  });

  assert.equal(result.success, true);
  assert.equal(result.bizId, 'biz-2');
  assert.equal(capturedRequest.phoneNumber, '13800138000');
  assert.equal(capturedRequest.countryCode, '86');
  assert.equal(capturedRequest.signName, '速通互联验证码');
  assert.equal(capturedRequest.templateCode, '100001');
  assert.deepEqual(JSON.parse(capturedRequest.templateParam), { code: '654321', min: '1' });
});

test('AliyunSMSClient allows explicit template params to override derived PNVS values', async () => {
  let capturedRequest = null;
  const client = new AliyunSMSClient({
    provider: 'pnvs',
    accessKeyId: 'test-ak',
    accessKeySecret: 'test-sk',
    signName: '速通互联验证码',
    templateCode: '100001',
    endpoint: 'dypnsapi.aliyuncs.com',
    regionId: 'ap-southeast-1',
    otpExpirySeconds: 60,
    templateParams: { min: '3', scene: 'login' },
    pnvsClient: {
      async sendSmsVerifyCode(request) {
        capturedRequest = request;
        return {
          body: {
            code: 'OK',
            success: true
          }
        };
      }
    }
  });

  await client.sendVerificationCode({
    phoneNumber: '13800138000',
    otp: '654321'
  });

  assert.deepEqual(JSON.parse(capturedRequest.templateParam), { code: '654321', min: '3', scene: 'login' });
});

test('AliyunSMSClient rejects unsupported providers during configuration validation', () => {
  const client = new AliyunSMSClient({
    provider: 'mystery',
    accessKeyId: 'test-ak',
    accessKeySecret: 'test-sk'
  });

  assert.equal(client.providerSupported, false);
  assert.deepEqual(client.missingConfiguration, ['provider']);
  assert.equal(client.configured, false);
  assert.throws(() => client.assertConfigured(), /aliyun_sms_provider_unsupported/);
});

test('AliyunSMSClient reports missing configuration for pnvs startup validation', () => {
  const client = new AliyunSMSClient({
    provider: 'pnvs',
    accessKeyId: 'test-ak',
    signName: '速通互联验证码',
    templateCode: '100001',
    endpoint: 'dypnsapi.aliyuncs.com',
    regionId: 'ap-southeast-1'
  });

  assert.equal(client.providerSupported, true);
  assert.equal(client.configured, false);
  assert.deepEqual(
    client.missingConfiguration,
    ['accessKeySecret', 'templateParam.min', 'pnvsClient']
  );
});

test('AliyunSMSClient reports missing min parameter for PNVS standard verification template', () => {
  const client = new AliyunSMSClient({
    provider: 'pnvs',
    accessKeyId: 'test-ak',
    accessKeySecret: 'test-sk',
    signName: '速通互联验证码',
    templateCode: '100001',
    endpoint: 'dypnsapi.aliyuncs.com',
    regionId: 'ap-southeast-1',
    pnvsClient: {}
  });

  assert.equal(client.configured, false);
  assert.deepEqual(client.missingConfiguration, ['templateParam.min']);
});

test('AliyunSMSClient accepts PNVS template params from JSON configuration', async () => {
  let capturedRequest = null;
  const client = new AliyunSMSClient({
    provider: 'pnvs',
    accessKeyId: 'test-ak',
    accessKeySecret: 'test-sk',
    signName: '速通互联验证码',
    templateCode: '100001',
    endpoint: 'dypnsapi.aliyuncs.com',
    regionId: 'ap-southeast-1',
    templateParams: '{"min":"2","scene":"signup"}',
    pnvsClient: {
      async sendSmsVerifyCode(request) {
        capturedRequest = request;
        return {
          body: {
            code: 'OK',
            success: true
          }
        };
      }
    }
  });

  await client.sendVerificationCode({
    phoneNumber: '13800138000',
    otp: '654321'
  });

  assert.deepEqual(JSON.parse(capturedRequest.templateParam), { code: '654321', min: '2', scene: 'signup' });
});

test('AliyunSMSClient flags invalid template params JSON during startup validation', () => {
  const client = new AliyunSMSClient({
    provider: 'pnvs',
    accessKeyId: 'test-ak',
    accessKeySecret: 'test-sk',
    signName: '速通互联验证码',
    templateCode: '100001',
    endpoint: 'dypnsapi.aliyuncs.com',
    regionId: 'ap-southeast-1',
    templateParams: '{not-json}',
    pnvsClient: {}
  });

  assert.equal(client.configured, false);
  assert.deepEqual(client.missingConfiguration, ['templateParams', 'templateParam.min']);
});

test('AliyunSMSClient rejects unsupported phone numbers before hitting provider APIs', async () => {
  const client = new AliyunSMSClient({
    provider: 'pnvs',
    accessKeyId: 'test-ak',
    accessKeySecret: 'test-sk',
    signName: '速通互联验证码',
    templateCode: '100001',
    endpoint: 'dypnsapi.aliyuncs.com',
    regionId: 'ap-southeast-1',
    otpExpirySeconds: 60,
    pnvsClient: {
      async sendSmsVerifyCode() {
        throw new Error('provider_should_not_be_called');
      }
    }
  });

  await assert.rejects(
    () => client.sendVerificationCode({ phoneNumber: '+1 650 555 0100', otp: '123456' }),
    /unsupported_phone_number/
  );
});

test('AliyunSMSClient surfaces PNVS provider rejection details', async () => {
  const client = new AliyunSMSClient({
    provider: 'pnvs',
    accessKeyId: 'test-ak',
    accessKeySecret: 'test-sk',
    signName: '速通互联验证码',
    templateCode: '100001',
    endpoint: 'dypnsapi.aliyuncs.com',
    regionId: 'ap-southeast-1',
    otpExpirySeconds: 60,
    pnvsClient: {
      async sendSmsVerifyCode() {
        return {
          body: {
            success: false,
            code: 'isv.TEMPLATE_ILLEGAL',
            message: 'template rejected'
          }
        };
      }
    }
  });

  await assert.rejects(
    () => client.sendVerificationCode({ phoneNumber: '13800138000', otp: '123456' }),
    /aliyun_pnvs_failed:template rejected/
  );
});

test('AliyunSMSClient surfaces dysms transport failures', async () => {
  const client = new AliyunSMSClient({
    provider: 'dysms',
    accessKeyId: 'test-ak',
    accessKeySecret: 'test-sk',
    signName: 'SkyBridge',
    templateCode: 'SMS_TEST_001',
    fetchImpl: async () => ({
      ok: false,
      status: 503,
      async text() {
        return 'upstream unavailable';
      }
    })
  });

  await assert.rejects(
    () => client.sendVerificationCode({ phoneNumber: '13800138000', otp: '123456' }),
    /aliyun_sms_http_503/
  );
});
