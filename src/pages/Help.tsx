import React, { useState } from 'react';
import { PRODUCT_NAME, SUPPORT_EMAIL } from '../lib/branding';

const Help: React.FC = () => {
  const [activeCategory, setActiveCategory] = useState('common');
  const [expandedFaq, setExpandedFaq] = useState<number | null>(null);

  const categories = {
    common: '常见问题',
    technical: '技术支持',
    account: '账户管理',
    billing: '付费相关'
  };

  const faqs = {
    common: [
      {
        question: `什么是${PRODUCT_NAME}？`,
        answer: `${PRODUCT_NAME} 是 skybridge.com 旗下的智能连接解决方案，融合导航式产品体验与现代 AI 技术，为用户提供高效、安全、稳定的远程连接服务。`
      },
      {
        question: `${PRODUCT_NAME}支持哪些操作系统？`,
        answer: '我们支持 macOS 14.0+、Windows 10 22H2+、iOS 17.0+、Android 13.0+、Linux（Ubuntu 22+/CentOS 9+），以及基于现代浏览器的 Web 应用。'
      },
      {
        question: `如何开始使用${PRODUCT_NAME}？`,
        answer: '您只需访问我们的下载页面，选择适合您操作系统的客户端，安装后使用星云账号登录即可开始使用。'
      },
      {
        question: `${PRODUCT_NAME}是否免费？`,
        answer: '我们提供免费的基础版本和多种付费专业版本。免费版本包含基本的连接功能，付费版本提供更多高级特性和更好的性能。'
      }
    ],
    technical: [
      {
        question: '连接速度较慢如何解决？',
        answer: '请检查您的网络环境，尝试切换到不同的服务器节点，或在设置中启用智能网络优化功能。如问题持续存在，请联系技术支持。'
      },
      {
        question: '如何配置企业级安全设置？',
        answer: '在应用设置中找到“安全选项”，您可以启用端到端加密、设置访问权限、配置身份认证方式等。详细配置指南请查看用户手册。'
      },
      {
        question: '支持API集成吗？',
        answer: '是的，我们提供丰富的REST API和SDK，支持与您现有的系统集成。开发者文档和API密钥可在用户中心获取。'
      },
      {
        question: '数据备份如何工作？',
        answer: `${PRODUCT_NAME} 提供自动数据备份功能，您的配置和重要数据会定期备份到安全的云存储中，支持一键恢复。`
      }
    ],
    account: [
      {
        question: '如何创建星云账号？',
        answer: '访问注册页面，选择您的守护星座，设置用户名和星云密钥，验证邮箱后即可完成注册。'
      },
      {
        question: '忘记密码怎么办？',
        answer: '在登录页面点击“忘记密码”，输入注册邮箱，我们会发送重置密码的链接到您的邮箱。'
      },
      {
        question: '如何修改账户信息？',
        answer: '登录后进入用户中心，在“账户设置”中可以修改您的个人信息、联系方式和偏好设置。'
      },
      {
        question: '可以同时在多个设备上使用吗？',
        answer: '是的，一个账号可以在多个设备上同时登录使用，具体设备数量限制根据您的套餐类型而定。'
      }
    ],
    billing: [
      {
        question: '有哪些付费套餐？',
        answer: '我们提供个人版、专业版和企业版三种付费套餐，价格从每月29元起，不同套餐包含不同的功能和服务限制。'
      },
      {
        question: '支持哪些支付方式？',
        answer: '支持支付宝、微信支付、银行卡支付以及PayPal等国际支付方式，企业用户还支持对公转账。'
      },
      {
        question: '可以申请退款吗？',
        answer: '我们提供7天无理由退款保障。如果您在购买后7天内对服务不满意，可以申请全额退款。'
      },
      {
        question: '如何升级或降级套餐？',
        answer: '在用户中心的“订阅管理”中可以随时升级或降级您的套餐，费用变化会在下个计费周期生效。'
      }
    ]
  };

  return (
    <div className="min-h-screen text-white relative overflow-hidden">
      <div className="relative z-10 container mx-auto px-6 py-20">
        {/* 页面标题 */}
        <div className="text-center mb-16">
          <h1 className="text-4xl font-bold mb-6 bg-gradient-to-r from-purple-400 to-blue-400 bg-clip-text text-transparent">
            帮助中心
          </h1>
          <p className="text-lg text-purple-200">
            24/7技术支持，让您的使用更顺畅
          </p>
        </div>

        <div className="max-w-6xl mx-auto">
          {/* 紧急联系方式 */}
          <div className="apple-glass-panel-strong apple-glass-sheen p-6 mb-12">
            <div className="flex items-center justify-between flex-wrap gap-6">
              <div className="flex items-center space-x-4">
                <div className="text-3xl">🚨</div>
                <div>
                  <h3 className="text-xl font-semibold text-red-200">紧急技术支持</h3>
                  <p className="text-red-300">7×24小时在线支持</p>
                </div>
              </div>
              <div className="flex space-x-4">
                <a 
                  href="tel:400-888-9999" 
                  className="apple-glass-cta apple-glass-sheen bg-red-600/80 text-white px-6 py-2"
                >
                  400-888-9999
                </a>
                <button className="apple-glass-cta apple-glass-sheen bg-purple-600/80 text-white px-6 py-2">
                  在线客服
                </button>
              </div>
            </div>
          </div>

          <div className="grid lg:grid-cols-4 gap-8">
            {/* 分类导航 */}
            <div className="lg:col-span-1">
              <div className="apple-glass-panel apple-glass-sheen p-6 sticky top-8">
                <h3 className="text-lg font-semibold mb-4 text-purple-200">帮助分类</h3>
                <nav className="space-y-2">
                  {Object.entries(categories).map(([key, label]) => (
                    <button
                      key={key}
                      onClick={() => setActiveCategory(key)}
                      className={`w-full text-left px-4 py-2 rounded-lg transition-colors ${
                        activeCategory === key
                          ? 'bg-purple-600/50 text-white'
                          : 'text-gray-300 hover:bg-purple-700/30'
                      }`}
                    >
                      {label}
                    </button>
                  ))}
                </nav>
              </div>
            </div>

            {/* FAQ内容 */}
            <div className="lg:col-span-3">
              <div className="apple-glass-panel apple-glass-sheen p-8">
                <h2 className="text-2xl font-semibold mb-6 text-purple-300">
                  {categories[activeCategory as keyof typeof categories]}
                </h2>
                <div className="space-y-4">
                  {faqs[activeCategory as keyof typeof faqs].map((faq, index) => (
                    <div key={index} className="border border-purple-500/20 rounded-lg overflow-hidden">
                      <button
                        onClick={() => setExpandedFaq(expandedFaq === index ? null : index)}
                        className="w-full text-left px-6 py-4 bg-purple-800/20 hover:bg-purple-800/30 transition-colors flex items-center justify-between"
                      >
                        <span className="font-medium text-purple-200">{faq.question}</span>
                        <svg 
                          className={`w-5 h-5 text-purple-300 transform transition-transform ${
                            expandedFaq === index ? 'rotate-180' : ''
                          }`}
                          fill="none" 
                          stroke="currentColor" 
                          viewBox="0 0 24 24"
                        >
                          <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M19 9l-7 7-7-7" />
                        </svg>
                      </button>
                      {expandedFaq === index && (
                        <div className="px-6 py-4 bg-purple-900/20 border-t border-purple-500/20">
                          <p className="text-gray-300 leading-relaxed">{faq.answer}</p>
                        </div>
                      )}
                    </div>
                  ))}
                </div>
              </div>

              {/* 联系支持 */}
              <div className="mt-8 apple-glass-panel-strong apple-glass-sheen p-8">
                <h3 className="text-xl font-semibold mb-4 text-purple-200">找不到答案？</h3>
                <p className="text-gray-300 mb-6">
                  我们的技术支持团队随时为您提供帮助，无论是技术问题、账户问题还是其他疑问。
                </p>
                <div className="grid md:grid-cols-2 gap-6">
                  <div className="apple-glass-panel apple-glass-sheen p-6">
                    <h4 className="font-semibold mb-2 text-purple-200">📧 邮件支持</h4>
                    <p className="text-gray-300 mb-3">{SUPPORT_EMAIL}</p>
                    <p className="text-sm text-purple-300">通常24小时内回复</p>
                  </div>
                  <div className="apple-glass-panel apple-glass-sheen p-6">
                    <h4 className="font-semibold mb-2 text-blue-200">💬 在线客服</h4>
                    <p className="text-gray-300 mb-3">实时聊天支持</p>
                    <p className="text-sm text-blue-300">工作日 9:00-21:00</p>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
};

export default Help;
