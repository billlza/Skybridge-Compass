import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  // 请求体大小限制 - 防止大型恶意请求
  serverExternalPackages: [],
  
  // 安全响应头配置
  async headers() {
    return [
      {
        source: '/:path*',
        headers: [
          // 防止点击劫持
          { key: 'X-Frame-Options', value: 'DENY' },
          // 防止 MIME 类型嗅探
          { key: 'X-Content-Type-Options', value: 'nosniff' },
          // XSS 保护
          { key: 'X-XSS-Protection', value: '1; mode=block' },
          // 严格传输安全
          { key: 'Strict-Transport-Security', value: 'max-age=31536000; includeSubDomains' },
          // 引用策略
          { key: 'Referrer-Policy', value: 'strict-origin-when-cross-origin' },
          // 权限策略 - 限制敏感 API
          { key: 'Permissions-Policy', value: 'camera=(), microphone=(), geolocation=()' },
        ],
      },
    ];
  },

  // 实验性功能 - 请求体大小限制
  experimental: {
    serverActions: {
      bodySizeLimit: '1mb', // 限制 Server Actions 请求体大小
    },
  },
};

export default nextConfig;
