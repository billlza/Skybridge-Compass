'use strict';

// Presence heartbeat metadata: validation, canonical fingerprinting and the
// server-observed public address policy.
//
// Everything here is pure so it can be unit tested without the HTTP runtime.
// The rules are deliberately strict (reject, never coerce): the values end up
// in the account device list of every device signed into the same account and
// are persisted into public.registered_devices.

const crypto = require('node:crypto');
const net = require('node:net');
const { stableCanonicalJSON } = require('./request_security');

const PRESENCE_PLATFORMS = Object.freeze(['macos', 'ios', 'ipados', 'android', 'windows', 'linux']);
const MAX_DEVICE_NAME_CODE_POINTS = 128;
const MAX_METADATA_BYTES = 64;
const MAX_LAN_ADDRESSES = 8;
const MAX_CAPABILITIES = 16;
const CAPABILITY_TOKEN_RE = /^[a-z0-9_]{1,32}$/;
// C0 / DEL / C1 controls plus the Unicode line/paragraph separators: none of
// them belong in a device name or version string and they are the classic
// log-injection vector.
// eslint-disable-next-line no-control-regex
const CONTROL_CHARACTER_RE = /[\u0000-\u001f\u007f-\u009f\u2028\u2029]/;

class PresenceReportError extends Error {
  constructor(code, field) {
    super(code);
    this.name = 'PresenceReportError';
    this.code = code;
    this.statusCode = 400;
    this.isPublicError = true;
    if (field) {
      this.publicDetails = { field };
    }
  }
}

function hasControlCharacters(value) {
  return CONTROL_CHARACTER_RE.test(value);
}

function normalizeDeviceName(raw) {
  if (raw === undefined || raw === null) return '';
  if (typeof raw !== 'string') {
    throw new PresenceReportError('invalid_presence_metadata', 'deviceName');
  }
  if (hasControlCharacters(raw)) {
    throw new PresenceReportError('invalid_presence_metadata', 'deviceName');
  }
  // Truncate by code point, never by UTF-16 unit: a lone surrogate is invalid
  // JSON for PostgreSQL and would make every later persist attempt fail.
  return Array.from(raw.trim()).slice(0, MAX_DEVICE_NAME_CODE_POINTS).join('');
}

function normalizeMetadataString(raw, field) {
  if (raw === undefined || raw === null) return null;
  if (typeof raw !== 'string') {
    throw new PresenceReportError('invalid_presence_metadata', field);
  }
  const value = raw.trim();
  if (!value) return null;
  if (hasControlCharacters(value) || Buffer.byteLength(value, 'utf8') > MAX_METADATA_BYTES) {
    throw new PresenceReportError('invalid_presence_metadata', field);
  }
  return value;
}

function normalizePlatform(raw) {
  if (raw === undefined || raw === null) return null;
  if (typeof raw !== 'string' || !PRESENCE_PLATFORMS.includes(raw)) {
    throw new PresenceReportError('invalid_presence_platform', 'platform');
  }
  return raw;
}

/**
 * Returns the canonical IP literal or `null` when the value is not an IP.
 * Accepts bracketed IPv6 and IPv4-mapped IPv6 (normalized to the IPv4 form);
 * rejects zone identifiers (`fe80::1%en0`) and anything with surrounding junk.
 */
function normalizeIPLiteral(raw) {
  if (typeof raw !== 'string') return null;
  let value = raw.trim();
  if (value.startsWith('[') && value.endsWith(']')) {
    value = value.slice(1, -1);
  }
  // Node's net.isIP accepts zone identifiers (fe80::1%en0); a scoped address is
  // meaningless outside the reporting host and is rejected here.
  if (value.includes('%')) return null;
  if (value.toLowerCase().startsWith('::ffff:')) {
    const mapped = value.slice('::ffff:'.length);
    if (net.isIPv4(mapped)) {
      value = mapped;
    }
  }
  const family = net.isIP(value);
  if (family === 0) return null;
  return family === 6 ? value.toLowerCase() : value;
}

function normalizeLanAddresses(raw) {
  if (raw === undefined || raw === null) return [];
  if (!Array.isArray(raw)) {
    throw new PresenceReportError('invalid_presence_metadata', 'lanAddresses');
  }
  if (raw.length > MAX_LAN_ADDRESSES) {
    throw new PresenceReportError('invalid_presence_lan_address', 'lanAddresses');
  }
  // Reporter order is meaningful: clients list their preferred interface first and the
  // account list shows the first address. Deduplicate, never re-sort.
  const normalized = [];
  for (const entry of raw) {
    const literal = normalizeIPLiteral(entry);
    if (!literal) {
      throw new PresenceReportError('invalid_presence_lan_address', 'lanAddresses');
    }
    if (!normalized.includes(literal)) {
      normalized.push(literal);
    }
  }
  return normalized;
}

/**
 * The app version persisted with a heartbeat comes from the authenticated request context
 * (clientVersion header/body), which version gating only parses leniently. Persisting it
 * must respect the same bounds as every other metadata string, otherwise a junk version
 * turns every registry write for that device into a spurious registry_unavailable.
 */
