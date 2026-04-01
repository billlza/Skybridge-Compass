import React from 'react';
import { BRAND_NAME, LEGAL_EMAIL } from '../lib/branding';

const Terms: React.FC = () => {
  return (
    <div className="min-h-screen text-white relative overflow-hidden">
      <div className="relative z-10 container mx-auto px-6 py-20">
        {/* 页面标题 */}
        <div className="text-center mb-16">
          <h1 className="text-4xl font-bold mb-6 bg-gradient-to-r from-purple-400 to-blue-400 bg-clip-text text-transparent">
            服务条款
          </h1>
          <p className="text-lg text-purple-200">
            最后更新时间：2025年9月12日
          </p>
        </div>

        <div className="max-w-4xl mx-auto">
          <div className="bg-purple-900/30 backdrop-blur-sm rounded-2xl p-8 border border-purple-500/20 space-y-8">
            <section>
              <h2 className="text-2xl font-semibold mb-4 text-purple-300">1. 接受条款</h2>
              <p className="text-gray-300 leading-relaxed">
                欢迎使用 {BRAND_NAME} 服务。通过访问或使用我们的服务，您同意受本服务条款的约束。
                如果您不同意这些条款，请不要使用我们的服务。
              </p>
            </section>

            <section>
              <h2 className="text-2xl font-semibold mb-4 text-purple-300">2. 服务描述</h2>
              <p className="text-gray-300 leading-relaxed mb-4">
                {BRAND_NAME} 提供智能网络连接服务，包括但不限于：
              </p>
              <ul className="list-disc list-inside text-gray-300 space-y-2 ml-4">
                <li>高效文件传输服务</li>
                <li>企业级安全连接</li>
                <li>远程硬件级连接</li>
                <li>跨平台支持和移动端服务</li>
                <li>团队协作和连接管理工具</li>
              </ul>
            </section>

            <section>
              <h2 className="text-2xl font-semibold mb-4 text-purple-300">3. 用户责任</h2>
              <p className="text-gray-300 leading-relaxed mb-4">
                使用我们的服务时，您同意：
              </p>
              <ul className="list-disc list-inside text-gray-300 space-y-2 ml-4">
                <li>提供准确、完整的注册信息</li>
                <li>保护您的账户安全和登录凭证</li>
                <li>遵守所有适用的法律法规</li>
                <li>不进行任何可能损害服务或其他用户的行为</li>
                <li>不传输恶意软件、病毒或有害内容</li>
              </ul>
            </section>

            <section>
              <h2 className="text-2xl font-semibold mb-4 text-purple-300">4. 服务可用性</h2>
              <p className="text-gray-300 leading-relaxed">
                我们努力保持服务的持续可用性，但不能保证服务100%无中断。服务可能因维护、升级、
                技术故障或其他因素暂时中断。我们保留随时修改、暂停或终止服务的权利。
              </p>
            </section>

            <section>
              <h2 className="text-2xl font-semibold mb-4 text-purple-300">5. 知识产权</h2>
              <p className="text-gray-300 leading-relaxed mb-4">
                {BRAND_NAME} 服务及相关软件、文档、商标等均受知识产权法保护。您同意：
              </p>
              <ul className="list-disc list-inside text-gray-300 space-y-2 ml-4">
                <li>不复制、修改、分发我们的软件或服务</li>
                <li>不逆向工程或尝试提取源代码</li>
                <li>尊重我们的商标和品牌标识</li>
                <li>仅在授权范围内使用我们的服务</li>
              </ul>
            </section>

            <section>
              <h2 className="text-2xl font-semibold mb-4 text-purple-300">6. 联系信息</h2>
              <p className="text-gray-300 leading-relaxed mb-4">
                如果您对本服务条款有任何疑问，请联系我们：
              </p>
              <div className="p-4 bg-purple-800/30 rounded-lg border border-purple-500/20">
                <p className="text-purple-200">邮箱：{LEGAL_EMAIL}</p>
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

export default Terms;
