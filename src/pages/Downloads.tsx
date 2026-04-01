import React from 'react';
import { PRODUCT_NAME } from '../lib/branding';

const PlatformIcon: React.FC<{ platform: string }> = ({ platform }) => {
  const iconProps = "w-8 h-8";
  
  switch (platform) {
    case 'macOS':
      return (
        <svg className={iconProps} fill="currentColor" viewBox="0 0 24 24">
          <path d="M12.152 6.896c-.948 0-2.415-1.078-3.96-1.04-2.04.027-3.91 1.183-4.961 3.014-2.117 3.675-.546 9.103 1.519 12.09 1.013 1.454 2.208 3.09 3.792 3.039 1.52-.065 2.09-.987 3.935-.987 1.831 0 2.35.987 3.96.948 1.637-.026 2.676-1.48 3.676-2.948 1.156-1.688 1.636-3.325 1.662-3.415-.039-.013-3.182-1.221-3.22-4.857-.026-3.04 2.48-4.494 2.597-4.559-1.429-2.09-3.623-2.324-4.39-2.376-2-.156-3.675 1.09-4.61 1.09zM15.53 3.83c.843-1.012 1.4-2.427 1.245-3.83-1.207.052-2.662.805-3.532 1.818-.78.896-1.454 2.338-1.273 3.714 1.338.104 2.715-.688 3.559-1.701z"/>
        </svg>
      );
    case 'Windows':
      return (
        <svg className={iconProps} fill="currentColor" viewBox="0 0 24 24">
          <path d="M3 12V6.75l6-1.32v6.48L3 12zm17-9v8.75l-10 .15V5.21L20 3zM3 13l6 .09v6.81l-6-1.15V13zm17 .25V22l-10-1.91V13.1L20 13.25z"/>
        </svg>
      );
    case 'iOS':
      return (
        <svg className={iconProps} fill="currentColor" viewBox="0 0 24 24">
          <path d="M15.5 1h-8C6.12 1 5 2.12 5 3.5v17C5 21.88 6.12 23 7.5 23h8c1.38 0 2.5-1.12 2.5-2.5v-17C18 2.12 16.88 1 15.5 1zM11.5 22c-.83 0-1.5-.67-1.5-1.5s.67-1.5 1.5-1.5 1.5.67 1.5 1.5-.67 1.5-1.5 1.5zm4.5-4H7V4h10v14z"/>
        </svg>
      );
    case 'Android':
      return (
        <svg className={iconProps} fill="currentColor" viewBox="0 0 24 24">
          <path d="M17.523 15.3414c-.5511 0-.9993-.4486-.9993-.9997s.4482-.9993.9993-.9993c.5511 0 .9993.4482.9993.9993.0001.5511-.4482.9997-.9993.9997m-11.046 0c-.5511 0-.9993-.4486-.9993-.9997s.4482-.9993.9993-.9993c.5511 0 .9993.4482.9993.9993 0 .5511-.4482.9997-.9993.9997m11.4045-6.02l1.9973-3.4592a.416.416 0 00-.1521-.5676.416.416 0 00-.5676.1521l-2.0223 3.503C15.5902 8.2439 13.8533 7.8508 12 7.8508s-3.5902.3931-5.1367 1.0989L4.841 5.4467a.4161.4161 0 00-.5677-.1521.4157.4157 0 00-.1521.5676l1.9973 3.4592C2.6889 11.1867.3432 14.6589 0 18.761h24c-.3435-4.1021-2.6892-7.5743-6.1185-9.4396"/>
        </svg>
      );
    case 'Linux':
      return (
        <svg className={iconProps} fill="currentColor" viewBox="0 0 24 24">
          <path d="M20.25 7.5L12 4.07L3.75 7.5L12 10.93L20.25 7.5Z"/>
          <path d="M3.75 16.5L12 19.93L20.25 16.5V10.93L12 14.36L3.75 10.93V16.5Z"/>
        </svg>
      );
    case 'Web应用':
      return (
        <svg className={iconProps} fill="currentColor" viewBox="0 0 24 24">
          <path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm-1 17.93c-3.94-.49-7-3.85-7-7.93 0-.62.08-1.21.21-1.79L9 15v1c0 1.1.9 2 2 2v1.93zm6.9-2.54c-.26-.81-1-1.39-1.9-1.39h-1v-3c0-.55-.45-1-1-1H8v-2h2c.55 0 1-.45 1-1V7h2c1.1 0 2-.9 2-2v-.41c2.93 1.19 5 4.06 5 7.41 0 2.08-.8 3.97-2.1 5.39z"/>
        </svg>
      );
    default:
      return (
        <svg className={iconProps} fill="currentColor" viewBox="0 0 24 24">
          <path d="M12 2L2 7v10c0 5.55 3.84 9.74 9 11 5.16-1.26 9-5.45 9-11V7l-10-5z"/>
        </svg>
      );
  }
};

