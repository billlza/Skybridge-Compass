import { useState } from 'react';
import { useReducedMotion } from 'motion/react';

interface HeroVideoBackdropProps {
  posterSrc: string;
  videoSrc: string;
}

export function HeroVideoBackdrop({ posterSrc, videoSrc }: HeroVideoBackdropProps) {
  const prefersReducedMotion = useReducedMotion();
  const [videoFailed, setVideoFailed] = useState(false);

  const shouldRenderVideo = !prefersReducedMotion && !videoFailed;

  return (
    <div className="absolute inset-0 overflow-hidden" aria-hidden="true">
      <img
        src={posterSrc}
        alt=""
        className="cinematic-media cinematic-poster"
        decoding="async"
        fetchPriority="high"
      />
      {shouldRenderVideo ? (
        <video
          className="cinematic-media cinematic-video"
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
      <div className="cinematic-vignette" />
      <div className="cinematic-light-sweep" />
      <div className="cinematic-scan-lines" />
    </div>
  );
}