function normalizeAppVersion(raw) {
  const value = normalizeMetadataString(raw, 'appVersion');
  if (!value) {
    throw new PresenceReportError('invalid_presence_metadata', 'appVersion');
  }
  return value;
}

function normalizeCapabilities(raw) {
  if (raw === undefined || raw === null) return [];
  if (!Array.isArray(raw)) {
    throw new PresenceReportError('invalid_presence_metadata', 'capabilities');
  }
  if (raw.length > MAX_CAPABILITIES) {
    throw new PresenceReportError('invalid_presence_capability', 'capabilities');
  }
  const normalized = new Set();
  for (const entry of raw) {
    if (typeof entry !== 'string' || !CAPABILITY_TOKEN_RE.test(entry)) {
      throw new PresenceReportError('invalid_presence_capability', 'capabilities');
    }
    normalized.add(entry);
  }
  return [...normalized].sort();
}

/**
 * Validates the optional metadata of a presence heartbeat body.
 * Every field is optional so clients that only send `deviceName` keep working.
 */
function normalizePresenceReport(body) {
  const source = body && typeof body === 'object' && !Array.isArray(body) ? body : {};
  return {
    deviceName: normalizeDeviceName(source.deviceName),
    platform: normalizePlatform(source.platform),
    deviceModel: normalizeMetadataString(source.deviceModel, 'deviceModel'),
    osVersion: normalizeMetadataString(source.osVersion, 'osVersion'),
    lanAddresses: normalizeLanAddresses(source.lanAddresses),
    capabilities: normalizeCapabilities(source.capabilities)
  };
}

/**
 * Fingerprint of the metadata that is persisted, used to skip the registry
 * write when nothing changed. LAN address order is part of the payload (the
 * first address is the reporter's preferred interface); capabilities are a
 * set and arrive sorted from normalizePresenceReport. `appVersion` is included
 * by the caller because it comes from the authenticated context, not the body.
 */
function presenceMetadataFingerprint(report, { appVersion = null, publicAddress = null } = {}) {
  const canonical = stableCanonicalJSON({
    deviceName: report.deviceName || '',
    platform: report.platform || null,
    deviceModel: report.deviceModel || null,
    osVersion: report.osVersion || null,
    appVersion: appVersion || null,
    lanAddresses: [...report.lanAddresses],
    capabilities: [...report.capabilities].sort(),
    publicAddress: publicAddress || null
  });
  return crypto.createHash('sha256').update(canonical).digest('hex');
}

function ipv4Octets(value) {
  const octets = value.split('.').map((part) => Number(part));
  return octets.length === 4 && octets.every((octet) => Number.isInteger(octet) && octet >= 0 && octet <= 255)
    ? octets
    : null;
}

function isGlobalUnicastIPv4(value) {
  const octets = ipv4Octets(value);
  if (!octets) return false;
  const [a, b] = octets;
  if (a === 0 || a === 10 || a === 127) return false;
  if (a === 100 && b >= 64 && b <= 127) return false; // CGNAT 100.64/10
  if (a === 169 && b === 254) return false;
  if (a === 172 && b >= 16 && b <= 31) return false;
  if (a === 192 && b === 0 && octets[2] === 0) return false;
  if (a === 192 && b === 168) return false;
  if (a === 198 && (b === 18 || b === 19)) return false;
  if (a >= 224) return false; // multicast + reserved + broadcast
  return true;
}

function isGlobalUnicastIPv6(value) {
  const lower = value.toLowerCase();
  if (lower === '::' || lower === '::1') return false;
  const firstGroup = lower.split(':')[0];
  if (firstGroup.length === 0) return false;
  const padded = firstGroup.padStart(4, '0');
  const leading = parseInt(padded.slice(0, 2), 16);
  if (Number.isNaN(leading)) return false;
  if (leading === 0xff) return false; // multicast
  if (leading === 0xfe && /^fe[89ab]/.test(padded)) return false; // link-local fe80::/10
  if (leading === 0xfc || leading === 0xfd) return false; // ULA fc00::/7
  return true;
}

/**
 * The public address the signaling server will record for a heartbeat.
 * Returns `null` unless the observed client address is a global unicast IP,
 * so a misconfigured proxy never stores loopback / RFC1918 as "public".
 */
function publicAddressForPresence(observedClientIP) {
  const literal = normalizeIPLiteral(observedClientIP);
  if (!literal) return null;
  if (net.isIPv4(literal)) {
    return isGlobalUnicastIPv4(literal) ? literal : null;
  }
  return isGlobalUnicastIPv6(literal) ? literal : null;
}

module.exports = {
  PRESENCE_PLATFORMS,
  MAX_DEVICE_NAME_CODE_POINTS,
  MAX_METADATA_BYTES,
  MAX_LAN_ADDRESSES,
  MAX_CAPABILITIES,
  PresenceReportError,
  normalizeAppVersion,
  normalizeIPLiteral,
  normalizePresenceReport,
  presenceMetadataFingerprint,
  publicAddressForPresence
};