const Downloads: React.FC = () => {
  const downloadOptions = [
    {
      platform: 'macOS',
      version: 'v2.0.0',
      size: '85.2MB',
      requirements: 'macOS 14.0+',
      features: '原生体验、M1/M2支持、触控栏、App Store更新',
      gradient: 'from-gray-600 to-gray-800',
      popular: false
    },
    {
      platform: 'Windows',
      version: 'v2.0.0',
      size: '92.8MB',
      requirements: 'Windows 10 22H2+',
      features: 'Windows 11支持、自动更新、系统集成、多显示器',
      gradient: 'from-blue-600 to-blue-800',
      popular: true
    },
    {
      platform: 'iOS',
      version: 'v2.0.0',
      size: '65.4MB',
      requirements: 'iOS 17.0+',
      features: '原生设计、iPad支持、触控优化、iCloud同步',
      gradient: 'from-blue-500 to-purple-600',
      popular: false
    },
    {
      platform: 'Android',
      version: 'v2.0.0',
      size: '58.7MB',
      requirements: 'Android 13.0+',
      features: 'Material Design、自适应屏幕、多主题、Google同步',
      gradient: 'from-green-500 to-green-700',
      popular: false
    },
    {
      platform: 'Linux',
      version: 'v2.0.0',
      size: '78.3MB',
      requirements: 'Ubuntu 22+/CentOS 9+',
      features: '.deb/.rpm包、命令行支持、源码编译',
      gradient: 'from-orange-600 to-red-600',
      popular: false
    },
    {
      platform: 'Web应用',
      version: 'v2.0.0',
      size: '无需下载',
      requirements: '现代浏览器',
      features: '无需安装、自动更新、PWA支持、离线使用',
      gradient: 'from-purple-500 to-indigo-600',
      popular: false
    }
  ];

  const versionHistory = [
    {
      version: 'v2.0.0',
      date: '2024年12月',
      changes: ['全新 UI 设计', '40% 性能提升', `新增 ${PRODUCT_NAME} 功能`, '修复已知问题']
    },
    {
      version: 'v1.9.5',
      date: '2024年11月',
      changes: ['启动速度优化', '批量管理功能', '网络错误处理改进', '界面细节优化']
    },
    {
      version: 'v1.9.0',
      date: '2024年10月',
      changes: ['跨平台同步', '智能分类功能', '第三方服务集成', '安全性增强']
    }
  ];

  return (
    <div className="min-h-screen pt-20 pb-16 px-4 sm:px-6 lg:px-8">
      <div className="max-w-7xl mx-auto">
        <div className="text-center mb-16">
          <h1 className="text-4xl sm:text-5xl font-bold text-white mb-6">
            下载
            <span className="bg-gradient-to-r from-blue-400 to-purple-500 bg-clip-text text-transparent ml-3">
              {PRODUCT_NAME}
            </span>
          </h1>
          <p className="text-xl text-gray-300 max-w-3xl mx-auto leading-relaxed mb-8">
            支持多个平台，选择适合您的版本，随时随地享受高效的远程桌面体验
          </p>
          <div className="apple-glass-panel apple-glass-sheen p-4 max-w-2xl mx-auto">
            <p className="text-blue-300 text-sm">
              🎉 最新版本 v2.0.0 已发布，全新UI设计，性能提升40%
            </p>
          </div>
        </div>

        <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-8 mb-16">
          {downloadOptions.map((option, index) => (
            <div
              key={index}
              className="relative apple-glass-panel apple-glass-sheen apple-glass-panel-interactive p-6 group"
            >
              {option.popular && (
                <div className="absolute -top-3 left-1/2 transform -translate-x-1/2">
                  <span className="bg-gradient-to-r from-blue-600 to-purple-600 text-white text-xs px-3 py-1 rounded-full font-semibold">
                    热门推荐
                  </span>
                </div>
              )}
              
              <div className={`apple-glass-icon w-16 h-16 bg-gradient-to-br ${option.gradient} flex items-center justify-center text-white mb-4`}>
                <PlatformIcon platform={option.platform} />
              </div>
              
              <h3 className="text-xl font-bold text-white mb-2">{option.platform}</h3>
              <div className="space-y-2 mb-4">
                <div className="flex justify-between text-sm">
                  <span className="text-gray-400">版本：</span>
                  <span className="text-gray-300">{option.version}</span>
                </div>
                <div className="flex justify-between text-sm">
                  <span className="text-gray-400">大小：</span>
                  <span className="text-gray-300">{option.size}</span>
                </div>
                <div className="flex justify-between text-sm">
                  <span className="text-gray-400">系统要求：</span>
                  <span className="text-gray-300 text-right text-xs">{option.requirements}</span>
                </div>
              </div>
              
              <div className="mb-6">
                <p className="text-gray-400 text-xs mb-2">特色功能：</p>
                <p className="text-gray-300 text-xs leading-relaxed">{option.features}</p>
              </div>
              
              <button className={`w-full apple-glass-cta apple-glass-sheen bg-gradient-to-r ${option.gradient} text-white`}>
                立即下载
              </button>
            </div>
          ))}
        </div>

        <div className="mb-16">
          <h2 className="text-3xl font-bold text-white mb-8 text-center">版本更新记录</h2>
          <div className="space-y-6">
            {versionHistory.map((version, index) => (
              <div key={index} className="apple-glass-panel apple-glass-sheen p-6">
                <div className="flex items-center justify-between mb-4">
                  <h3 className="text-xl font-bold text-white">{version.version}</h3>
                  <span className="text-gray-400 text-sm">{version.date}</span>
                </div>
                <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
                  {version.changes.map((change, changeIndex) => (
                    <div key={changeIndex} className="flex items-center text-gray-300">
                      <div className="w-2 h-2 bg-blue-400 rounded-full mr-3"></div>
                      <span className="text-sm">{change}</span>
                    </div>
                  ))}
                </div>
              </div>
            ))}
          </div>
        </div>

        <div className="grid grid-cols-1 md:grid-cols-2 gap-8">
          <div className="apple-glass-panel-strong apple-glass-sheen p-8">
            <h3 className="text-2xl font-bold text-white mb-4">Beta测试计划</h3>
            <p className="text-gray-300 mb-6">
              申请加入Beta测试，提前体验最新功能和特性
            </p>
            <button className="apple-glass-cta apple-glass-cta-primary apple-glass-sheen">
              申请Beta测试
            </button>
          </div>

          <div className="apple-glass-panel-strong apple-glass-sheen p-8">
            <h3 className="text-2xl font-bold text-white mb-4">需要帮助？</h3>
            <p className="text-gray-300 mb-6">
              安装遇到问题？查看帮助文档或联系我们的技术支持团队
            </p>
            <div className="flex gap-4">
              <button className="apple-glass-cta apple-glass-cta-secondary apple-glass-sheen text-sm px-4 py-2">
                查看文档
              </button>
              <button className="apple-glass-cta apple-glass-sheen text-sm px-4 py-2 bg-gradient-to-r from-green-600 to-teal-600 text-white">
                联系支持
              </button>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
};

export default Downloads;
