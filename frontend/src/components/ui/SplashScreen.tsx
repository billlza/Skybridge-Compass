'use client';

import { motion } from 'framer-motion';
import { useEffect, useState } from 'react';
import { Compass } from 'lucide-react';

export default function SplashScreen({ onFinish }: { onFinish: () => void }) {
  const [progress, setProgress] = useState(0);

  useEffect(() => {
    const timer = setInterval(() => {
      setProgress((prev) => {
        if (prev >= 100) {
          clearInterval(timer);
          setTimeout(onFinish, 500); // Wait a bit before finishing
          return 100;
        }
        return prev + 2; // Simulate loading
      });
    }, 30);

    return () => clearInterval(timer);
  }, [onFinish]);

  return (
    <div className="fixed inset-0 z-50 flex flex-col items-center justify-center bg-[#0f1729] text-white">
      <motion.div
        initial={{ scale: 0.8, opacity: 0 }}
        animate={{ scale: 1, opacity: 1 }}
        transition={{ duration: 0.5 }}
        className="flex flex-col items-center"
      >
        <div className="relative mb-8">
            {/* Logo Placeholder - using Lucide Compass for now */}
            <motion.div
                animate={{ rotate: 360 }}
                transition={{ duration: 3, repeat: Infinity, ease: "linear" }}
            >
                <Compass size={80} className="text-accent" />
            </motion.div>
            <div className="absolute inset-0 bg-accent/20 blur-xl rounded-full" />
        </div>
        
        <h1 className="text-3xl font-bold mb-2 tracking-wider">云桥司南</h1>
        <p className="text-slate-400 text-sm mb-8 tracking-widest uppercase">SkyBridge Compass</p>

        <div className="w-64 h-1 bg-slate-800 rounded-full overflow-hidden">
          <motion.div 
            className="h-full bg-accent"
            initial={{ width: 0 }}
            animate={{ width: `${progress}%` }}
          />
        </div>
        <p className="mt-2 text-xs text-slate-500">{progress}%</p>
      </motion.div>
    </div>
  );
}




