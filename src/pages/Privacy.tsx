import React from 'react';
import { BRAND_NAME, PRIVACY_EMAIL } from '../lib/branding';

const Privacy: React.FC = () => {
  return (
    <div className="min-h-screen text-white relative overflow-hidden">
      <div className="relative z-10 container mx-auto px-6 py-20">
        {/* 页面标题 */}
        <div className="text-center mb-16">
          <h1 className="text-4xl font-bold mb-6 bg-gradient-to-r from-purple-400 to-blue-400 bg-clip-text text-transparent">
            隐私政策
          </h1>
          <p className="text-lg text-purple-200">
            最后更新时间：2025年9月12日
          </p>
        </div>

        <div className="max-w-4xl mx-auto">
          <div className="bg-purple-900/30 backdrop-blur-sm rounded-2xl p-8 border border-purple-500/20 space-y-8">
            <section>
              <h2 className="text-2xl font-semibold mb-4 text-purple-300">1. 信息收集</h2>
              <p className="text-gray-300 leading-relaxed mb-4">
                {BRAND_NAME} 致力于保护您的隐私。我们仅收集提供服务所必需的信息，包括但不限于：
              </p>
              <ul className="list-disc list-inside text-gray-300 space-y-2 ml-4">
                <li>用户注册信息（用户名、邮箱地址）</li>
                <li>网络连接日志和性能数据</li>
                <li>设备信息和操作系统版本</li>
                <li>服务使用统计信息</li>
              </ul>
            </section>

            <section>
              <h2 className="text-2xl font-semibold mb-4 text-purple-300">2. 信息使用</h2>
              <p className="text-gray-300 leading-relaxed mb-4">
                我们使用收集的信息用于：
              </p>
              <ul className="list-disc list-inside text-gray-300 space-y-2 ml-4">
                <li>提供和改进 {BRAND_NAME} 服务</li>
                <li>优化网络连接性能</li>
                <li>提供技术支持和客户服务</li>
                <li>发送重要的服务更新通知</li>
                <li>进行安全监控和欺诈防护</li>
              </ul>
            </section>

            <section>
              <h2 className="text-2xl font-semibold mb-4 text-purple-300">3. 数据保护</h2>
              <p className="text-gray-300 leading-relaxed mb-4">
                我们采用业界标准的安全措施保护您的数据：
              </p>
              <ul className="list-disc list-inside text-gray-300 space-y-2 ml-4">
                <li>端到端加密技术保护数据传输</li>
                <li>严格的访问控制和权限管理</li>
                <li>定期安全审计和漏洞检测</li>
                <li>数据备份和灾难恢复机制</li>
              </ul>
            </section>

            <section>
              <h2 className="text-2xl font-semibold mb-4 text-purple-300">4. 信息共享</h2>
              <p className="text-gray-300 leading-relaxed">
                我们承诺不会向第三方出售、交易或转让您的个人信息。仅在以下情况下可能共享必要信息：
              </p>
              <ul className="list-disc list-inside text-gray-300 space-y-2 ml-4 mt-4">
                <li>获得您的明确同意</li>
                <li>遵守法律法规要求</li>
                <li>保护我们的权利和财产安全</li>
                <li>与可信任的服务提供商合作（在严格保密协议约束下）</li>
              </ul>
            </section>

            <section>
              <h2 className="text-2xl font-semibold mb-4 text-purple-300">5. 联系我们</h2>
              <p className="text-gray-300 leading-relaxed">
                如果您对本隐私政策有任何疑问，请联系我们：
              </p>
              <div className="mt-4 p-4 bg-purple-800/30 rounded-lg border border-purple-500/20">
                <p className="text-purple-200">邮箱：{PRIVACY_EMAIL}</p>
                <p className="text-purple-200">电话：400-888-9999</p>
                <p className="text-purple-200">地址：北京市朝阳区望京SOHO T3-2808</p>
              </div>
            </section>
          </div>
        </div>
      </div>
    </div>
  );
};

export default Privacy;
