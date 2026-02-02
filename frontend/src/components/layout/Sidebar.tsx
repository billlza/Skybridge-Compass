'use client';

import Link from 'next/link';
import { usePathname } from 'next/navigation';
import { 
  LayoutDashboard, 
  Search, 
  Usb, 
  Files, 
  MonitorPlay, 
  Activity, 
  Settings,
  Compass
} from 'lucide-react';
import { cn } from '@/lib/utils'; // We need to create this util

const menuItems = [
  { icon: LayoutDashboard, label: '主控制台', href: '/' },
  { icon: Search, label: '设备发现', href: '/discovery' },
  { icon: Usb, label: 'USB 管理', href: '/usb' },
  { icon: Files, label: '文件传输 (量子通信)', href: '/transfer' },
  { icon: MonitorPlay, label: '远程桌面 (量子通信)', href: '/remote' },
  { icon: Activity, label: '系统监控', href: '/monitor' },
  { icon: Settings, label: '设置', href: '/settings' },
];

export default function Sidebar() {
  const pathname = usePathname();

  return (
    <aside className="w-64 h-full hidden md:flex flex-col bg-sidebar/50 backdrop-blur-xl border-r border-white/5 relative z-20">
      {/* Logo Area */}
      <div className="h-20 flex items-center gap-3 px-6 border-b border-white/5">
        <div className="bg-accent/20 p-2 rounded-lg">
            <Compass className="text-accent w-6 h-6" />
        </div>
        <div>
            <h1 className="font-bold text-lg leading-none">云桥司南</h1>
            <p className="text-[10px] text-slate-400 mt-1">下一代跨平台连接体验</p>
        </div>
      </div>

      {/* Navigation */}
      <nav className="flex-1 py-6 px-3 space-y-1">
        {menuItems.map((item) => {
          const isActive = pathname === item.href;
          return (
            <Link
              key={item.href}
              href={item.href}
              className={cn(
                "flex items-center gap-3 px-4 py-3 rounded-xl transition-all duration-200 group relative overflow-hidden",
                isActive 
                  ? "bg-accent text-white shadow-lg shadow-accent/20" 
                  : "text-slate-400 hover:text-white hover:bg-white/5"
              )}
            >
              <item.icon size={20} className={cn("shrink-0", isActive ? "text-white" : "text-slate-400 group-hover:text-accent")} />
              <span className="text-sm font-medium">{item.label}</span>
              {isActive && (
                 <div className="absolute inset-0 bg-gradient-to-r from-transparent via-white/10 to-transparent translate-x-[-100%] animate-[shimmer_2s_infinite]"></div>
              )}
            </Link>
          );
        })}
      </nav>

      {/* User Footer */}
      <div className="p-4 border-t border-white/5">
        <div className="flex items-center gap-3 p-3 rounded-xl bg-white/5 hover:bg-white/10 transition-colors cursor-pointer border border-white/5">
            <div className="w-10 h-10 rounded-full bg-gradient-to-br from-pink-500 to-violet-500 flex items-center justify-center text-white font-bold text-xs">
                SB
            </div>
            <div className="flex-1 min-w-0">
                <p className="text-sm font-medium truncate">SkyBridge</p>
                <p className="text-xs text-slate-500 truncate">Public Website</p>
            </div>
        </div>
      </div>
    </aside>
  );
}




