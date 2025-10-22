/** @type {import('next').NextConfig} */
const nextConfig = {
  // Turbopack 配置（2025年最新标准）
  turbopack: {
    // 设置工作区根目录
    root: __dirname,
    // SVG 处理规则
    rules: {
      '*.svg': {
        loaders: ['@svgr/webpack'],
        as: '*.js',
      },
    },
  },
  
  // 需要转译的包
  transpilePackages: ['recharts', 'lucide-react'],
  
  // TypeScript 配置
  typescript: {
    // 在生产构建时忽略类型错误（可选）
    ignoreBuildErrors: false,
  },
  
  // ESLint 配置
  eslint: {
    // 在生产构建时忽略 ESLint 错误（可选）
    ignoreDuringBuilds: false,
  },
  
  // 图片优化配置
  images: {
    domains: ['localhost'],
    formats: ['image/webp', 'image/avif'],
  },
  
  // 压缩配置
  compress: true,
  
  // 输出配置
  output: 'standalone',
  
  // 环境变量配置
  env: {
    CUSTOM_KEY: 'skybridge-compass',
  },
  
  // 重定向配置
  async redirects() {
    return [
      {
        source: '/',
        destination: '/dashboard',
        permanent: false,
      },
    ]
  },
}

module.exports = nextConfig