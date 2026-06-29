import { useEffect, useRef, useState } from 'react';
import { motion, useReducedMotion } from 'motion/react';
import { Activity, Gauge, Lock, MonitorSmartphone, Radio, Server, Waypoints } from 'lucide-react';

/** Small "live" number that random-walks inside a range so panels feel real-time. */
function LiveNumber({
  min,
  max,
  decimals = 0,
  suffix = '',
  interval = 1400,
  seed,
}: {
  min: number;
  max: number;
  decimals?: number;
  suffix?: string;
  interval?: number;
  seed: number;
}) {
  const prefersReducedMotion = useReducedMotion();
  const [value, setValue] = useState(() => (min + max) / 2);
  const tick = useRef(seed);

  useEffect(() => {
    if (prefersReducedMotion) return undefined;
    const id = setInterval(() => {
      tick.current += 1;
      // deterministic-ish smooth oscillation, no Math.random dependency
      const wave = (Math.sin(tick.current * 0.9 + seed) + Math.sin(tick.current * 0.37 + seed * 2)) / 2;
      const next = min + ((wave + 1) / 2) * (max - min);
      setValue(next);
    }, interval);
    return () => clearInterval(id);
  }, [min, max, interval, seed, prefersReducedMotion]);

  return (
    <span className="tabular-nums">
      {value.toFixed(decimals)}
      {suffix}
    </span>
  );
}

/** Row 1 — a live secure session: device → encrypted route → remote host. */
export function ConnectionPreview() {
  const prefersReducedMotion = useReducedMotion();

  return (
    <div className="liquid-glass relative h-full overflow-hidden rounded-[1.75rem] p-6 sm:p-7">
      <div className="cinematic-mini-sweep z-[1]" />
      <div className="relative z-10 flex h-full flex-col">
        <div className="flex items-center justify-between">
          <div className="inline-flex items-center gap-2 rounded-full liquid-glass px-3 py-1 font-body text-[0.7rem] font-medium text-white/80">
            <span className="relative flex size-2">
              <span className="absolute inline-flex size-2 animate-ping rounded-full bg-teal-300/70" />
              <span className="relative inline-flex size-2 rounded-full bg-teal-300" />
            </span>
            实时会话
          </div>
          <div className="inline-flex items-center gap-1.5 font-body text-[0.7rem] text-white/55">
            <Lock aria-hidden="true" className="size-3.5" />
            端到端加密
          </div>
        </div>

        {/* connection diagram */}
        <div className="relative mt-8 flex items-center justify-between">
          <div className="flex flex-col items-center gap-2">
            <div className="flex size-14 items-center justify-center rounded-2xl liquid-glass-strong text-white">
              <MonitorSmartphone aria-hidden="true" className="size-6" />
            </div>
            <span className="font-body text-[0.68rem] text-white/55">本地设备</span>
          </div>

          <svg viewBox="0 0 220 80" className="mx-1 h-20 flex-1" preserveAspectRatio="none" aria-hidden="true">
            <path d="M4 40 C 70 8, 150 72, 216 40" fill="none" stroke="rgba(255,255,255,0.14)" strokeWidth="2" strokeDasharray="3 8" />
            <path
              id="sessionPath"
              d="M4 40 C 70 8, 150 72, 216 40"
              fill="none"
              stroke="url(#sessionGrad)"
              strokeWidth="2.4"
              strokeLinecap="round"
            />
            <defs>
              <linearGradient id="sessionGrad" x1="0" y1="0" x2="1" y2="0">
                <stop offset="0%" stopColor="rgba(45,212,191,0)" />
                <stop offset="50%" stopColor="rgba(125,249,236,0.9)" />
                <stop offset="100%" stopColor="rgba(129,140,248,0)" />
              </linearGradient>
            </defs>
            {!prefersReducedMotion ? (
              <motion.circle
                r="4"
                fill="#7df9ec"
                style={{ filter: 'drop-shadow(0 0 6px rgba(125,249,236,0.9))', offsetPath: "path('M4 40 C 70 8, 150 72, 216 40')" } as never}
                animate={{ offsetDistance: ['0%', '100%'] }}
                transition={{ duration: 2.2, repeat: Infinity, ease: 'easeInOut' }}
              />
            ) : null}
          </svg>

          <div className="flex flex-col items-center gap-2">
            <div className="flex size-14 items-center justify-center rounded-2xl liquid-glass-strong text-white">
              <Server aria-hidden="true" className="size-6" />
            </div>
            <span className="font-body text-[0.68rem] text-white/55">远程主机</span>
          </div>
        </div>

        {/* live metrics */}
        <div className="mt-auto grid grid-cols-3 gap-2.5 pt-7">
          {[
            { icon: Gauge, label: '延迟', node: <LiveNumber min={18} max={32} suffix="ms" seed={1} /> },
            { icon: Activity, label: '吞吐', node: <LiveNumber min={86} max={120} suffix="MB/s" seed={3} /> },
            { icon: Radio, label: '丢包', node: <LiveNumber min={0} max={0.4} decimals={2} suffix="%" seed={5} /> },
          ].map((m) => {
            const Icon = m.icon;
            return (
              <div key={m.label} className="rounded-2xl border border-white/10 bg-white/[0.04] p-3">
                <Icon aria-hidden="true" className="size-3.5 text-white/45" />
                <div className="mt-2 font-heading text-xl italic text-white">{m.node}</div>
                <div className="mt-0.5 font-body text-[0.66rem] text-white/45">{m.label}</div>
              </div>
            );
          })}
        </div>
      </div>
    </div>
  );
}

