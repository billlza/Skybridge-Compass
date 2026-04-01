import React, { useEffect, useRef } from 'react';
import { motion } from 'motion/react';

interface NebulaParticle {
  x: number;
  y: number;
  radius: number;
  color: string;
  vx: number;
  vy: number;
  life: number;
  maxLife: number;
}

const StarryBackground: React.FC = () => {
  const canvasRef = useRef<HTMLCanvasElement>(null);

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;

    const ctx = canvas.getContext('2d');
    if (!ctx) return;

    let width = window.innerWidth;
    let height = window.innerHeight;
    let particles: NebulaParticle[] = [];
    let stars: { x: number; y: number; radius: number; alpha: number; dAlpha: number }[] = [];
    let animationFrameId: number;

    const resize = () => {
      width = window.innerWidth;
      height = window.innerHeight;
      canvas.width = width;
      canvas.height = height;
      initParticles();
    };

    const colors = [
      'rgba(76, 29, 149, 0.3)',   // Deep Violet
      'rgba(59, 130, 246, 0.2)',  // Blue
      'rgba(236, 72, 153, 0.15)', // Pink
      'rgba(16, 185, 129, 0.1)',  // Emerald/Teal hint
      'rgba(99, 102, 241, 0.2)',  // Indigo
    ];

    const initParticles = () => {
      particles = [];
      stars = [];
      
      // Create Nebula Clouds (Large, soft particles)
      const particleCount = Math.max(15, Math.floor((width * height) / 40000));
      
      for (let i = 0; i < particleCount; i++) {
        particles.push({
          x: Math.random() * width,
          y: Math.random() * height,
          radius: Math.random() * (Math.min(width, height) * 0.4) + 100,
          color: colors[Math.floor(Math.random() * colors.length)],
          vx: (Math.random() - 0.5) * 0.2, // Very slow movement
          vy: (Math.random() - 0.5) * 0.2,
          life: Math.random() * 1000,
          maxLife: 1000 + Math.random() * 1000,
        });
      }

      // Create Stars
      const starCount = Math.floor((width * height) / 8000);
      for (let i = 0; i < starCount; i++) {
        stars.push({
          x: Math.random() * width,
          y: Math.random() * height,
          radius: Math.random() * 1.5 + 0.5,
          alpha: Math.random(),
          dAlpha: (Math.random() - 0.5) * 0.02,
        });
      }
    };

    const draw = () => {
      ctx.clearRect(0, 0, width, height);
      
      // Draw background base (Deep Space)
      // We rely on the CSS background for the very bottom, but we can add a wash here
      // ctx.fillStyle = '#0f172a'; // Slate 900
      // ctx.fillRect(0, 0, width, height);

      // Draw Nebula
      ctx.globalCompositeOperation = 'screen'; // Blend mode for glowing effect
      
      particles.forEach(p => {
        p.x += p.vx;
        p.y += p.vy;
        p.life++;

        // Wrap around screen
        if (p.x < -p.radius) p.x = width + p.radius;
        if (p.x > width + p.radius) p.x = -p.radius;
        if (p.y < -p.radius) p.y = height + p.radius;
        if (p.y > height + p.radius) p.y = -p.radius;

        // Pulse radius slightly
        const pulse = Math.sin(p.life * 0.002) * 20;
        
        const gradient = ctx.createRadialGradient(p.x, p.y, 0, p.x, p.y, p.radius + pulse);
        gradient.addColorStop(0, p.color);
        gradient.addColorStop(1, 'rgba(0,0,0,0)');

        ctx.fillStyle = gradient;
        ctx.beginPath();
        ctx.arc(p.x, p.y, p.radius + pulse, 0, Math.PI * 2);
        ctx.fill();
      });

      // Draw Stars
      ctx.globalCompositeOperation = 'source-over';
      stars.forEach(star => {
        star.alpha += star.dAlpha;
        if (star.alpha <= 0 || star.alpha >= 1) {
          star.dAlpha = -star.dAlpha;
        }
        
        ctx.fillStyle = `rgba(255, 255, 255, ${Math.max(0, Math.min(1, star.alpha))})`;
        ctx.beginPath();
        ctx.arc(star.x, star.y, star.radius, 0, Math.PI * 2);
        ctx.fill();
      });

      animationFrameId = requestAnimationFrame(draw);
    };

    window.addEventListener('resize', resize);
    resize();
    draw();

    return () => {
      window.removeEventListener('resize', resize);
      cancelAnimationFrame(animationFrameId);
    };
  }, []);

  return (
    <>
      {/* 
        Base Layer: Deep, rich dark gradient 
        Provides the canvas for the nebula
      */}
      <div 
        className="fixed inset-0 pointer-events-none z-0"
        style={{
          background: 'radial-gradient(circle at center, #1e1b4b 0%, #020617 100%)',
        }}
      />
      
      {/* 
        Texture Layer: Grain/Noise 
        Adds the "painting/paper" texture feel
      */}
      <div 
        className="fixed inset-0 pointer-events-none z-0 opacity-[0.05]"
        style={{
          backgroundImage: `url("data:image/svg+xml,%3Csvg viewBox='0 0 200 200' xmlns='http://www.w3.org/2000/svg'%3E%3Cfilter id='noiseFilter'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.65' numOctaves='3' stitchTiles='stitch'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23noiseFilter)'/%3E%3C/svg%3E")`,
        }}
      />

      {/* Nebula & Stars Canvas */}
      <motion.canvas
        ref={canvasRef}
        initial={{ opacity: 0 }}
        animate={{ opacity: 1 }}
        transition={{ duration: 1.5 }}
        className="fixed inset-0 pointer-events-none z-0"
      />
    </>
  );
};

export default StarryBackground;
