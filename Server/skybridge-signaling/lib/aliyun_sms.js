'use strict';

const crypto = require('crypto');
const OpenApi = require('@alicloud/openapi-client');
const DypnsapiModule = require('@alicloud/dypnsapi20170525/dist/client.js');

const DEFAULT_PROVIDER = 'pnvs';
const DEFAULT_ENDPOINT = 'dysmsapi.aliyuncs.com';
const DEFAULT_PNVS_ENDPOINT = 'dypnsapi.aliyuncs.com';
const DEFAULT_PNVS_REGION_ID = 'ap-southeast-1';
const DEFAULT_PNVS_SIGN_NAME = '速通互联验证码';
const DEFAULT_PNVS_TEMPLATE_CODE = '100001';
const DEFAULT_VERSION = '2017-05-25';
const DEFAULT_ACTION = 'SendSms';
const DEFAULT_SIGNATURE_ALGORITHM = 'ACS3-HMAC-SHA256';
const SUPPORTED_PROVIDERS = new Set(['pnvs', 'dysms']);
const SIGNED_HEADERS = [
  'content-type',
  'host',
  'x-acs-action',
  'x-acs-content-sha256',
  'x-acs-date',
  'x-acs-signature-nonce',
  'x-acs-version'
];

function sha256Hex(value) {
  return crypto.createHash('sha256').update(value).digest('hex');
}

function hmacSha256Hex(secret, payload) {
  return crypto.createHmac('sha256', secret).update(payload).digest('hex');
}

function normalizeMainlandChinaPhone(raw) {
  const trimmed = String(raw || '').trim();
  if (!trimmed) return null;
  const digits = trimmed.replace(/[^\d+]/g, '');
  if (/^1[3-9]\d{9}$/.test(digits)) {
    return digits;
  }
  if (/^\+861[3-9]\d{9}$/.test(digits)) {
    return digits.slice(3);
  }
  if (/^861[3-9]\d{9}$/.test(digits)) {
    return digits.slice(2);
  }
  return null;
}

function requiredString(raw) {
  const value = String(raw || '').trim();
  return value || null;
}

function parsePositiveInteger(raw) {
  if (raw === null || raw === undefined || raw === '') {
    return null;
  }
  const value = Number.parseInt(String(raw).trim(), 10);
  return Number.isFinite(value) && value > 0 ? value : null;
}

function sanitizeTemplateParams(raw) {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) {
    return {};
  }
  const sanitized = {};
  for (const [key, value] of Object.entries(raw)) {
    const normalizedKey = String(key || '').trim();
    if (!normalizedKey || value === null || value === undefined) {
      continue;
    }
    const normalizedValue = String(value).trim();
    if (!normalizedValue) {
      continue;
    }
    sanitized[normalizedKey] = normalizedValue;
  }
  return sanitized;
}

function parseTemplateParams(raw) {
  if (raw === null || raw === undefined || raw === '') {
    return { value: {}, error: null };
  }
  if (typeof raw === 'object' && !Array.isArray(raw)) {
    return { value: sanitizeTemplateParams(raw), error: null };
  }
  try {
    const parsed = JSON.parse(String(raw));
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
      return { value: {}, error: 'template_params_must_be_json_object' };
    }
    return { value: sanitizeTemplateParams(parsed), error: null };
  } catch (_) {
    return { value: {}, error: 'template_params_invalid_json' };
  }
}

function createPnvsClient({ accessKeyId, accessKeySecret, endpoint, regionId }) {
  const config = new OpenApi.Config({
    accessKeyId,
    accessKeySecret,
    endpoint,
    regionId,
    protocol: 'HTTPS'
  });
  return new DypnsapiModule.default(config);
}

