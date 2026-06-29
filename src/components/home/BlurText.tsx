import { useEffect, useMemo, useRef, useState } from 'react';
import type { CSSProperties, ReactNode } from 'react';
import { motion, useReducedMotion } from 'motion/react';

type Direction = 'bottom' | 'top';

interface BlurTextProps {
  text: string;
  className?: string;
  /**
   * Split the animation per word (latin) or per character. When set to
   * 'auto' (default) we segment by whitespace, and fall back to per-character
   * for runs without spaces (e.g. Chinese) so CJK headings still stagger.
   */
  animateBy?: 'words' | 'chars' | 'auto';
  direction?: Direction;
  /** Per-element stagger in milliseconds (sample default 200ms). */
  delay?: number;
  /** Initial delay before the first element begins, in seconds. */
  startDelay?: number;
  /** Re-trigger every time the element scrolls back into view. */
  repeat?: boolean;
  as?: 'h1' | 'h2' | 'h3' | 'p' | 'span' | 'div';
  style?: CSSProperties;
}

type Segment = { value: string; spaceAfter: boolean };

function segment(text: string, mode: 'words' | 'chars' | 'auto'): Segment[] {
  if (mode === 'chars') {
    return Array.from(text).map((ch) => ({ value: ch === ' ' ? '\u00a0' : ch, spaceAfter: false }));
  }

  const words = text.split(/(\s+)/).filter((part) => part.length > 0);
  const out: Segment[] = [];

  for (const part of words) {
    if (/^\s+$/.test(part)) {
      if (out.length > 0) out[out.length - 1].spaceAfter = true;
      continue;
    }
    // For "auto", break space-less runs longer than one glyph into characters
    // so Chinese/Japanese headings still animate glyph by glyph.
    if (mode === 'auto' && !/\s/.test(part) && /[\u3000-\u9fff\uff00-\uffef]/.test(part)) {
      for (const ch of Array.from(part)) out.push({ value: ch, spaceAfter: false });
      continue;
    }
    out.push({ value: part, spaceAfter: false });
  }

  return out;
}

const KEYFRAME_STEP = 0.35;

export function BlurText({
  text,
  className = '',
  animateBy = 'auto',
  direction = 'bottom',
  delay = 120,
  startDelay = 0,
  repeat = false,
  as = 'span',
  style,
}: BlurTextProps) {
  const prefersReducedMotion = useReducedMotion();
  const ref = useRef<HTMLElement | null>(null);
  const [inView, setInView] = useState(false);

  const segments = useMemo(() => segment(text, animateBy), [text, animateBy]);

  useEffect(() => {
    const node = ref.current;
    if (!node) return undefined;

    const observer = new IntersectionObserver(
      (entries) => {
        entries.forEach((entry) => {
          if (entry.isIntersecting) {
            setInView(true);
            if (!repeat) observer.unobserve(entry.target);
          } else if (repeat) {
            setInView(false);
          }
        });
      },
      { threshold: 0.18, rootMargin: '0px 0px -12% 0px' },
    );

    observer.observe(node);
    return () => observer.disconnect();
  }, [repeat]);

  const yFrom = direction === 'bottom' ? 50 : -50;
  const yMid = direction === 'bottom' ? -5 : 5;

  const Tag = motion[as] as typeof motion.span;

  if (prefersReducedMotion) {
    const Plain = as as 'span';
    return (
      <Plain className={className} style={style}>
        {text}
      </Plain>
    );
  }

  return (
    <Tag
      ref={ref as never}
      className={className}
      style={{ ...style, display: 'inline-block', willChange: 'transform, filter, opacity' }}
    >
      {segments.map((seg, index) => (
        <span key={`${seg.value}-${index}`} style={{ display: 'inline-block', whiteSpace: 'pre' }}>
          <motion.span
            style={{ display: 'inline-block', willChange: 'transform, filter, opacity' }}
            initial={{ filter: 'blur(10px)', opacity: 0, y: yFrom }}
            animate={
              inView
                ? {
                    filter: ['blur(10px)', 'blur(5px)', 'blur(0px)'],
                    opacity: [0, 0.5, 1],
                    y: [yFrom, yMid, 0],
                  }
                : { filter: 'blur(10px)', opacity: 0, y: yFrom }
            }
            transition={{
              duration: KEYFRAME_STEP * 2,
              ease: [0.22, 1, 0.36, 1],
              delay: startDelay + (index * delay) / 1000,
              times: [0, 0.5, 1],
            }}
          >
            {seg.value as ReactNode}
          </motion.span>
          {seg.spaceAfter ? '\u00a0' : ''}
        </span>
      ))}
    </Tag>
  );
}

export default BlurText;
