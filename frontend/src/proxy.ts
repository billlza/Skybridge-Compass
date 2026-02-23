import { NextResponse } from 'next/server';
import type { NextRequest } from 'next/server';

// 简单的内存限流器 (生产环境建议使用 Redis)
const rateLimitMap = new Map<string, { count: number; timestamp: number }>();

const RATE_LIMIT_WINDOW = 60 * 1000; // 1分钟窗口
const MAX_REQUESTS = 100; // 每窗口最大请求数
const MAX_BODY_SIZE = 1024 * 1024; // 1MB
const MAX_TRACKED_IPS = 10_000; // 防止 Map 无限制增长导致内存 DoS

// 可疑请求模式检测
const SUSPICIOUS_PATTERNS = [
  /\$\{.*\}/,           // 模板注入
  /<script/i,           // XSS
  /javascript:/i,       // JS 协议
  /data:text\/html/i,   // Data URI XSS
];

function isTrustedProxyHeaders(): boolean {
  const v = process.env.SKYBRIDGE_TRUST_PROXY_HEADERS;
  if (v === undefined) return process.env.NODE_ENV === 'production';
  return v === '1' || v === 'true';
}

function normalizeIp(ip: string | null): string | undefined {
  if (!ip) return;
  const trimmed = ip.trim();
  if (!trimmed) return;
  // Very small sanity filter: accept typical IPv4/IPv6 strings only.
  // (Avoid treating arbitrary attacker strings as "IPs" for rate limiting.)
  if (/^[0-9a-fA-F:.]+$/.test(trimmed)) return trimmed;
  return;
}

function getClientIP(request: NextRequest): string {
  // Prefer platform-provided headers (Cloudflare/Vercel) when present.
  if (!isTrustedProxyHeaders()) return 'unknown';
  const cfIP = normalizeIp(request.headers.get('cf-connecting-ip'));
  if (cfIP) return cfIP;
  const realIP = normalizeIp(request.headers.get('x-real-ip'));
  if (realIP) return realIP;
  const forwarded = request.headers.get('x-forwarded-for');
  const firstForwarded = normalizeIp(forwarded?.split(',')[0]?.trim() ?? null);
  if (firstForwarded) return firstForwarded;
  return 'unknown';
}

function isRateLimited(ip: string): boolean {
  const now = Date.now();
  const record = rateLimitMap.get(ip);

  if (!record || now - record.timestamp > RATE_LIMIT_WINDOW) {
    // Cleanup a bit on window rollover + bound the map size (防内存 DoS).
    // Remove stale entries (older than 2 windows).
    for (const [k, v] of rateLimitMap.entries()) {
      if (now - v.timestamp > RATE_LIMIT_WINDOW * 2) {
        rateLimitMap.delete(k);
      }
    }
    // Hard cap: evict oldest entries.
    while (rateLimitMap.size > MAX_TRACKED_IPS) {
      const oldestKey = rateLimitMap.keys().next().value as string | undefined;
      if (!oldestKey) break;
      rateLimitMap.delete(oldestKey);
    }
    rateLimitMap.set(ip, { count: 1, timestamp: now });
    return false;
  }

  record.count++;
  return record.count > MAX_REQUESTS;
}

function hasSuspiciousContent(url: string): boolean {
  return SUSPICIOUS_PATTERNS.some(pattern => pattern.test(url));
}

function createCspNonce(): string {
  // CSP nonces should be base64. Use WebCrypto for Edge runtime compatibility.
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  let binary = '';
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary);
}

function buildCsp(nonce: string): string {
  // Keep CSP compatible with Next.js: we provide a per-request nonce for
  // scripts (XSS defense-in-depth). Note that many UI libs use inline styles
  // (e.g., animations), so we intentionally allow inline styles.
  const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL;
  let supabaseOrigin: string | undefined;
  let supabaseWssOrigin: string | undefined;

  if (supabaseUrl) {
    try {
      supabaseOrigin = new URL(supabaseUrl).origin;
      supabaseWssOrigin = supabaseOrigin.replace(/^https:/, 'wss:');
    } catch {
      // Ignore invalid URL; CSP will fall back to 'self' only.
    }
  }

  const connectSrc = ["'self'"];
  const imgSrc = ["'self'", 'data:', 'blob:'];
  if (supabaseOrigin) {
    connectSrc.push(supabaseOrigin);
    imgSrc.push(supabaseOrigin);
  }
  if (supabaseWssOrigin) {
    connectSrc.push(supabaseWssOrigin);
  }

  const directives = [
    "default-src 'self'",
    "base-uri 'none'",
    "form-action 'self'",
    "frame-ancestors 'none'",
    "object-src 'none'",
    `script-src 'self' 'nonce-${nonce}'`,
    "script-src-attr 'none'",
    "style-src 'self' 'unsafe-inline'",
    `connect-src ${connectSrc.join(' ')}`,
    `img-src ${imgSrc.join(' ')}`,
    "font-src 'self' data:",
  ];

  return directives.join('; ');
}

// Next.js Proxy entrypoint (Next.js 16+): this file must be named `proxy.ts`.
export function proxy(request: NextRequest) {
  const ip = getClientIP(request);
  const url = request.url;

  // 1. 限流检查
  // If we cannot determine a stable client identity, don't apply IP-based rate
  // limiting (otherwise everyone shares the same "unknown" bucket).
  if (ip !== 'unknown' && isRateLimited(ip)) {
    console.warn(`[Security] Rate limit exceeded for IP: ${ip}`);
    return new NextResponse('Too Many Requests', { 
      status: 429,
      headers: { 'Retry-After': '60' }
    });
  }

  // 2. 请求体大小检查
  const contentLength = request.headers.get('content-length');
  if (contentLength && parseInt(contentLength) > MAX_BODY_SIZE) {
    console.warn(`[Security] Request too large from IP: ${ip}`);
    return new NextResponse('Payload Too Large', { status: 413 });
  }

  // 3. 可疑内容检测
  if (hasSuspiciousContent(url)) {
    console.warn(`[Security] Suspicious request blocked from IP: ${ip}, URL: ${url}`);
    return new NextResponse('Bad Request', { status: 400 });
  }

  const nonce = createCspNonce();
  const csp = buildCsp(nonce);

  // IMPORTANT: Next.js extracts the nonce from the *request* headers during
  // render, so we forward the CSP header to the app via request headers.
  const requestId = request.headers.get('x-request-id') || crypto.randomUUID();
  const requestHeaders = new Headers(request.headers);
  requestHeaders.set('content-security-policy', csp);
  requestHeaders.set('x-request-id', requestId);

  // 4. 添加安全追踪头
  const response = NextResponse.next({
    request: {
      headers: requestHeaders,
    },
  });
  response.headers.set('X-Request-ID', requestId);
  response.headers.set('Content-Security-Policy', csp);
  
  return response;
}

export default proxy

export const config = {
  matcher: [
    // 匹配所有路径，排除静态资源
    '/((?!_next/static|_next/image|favicon.ico|.*\\.(?:svg|png|jpg|jpeg|gif|webp)$).*)',
  ],
};
