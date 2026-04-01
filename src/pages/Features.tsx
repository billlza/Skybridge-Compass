import React from 'react';
import { PRODUCT_NAME } from '../lib/branding';

const Features: React.FC = () => {
  const features = [
    {
      title: '高效文件传输',
      description: '支持大文件传输、断点续传、文件加密、传输优化',
      icon: (
        <svg className="w-8 h-8" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M7 16a4 4 0 01-.88-7.903A5 5 0 1115.9 6L16 6a5 5 0 011 9.9M9 19l3 3m0 0l3-3m-3 3V10" />
        </svg>
      ),
      features: ['大文件支持', '断点续传', '文件加密', '传输优化'],
      gradient: 'from-blue-500 to-cyan-500'
    },
    {
      title: '企业级安全',
      description: '端到端加密、身份认证、权限管理、安全审计',
      icon: (
        <svg className="w-8 h-8" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M9 12l2 2 4-4m5.618-4.016A11.955 11.955 0 0112 2.944a11.955 11.955 0 01-8.618 3.04A12.02 12.02 0 003 9c0 5.591 3.824 10.29 9 11.622 5.176-1.332 9-6.03 9-11.622 0-1.042-.133-2.052-.382-3.016z" />
        </svg>
      ),
      features: ['端到端加密', '身份认证', '权限管理', '安全审计'],
      gradient: 'from-purple-500 to-pink-500'
    },
    {
      title: '远程硬件级连接',
      description: '硬件级控制、低延迟连接、连接恢复、性能优化',
      icon: (
        <svg className="w-8 h-8" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M8.111 16.404a5.5 5.5 0 017.778 0M12 20h.01m-7.08-7.071c3.904-3.905 10.236-3.905 14.141 0M1.394 9.393c5.857-5.857 15.355-5.857 21.213 0" />
        </svg>
      ),
      features: ['硬件级控制', '低延迟连接', '连接恢复', '性能优化'],
      gradient: 'from-green-500 to-teal-500'
    },
    {
      title: '跨平台支持',
      description: 'Windows、macOS、Linux、iOS/Android移动端',
      icon: (
        <svg className="w-8 h-8" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M9.75 17L9 20l-1 1h8l-1-1-.75-3M3 13h18M5 17h14a2 2 0 002-2V5a2 2 0 00-2-2H5a2 2 0 00-2 2v10a2 2 0 002 2z" />
        </svg>
      ),
      features: ['Windows、macOS、Linux支持', 'iOS/Android移动端'],
      gradient: 'from-orange-500 to-red-500'
    },
    {
      title: '团队协作',
      description: '多用户支持、权限分级、实时协作、消息通知',
      icon: (
        <svg className="w-8 h-8" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M17 20h5v-2a3 3 0 00-5.356-1.857M17 20H7m10 0v-2c0-.656-.126-1.283-.356-1.857M7 20H2v-2a3 3 0 015.356-1.857M7 20v-2c0-.656.126-1.283.356-1.857m0 0a5.002 5.002 0 019.288 0M15 7a3 3 0 11-6 0 3 3 0 016 0zm6 3a2 2 0 11-4 0 2 2 0 014 0zM7 10a2 2 0 11-4 0 2 2 0 014 0z" />
        </svg>
      ),
      features: ['多用户支持', '权限分级', '实时协作', '消息通知'],
      gradient: 'from-indigo-500 to-purple-500'
    },
    {
      title: '移动端支持',
      description: 'iOS/Android原生应用、移动优化、触控支持',
      icon: (
        <svg className="w-8 h-8" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M12 18h.01M8 21h8a2 2 0 002-2V5a2 2 0 00-2-2H8a2 2 0 00-2 2v14a2 2 0 002 2z" />
        </svg>
      ),
      features: ['iOS/Android原生应用', '移动优化', '触控支持'],
      gradient: 'from-pink-500 to-rose-500'
    },
    {
      title: '连接管理',
      description: '实时监控连接状态，性能优化',
      icon: (
        <svg className="w-8 h-8" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M9 19v-6a2 2 0 00-2-2H5a2 2 0 00-2 2v6a2 2 0 002 2h2a2 2 0 002-2zm0 0V9a2 2 0 012-2h2a2 2 0 012 2v10m-6 0a2 2 0 002 2h2a2 2 0 002-2m0 0V5a2 2 0 012-2h2a2 2 0 012 2v14a2 2 0 01-2 2h-2a2 2 0 01-2-2z" />
        </svg>
      ),
      features: ['实时监控', '性能优化'],
      gradient: 'from-teal-500 to-green-500'
    },
    {
      title: '智能网络优化',
      description: '自动网络配置优化',
      icon: (
        <svg className="w-8 h-8" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M13 10V3L4 14h7v7l9-11h-7z" />
        </svg>
      ),
      features: ['自动网络配置优化'],
      gradient: 'from-yellow-500 to-orange-500'
    },
    {
      title: '数据备份',
      description: '自动备份和灾难恢复',
      icon: (
        <svg className="w-8 h-8" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M4 7v10c0 2.21 3.582 4 8 4s8-1.79 8-4V7M4 7c0 2.21 3.582 4 8 4s8-1.79 8-4M4 7c0-2.21 3.582-4 8-4s8 1.79 8 4m0 5c0 2.21-3.582 4-8 4s-8-1.79-8-4" />
        </svg>
      ),
      features: ['自动备份和灾难恢复'],
      gradient: 'from-blue-600 to-indigo-600'
    },
    {
      title: '本地部署支持',
      description: '满足企业定制化需求',
      icon: (
        <svg className="w-8 h-8" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M19 21V5a2 2 0 00-2-2H7a2 2 0 00-2 2v16m14 0h2m-2 0h-5m-9 0H3m2 0h5M9 7h1m-1 4h1m4-4h1m-1 4h1m-5 10v-5a1 1 0 011-1h2a1 1 0 011 1v5m-4 0h4" />
        </svg>
      ),
      features: ['企业定制化需求'],
      gradient: 'from-gray-600 to-gray-800'
    },
    {
      title: 'API集成',
      description: '丰富的API接口',
      icon: (
        <svg className="w-8 h-8" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M10 20l4-16m4 4l4 4-4 4M6 16l-4-4 4-4" />
        </svg>
      ),
      features: ['丰富的API接口'],
      gradient: 'from-emerald-500 to-teal-500'
    },
    {
      title: '智能连接管理',
      description: 'AI驱动的智能优化',
      icon: (
        <svg className="w-8 h-8" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M9.663 17h4.673M12 3v1m6.364 1.636l-.707.707M21 12h-1M4 12H3m3.343-5.657l-.707-.707m2.828 9.9a5 5 0 117.072 0l-.548.547A3.374 3.374 0 0014 18.469V19a2 2 0 11-4 0v-.531c0-.895-.356-1.754-.988-2.386l-.548-.547z" />
        </svg>
      ),
      features: ['AI驱动的智能优化'],
      gradient: 'from-violet-500 to-purple-500'
    }
  ];

  return (
    <div className="min-h-screen pt-20 pb-16 px-4 sm:px-6 lg:px-8">
      <div className="max-w-7xl mx-auto">
        <div className="text-center mb-16">
          <h1 className="text-4xl sm:text-5xl font-bold text-white mb-6">
            强大的
            <span className="bg-gradient-to-r from-blue-400 to-purple-500 bg-clip-text text-transparent ml-3">
              功能特性
            </span>
          </h1>
          <p className="text-xl text-gray-300 max-w-3xl mx-auto leading-relaxed">
            {PRODUCT_NAME} 提供全面的远程桌面解决方案，12 大核心功能模块，让您的工作更高效、更安全、更便捷
          </p>
        </div>

        <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-8 mb-16">
          {features.map((feature, index) => (
            <div
              key={index}
              className="apple-glass-panel apple-glass-sheen apple-glass-panel-interactive p-6 group"
            >
              <div className={`apple-glass-icon w-16 h-16 bg-gradient-to-br ${feature.gradient} flex items-center justify-center text-white mb-6 group-hover:scale-110 transition-transform duration-300`}>
                {feature.icon}
              </div>
              
              <h3 className="text-xl font-bold text-white mb-3">{feature.title}</h3>
              <p className="text-gray-300 mb-4 leading-relaxed text-sm">{feature.description}</p>
              
              <div className="space-y-2">
                {feature.features.map((item, itemIndex) => (
                  <div key={itemIndex} className="flex items-center text-gray-400">
                    <div className={`w-2 h-2 bg-gradient-to-r ${feature.gradient} rounded-full mr-3`}></div>
                    <span className="text-xs">{item}</span>
                  </div>
                ))}
              </div>
            </div>
          ))}
        </div>

        <div className="text-center">
          <div className="apple-glass-panel-strong apple-glass-sheen p-8">
            <h2 className="text-2xl font-bold text-white mb-4">体验强大功能</h2>
            <p className="text-gray-300 mb-6 max-w-2xl mx-auto">
              立即开始使用 {PRODUCT_NAME}，体验专业的文件传输和远程连接解决方案
            </p>
            <div className="flex flex-col sm:flex-row gap-4 justify-center">
              <button className="apple-glass-cta apple-glass-cta-primary apple-glass-sheen">
                免费试用
              </button>
              <button className="apple-glass-cta apple-glass-cta-secondary apple-glass-sheen">
                查看演示
              </button>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
};

export default Features;
