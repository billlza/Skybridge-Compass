import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  poweredByHeader: false,

  // 安全响应头配置
  async headers() {
    const baseHeaders = [
      // 防止点击劫持
      { key: 'X-Frame-Options', value: 'DENY' },
      // 防止 MIME 类型嗅探
      { key: 'X-Content-Type-Options', value: 'nosniff' },
      // 引用策略
      { key: 'Referrer-Policy', value: 'strict-origin-when-cross-origin' },
      // 权限策略 - 限制敏感 API
      { key: 'Permissions-Policy', value: 'camera=(), microphone=(), geolocation=()' },
      // 避免旧式跨域策略文件被滥用
      { key: 'X-Permitted-Cross-Domain-Policies', value: 'none' },
      // 隔离跨站窗口关系，且兼容 OAuth 弹窗
      { key: 'Cross-Origin-Opener-Policy', value: 'same-origin-allow-popups' },
      // 限制本站资源被第三方站点跨站读取（不影响站内使用）
      { key: 'Cross-Origin-Resource-Policy', value: 'same-site' },
    ];

    const enableHsts = process.env.SKYBRIDGE_ENABLE_HSTS === '1' || process.env.SKYBRIDGE_ENABLE_HSTS === 'true'
    const productionOnly = process.env.NODE_ENV === 'production' && enableHsts
      ? [
          // HSTS 具有“粘性”风险（配置错误可能导致长期访问异常）；仅在明确确认全站永久 HTTPS 后启用
          { key: 'Strict-Transport-Security', value: 'max-age=31536000; includeSubDomains' },
        ]
      : [];

    return [
      {
        source: '/:path*',
        headers: [...baseHeaders, ...productionOnly],
      },
      // 认证回调/重置页面包含敏感上下文，避免被中间缓存持久化
      {
        source: '/auth/:path*',
        headers: [{ key: 'Cache-Control', value: 'no-store' }],
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