class AliyunSMSClient {
  constructor(options = {}) {
    this.provider = String(
      options.provider
      || process.env.ALIYUN_SMS_PROVIDER
      || DEFAULT_PROVIDER
    ).trim().toLowerCase();
    this.accessKeyId = requiredString(
      options.accessKeyId
      || process.env.ALICLOUD_ACCESS_KEY_ID
      || process.env.ALIBABA_CLOUD_ACCESS_KEY_ID
      || process.env.ALIYUN_ACCESS_KEY_ID
    );
    this.accessKeySecret = requiredString(
      options.accessKeySecret
      || process.env.ALICLOUD_ACCESS_KEY_SECRET
      || process.env.ALIBABA_CLOUD_ACCESS_KEY_SECRET
      || process.env.ALIYUN_ACCESS_KEY_SECRET
    );
    this.signName = requiredString(
      options.signName
      || process.env.ALIYUN_PNVS_SIGN_NAME
      || process.env.ALIYUN_SMS_SIGN_NAME
      || (this.provider === 'pnvs' ? DEFAULT_PNVS_SIGN_NAME : '')
    );
    this.templateCode = requiredString(
      options.templateCode
      || process.env.ALIYUN_PNVS_TEMPLATE_CODE
      || process.env.ALIYUN_SMS_TEMPLATE_CODE
      || (this.provider === 'pnvs' ? DEFAULT_PNVS_TEMPLATE_CODE : '')
    );
    this.endpoint = requiredString(
      options.endpoint
      || process.env.ALIYUN_PNVS_ENDPOINT
      || process.env.ALIYUN_SMS_ENDPOINT
    ) || (this.provider === 'pnvs' ? DEFAULT_PNVS_ENDPOINT : DEFAULT_ENDPOINT);
    this.regionId = requiredString(
      options.regionId
      || process.env.ALIYUN_PNVS_REGION_ID
      || process.env.ALIYUN_REGION_ID
      || (this.provider === 'pnvs' ? DEFAULT_PNVS_REGION_ID : '')
    );
    this.otpExpirySeconds = parsePositiveInteger(
      options.otpExpirySeconds
      || process.env.SUPABASE_SMS_OTP_EXP_SECONDS
      || process.env.ALIYUN_SMS_OTP_EXP_SECONDS
    );
    const templateParamsSource = options.templateParams ?? process.env.ALIYUN_SMS_TEMPLATE_PARAMS_JSON;
    const parsedTemplateParams = parseTemplateParams(templateParamsSource);
    this.templateParams = parsedTemplateParams.value;
    this.templateParamsError = parsedTemplateParams.error;
    this.version = requiredString(options.version || process.env.ALIYUN_SMS_API_VERSION) || DEFAULT_VERSION;
    this.fetchImpl = options.fetchImpl || global.fetch;
    this.pnvsClient = options.pnvsClient || (
      this.provider === 'pnvs'
      && this.accessKeyId
      && this.accessKeySecret
      && this.endpoint
      && this.regionId
        ? createPnvsClient({
          accessKeyId: this.accessKeyId,
          accessKeySecret: this.accessKeySecret,
          endpoint: this.endpoint,
          regionId: this.regionId
        })
        : null
    );
  }

  get configured() {
    if (!this.providerSupported) {
      return false;
    }
    return this.missingConfiguration.length === 0;
  }

  get providerSupported() {
    return SUPPORTED_PROVIDERS.has(this.provider);
  }

  get usesDefaultPNVSVerificationTemplate() {
    return this.provider === 'pnvs' && this.templateCode === DEFAULT_PNVS_TEMPLATE_CODE;
  }

  get derivedTemplateMin() {
    if (!Number.isFinite(this.otpExpirySeconds) || this.otpExpirySeconds <= 0) {
      return null;
    }
    return Math.max(1, Math.ceil(this.otpExpirySeconds / 60));
  }

  get configuredTemplateMin() {
    return parsePositiveInteger(this.templateParams.min);
  }

  hasRequiredTemplateMin() {
    return Number.isFinite(this.configuredTemplateMin) || Number.isFinite(this.derivedTemplateMin);
  }

  buildTemplateParams({ otp }) {
    const params = {
      ...this.templateParams,
      code: String(otp || '').trim()
    };
    if (this.usesDefaultPNVSVerificationTemplate) {
      const minValue = this.configuredTemplateMin || this.derivedTemplateMin;
      if (Number.isFinite(minValue)) {
        params.min = String(minValue);
      }
    }
    return params;
  }

  get missingConfiguration() {
    const missing = [];
    if (!this.providerSupported) {
      missing.push('provider');
      return missing;
    }
    if (this.templateParamsError) {
      missing.push('templateParams');
    }
    if (this.provider === 'pnvs') {
      if (!this.accessKeyId) missing.push('accessKeyId');
      if (!this.accessKeySecret) missing.push('accessKeySecret');
      if (!this.signName) missing.push('signName');
      if (!this.templateCode) missing.push('templateCode');
      if (!this.endpoint) missing.push('endpoint');
      if (!this.regionId) missing.push('regionId');
      if (this.usesDefaultPNVSVerificationTemplate && !this.hasRequiredTemplateMin()) {
        missing.push('templateParam.min');
      }
      if (!this.pnvsClient) missing.push('pnvsClient');
      return missing;
    }
    if (!this.accessKeyId) missing.push('accessKeyId');
    if (!this.accessKeySecret) missing.push('accessKeySecret');
    if (!this.signName) missing.push('signName');
    if (!this.templateCode) missing.push('templateCode');
    if (!this.endpoint) missing.push('endpoint');
    if (typeof this.fetchImpl !== 'function') missing.push('fetchImpl');
    return missing;
  }

  get configurationStatus() {
    const missingConfiguration = this.missingConfiguration;
    return {
      provider: this.provider,
      providerSupported: this.providerSupported,
      configured: this.providerSupported && missingConfiguration.length === 0,
      missingConfiguration
    };
  }

  assertConfigured() {
    if (this.configured) return;
    const error = new Error(this.providerSupported ? 'aliyun_sms_not_configured' : 'aliyun_sms_provider_unsupported');
    error.configurationStatus = this.configurationStatus;
    throw error;
  }

