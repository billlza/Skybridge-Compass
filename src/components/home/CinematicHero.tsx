import { Link } from 'react-router-dom';
import { motion, useReducedMotion } from 'motion/react';
import { ArrowUpRight, Play, ShieldCheck, Route, MonitorUp } from 'lucide-react';
import { PRODUCT_NAME } from '../../lib/branding';
import { HeroVideoBackdrop } from './HeroVideoBackdrop';
import { NebulaField } from './NebulaField';
import { BlurText } from './BlurText';

interface CinematicHeroProps {
  isAuthenticated: boolean;
  displayName: string;
}

const signalItems = [
  { label: '可信设备', value: 'Identity' },
  { label: '智能路由', value: 'Route' },
  { label: '跨端连接', value: 'Bridge' },
];

const proofItems = [
  {
    icon: ShieldCheck,
    label: '端到端保护',
    description: '身份、设备和传输路径分层校验。',
  },
  {
    icon: Route,
    label: '路径择优',
    description: '在复杂网络中选择更稳定的连接路线。',
  },
  {
    icon: MonitorUp,
    label: '远程工作面',
    description: '文件、桌面和设备状态集中到一个入口。',
  },
];

const trustedBy = ['金融科技', '智能制造', '在线教育', '跨境协作', '政企云'];

export function CinematicHero({ isAuthenticated, displayName }: CinematicHeroProps) {
  const prefersReducedMotion = useReducedMotion();

  const primaryCta = isAuthenticated
    ? { to: '/sinan', label: `进入 ${PRODUCT_NAME}` }
    : { to: '/auth?mode=register', label: '创建星云账号' };

  const secondaryCta = isAuthenticated
    ? { to: '/downloads', label: '下载客户端' }
    : { to: '/sinan', label: '观看影片' };

  const fadeIn = (delay: number) =>
    prefersReducedMotion
      ? {}
      : {
          initial: { opacity: 0, y: 20, filter: 'blur(10px)' },
          animate: { opacity: 1, y: 0, filter: 'blur(0px)' },
          transition: { duration: 0.6, delay, ease: [0.22, 1, 0.36, 1] as [number, number, number, number] },
        };

  return (
    <section className="cinematic-hero relative min-h-[900px] overflow-hidden px-4 pb-20 pt-28 sm:px-6 lg:px-8">
      <HeroVideoBackdrop posterSrc="/media/sinan-hero-poster.jpg" videoSrc="/media/sinan-hero.mp4" />
      <NebulaField shouldAnimate={prefersReducedMotion !== true} />

      <div className="relative z-10 mx-auto flex min-h-[780px] max-w-7xl flex-col">
        <div className="max-w-5xl pt-12 sm:pt-16 lg:pt-20">
          {/* intro badge pill */}
          <motion.div className="mb-7 inline-flex items-center gap-2.5 rounded-full liquid-glass px-1 py-1 pr-4" {...fadeIn(0.1)}>
            <span className="rounded-full bg-white px-3 py-1 font-body text-xs font-semibold text-black">全新</span>
            <span className="font-body text-xs font-medium text-white/85">AI 智能连接路由，现已上线。</span>
          </motion.div>

          {/* BlurText hero heading */}
          <h1 className="max-w-5xl font-heading text-[3.6rem] font-normal italic leading-[0.92] text-white sm:text-[5rem] lg:text-[5.8rem] xl:text-[6.25rem]">
            <BlurText as="span" text="云桥司南" delay={120} startDelay={0.1} className="block" animateBy="chars" />
            <span className="block text-white/72">
              <BlurText as="span" text="指引你的远程工作面" delay={70} startDelay={0.6} animateBy="chars" />
            </span>
          </h1>

          <motion.p
            className="mt-8 max-w-2xl font-body text-base font-light leading-7 text-white/68 sm:text-lg"
            {...fadeIn(0.8)}
          >
            融合东方司南的方向感与现代安全连接技术，把远程桌面、文件传输、可信设备和智能路由收束成一个克制、可靠的数字入口。
          </motion.p>

          <motion.div className="mt-9 flex flex-col gap-3 sm:flex-row sm:items-center" {...fadeIn(1.1)}>
            <Link
              to={primaryCta.to}
              className="liquid-glass-strong inline-flex items-center justify-center gap-2 rounded-full px-6 py-3 font-body text-sm font-semibold text-white"
            >
              {primaryCta.label}
              <ArrowUpRight aria-hidden="true" className="size-4" />
            </Link>
            <Link
              to={secondaryCta.to}
              className="inline-flex items-center justify-center gap-2 rounded-full px-6 py-3 font-body text-sm font-medium text-white/78 transition hover:text-white"
            >
              <Play aria-hidden="true" className="size-4 fill-current" />
              {secondaryCta.label}
            </Link>
          </motion.div>

          {isAuthenticated ? (
            <div className="mt-6 inline-flex rounded-full liquid-glass px-4 py-2 font-body text-sm text-white/72">
              欢迎回来，{displayName}
            </div>
          ) : null}

          {/* trusted-by bar */}
          <motion.div className="mt-12 flex flex-col gap-4 sm:flex-row sm:items-center sm:gap-8" {...fadeIn(1.35)}>
            <div className="inline-flex w-fit rounded-full liquid-glass px-4 py-1.5 font-body text-xs text-white/70">
              受这些团队信赖
            </div>
            <div className="flex flex-wrap items-center gap-x-8 gap-y-2">
              {trustedBy.map((name) => (
                <span key={name} className="font-heading text-xl italic text-white/55 sm:text-2xl">
                  {name}
                </span>
              ))}
            </div>
          </motion.div>
        </div>

        <div className="mt-auto grid gap-4 pt-16 lg:grid-cols-[1fr_1.35fr] lg:items-end">
          <div className="liquid-glass rounded-[1.5rem] p-5">
            <p className="font-body text-xs uppercase text-white/42">Live signals</p>
            <div className="mt-5 grid grid-cols-3 gap-3">
              {signalItems.map((item) => (
                <div key={item.label} className="rounded-2xl border border-white/10 bg-white/[0.04] p-3">
                  <div className="font-heading text-2xl italic text-white">{item.value}</div>
                  <div className="mt-1 font-body text-xs text-white/52">{item.label}</div>
                </div>
              ))}
            </div>
          </div>

          <div className="grid gap-3 md:grid-cols-3">
            {proofItems.map((item) => {
              const Icon = item.icon;

              return (
                <div key={item.label} className="liquid-glass rounded-[1.5rem] p-5">
                  <div className="mb-4 inline-flex size-10 items-center justify-center rounded-full liquid-glass-strong text-white">
                    <Icon aria-hidden="true" className="size-4" />
                  </div>
                  <h2 className="font-body text-sm font-semibold text-white">{item.label}</h2>
                  <p className="mt-2 font-body text-sm font-light leading-6 text-white/58">{item.description}</p>
                </div>
              );
            })}
          </div>
        </div>
      </div>
    </section>
  );
}
