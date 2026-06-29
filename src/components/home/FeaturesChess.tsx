import type { ReactNode } from 'react';
import { Link } from 'react-router-dom';
import { ArrowUpRight } from 'lucide-react';
import { BlurText } from './BlurText';
import { SectionReveal } from './SectionReveal';
import { ConnectionPreview, RouteOptimizePreview } from './LivePreviews';

interface ChessRow {
  reverse: boolean;
  title: string;
  body: string;
  cta: { label: string; to: string };
  preview: ReactNode;
}

const rows: ChessRow[] = [
  {
    reverse: false,
    title: '为连接而生，为安全而稳。',
    body: '每一条连接路径都是被设计出来的，而不是碰运气。司南为身份、设备与传输分层校验，让远程会话在复杂网络里依然保持低延迟、可追踪、可信任。',
    cta: { label: '了解连接架构', to: '/sinan' },
    preview: <ConnectionPreview />,
  },
  {
    reverse: true,
    title: '它会自动选择更优路径。',
    body: '网络状况每时每刻都在变。司南持续评估直连、中继与跨区线路的延迟、丢包与稳定性，并在毫秒之间切换到更优路径——无需你手动调参，连接只会越用越顺。',
    cta: { label: '查看工作原理', to: '/features' },
    preview: <RouteOptimizePreview />,
  },
];

export function FeaturesChess() {
  return (
    <section className="relative isolate overflow-hidden bg-black px-4 pb-12 pt-24 sm:px-6 lg:px-8">
      <div className="absolute inset-0 z-0 bg-[radial-gradient(circle_at_82%_8%,rgba(45,212,191,0.12),transparent_34%),radial-gradient(circle_at_10%_60%,rgba(129,140,248,0.12),transparent_36%)]" />

      <div className="relative z-10 mx-auto max-w-7xl">
        <SectionReveal className="mx-auto max-w-3xl text-center">
          <div className="mb-5 inline-flex rounded-full liquid-glass px-4 py-1.5 font-body text-xs font-medium text-white/80">
            产品能力 · Capabilities
          </div>
          <BlurText
            as="h2"
            text="专业级连接，零配置复杂度。"
            className="font-heading text-4xl italic leading-[0.95] text-white sm:text-5xl lg:text-6xl"
            delay={90}
          />
          <p className="mt-6 font-body text-base font-light leading-7 text-white/58">
            把远程桌面、文件传输、可信设备与智能路由收束到同一个克制的入口。复杂的连接逻辑由司南承担，你只需要专注真正的工作。
          </p>
        </SectionReveal>

        <div className="mt-20 flex flex-col gap-20 lg:gap-28">
          {rows.map((row) => (
            <div
              key={row.title}
              className={`flex flex-col gap-10 lg:flex-row lg:items-center lg:gap-16 ${
                row.reverse ? 'lg:flex-row-reverse' : ''
              }`}
            >
              <SectionReveal className="flex-1">
                <BlurText
                  as="h3"
                  text={row.title}
                  className="font-heading text-3xl italic leading-[0.98] text-white sm:text-4xl lg:text-[2.85rem]"
                  delay={70}
                />
                <p className="mt-6 max-w-xl font-body text-base font-light leading-7 text-white/60">{row.body}</p>
                <Link
                  to={row.cta.to}
                  className="mt-8 inline-flex items-center gap-2 rounded-full liquid-glass-strong px-5 py-3 font-body text-sm font-semibold text-white"
                >
                  {row.cta.label}
                  <ArrowUpRight aria-hidden="true" className="size-4" />
                </Link>
              </SectionReveal>

              <SectionReveal delay={0.12} className="min-h-[340px] flex-1">
                {row.preview}
              </SectionReveal>
            </div>
          ))}
        </div>
      </div>
    </section>
  );
}

export default FeaturesChess;