  async sendVerificationCode({ phoneNumber, otp }) {
    this.assertConfigured();

    if (this.provider === 'pnvs') {
      return this.sendViaPNVS({ phoneNumber, otp });
    }

    return this.sendViaDysms({ phoneNumber, otp });
  }

  async sendViaPNVS({ phoneNumber, otp }) {
    const normalizedPhone = normalizeMainlandChinaPhone(phoneNumber);
    if (!normalizedPhone) {
      throw new Error('unsupported_phone_number');
    }

    const code = String(otp || '').trim();
    if (!/^\d{4,8}$/.test(code)) {
      throw new Error('invalid_otp_code');
    }

    const request = new DypnsapiModule.SendSmsVerifyCodeRequest({
      phoneNumber: normalizedPhone,
      countryCode: '86',
      signName: this.signName,
      templateCode: this.templateCode,
      templateParam: JSON.stringify(this.buildTemplateParams({ otp: code })),
      outId: 'skybridge_supabase_hook'
    });
    const response = await this.pnvsClient.sendSmsVerifyCode(request);
    const body = response?.body || {};
    if (!body.success || String(body.code || '').toUpperCase() !== 'OK') {
      const detail = body.message || body.code || 'pnvs_send_failed';
      const error = new Error(`aliyun_pnvs_failed:${detail}`);
      error.response = body;
      throw error;
    }

    return {
      success: true,
      requestId: body.requestId || body.model?.requestId || null,
      bizId: body.model?.bizId || null,
      code: body.code || 'OK'
    };
  }

  async sendViaDysms({ phoneNumber, otp }) {
    const normalizedPhone = normalizeMainlandChinaPhone(phoneNumber);
    if (!normalizedPhone) {
      throw new Error('unsupported_phone_number');
    }

    const code = String(otp || '').trim();
    if (!/^\d{4,8}$/.test(code)) {
      throw new Error('invalid_otp_code');
    }

    const requestBody = JSON.stringify({
      PhoneNumbers: normalizedPhone,
      SignName: this.signName,
      TemplateCode: this.templateCode,
      TemplateParam: JSON.stringify(this.buildTemplateParams({ otp: code }))
    });

    const bodyHash = sha256Hex(requestBody);
    const acsDate = new Date().toISOString().replace(/\.\d{3}Z$/, 'Z');
    const nonce = crypto.randomUUID();
    const headers = {
      'content-type': 'application/json; charset=utf-8',
      host: this.endpoint,
      'x-acs-action': DEFAULT_ACTION,
      'x-acs-content-sha256': bodyHash,
      'x-acs-date': acsDate,
      'x-acs-signature-nonce': nonce,
      'x-acs-version': this.version
    };

    const canonicalHeaders = SIGNED_HEADERS
      .map((headerName) => `${headerName}:${headers[headerName]}`)
      .join('\n');
    const canonicalRequest = [
      'POST',
      '/',
      '',
      canonicalHeaders,
      '',
      SIGNED_HEADERS.join(';'),
      bodyHash
    ].join('\n');
    const stringToSign = `${DEFAULT_SIGNATURE_ALGORITHM}\n${sha256Hex(canonicalRequest)}`;
    const authorization = `${DEFAULT_SIGNATURE_ALGORITHM} Credential=${this.accessKeyId},SignedHeaders=${SIGNED_HEADERS.join(';')},Signature=${hmacSha256Hex(this.accessKeySecret, stringToSign)}`;

    const response = await this.fetchImpl(`https://${this.endpoint}/`, {
      method: 'POST',
      headers: {
        Authorization: authorization,
        Accept: 'application/json',
        'Content-Type': headers['content-type'],
        Host: headers.host,
        'x-acs-action': headers['x-acs-action'],
        'x-acs-content-sha256': headers['x-acs-content-sha256'],
        'x-acs-date': headers['x-acs-date'],
        'x-acs-signature-nonce': headers['x-acs-signature-nonce'],
        'x-acs-version': headers['x-acs-version']
      },
      body: requestBody
    });

    const rawText = await response.text();
    let parsed = null;
    try {
      parsed = rawText ? JSON.parse(rawText) : null;
    } catch (_) {
      parsed = null;
    }

    if (!response.ok) {
      const detail = parsed?.Message || parsed?.message || rawText || `http_${response.status}`;
      const error = new Error(`aliyun_sms_http_${response.status}:${detail}`);
      error.statusCode = response.status;
      error.responseText = rawText;
      throw error;
    }

    if (!parsed || parsed.Code !== 'OK') {
      const detail = parsed?.Message || rawText || 'aliyun_sms_failed';
      const error = new Error(`aliyun_sms_failed:${detail}`);
      error.response = parsed;
      throw error;
    }

    return {
      success: true,
      requestId: parsed.RequestId || null,
      bizId: parsed.BizId || null,
      code: parsed.Code
    };
  }
}

module.exports = {
  AliyunSMSClient,
  normalizeMainlandChinaPhone
};
