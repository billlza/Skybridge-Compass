import { SectionReveal } from './SectionReveal';
import { CinematicBackdrop } from './CinematicBackdrop';

const stats = [
  { value: '99.95%', label: '连接可用性' },
  { value: '28ms', label: '区域内平均延迟' },
  { value: '200+', label: '全球加速节点' },
  { value: '10M+', label: '已建立的安全会话' },
];

export function StatsSection() {
  return (
    <section className="relative isolate flex items-center overflow-hidden bg-black px-4 py-24 sm:px-6 lg:px-8">
      {/* desaturated (black & white) cinematic background */}
      <CinematicBackdrop desaturate tone="mono" topFade={200} bottomFade={200} showRealtimeField={false} />

      <div className="relative z-10 mx-auto w-full max-w-6xl">
        <SectionReveal className="liquid-glass rounded-[2rem] p-10 sm:p-14 lg:p-16">
          <div className="grid gap-10 sm:grid-cols-2 lg:grid-cols-4">
            {stats.map((stat, index) => (
              <SectionReveal key={stat.label} delay={index * 0.1} className="text-center sm:text-left">
                <div className="font-heading text-4xl italic leading-none text-white sm:text-5xl lg:text-6xl">
                  {stat.value}
                </div>
                <div className="mt-3 font-body text-sm font-light text-white/60">{stat.label}</div>
              </SectionReveal>
            ))}
          </div>
        </SectionReveal>
      </div>
    </section>
  );
}

export default StatsSection;
