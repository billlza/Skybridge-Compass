const DEFAULT_ALLOWED_ORIGINS = [
  'http://localhost:3000',
  'http://127.0.0.1:3000',
  'http://localhost:4173',
  'http://127.0.0.1:4173',
  'https://skybridge-compass.vercel.app',
  'https://nebula-technologies.net',
  'https://www.nebula-technologies.net',
  'https://skybridge.com',
  'https://www.skybridge.com',
];

function allowedOrigins() {
  return (Deno.env.get('CORS_ORIGINS') ?? DEFAULT_ALLOWED_ORIGINS.join(','))
    .split(',')
    .map(origin => origin.trim())
    .filter(Boolean);
}

export function getCorsHeaders(req: Request) {
  const origins = allowedOrigins();
  const requestOrigin = req.headers.get('origin');
  const allowOrigin =
    requestOrigin && origins.includes(requestOrigin) ? requestOrigin : origins[0];

  return {
    'Access-Control-Allow-Origin': allowOrigin,
    'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
    'Access-Control-Allow-Methods': 'POST, GET, OPTIONS, PUT, DELETE, PATCH',
    'Access-Control-Max-Age': '86400',
    'Access-Control-Allow-Credentials': 'false',
    'Vary': 'Origin',
  };
}

export function maskContact(contactType: string, contactValue: string) {
  if (contactType === 'email') {
    return contactValue.replace(/(.{2}).*(@.*)/, '$1***$2');
  }

  if (contactType === 'phone') {
    return contactValue.replace(/(\d{3})\d{4}(\d{4})/, '$1****$2');
  }

  return contactValue;
}

export function generateNebulaId() {
  const bytes = crypto.getRandomValues(new Uint8Array(8));
  let rawId = 0n;

  for (const byte of bytes) {
    rawId = (rawId << 8n) | BigInt(byte);
  }

  const year = new Date().getUTCFullYear();
  const suffix = rawId.toString(36).toUpperCase().padStart(12, '0').slice(-12);

  return `NEBULA-${year}-${suffix}`;
}
