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

test('AliyunSMSClient uses PNVS provider for personal developer SMS auth flow', async () => {
  let capturedRequest = null;
  const client = new AliyunSMSClient({
    provider: 'pnvs',
    accessKeyId: 'test-ak',
    accessKeySecret: 'test-sk',
    signName: '速通互联验证码',
    templateCode: '100001',
    endpoint: 'dypnsapi.aliyuncs.com',
    regionId: 'ap-southeast-1',
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
  assert.deepEqual(JSON.parse(capturedRequest.templateParam), { code: '654321' });
});
