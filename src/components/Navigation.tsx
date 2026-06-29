import React, { useState, useRef } from 'react';
import { Link, useLocation } from 'react-router-dom';
import { useAuth } from '../contexts/useAuth';
import { BRAND_NAME, PRODUCT_SHORT_NAME } from '../lib/branding';
import { getPreferredDisplayName } from '../lib/userDisplay';

const Navigation: React.FC = () => {
  const location = useLocation();
  const { user, userProfile, signOut } = useAuth();
  const displayName = getPreferredDisplayName(user, userProfile);
  const [isMobileMenuOpen, setIsMobileMenuOpen] = useState(false);
  const [clickAnimation, setClickAnimation] = useState<string | null>(null);

  const handleSignOut = async () => {
    try {
      await signOut();
      setIsMobileMenuOpen(false);
    } catch (error) {
      console.error('Sign out error:', error);
    }
  };

  const handleNavClick = (path: string) => {
    setClickAnimation(path);
    
    // 安全地操作SVG元素，添加错误处理
    try {
      const turbulenceElement = document.getElementById('turbulence');
      const rippleTurbulenceElement = document.getElementById('rippleTurbulence');
      
      if (turbulenceElement && rippleTurbulenceElement && 
          turbulenceElement.isConnected && rippleTurbulenceElement.isConnected) {
        turbulenceElement.setAttribute('baseFrequency', '0.04 0.04');
        rippleTurbulenceElement.setAttribute('baseFrequency', '0.08 0.08');
        
        setTimeout(() => {
          // 再次检查元素是否仍在DOM中
          if (turbulenceElement.isConnected && rippleTurbulenceElement.isConnected) {
            turbulenceElement.setAttribute('baseFrequency', '0.02 0.02');
            rippleTurbulenceElement.setAttribute('baseFrequency', '0.05 0.05');
          }
        }, 250);
      }
    } catch (error) {
      console.warn('SVG animation error (non-critical):', error);
    }
    
    setTimeout(() => setClickAnimation(null), 250);
  };

  const navItems = [
    { path: '/', label: '首页' },
    { path: '/features', label: '功能特性' },
    { path: '/downloads', label: '下载' },
    { path: '/sinan', label: PRODUCT_SHORT_NAME },
    { path: '/contact', label: '联系我们' },
    { path: '/help', label: '帮助中心' }
  ];

  return (
    <nav className="fixed top-0 w-full z-50 bg-black/15 backdrop-blur-md border-b border-white/20 shadow-lg shadow-black/20">
      {/* SVG滤镜定义 - 实现真正的透镜扭曲效果 */}
      <svg width="0" height="0" style={{ position: 'absolute' }}>
        <defs>
          <filter id="liquidGlass" x="-50%" y="-50%" width="200%" height="200%">
            <feTurbulence
              id="turbulence"
              baseFrequency="0.02 0.02"
              numOctaves="3"
              stitchTiles="stitch"
              type="fractalNoise"
            />
            <feDisplacementMap
              in="SourceGraphic"
              in2="turbulence"
              scale="5"
              xChannelSelector="R"
              yChannelSelector="G"
            />
          </filter>
          <filter id="liquidRipple" x="-100%" y="-100%" width="300%" height="300%">
            <feTurbulence
              id="rippleTurbulence"
              baseFrequency="0.05 0.05"
              numOctaves="2"
              type="fractalNoise"
            />
            <feDisplacementMap
              in="SourceGraphic"
              in2="rippleTurbulence"
              scale="10"
              xChannelSelector="R"
              yChannelSelector="G"
            />
          </filter>
          <radialGradient id="lensGradient" cx="50%" cy="50%" r="50%">
            <stop offset="0%" stopColor="rgba(255,255,255,0.3)" />
            <stop offset="30%" stopColor="rgba(255,255,255,0.1)" />
            <stop offset="70%" stopColor="rgba(255,255,255,0.05)" />
            <stop offset="100%" stopColor="transparent" />
          </radialGradient>
        </defs>
      </svg>
      <style>
        {`
          .apple-liquid-glass {
            position: relative;
            overflow: visible;
            will-change: transform, backdrop-filter;
            transition: all 0.4s cubic-bezier(0.25, 0.46, 0.45, 0.94);
          }
          
          .apple-liquid-glass::before {
            content: '';
            position: absolute;
            top: -5px;
            left: -5px;
            right: -5px;
            bottom: -5px;
            background: radial-gradient(
              ellipse at center,
              rgba(255, 255, 255, 0.15) 0%,
              rgba(255, 255, 255, 0.08) 30%,
              rgba(255, 255, 255, 0.03) 70%,
              transparent 100%
            );
            border-radius: inherit;
            opacity: 0;
            transform: scale(0.8);
            transition: all 0.4s cubic-bezier(0.25, 0.46, 0.45, 0.94);
            pointer-events: none;
            z-index: -1;
            filter: url(#liquidGlass);
          }
          
          .apple-liquid-glass::after {
            content: '';
            position: absolute;
            top: 0;
            left: 0;
            right: 0;
            bottom: 0;
            background: url('data:image/svg+xml,<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100"><defs><radialGradient id="lens" cx="50%" cy="30%" r="40%"><stop offset="0%" stop-color="white" stop-opacity="0.4"/><stop offset="50%" stop-color="white" stop-opacity="0.1"/><stop offset="100%" stop-color="white" stop-opacity="0"/></radialGradient></defs><ellipse cx="50" cy="50" rx="45" ry="40" fill="url(%23lens)"/></svg>');
            background-size: 100% 100%;
            border-radius: inherit;
            opacity: 0;
            transform: scale(0.9) translateY(2px);
            transition: all 0.4s cubic-bezier(0.25, 0.46, 0.45, 0.94);
            pointer-events: none;
            mix-blend-mode: plus-lighter;
            z-index: -1;
          }
          
          .apple-liquid-glass:hover {
            transform: scale(1.02) translateY(-1px);
            backdrop-filter: blur(8px) saturate(1.2);
          }
          
          .apple-liquid-glass:hover::before {
            opacity: 1;
            transform: scale(1.1);
            box-shadow: 
              inset 0 1px 0 rgba(255, 255, 255, 0.3),
              inset 0 -1px 0 rgba(255, 255, 255, 0.1),
              0 8px 32px rgba(0, 0, 0, 0.4),
              0 0 0 1px rgba(255, 255, 255, 0.15);
          }
          
          .apple-liquid-glass:hover::after {
            opacity: 1;
            transform: scale(1.05) translateY(-1px);
          }
          
          .apple-liquid-glass-active {
            transform: scale(1.0) translateY(0px);
            backdrop-filter: blur(6px) saturate(1.1);
          }
          
          .apple-liquid-glass-active::before {
            opacity: 1;
            transform: scale(1.0);
            background: radial-gradient(
              ellipse at center,
              rgba(59, 130, 246, 0.2) 0%,
              rgba(147, 51, 234, 0.12) 40%,
              rgba(59, 130, 246, 0.05) 80%,
              transparent 100%
            );
            box-shadow: 
              inset 0 1px 0 rgba(59, 130, 246, 0.4),
              inset 0 -1px 0 rgba(147, 51, 234, 0.3),
              0 4px 16px rgba(59, 130, 246, 0.3),
              0 0 0 1px rgba(59, 130, 246, 0.2);
          }
          
          .apple-liquid-glass-active::after {
            opacity: 0.8;
            transform: scale(1.0) translateY(0px);
            background: url('data:image/svg+xml,<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100"><defs><radialGradient id="activeLens" cx="50%" cy="30%" r="40%"><stop offset="0%" stop-color="%2359a0f2" stop-opacity="0.3"/><stop offset="50%" stop-color="%239333ea" stop-opacity="0.15"/><stop offset="100%" stop-color="%2359a0f2" stop-opacity="0"/></radialGradient></defs><ellipse cx="50" cy="50" rx="45" ry="40" fill="url(%23activeLens)"/></svg>');
          }
          
          .liquid-droplet-effect {
            position: relative;
            overflow: hidden;
          }
          
          .liquid-droplet-effect::before {
            content: '';
            position: absolute;
            top: 50%;
            left: 50%;
            width: 0;
            height: 0;
            background: radial-gradient(
              ellipse 120% 80% at center,
              rgba(255, 255, 255, 0.8) 0%,
              rgba(255, 255, 255, 0.4) 25%,
              rgba(255, 255, 255, 0.2) 50%,
              rgba(255, 255, 255, 0.1) 75%,
              transparent 100%
            );
            border-radius: 50%;
            transform: translate(-50%, -50%);
            opacity: 0;
            filter: url(#liquidRipple);
            animation: ellipticalDropletExpand 0.25s cubic-bezier(0.25, 0.46, 0.45, 0.94) forwards;
            pointer-events: none;
            z-index: -1;
          }
          
          @keyframes ellipticalDropletExpand {
            0% {
              width: 0;
              height: 0;
              opacity: 1;
              transform: translate(-50%, -50%) scale(0);
              filter: url(#liquidRipple) blur(0px);
            }
            30% {
              opacity: 0.9;
              transform: translate(-50%, -50%) scale(0.8);
              filter: url(#liquidRipple) blur(0.5px);
            }
            60% {
              opacity: 0.6;
              transform: translate(-50%, -50%) scale(1.1);
              filter: url(#liquidRipple) blur(1px);
            }
            100% {
              width: 200px;
              height: 120px;
              opacity: 0;
              transform: translate(-50%, -50%) scale(1.4);
              filter: url(#liquidRipple) blur(2px);
            }
          }
          
          .glass-morphism-button {
            position: relative;
            backdrop-filter: blur(12px) saturate(1.1);
            background: linear-gradient(
              135deg,
              rgba(255, 255, 255, 0.12) 0%,
              rgba(255, 255, 255, 0.06) 50%,
              rgba(255, 255, 255, 0.03) 100%
            );
            border: 1px solid rgba(255, 255, 255, 0.2);
            transition: all 0.4s cubic-bezier(0.25, 0.46, 0.45, 0.94);
            will-change: transform, backdrop-filter;
            box-shadow: 
              0 4px 16px rgba(0, 0, 0, 0.1),
              inset 0 1px 0 rgba(255, 255, 255, 0.2);
          }
          
          .glass-morphism-button::before {
            content: '';
            position: absolute;
            top: 0;
            left: 0;
            right: 0;
            bottom: 0;
            background: radial-gradient(
              ellipse at top left,
              rgba(255, 255, 255, 0.15) 0%,
              transparent 50%
            );
            border-radius: inherit;
            opacity: 0;
            transition: opacity 0.3s ease;
          }
          
          .glass-morphism-button:hover {
            backdrop-filter: blur(16px) saturate(1.3);
            background: linear-gradient(
              135deg,
              rgba(255, 255, 255, 0.18) 0%,
              rgba(255, 255, 255, 0.09) 50%,
              rgba(255, 255, 255, 0.06) 100%
            );
            border-color: rgba(255, 255, 255, 0.3);
            transform: translateY(-2px) scale(1.02);
            box-shadow: 
              0 8px 32px rgba(0, 0, 0, 0.2),
              inset 0 1px 0 rgba(255, 255, 255, 0.3),
              inset 0 -1px 0 rgba(255, 255, 255, 0.1);
          }
          
          .glass-morphism-button:hover::before {
            opacity: 1;
          }
          
          @supports not (backdrop-filter: blur(1px)) {
            .apple-liquid-glass::before {
              background: rgba(255, 255, 255, 0.15);
            }
            .glass-morphism-button {
              background: rgba(255, 255, 255, 0.1);
            }
          }
        `}
      </style>
      <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8">
        <div className="flex items-center justify-between h-16">
          {/* Logo */}
          <Link to="/" className="flex items-center space-x-3">
            <img 
              src="/logo.png" 
              alt={BRAND_NAME} 
              className="w-10 h-10 rounded-lg object-contain"
            />
            <span className="text-white text-xl font-semibold">{BRAND_NAME}</span>
          </Link>

          {/* Navigation Links */}
          <div className="hidden md:block">
            <div className="ml-10 flex items-baseline space-x-4">
              {navItems.map((item) => (
                <Link
                  key={item.path}
                  to={item.path}
                  onClick={() => handleNavClick(item.path)}
                  className={`px-4 py-2 rounded-lg text-sm font-medium transition-all duration-400 apple-liquid-glass ${
                    location.pathname === item.path
                      ? 'text-blue-300 apple-liquid-glass-active'
                      : 'text-gray-300 hover:text-white'
                  } ${
                    clickAnimation === item.path ? 'liquid-droplet-effect' : ''
                  }`}
                >
                  {item.label}
                </Link>
              ))}
            </div>
          </div>

          {/* User Menu */}
          <div className="hidden md:flex items-center space-x-3">
            <div key="user-menu" className={user ? "flex items-center space-x-4" : "hidden"}>
              <div className="flex items-center space-x-2 text-sm text-gray-300">
                <div className="h-2 w-2 bg-green-400 rounded-full"></div>
                <span>{displayName}</span>
              </div>
              <Link
                to="/profile"
                className="px-4 py-2 text-sm font-medium text-gray-300 hover:text-white rounded-lg transition-all duration-400 glass-morphism-button"
              >
                个人资料
              </Link>
              <button
                onClick={handleSignOut}
                className="px-4 py-2 text-sm font-medium text-gray-300 hover:text-red-400 rounded-lg transition-all duration-400 glass-morphism-button hover:border-red-400/30 hover:bg-red-500/10"
              >
                退出登录
              </button>
            </div>
            <div key="guest-menu" className={!user ? "flex items-center space-x-3" : "hidden"}>
              <Link
                to="/auth?mode=login"
                className="px-4 py-2 text-sm font-medium text-gray-300 hover:text-white rounded-lg glass-morphism-button"
              >
                登录
              </Link>
              <Link
                to="/auth?mode=register"
                className="relative overflow-hidden text-white font-semibold py-2 px-4 rounded-lg transition-all duration-400 transform hover:scale-105 hover:shadow-lg hover:shadow-blue-500/25 text-sm"
                style={{
                  background: 'linear-gradient(135deg, rgba(59, 130, 246, 0.85) 0%, rgba(147, 51, 234, 0.85) 100%)',
                  backdropFilter: 'blur(12px)',
                  border: '1px solid rgba(255, 255, 255, 0.25)',
                  boxShadow: '0 4px 16px rgba(59, 130, 246, 0.2), inset 0 1px 0 rgba(255, 255, 255, 0.2)'
                }}
              >
                注册星云账号
              </Link>
            </div>
          </div>

          {/* Mobile menu button */}
          <div className="md:hidden">
            <button 
              onClick={() => setIsMobileMenuOpen(!isMobileMenuOpen)}
              className="text-gray-300 hover:text-white p-2"
            >
              <svg className="h-6 w-6" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M4 6h16M4 12h16M4 18h16" />
              </svg>
            </button>
          </div>
        </div>

        {/* Mobile Menu */}
        {isMobileMenuOpen && (
          <div className="md:hidden">
            <div className="px-2 pt-2 pb-3 space-y-1 bg-black/20 backdrop-blur-xl rounded-xl mt-2 border border-white/10 shadow-2xl shadow-black/50" style={{
              background: 'linear-gradient(135deg, rgba(0, 0, 0, 0.3) 0%, rgba(0, 0, 0, 0.1) 100%)',
              backdropFilter: 'blur(20px)'
            }}>
              {navItems.map((item) => (
                <Link
                  key={item.path}
                  to={item.path}
                  onClick={() => {
                    handleNavClick(item.path);
                    setIsMobileMenuOpen(false);
                  }}
                  className={`block px-4 py-3 rounded-lg text-base font-medium transition-all duration-400 apple-liquid-glass ${
                    location.pathname === item.path
                      ? 'text-blue-300 apple-liquid-glass-active'
                      : 'text-gray-300 hover:text-white'
                  }`}
                >
                  {item.label}
                </Link>
              ))}
              <div className="border-t border-white/10 pt-4 mt-4">
                <div key="mobile-user-menu" className={user ? "space-y-2" : "hidden"}>
                  <div className="px-3 py-2 text-sm text-gray-300 text-center">
                    已登录为: {displayName}
                  </div>
                  <Link
                    to="/profile"
                    onClick={() => setIsMobileMenuOpen(false)}
                    className="block w-full px-4 py-3 rounded-lg text-base font-medium text-gray-300 hover:text-white text-center glass-morphism-button transition-all duration-400"
                  >
                    个人资料
                  </Link>
                  <button
                    onClick={handleSignOut}
                    className="block w-full px-4 py-3 rounded-lg text-base font-medium text-red-400 text-center glass-morphism-button hover:border-red-400/30 hover:bg-red-500/10 transition-all duration-400"
                  >
                    退出登录
                  </button>
                </div>
                <div key="mobile-guest-menu" className={!user ? "space-y-2" : "hidden"}>
                  <Link
                    to="/auth?mode=login"
                    onClick={() => setIsMobileMenuOpen(false)}
                    className="block px-4 py-3 rounded-lg text-base font-medium text-gray-300 hover:text-white text-center glass-morphism-button"
                  >
                    登录
                  </Link>
                  <Link
                    to="/auth?mode=register"
                    onClick={() => setIsMobileMenuOpen(false)}
                    className="block px-4 py-3 rounded-lg text-base font-medium text-white text-center transition-all duration-400 hover:scale-105"
                    style={{
                      background: 'linear-gradient(135deg, rgba(59, 130, 246, 0.85) 0%, rgba(147, 51, 234, 0.85) 100%)',
                      backdropFilter: 'blur(12px)',
                      border: '1px solid rgba(255, 255, 255, 0.25)',
                      boxShadow: '0 4px 16px rgba(59, 130, 246, 0.2), inset 0 1px 0 rgba(255, 255, 255, 0.2)'
                    }}
                  >
                    注册星云账号
                  </Link>
                </div>
              </div>
            </div>
          </div>
        )}
      </div>
    </nav>
  );
};

export default Navigation;
