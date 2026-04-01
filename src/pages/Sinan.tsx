import React from 'react';
import { motion } from 'motion/react';
import { PRODUCT_NAME } from '../lib/branding';

const Sinan: React.FC = () => {
  return (
    <div className="min-h-screen text-white relative overflow-hidden font-sans">
      {/* 
        背景层：由 App.tsx 统一渲染 StarryBackground
        此处不再重复渲染，避免双重叠加导致的性能问题和视觉异常
      */}

      <div className="relative z-10 container mx-auto px-6 py-24">
        {/* 页面标题 */}
        <motion.div 
          initial={{ opacity: 0, y: 20 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.8 }}
          className="text-center mb-20"
        >
          <div className="inline-block p-1 rounded-full bg-gradient-to-r from-teal-500/20 to-amber-500/20 border border-teal-500/30 backdrop-blur-md mb-6">
            <span className="px-4 py-1 text-sm font-medium bg-gradient-to-r from-teal-300 to-amber-200 bg-clip-text text-transparent">
              传承 · 创新 · 引领
            </span>
          </div>
          <h1 className="text-5xl md:text-7xl font-bold mb-8 text-white tracking-tight">
            云桥<span className="text-transparent bg-clip-text bg-gradient-to-r from-teal-400 to-amber-400">司南</span>
          </h1>
          <p className="text-xl text-slate-300 max-w-3xl mx-auto font-light leading-relaxed">
            融合<span className="text-amber-300 font-medium mx-1">东方智慧</span>与
            <span className="text-teal-300 font-medium mx-1">现代科技</span>，
            为您在数字星海中指引方向
          </p>
        </motion.div>

        {/* 品牌故事板块 */}
        <section className="mb-24">
          <div className="max-w-5xl mx-auto">
            <div className="grid md:grid-cols-2 gap-16 items-center">
              <motion.div 
                initial={{ opacity: 0, x: -30 }}
                whileInView={{ opacity: 1, x: 0 }}
                transition={{ duration: 0.8 }}
                viewport={{ once: true }}
                className="space-y-8"
              >
                <div className="relative group">
                  <div className="absolute -inset-1 bg-gradient-to-r from-amber-500/20 to-teal-500/20 rounded-2xl blur opacity-25 group-hover:opacity-50 transition duration-500"></div>
                  <div className="relative bg-slate-900/50 backdrop-blur-xl rounded-2xl p-8 border border-white/10 hover:border-amber-500/30 transition-colors duration-300">
                    <h3 className="text-2xl font-semibold mb-4 text-amber-100 flex items-center">
                      <span className="w-8 h-8 rounded-lg bg-amber-500/10 flex items-center justify-center mr-3 text-lg border border-amber-500/20">📜</span>
                      司南之智
                    </h3>
                    <p className="text-slate-300 leading-relaxed">
                      "司南"作为中国四大发明之一，不仅是物理方位的指引者，更是中华民族探索未知的精神图腾。其"磁石立极，勺指乾坤"的智慧，穿越千年，依然熠熠生辉。
                    </p>
                  </div>
                </div>

                <div className="relative group">
                  <div className="absolute -inset-1 bg-gradient-to-r from-teal-500/20 to-blue-500/20 rounded-2xl blur opacity-25 group-hover:opacity-50 transition duration-500"></div>
                  <div className="relative bg-slate-900/50 backdrop-blur-xl rounded-2xl p-8 border border-white/10 hover:border-teal-500/30 transition-colors duration-300">
                    <h3 className="text-2xl font-semibold mb-4 text-teal-100 flex items-center">
                      <span className="w-8 h-8 rounded-lg bg-teal-500/10 flex items-center justify-center mr-3 text-lg border border-teal-500/20">🚀</span>
                      云桥之技
                    </h3>
                    <p className="text-slate-300 leading-relaxed">
                      承袭司南内核，云桥以量子加密与智能路由为"磁石"，构建新一代数字罗盘。在复杂的数据洪流中，为用户规划最优路径，实现毫秒级的精准连接。
                    </p>
                  </div>
                </div>
              </motion.div>

              <motion.div 
                initial={{ opacity: 0, x: 30 }}
                whileInView={{ opacity: 1, x: 0 }}
                transition={{ duration: 0.8 }}
                viewport={{ once: true }}
                className="text-center relative"
              >
                {/* 司南图形可视化 */}
                <div className="relative w-80 h-80 mx-auto">
                  {/* 外圈罗盘 */}
                  <div className="absolute inset-0 rounded-full border border-slate-700/50 flex items-center justify-center">
                    <div className="w-[90%] h-[90%] rounded-full border border-slate-800/50 border-dashed animate-[spin_60s_linear_infinite]"></div>
                  </div>
                  
                  {/* 中间发光层 */}
                  <div className="absolute inset-0 bg-gradient-to-br from-teal-500/10 to-amber-500/10 rounded-full blur-3xl animate-pulse"></div>
                  
                  {/* 核心图标 */}
                  <div className="relative w-full h-full flex items-center justify-center">
                    <div className="w-48 h-48 bg-slate-900/80 backdrop-blur-md rounded-full border border-white/10 flex items-center justify-center shadow-2xl shadow-teal-900/20">
                      <span className="text-7xl filter drop-shadow-[0_0_15px_rgba(20,184,166,0.5)]">🧭</span>
                    </div>
                  </div>
                  
                  {/* 装饰粒子 */}
                  <div className="absolute top-0 left-1/2 -translate-x-1/2 w-1 h-8 bg-gradient-to-b from-transparent to-teal-500/50"></div>
                  <div className="absolute bottom-0 left-1/2 -translate-x-1/2 w-1 h-8 bg-gradient-to-t from-transparent to-amber-500/50"></div>
                  <div className="absolute left-0 top-1/2 -translate-y-1/2 w-8 h-1 bg-gradient-to-r from-transparent to-slate-500/50"></div>
                  <div className="absolute right-0 top-1/2 -translate-y-1/2 w-8 h-1 bg-gradient-to-l from-transparent to-slate-500/50"></div>
                </div>
                <p className="mt-8 text-teal-200/80 font-mono tracking-widest text-sm uppercase">Heritage & Innovation</p>
              </motion.div>
            </div>
          </div>
        </section>

        {/* 核心理念 */}
        <section className="mb-24">
          <div className="max-w-6xl mx-auto">
            <h2 className="text-3xl font-bold text-center mb-16 text-transparent bg-clip-text bg-gradient-to-r from-teal-100 to-white">
              核心理念
            </h2>
            <div className="grid md:grid-cols-3 gap-8">
              {[
                {
                  icon: "🌟",
                  title: "精准",
                  desc: "毫秒级路由择优，如司南之定极",
                  color: "from-amber-500/20 to-orange-500/5",
                  border: "hover:border-amber-500/30"
                },
                {
                  icon: "🛡️",
                  title: "安全",
                  desc: "银行级加密隧道，护数据之周全",
                  color: "from-teal-500/20 to-blue-500/5",
                  border: "hover:border-teal-500/30"
                },
                {
                  icon: "⚡",
                  title: "极速",
                  desc: "全球节点覆盖，破时空之阻隔",
                  color: "from-emerald-500/20 to-teal-500/5",
                  border: "hover:border-emerald-500/30"
                }
              ].map((item, index) => (
                <motion.div
                  key={index}
                  whileHover={{ y: -5 }}
                  className={`bg-gradient-to-br ${item.color} backdrop-blur-sm rounded-2xl p-8 border border-white/5 ${item.border} transition-all duration-300 group`}
                >
                  <div className="text-4xl mb-6 group-hover:scale-110 transition-transform duration-300">{item.icon}</div>
                  <h3 className="text-xl font-bold mb-3 text-white">{item.title}</h3>
                  <p className="text-slate-400 group-hover:text-slate-200 transition-colors">
                    {item.desc}
                  </p>
                </motion.div>
              ))}
            </div>
          </div>
        </section>

        {/* 品牌定位 */}
        <section className="mb-24">
          <div className="max-w-4xl mx-auto relative">
            <div className="absolute inset-0 bg-gradient-to-r from-teal-500/10 via-amber-500/5 to-teal-500/10 blur-3xl rounded-full"></div>
            <div className="relative bg-slate-900/60 backdrop-blur-xl rounded-3xl p-12 border border-white/10 text-center overflow-hidden">
              <div className="absolute top-0 left-0 w-full h-1 bg-gradient-to-r from-transparent via-teal-500/50 to-transparent"></div>
              
              <h2 className="text-3xl md:text-4xl font-bold mb-8 text-white">
                智能连接的<span className="text-teal-400">领航者</span>
              </h2>
              <p className="text-lg text-slate-300 leading-relaxed mb-10 max-w-2xl mx-auto">
                {PRODUCT_NAME} 不仅是技术的创新者，更是数字文明的摆渡人。
                我们将持续探索连接的边界，让每一次数据的交互都充满温度与智慧。
              </p>
              
              <div className="flex flex-wrap justify-center gap-4">
                {['智能导航', '全球互联', '量子安全', '边缘计算'].map((tag, i) => (
                  <span key={i} className="px-6 py-2 bg-white/5 rounded-full text-slate-300 border border-white/10 text-sm font-medium hover:bg-white/10 hover:border-teal-500/30 hover:text-teal-200 transition-all cursor-default">
                    {tag}
                  </span>
                ))}
              </div>
            </div>
          </div>
        </section>

        {/* CTA */}
        <div className="text-center pb-10">
          <a 
            href="/contact" 
            className="group relative inline-flex items-center px-8 py-4 bg-slate-900 text-white font-semibold rounded-full overflow-hidden transition-all duration-300 hover:shadow-[0_0_20px_rgba(20,184,166,0.3)] border border-teal-500/30 hover:border-teal-400"
          >
            <div className="absolute inset-0 w-full h-full bg-gradient-to-r from-teal-500/20 to-amber-500/20 opacity-0 group-hover:opacity-100 transition-opacity duration-300"></div>
            <span className="relative z-10 mr-2 group-hover:text-teal-100 transition-colors">开启探索之旅</span>
            <svg className="relative z-10 w-5 h-5 group-hover:translate-x-1 transition-transform" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M17 8l4 4m0 0l-4 4m4-4H3" />
            </svg>
          </a>
        </div>
      </div>
    </div>
  );
};

export default Sinan;
