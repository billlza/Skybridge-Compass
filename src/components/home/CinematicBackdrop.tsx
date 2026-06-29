import { useState } from 'react';
import type { CSSProperties } from 'react';
import { useReducedMotion } from 'motion/react';
import { NebulaField } from './NebulaField';

type Tone = 'teal' | 'indigo' | 'mono';

interface CinematicBackdropProps {
  /** Local video source; defaults to the self-hosted hero clip. */
  videoSrc?: string;
  posterSrc?: string;
  /** Desaturate to near black & white (used by the stats band). */
  desaturate?: boolean;
  /** Color wash so repeated use of one clip still feels distinct per section. */
  tone?: Tone;
  /** Height of the top fade-in-from-black band, in px. */
  topFade?: number;
  /** Height of the bottom fade-to-black band, in px. */
  bottomFade?: number;
  /** Render the realtime ambient field over the media. */
  showRealtimeField?: boolean;
  className?: string;
}

const toneWash: Record<Tone, string> = {
  teal: 'radial-gradient(circle at 18% 22%, rgba(45,212,191,0.22), transparent 38%), radial-gradient(circle at 82% 14%, rgba(99,102,241,0.16), transparent 42%)',
  indigo:
    'radial-gradient(circle at 80% 24%, rgba(129,140,248,0.24), transparent 40%), radial-gradient(circle at 14% 70%, rgba(45,212,191,0.14), transparent 44%)',
  mono: 'radial-gradient(circle at 50% 20%, rgba(148,163,184,0.16), transparent 46%)',
};

export function CinematicBackdrop({
  videoSrc = '/media/sinan-hero.mp4',
  posterSrc = '/media/sinan-hero-poster.jpg',
  desaturate = false,
  tone = 'teal',
  topFade = 200,
  bottomFade = 200,
  showRealtimeField = true,
  className = '',
}: CinematicBackdropProps) {
  const prefersReducedMotion = useReducedMotion();
  const [videoFailed, setVideoFailed] = useState(false);
  const shouldRenderVideo = !prefersReducedMotion && !videoFailed;

  const mediaFilter = desaturate
    ? 'saturate(0) contrast(108%) brightness(86%)'
    : 'saturate(112%) contrast(104%)';

  return (
    <div className={`absolute inset-0 overflow-hidden ${className}`} aria-hidden="true">
      <img
        src={posterSrc}
        alt=""
        className="absolute inset-0 z-0 h-full w-full object-cover"
        style={{ filter: mediaFilter, opacity: 0.82 }}
        decoding="async"
      />
      {shouldRenderVideo ? (
        <video
          className="absolute inset-0 z-0 h-full w-full object-cover"
          style={{ filter: mediaFilter, opacity: 0.7 } as CSSProperties}
          autoPlay
          loop
          muted
          playsInline
          preload="metadata"
          poster={posterSrc}
          onError={() => setVideoFailed(true)}
        >
          <source src={videoSrc} type="video/mp4" />
        </video>
      ) : null}

      {/* tone wash */}
      <div className="absolute inset-0 z-[1]" style={{ background: toneWash[tone], mixBlendMode: 'screen' }} />

      {showRealtimeField ? (
        <NebulaField shouldAnimate={prefersReducedMotion !== true} variant="section" edgeFades={false} />
      ) : null}

      {/* light sweep for a live, cinematic feel */}
      <div className="cinematic-light-sweep z-[3]" />

      {/* top + bottom fades to black so sections melt together */}
      <div
        className="pointer-events-none absolute inset-x-0 top-0 z-[4]"
        style={{ height: topFade, background: 'linear-gradient(to bottom, #000 0%, transparent 100%)' }}
      />
      <div
        className="pointer-events-none absolute inset-x-0 bottom-0 z-[4]"
        style={{ height: bottomFade, background: 'linear-gradient(to top, #000 0%, transparent 100%)' }}
      />
    </div>
  );
}

export default CinematicBackdrop;
