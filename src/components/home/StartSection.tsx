import { Link } from 'react-router-dom';
import { ArrowUpRight } from 'lucide-react';
import { BlurText } from './BlurText';
import { SectionReveal } from './SectionReveal';
import { CinematicBackdrop } from './CinematicBackdrop';
import { PRODUCT_NAME } from '../../lib/branding';

const steps = [
  { step: '01', title: '识别设备', desc: '从账号、设备与会话建立可验证身份。' },
  { step: '02', title: '择优路径', desc: '按网络状态选择更稳定的连接路线。' },
  { step: '03', title: '进入工作面', desc: '远程桌面、文件与状态统一呈现。' },
];

export function StartSection() {
  return (
    <section className="relative isolate flex min-h-[560px] items-center overflow-hidden bg-black px-4 py-28 sm:px-6 lg:px-8">
      <CinematicBackdrop tone="indigo" topFade={200} bottomFade={200} />

      <div className="relative z-10 mx-auto w-full max-w-4xl text-center">
        <SectionReveal>
          <div className="mb-6 inline-flex rounded-full liquid-glass px-3.5 py-1 font-body text-xs font-medium text-white/85">
            运作方式 · How It Works
          </div>
        </SectionReveal>

        <BlurText
          as="h2"
          text="你指方向，司南通连接。"
          className="mx-auto max-w-3xl font-heading text-4xl italic leading-[0.92] tracking-tight text-white sm:text-5xl lg:text-6xl"
          delay={90}
        />

        <SectionReveal delay={0.15}>
          <p className="mx-auto mt-6 max-w-2xl font-body text-base font-light leading-7 text-white/65">
            说出你要到达的设备和工作面，剩下的交给 {PRODUCT_NAME}——身份校验、路径择优、加密传输、远程接入，几秒之内打通，而不是几天。
          </p>
        </SectionReveal>

        <SectionReveal delay={0.25}>
          <div className="mx-auto mt-12 grid max-w-3xl gap-3 sm:grid-cols-3">
            {steps.map((s) => (
              <div key={s.step} className="rounded-[1.4rem] liquid-glass px-5 py-6 text-left">
                <div className="font-heading text-3xl italic text-white/38">{s.step}</div>
                <h3 className="mt-3 font-body text-sm font-semibold text-white">{s.title}</h3>
                <p className="mt-2 font-body text-[0.8rem] font-light leading-6 text-white/55">{s.desc}</p>
              </div>
            ))}
          </div>
        </SectionReveal>

        <SectionReveal delay={0.35}>
          <Link
            to="/auth?mode=register"
            className="mt-12 inline-flex items-center justify-center gap-2 rounded-full liquid-glass-strong px-6 py-3 font-body text-sm font-semibold text-white"
          >
            立即开始连接
            <ArrowUpRight aria-hidden="true" className="size-4" />
          </Link>
        </SectionReveal>
      </div>
    </section>
  );
}

export default StartSection;
