import { Link } from 'react-router-dom';
import { ArrowUpRight } from 'lucide-react';
import { BlurText } from './BlurText';
import { SectionReveal } from './SectionReveal';
import { CinematicBackdrop } from './CinematicBackdrop';
import { BRAND_NAME } from '../../lib/branding';

const footerLinks = [
  { label: '隐私政策', to: '/privacy' },
  { label: '服务条款', to: '/terms' },
  { label: '联系我们', to: '/contact' },
];

export function CtaFooter() {
  return (
    <section className="relative isolate flex min-h-[640px] flex-col justify-center overflow-hidden bg-black px-4 py-28 sm:px-6 lg:px-8">
      <CinematicBackdrop tone="teal" topFade={220} bottomFade={120} />

      <div className="relative z-10 mx-auto w-full max-w-5xl text-center">
        <BlurText
          as="h2"
          text="你的下一次连接，从这里开始。"
          className="mx-auto max-w-4xl font-heading text-5xl italic leading-[0.9] text-white sm:text-6xl lg:text-7xl"
          delay={80}
        />

        <SectionReveal delay={0.15}>
          <p className="mx-auto mt-7 max-w-2xl font-body text-base font-light leading-7 text-white/65">
            预约一次演示，看看东方司南的方向感与现代安全连接结合会是什么样子。没有承诺，没有压力，只有可能性。
          </p>
        </SectionReveal>

        <SectionReveal delay={0.25}>
          <div className="mt-10 flex flex-col items-center justify-center gap-3 sm:flex-row">
            <Link
              to="/contact"
              className="inline-flex items-center justify-center gap-2 rounded-full liquid-glass-strong px-6 py-3 font-body text-sm font-semibold text-white"
            >
              预约演示
              <ArrowUpRight aria-hidden="true" className="size-4" />
            </Link>
            <Link
              to="/features"
              className="inline-flex items-center justify-center gap-2 rounded-full bg-white px-6 py-3 font-body text-sm font-semibold text-black transition hover:bg-white/90"
            >
              查看方案
            </Link>
          </div>
        </SectionReveal>

        <div className="mt-28 border-t border-white/10 pt-8">
          <div className="flex flex-col items-center justify-between gap-4 sm:flex-row">
            <p className="font-body text-xs text-white/40">© 2026 {BRAND_NAME} · 保留所有权利。</p>
            <div className="flex items-center gap-6">
              {footerLinks.map((link) => (
                <Link key={link.to} to={link.to} className="font-body text-xs text-white/40 transition hover:text-white/70">
                  {link.label}
                </Link>
              ))}
            </div>
          </div>
        </div>
      </div>
    </section>
  );
}

export default CtaFooter;
