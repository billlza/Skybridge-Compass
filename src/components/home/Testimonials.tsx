import { BlurText } from './BlurText';
import { SectionReveal } from './SectionReveal';

const testimonials = [
  {
    quote: '迁移到司南之后，跨国团队的远程桌面终于不再卡顿。连接稳定得让人几乎忘记它的存在。',
    name: '陈思远',
    role: 'CTO · 澜图科技',
  },
  {
    quote: '我们最看重的是它对失败路径的诚实——异常会被清楚地暴露出来，而不是假装一切正常。',
    name: '马维',
    role: '基础设施负责人 · 弧线网络',
  },
  {
    quote: '从设备识别到加密传输，司南把复杂的连接过程讲清楚了。这是真正的产品级体验。',
    name: '沃伊',
    role: '安全总监 · 赫力克斯',
  },
];

export function Testimonials() {
  return (
    <section className="relative isolate overflow-hidden bg-black px-4 pb-24 pt-20 sm:px-6 lg:px-8">
      <div className="absolute inset-0 z-0 bg-[radial-gradient(circle_at_50%_0%,rgba(99,102,241,0.12),transparent_38%)]" />

      <div className="relative z-10 mx-auto max-w-7xl">
        <SectionReveal className="mx-auto max-w-3xl text-center">
          <div className="mb-5 inline-flex rounded-full liquid-glass px-4 py-1.5 font-body text-xs font-medium text-white/80">
            客户怎么说 · What They Say
          </div>
          <BlurText
            as="h2"
            text="不必只听我们说。"
            className="font-heading text-4xl italic leading-[0.95] text-white sm:text-5xl lg:text-6xl"
            delay={100}
          />
        </SectionReveal>

        <div className="mt-16 grid gap-6 md:grid-cols-3">
          {testimonials.map((item, index) => (
            <SectionReveal key={item.name} delay={index * 0.1} className="liquid-glass flex h-full flex-col rounded-[1.75rem] p-8">
              <p className="font-body text-base font-light italic leading-7 text-white/82">“{item.quote}”</p>
              <div className="mt-8 border-t border-white/10 pt-5">
                <div className="font-body text-sm font-medium text-white">{item.name}</div>
                <div className="mt-1 font-body text-xs font-light text-white/50">{item.role}</div>
              </div>
            </SectionReveal>
          ))}
        </div>
      </div>
    </section>
  );
}

export default Testimonials;
