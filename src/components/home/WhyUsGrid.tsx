import { Compass, Gauge, ShieldCheck, Zap } from 'lucide-react';
import { BlurText } from './BlurText';
import { SectionReveal } from './SectionReveal';

const reasons = [
  {
    icon: Zap,
    title: '数秒接入',
    body: '从身份校验到打通工作面只需几秒钟，而不是反复排查网络。等待，从来不该是一种工作方式。',
  },
  {
    icon: Compass,
    title: '克制的设计',
    body: '连接、权限与传输的每个状态都被认真对待、清晰可读。高级感来自秩序，而非堆叠的装饰。',
  },
  {
    icon: Gauge,
    title: '为稳定而调',
    body: '基于实时网络数据持续择优路径。连接质量可度量、可复现，结果经得起检验。',
  },
  {
    icon: ShieldCheck,
    title: '默认安全',
    body: '端到端加密、可信设备、分层校验全部标配。关键失败路径保持显式，不靠静默兜底掩盖异常。',
  },
];

export function WhyUsGrid() {
  return (
    <section className="relative isolate overflow-hidden bg-black px-4 pb-20 pt-24 sm:px-6 lg:px-8">
      <div className="absolute inset-0 z-0 bg-[radial-gradient(circle_at_12%_20%,rgba(45,212,191,0.12),transparent_32%),radial-gradient(circle_at_88%_30%,rgba(129,140,248,0.14),transparent_34%)]" />

      <div className="relative z-10 mx-auto max-w-7xl">
        <SectionReveal className="mx-auto max-w-3xl text-center">
          <div className="mb-5 inline-flex rounded-full liquid-glass px-4 py-1.5 font-body text-xs font-medium text-white/80">
            为什么选择司南 · Why Us
          </div>
          <BlurText
            as="h2"
            text="差别，体现在每一个细节里。"
            className="font-heading text-4xl italic leading-[0.95] text-white sm:text-5xl lg:text-6xl"
            delay={90}
          />
          <p className="mt-6 font-body text-base font-light leading-7 text-white/58">
            同样是远程连接，司南选择把复杂藏在系统里、把清晰留给用户。这不是更花哨的工具，而是更值得信任的连接方式。
          </p>
        </SectionReveal>

        <div className="mt-16 grid gap-5 md:grid-cols-2 lg:grid-cols-4">
          {reasons.map((item, index) => {
            const Icon = item.icon;
            return (
              <SectionReveal key={item.title} delay={index * 0.08} className="liquid-glass h-full rounded-[1.75rem] p-6">
                <div className="mb-8 inline-flex size-10 items-center justify-center rounded-full liquid-glass-strong text-white">
                  <Icon aria-hidden="true" className="size-5" />
                </div>
                <h3 className="font-body text-lg font-semibold text-white">{item.title}</h3>
                <p className="mt-4 font-body text-sm font-light leading-6 text-white/58">{item.body}</p>
              </SectionReveal>
            );
          })}
        </div>
      </div>
    </section>
  );
}

export default WhyUsGrid;