/** Row 2 — live route optimization: candidate paths scored and re-chosen in real time. */
export function RouteOptimizePreview() {
  const prefersReducedMotion = useReducedMotion();
  const [best, setBest] = useState(0);
  const routes = ['直连 · LAN', '中继 · 上海', '中继 · 法兰克福'];

  useEffect(() => {
    if (prefersReducedMotion) return undefined;
    const id = setInterval(() => setBest((b) => (b + 1) % routes.length), 2600);
    return () => clearInterval(id);
  }, [prefersReducedMotion, routes.length]);

  const scores = [92, 78, 64];

  return (
    <div className="liquid-glass relative h-full overflow-hidden rounded-[1.75rem] p-6 sm:p-7">
      <div className="cinematic-mini-sweep z-[1]" />
      <div className="relative z-10 flex h-full flex-col">
        <div className="flex items-center justify-between">
          <div className="inline-flex items-center gap-2 font-body text-[0.7rem] font-medium text-white/80">
            <Waypoints aria-hidden="true" className="size-3.5 text-teal-300" />
            路径择优
          </div>
          <motion.div
            className="inline-flex items-center gap-1.5 rounded-full liquid-glass px-3 py-1 font-body text-[0.7rem] text-white/75"
            animate={prefersReducedMotion ? undefined : { opacity: [0.55, 1, 0.55] }}
            transition={{ duration: 2.2, repeat: Infinity, ease: 'easeInOut' }}
          >
            实时优化中
          </motion.div>
        </div>

        <div className="mt-7 flex flex-col gap-3">
          {routes.map((route, index) => {
            const active = index === best;
            return (
              <div key={route} className="rounded-2xl border border-white/10 bg-white/[0.035] px-4 py-3">
                <div className="flex items-center justify-between font-body text-[0.74rem]">
                  <span className={active ? 'text-white' : 'text-white/55'}>{route}</span>
                  <span className={active ? 'text-teal-300' : 'text-white/40'}>
                    {active ? '已择优' : `${scores[index]} 分`}
                  </span>
                </div>
                <div className="mt-2 h-1.5 w-full overflow-hidden rounded-full bg-white/10">
                  <motion.div
                    className="h-full rounded-full"
                    style={{
                      background: active
                        ? 'linear-gradient(90deg, rgba(45,212,191,0.9), rgba(129,140,248,0.9))'
                        : 'rgba(255,255,255,0.22)',
                    }}
                    initial={false}
                    animate={{ width: `${active ? 96 : scores[index]}%` }}
                    transition={{ duration: 0.8, ease: [0.22, 1, 0.36, 1] }}
                  />
                </div>
              </div>
            );
          })}
        </div>

        {/* live latency sparkline */}
        <div className="mt-auto rounded-2xl border border-white/10 bg-white/[0.04] p-4 pt-3">
          <div className="flex items-center justify-between">
            <span className="font-body text-[0.66rem] text-white/45">延迟趋势 · 最近 60s</span>
            <span className="font-heading text-base italic text-white">
              <LiveNumber min={19} max={28} suffix="ms" seed={2} />
            </span>
          </div>
          <svg viewBox="0 0 240 48" className="mt-2 h-10 w-full" preserveAspectRatio="none" aria-hidden="true">
            <motion.path
              d="M0 34 L24 30 L48 36 L72 22 L96 28 L120 18 L144 26 L168 16 L192 24 L216 14 L240 20"
              fill="none"
              stroke="url(#sparkGrad)"
              strokeWidth="2"
              strokeLinecap="round"
              strokeLinejoin="round"
              initial={prefersReducedMotion ? false : { pathLength: 0, opacity: 0.4 }}
              animate={prefersReducedMotion ? undefined : { pathLength: 1, opacity: 1 }}
              transition={{ duration: 1.6, ease: 'easeInOut' }}
            />
            <defs>
              <linearGradient id="sparkGrad" x1="0" y1="0" x2="1" y2="0">
                <stop offset="0%" stopColor="rgba(45,212,191,0.7)" />
                <stop offset="100%" stopColor="rgba(129,140,248,0.9)" />
              </linearGradient>
            </defs>
          </svg>
        </div>
      </div>
    </div>
  );
}
