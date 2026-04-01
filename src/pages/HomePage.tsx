import React from 'react';
import { Link } from 'react-router-dom';
import { useAuth } from '../contexts/AuthContext';
import { BRAND_NAME, PRODUCT_NAME, SUPPORT_EMAIL } from '../lib/branding';
import { getPreferredDisplayName } from '../lib/userDisplay';

const HomePage: React.FC = () => {
  const { user, userProfile } = useAuth();
  const displayName = getPreferredDisplayName(user, userProfile);

  return (
    <div className="min-h-screen pt-20 pb-16 px-4 sm:px-6 lg:px-8">
      <style>
        {`
          .apple-home-shell {
            position: relative;
          }

          .apple-home-shell::before {
            content: '';
            position: absolute;
            inset: 0 auto auto 50%;
            width: min(72vw, 52rem);
            height: 24rem;
            transform: translateX(-50%);
            background:
              radial-gradient(circle at 50% 10%, rgba(255, 255, 255, 0.16), transparent 58%),
              radial-gradient(circle at 28% 34%, rgba(96, 165, 250, 0.16), transparent 52%),
              radial-gradient(circle at 72% 28%, rgba(167, 139, 250, 0.14), transparent 50%);
            filter: blur(46px);
            opacity: 0.9;
            pointer-events: none;
          }

          .apple-sheen {
            position: relative;
            isolation: isolate;
            overflow: hidden;
          }

          .apple-sheen::before {
            content: '';
            position: absolute;
            inset: 1px;
            border-radius: inherit;
            background:
              linear-gradient(180deg, rgba(255, 255, 255, 0.18), rgba(255, 255, 255, 0.02) 36%, transparent 60%),
              radial-gradient(circle at top, rgba(255, 255, 255, 0.14), transparent 56%);
            pointer-events: none;
            opacity: 0.88;
            z-index: -1;
          }

          .apple-sheen::after {
            content: '';
            position: absolute;
            top: -120%;
            left: -32%;
            width: 42%;
            height: 320%;
            background: linear-gradient(180deg, transparent, rgba(255, 255, 255, 0.2), transparent);
            opacity: 0;
            transform: rotate(22deg);
            transition: opacity 320ms ease;
            pointer-events: none;
          }

          .apple-sheen:hover::after {
            opacity: 1;
            animation: appleSheenSweep 1.4s ease;
          }

          .apple-hero-panel {
            position: relative;
            padding: 2rem 1.5rem 0;
          }

          .apple-hero-actions {
            transform: translateY(-1.25rem);
            will-change: transform;
          }

          .apple-hero-panel::before {
            content: '';
            position: absolute;
            inset: 0 8% auto;
            height: 100%;
            border-radius: 2rem;
            background:
              linear-gradient(180deg, rgba(255, 255, 255, 0.08), rgba(255, 255, 255, 0.02) 40%, transparent 100%),
              radial-gradient(circle at top, rgba(255, 255, 255, 0.12), transparent 58%);
            border: 1px solid rgba(255, 255, 255, 0.14);
            box-shadow:
              inset 0 1px 0 rgba(255, 255, 255, 0.2),
              0 28px 80px rgba(15, 23, 42, 0.28);
            backdrop-filter: blur(22px) saturate(145%);
            pointer-events: none;
            z-index: -1;
          }

          .apple-hero-title {
            display: inline-block;
            position: relative;
            text-shadow:
              0 0 18px rgba(96, 165, 250, 0.2),
              0 18px 40px rgba(15, 23, 42, 0.3);
          }

          .apple-hero-title::after {
            content: '';
            position: absolute;
            inset: auto 14% -0.6rem;
            height: 1px;
            background: linear-gradient(90deg, transparent, rgba(255, 255, 255, 0.4), transparent);
            opacity: 0.75;
          }

          .apple-cta {
            position: relative;
            overflow: hidden;
            border-radius: 999px;
            padding: 0.95rem 2rem;
            font-weight: 600;
            letter-spacing: 0.01em;
            backdrop-filter: blur(16px) saturate(145%);
            transition:
              transform 240ms ease,
              box-shadow 240ms ease,
              border-color 240ms ease,
              background-color 240ms ease;
            box-shadow:
              0 18px 38px rgba(15, 23, 42, 0.28),
              inset 0 1px 0 rgba(255, 255, 255, 0.22);
          }

          .apple-cta:hover {
            transform: translateY(-2px) scale(1.01);
          }

          .apple-cta-primary {
            background: linear-gradient(135deg, rgba(77, 146, 255, 0.92), rgba(88, 104, 255, 0.9) 55%, rgba(142, 92, 255, 0.86));
            border: 1px solid rgba(255, 255, 255, 0.24);
            color: white;
          }

          .apple-cta-primary:hover {
            box-shadow:
              0 20px 48px rgba(79, 123, 255, 0.32),
              inset 0 1px 0 rgba(255, 255, 255, 0.28);
          }

          .apple-cta-secondary {
            background: linear-gradient(180deg, rgba(255, 255, 255, 0.14), rgba(255, 255, 255, 0.08));
            border: 1px solid rgba(255, 255, 255, 0.16);
            color: white;
          }

          .apple-cta-secondary:hover {
            background: linear-gradient(180deg, rgba(255, 255, 255, 0.2), rgba(255, 255, 255, 0.1));
            box-shadow:
              0 20px 48px rgba(15, 23, 42, 0.24),
              inset 0 1px 0 rgba(255, 255, 255, 0.24);
          }

          .apple-panel-card {
            position: relative;
            overflow: hidden;
            border-radius: 1.75rem;
            border: 1px solid rgba(255, 255, 255, 0.12);
            background:
              linear-gradient(180deg, rgba(255, 255, 255, 0.09), rgba(255, 255, 255, 0.04)),
              rgba(15, 23, 42, 0.22);
            backdrop-filter: blur(22px) saturate(150%);
            box-shadow:
              inset 0 1px 0 rgba(255, 255, 255, 0.16),
              0 24px 60px rgba(2, 6, 23, 0.22);
            transition:
              transform 260ms ease,
              box-shadow 260ms ease,
              border-color 260ms ease;
          }

          .apple-panel-card:hover {
            transform: translateY(-6px);
            border-color: rgba(255, 255, 255, 0.2);
            box-shadow:
              inset 0 1px 0 rgba(255, 255, 255, 0.22),
              0 34px 76px rgba(2, 6, 23, 0.28);
          }

          .apple-icon-shell {
            position: relative;
            overflow: hidden;
            box-shadow:
              inset 0 1px 0 rgba(255, 255, 255, 0.24),
              0 12px 28px rgba(15, 23, 42, 0.25);
          }

          .apple-icon-shell::after {
            content: '';
            position: absolute;
            inset: 1px;
            border-radius: inherit;
            background: linear-gradient(180deg, rgba(255, 255, 255, 0.18), transparent 60%);
            pointer-events: none;
          }

          .apple-stat-card {
            text-align: center;
            padding: 2rem;
          }

          .apple-stat-value {
            text-shadow: 0 12px 32px rgba(15, 23, 42, 0.3);
          }

          .apple-contact-shell {
            position: relative;
            overflow: hidden;
          }

          .apple-contact-shell::after {
            content: '';
            position: absolute;
            inset: auto -6rem -8rem auto;
            width: 18rem;
            height: 18rem;
            background: radial-gradient(circle, rgba(147, 197, 253, 0.14), transparent 68%);
            filter: blur(14px);
            pointer-events: none;
          }

          @keyframes appleSheenSweep {
            0% {
              transform: translateX(-180%) rotate(22deg);
            }
            100% {
              transform: translateX(420%) rotate(22deg);
            }
          }

          @media (max-width: 640px) {
            .apple-hero-panel {
              padding: 1.5rem 0 0;
            }

            .apple-hero-actions {
              transform: translateY(-0.85rem);
            }

            .apple-hero-panel::before {
              inset-inline: 0;
              border-radius: 1.5rem;
            }
          }

          @media (prefers-reduced-motion: reduce) {
            .apple-panel-card,
            .apple-cta,
            .apple-sheen::after {
              transition: none !important;
              animation: none !important;
              transform: none !important;
            }
          }
        `}
      </style>
      <div className="max-w-7xl mx-auto apple-home-shell">
        {/* User Welcome Section */}
        <div key="welcome-section" className={user ? "text-center mb-8" : "hidden"}>
          <div className="apple-panel-card apple-sheen p-6 max-w-2xl mx-auto">
            <div className="flex items-center justify-center mb-4">
              <div className="h-3 w-3 bg-green-400 rounded-full animate-pulse mr-3"></div>
              <h2 className="text-xl font-semibold text-white">
                欢迎回到星云世界，{displayName}！
              </h2>
            </div>
            <p className="text-gray-300 text-sm">
              您已成功登录 {BRAND_NAME} 平台，现在可以享受全部连接与协作服务
            </p>
          </div>
        </div>

        {/* Hero Section */}
        <div className="text-center mb-16 apple-hero-panel">
          {/* Main heading */}
          <h1 className="text-5xl sm:text-6xl lg:text-7xl font-bold text-white mb-6 leading-tight">
            <span className="apple-hero-title bg-gradient-to-r from-sky-200 via-blue-100 to-violet-200 bg-clip-text text-transparent">
              {BRAND_NAME}
            </span>
          </h1>
          
          {/* Subtitle */}
          <h2 className="text-xl sm:text-2xl lg:text-3xl text-gray-300 mb-4 font-light">
            智能远程桌面管理平台
          </h2>
          
          {/* Description */}
          <p className="text-lg sm:text-xl text-gray-400 mb-12 max-w-3xl mx-auto leading-relaxed">
            提供高效的文件传输和远程连接功能，让您轻松管理远程设备，
            随时随地安全访问您的工作环境。
          </p>

          {/* Call to action buttons - 根据登录状态显示不同按钮 */}
          <div className="apple-hero-actions flex flex-col sm:flex-row items-center justify-center gap-4 mb-16">
            <div key="user-actions" className={user ? "flex flex-col sm:flex-row items-center justify-center gap-4" : "hidden"}>
              <Link 
                to="/sinan" 
                className="apple-cta apple-cta-primary apple-sheen"
              >
                开始使用 {PRODUCT_NAME}
              </Link>
              <Link 
                to="/downloads" 
                className="apple-cta apple-cta-secondary apple-sheen"
              >
                下载客户端
              </Link>
            </div>
            <div key="guest-actions" className={!user ? "flex flex-col sm:flex-row items-center justify-center gap-4" : "hidden"}>
              <Link
                to="/auth?mode=register"
                className="apple-cta apple-cta-primary apple-sheen"
              >
                免费注册星云账号
              </Link>
              <Link 
                to="/sinan" 
                className="apple-cta apple-cta-secondary apple-sheen"
              >
                了解 {PRODUCT_NAME}
              </Link>
            </div>
          </div>
        </div>

        {/* Feature highlights */}
        <div className="mb-16">
          <div className="text-center mb-12">
            <h2 className="text-3xl sm:text-4xl font-bold text-white mb-4">
              核心功能特性
            </h2>
            <p className="text-xl text-gray-300">
              专业的远程桌面解决方案，让您的工作更高效
            </p>
          </div>
          
          <div className="grid grid-cols-1 md:grid-cols-3 gap-8">
            <div className="apple-panel-card apple-sheen text-center p-6">
              <div className="apple-icon-shell w-12 h-12 bg-gradient-to-br from-blue-500 to-cyan-500 rounded-2xl mx-auto mb-4 flex items-center justify-center">
                <svg className="w-6 h-6 text-white" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M7 16a4 4 0 01-.88-7.903A5 5 0 1115.9 6L16 6a5 5 0 011 9.9M9 19l3 3m0 0l3-3m-3 3V10" />
                </svg>
              </div>
              <h3 className="text-white font-semibold mb-2">高效文件传输</h3>
              <p className="text-gray-400 text-sm">快速、安全的文件共享体验</p>
            </div>
            
            <div className="apple-panel-card apple-sheen text-center p-6">
              <div className="apple-icon-shell w-12 h-12 bg-gradient-to-br from-purple-500 to-pink-500 rounded-2xl mx-auto mb-4 flex items-center justify-center">
                <svg className="w-6 h-6 text-white" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M9 12l2 2 4-4m5.618-4.016A11.955 11.955 0 0112 2.944a11.955 11.955 0 01-8.618 3.04A12.02 12.02 0 003 9c0 5.591 3.824 10.29 9 11.622 5.176-1.332 9-6.03 9-11.622 0-1.042-.133-2.052-.382-3.016z" />
                </svg>
              </div>
              <h3 className="text-white font-semibold mb-2">企业级安全</h3>
              <p className="text-gray-400 text-sm">银行级加密保护您的数据安全</p>
            </div>
            
            <div className="apple-panel-card apple-sheen text-center p-6">
              <div className="apple-icon-shell w-12 h-12 bg-gradient-to-br from-green-500 to-teal-500 rounded-2xl mx-auto mb-4 flex items-center justify-center">
                <svg className="w-6 h-6 text-white" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M8.111 16.404a5.5 5.5 0 017.778 0M12 20h.01m-7.08-7.071c3.904-3.905 10.236-3.905 14.141 0M1.394 9.393c5.857-5.857 15.355-5.857 21.213 0" />
                </svg>
              </div>
              <h3 className="text-white font-semibold mb-2">远程硬件级连接</h3>
              <p className="text-gray-400 text-sm">稳定可靠的远程桌面体验</p>
            </div>
          </div>
        </div>

        {/* User Testimonials Section */}
        <div className="mb-16">
          <div className="text-center mb-12">
            <h2 className="text-3xl sm:text-4xl font-bold text-white mb-4">
              加入数万用户的选择
            </h2>
            <p className="text-xl text-gray-300">
              体验专业服务，让您的工作更高效
            </p>
          </div>

          <div className="grid grid-cols-1 md:grid-cols-3 gap-8">
            <div className="apple-panel-card apple-sheen apple-stat-card">
              <div className="apple-stat-value text-4xl font-bold text-blue-200 mb-2">50,000+</div>
              <div className="text-gray-300">活跃用户</div>
            </div>
            <div className="apple-panel-card apple-sheen apple-stat-card">
              <div className="apple-stat-value text-4xl font-bold text-violet-200 mb-2">99.9%</div>
              <div className="text-gray-300">服务可用性</div>
            </div>
            <div className="apple-panel-card apple-sheen apple-stat-card">
              <div className="apple-stat-value text-4xl font-bold text-emerald-200 mb-2">24/7</div>
              <div className="text-gray-300">技术支持</div>
            </div>
          </div>
        </div>

        {/* Enterprise Applications Section */}
        <div className="mb-16">
          <div className="text-center mb-12">
            <h2 className="text-3xl sm:text-4xl font-bold text-white mb-4">
              企业应用场景
            </h2>
            <p className="text-xl text-gray-300">
              适用于各行各业的数字化转型需求
            </p>
          </div>
          
          <div className="grid grid-cols-1 md:grid-cols-3 gap-8">
            <div className="apple-panel-card apple-sheen p-8">
              <div className="apple-icon-shell w-12 h-12 bg-gradient-to-br from-blue-500 to-cyan-500 rounded-2xl mb-6 flex items-center justify-center">
                <svg className="w-6 h-6 text-white" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M19 21V5a2 2 0 00-2-2H7a2 2 0 00-2 2v16m14 0h2m-2 0h-5m-9 0H3m2 0h5M9 7h1m-1 4h1m4-4h1m-1 4h1m-5 10v-5a1 1 0 011-1h2a1 1 0 011 1v5m-4 0h4" />
                </svg>
              </div>
              <h3 className="text-xl font-bold text-white mb-4">企业办公</h3>
              <p className="text-gray-300 text-sm mb-4">远程文件同步、跨地协作、移动办公</p>
              <ul className="text-gray-400 text-xs space-y-2">
                <li>• 远程文件同步</li>
                <li>• 跨地协作</li>
                <li>• 移动办公</li>
              </ul>
            </div>

            <div className="apple-panel-card apple-sheen p-8">
              <div className="apple-icon-shell w-12 h-12 bg-gradient-to-br from-purple-500 to-pink-500 rounded-2xl mb-6 flex items-center justify-center">
                <svg className="w-6 h-6 text-white" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M9 3v2m6-2v2M9 19v2m6-2v2M5 9H3m2 6H3m18-6h-2m2 6h-2M7 19h10a2 2 0 002-2V7a2 2 0 00-2-2H7a2 2 0 00-2 2v10a2 2 0 002 2zM9 9h6v6H9V9z" />
                </svg>
              </div>
              <h3 className="text-xl font-bold text-white mb-4">IT运维</h3>
              <p className="text-gray-300 text-sm mb-4">服务器远程管理、系统维护、故障排查、批量部署</p>
              <ul className="text-gray-400 text-xs space-y-2">
                <li>• 服务器远程管理</li>
                <li>• 系统维护</li>
                <li>• 故障排查</li>
                <li>• 批量部署</li>
              </ul>
            </div>

            <div className="apple-panel-card apple-sheen p-8">
              <div className="apple-icon-shell w-12 h-12 bg-gradient-to-br from-green-500 to-teal-500 rounded-2xl mb-6 flex items-center justify-center">
                <svg className="w-6 h-6 text-white" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M12 6.253v13m0-13C10.832 5.477 9.246 5 7.5 5S4.168 5.477 3 6.253v13C4.168 18.477 5.754 18 7.5 18s3.332.477 4.5 1.253m0-13C13.168 5.477 14.754 5 16.5 5c1.746 0 3.332.477 4.5 1.253v13C19.832 18.477 18.246 18 16.5 18c-1.746 0-3.332.477-4.5 1.253" />
                </svg>
              </div>
              <h3 className="text-xl font-bold text-white mb-4">教育培训</h3>
              <p className="text-gray-300 text-sm mb-4">远程教学支持、课件分发、在线实验室</p>
              <ul className="text-gray-400 text-xs space-y-2">
                <li>• 远程教学支持</li>
                <li>• 课件分发</li>
                <li>• 在线实验室</li>
              </ul>
            </div>
          </div>
        </div>

        {/* Contact Information Section */}
        <div className="mb-16">
          <div className="apple-panel-card apple-sheen apple-contact-shell p-8">
            <div className="text-center mb-12">
              <h2 className="text-3xl font-bold text-white mb-4">联系我们</h2>
              <p className="text-gray-300">随时为您提供专业的技术支持和解决方案咨询</p>
            </div>

            <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-8">
              <div className="text-center">
                <h3 className="text-white font-semibold mb-4">北京总部</h3>
                <div className="space-y-2 text-sm text-gray-300">
                  <p>北京市朝阳区望京SOHO T3-2808</p>
                  <p className="text-blue-400 font-semibold">400-888-9999</p>
                  <p className="text-purple-400">{SUPPORT_EMAIL}</p>
                </div>
              </div>

              <div className="text-center">
                <h3 className="text-white font-semibold mb-4">上海分公司</h3>
                <div className="space-y-2 text-sm text-gray-300">
                  <p>上海市浦东新区陆家嘴环路1000号</p>
                  <p>恒生银行大厦50F</p>
                  <p className="text-green-400">021-6888-9999</p>
                </div>
              </div>

              <div className="text-center">
                <h3 className="text-white font-semibold mb-4">深圳分公司</h3>
                <div className="space-y-2 text-sm text-gray-300">
                  <p>深圳市南山区深南大道10000号</p>
                  <p>腾讯滨海大厦45F</p>
                  <p className="text-yellow-400">0755-8888-9999</p>
                </div>
              </div>

              <div className="text-center">
                <h3 className="text-white font-semibold mb-4">成都分公司</h3>
                <div className="space-y-2 text-sm text-gray-300">
                  <p>成都市高新区天府大道中段666号</p>
                  <p>希望金融大厦35F</p>
                  <p className="text-orange-400">028-8888-9999</p>
                </div>
              </div>
            </div>

            <div className="mt-12 text-center">
              <div className="inline-flex items-center space-x-8">
                <div className="flex items-center space-x-2">
                  <div className="w-3 h-3 bg-green-400 rounded-full animate-pulse"></div>
                  <span className="text-green-400 font-semibold">7×24小时技术支持</span>
                </div>
                <div className="flex items-center space-x-2">
                  <div className="w-3 h-3 bg-blue-400 rounded-full animate-pulse"></div>
                  <span className="text-blue-400 font-semibold">在线客服</span>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
};

export default HomePage;
