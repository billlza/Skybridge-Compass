'use client'

import { useState } from 'react'
import { usePathname } from 'next/navigation'
import { cn } from '@/lib/utils'
import { useDashboardStore } from '@/stores/dashboard-store'
import {
  BarChart3,
  Plane,
  Users,
  Settings,
  Bell,
  Calendar,
  Map,
  TrendingUp,
  ChevronLeft,
  ChevronRight,
  Home,
  Monitor,
  Upload,
  Server,
  Activity
} from 'lucide-react'

// 导航菜单项配置
const navigationItems = [
  {
    id: 'dashboard',
    label: '主控制台',
    icon: Home,
    href: '/',
    description: '系统概览和快速操作'
  },
  {
    id: 'device-management',
    label: '设备管理',
    icon: Server,
    href: '/device-management',
    description: '设备连接和状态管理'
  },
  {
    id: 'file-transfer',
    label: '文件传输',
    icon: Upload,
    href: '/file-transfer',
    description: '文件上传下载管理'
  },
  {
    id: 'remote-desktop',
    label: '远程桌面',
    icon: Monitor,
    href: '/remote-desktop',
    description: 'VNC/RDP远程连接'
  },
  {
    id: 'system-monitoring',
    label: '系统监控',
    icon: Activity,
    href: '/system-monitoring',
    description: '实时性能监控'
  },
  {
    id: 'user-settings',
    label: '用户设置',
    icon: Settings,
    href: '/user-settings',
    description: '个人资料和系统配置'
  }
]

interface SidebarProps {
  className?: string
}

export function Sidebar({ className }: SidebarProps) {
  const { sidebarCollapsed, toggleSidebar } = useDashboardStore()
  const [hoveredItem, setHoveredItem] = useState<string | null>(null)
  const pathname = usePathname()

  return (
    <aside
      className={cn(
        "fixed left-0 top-0 z-40 h-screen transition-all duration-300 ease-in-out",
        "bg-slate-900/95 backdrop-blur-xl",
        "border-r border-slate-700/50 shadow-2xl shadow-black/20",
        // 响应式宽度优化 - 统一宽度设置
        sidebarCollapsed 
          ? "w-16" 
          : "w-64",
        // 移动端适配 - 小屏幕下隐藏或覆盖显示
        "md:relative md:translate-x-0",
        "max-md:absolute max-md:inset-y-0 max-md:left-0",
        sidebarCollapsed 
          ? "max-md:-translate-x-full" 
          : "max-md:translate-x-0 max-md:w-64",
        className
      )}
    >
      {/* 侧边栏头部 */}
      <div className="relative z-10 flex items-center justify-between p-4 border-b border-white/[0.08]">
        {!sidebarCollapsed && (
          <div className="flex items-center space-x-2">
            <div className="relative w-8 h-8 bg-gradient-to-br from-blue-500 to-cyan-500 rounded-lg flex items-center justify-center shadow-lg shadow-blue-500/25">
              {/* 内部高光 */}
              <div className="absolute inset-0 bg-gradient-to-br from-white/20 to-transparent rounded-lg" />
              <Monitor className="relative w-5 h-5 text-white drop-shadow-sm" />
            </div>
            <div>
              <h1 className="text-lg font-bold text-white drop-shadow-sm">SkyBridge</h1>
              <p className="text-xs text-slate-300/80">Compass Pro</p>
            </div>
          </div>
        )}
        
        <button
          onClick={toggleSidebar}
          className={cn(
            'relative p-1.5 rounded-lg transition-all duration-200',
            'bg-white/[0.05] hover:bg-white/[0.1] backdrop-blur-sm',
            'border border-white/[0.08] hover:border-white/[0.15]',
            'shadow-lg shadow-black/10 hover:shadow-xl hover:shadow-black/20',
            'text-slate-300 hover:text-white'
          )}
          title={sidebarCollapsed ? '展开侧边栏' : '收起侧边栏'}
        >
          {/* 按钮内部光效 */}
          <div className="absolute inset-0 bg-gradient-to-br from-white/10 to-transparent rounded-lg" />
          {sidebarCollapsed ? (
            <ChevronRight className="relative w-4 h-4" />
          ) : (
            <ChevronLeft className="relative w-4 h-4" />
          )}
        </button>
      </div>

      {/* 导航菜单 */}
      <nav className="relative z-10 flex-1 p-4 space-y-2">
        {navigationItems.map((item) => {
          const Icon = item.icon
          const isHovered = hoveredItem === item.id
          const isActive = pathname === item.href
          
          return (
            <div
              key={item.id}
              className="relative"
              onMouseEnter={() => setHoveredItem(item.id)}
              onMouseLeave={() => setHoveredItem(null)}
            >
              <a
                href={item.href}
                className={cn(
                  'relative flex items-center space-x-3 px-3 py-2.5 rounded-lg transition-all duration-200 group overflow-hidden',
                  isActive
                    ? [
                        // 激活状态的液态玻璃效果
                        'bg-gradient-to-r from-blue-500/20 to-cyan-400/15',
                        'backdrop-blur-sm border border-blue-400/20',
                        'shadow-lg shadow-blue-500/20',
                        'text-white',
                        // 内部光效
                        'before:absolute before:inset-0 before:bg-gradient-to-r before:from-white/10 before:to-transparent before:rounded-lg',
                        // 边缘高光
                        'after:absolute after:inset-0 after:border after:border-white/20 after:rounded-lg'
                      ]
                    : [
                        // 非激活状态
                        'text-slate-300 hover:text-white',
                        'hover:bg-white/[0.08] hover:backdrop-blur-sm',
                        'hover:border hover:border-white/[0.1]',
                        'hover:shadow-lg hover:shadow-black/10'
                      ]
                )}
              >
                {/* 悬停时的动态光效 */}
                {isHovered && !isActive && (
                  <div className="absolute inset-0 bg-gradient-to-r from-white/[0.05] to-transparent rounded-lg transition-opacity duration-300" />
                )}
                
                <Icon className={cn(
                  'relative w-5 h-5 flex-shrink-0 transition-all duration-200',
                  isActive 
                    ? 'text-white drop-shadow-sm' 
                    : 'text-slate-400 group-hover:text-white'
                )} />
                
                {!sidebarCollapsed && (
                  <span className="relative font-medium truncate">
                    {item.label}
                  </span>
                )}
                
                {/* 激活指示器 */}
                {isActive && (
                  <div className="absolute right-0 w-1 h-8 bg-gradient-to-b from-blue-400 to-cyan-400 rounded-l-full shadow-lg shadow-blue-400/50" />
                )}
              </a>
              
              {/* 收起状态下的提示框 */}
              {sidebarCollapsed && isHovered && (
                <div className={cn(
                  'absolute left-full top-0 ml-2 px-3 py-2 rounded-lg shadow-xl whitespace-nowrap z-50 transition-all duration-200',
                  // 提示框的液态玻璃效果
                  'bg-slate-800/90 backdrop-blur-xl backdrop-saturate-150',
                  'border border-white/10 text-white text-sm',
                  'shadow-2xl shadow-black/30'
                )}>
                  {/* 提示框内部光效 */}
                  <div className="absolute inset-0 bg-gradient-to-br from-white/10 to-transparent rounded-lg" />
                  <span className="relative">{item.label}</span>
                </div>
              )}
            </div>
          )
        })}
      </nav>

      {/* 侧边栏底部 */}
      <div className="relative z-10 p-4 border-t border-white/[0.08]">
        {!sidebarCollapsed ? (
          <div className={cn(
            "flex items-center space-x-3 rounded-xl p-3 transition-all duration-300",
            "hover:bg-white/8 backdrop-blur-md liquid-ripple",
            // 响应式布局
            "max-sm:justify-center",
            sidebarCollapsed && "justify-center"
          )}>
            {/* 背景光效 */}
            <div className="absolute inset-0 bg-gradient-to-br from-green-500/10 to-emerald-400/5 rounded-lg" />
            
            <div className="relative w-8 h-8 bg-gradient-to-br from-green-500 to-emerald-500 rounded-full flex items-center justify-center shadow-lg shadow-green-500/25">
              {/* 头像内部高光 */}
              <div className="absolute inset-0 bg-gradient-to-br from-white/20 to-transparent rounded-full" />
              <span className="relative text-sm font-bold text-white drop-shadow-sm">管</span>
            </div>
            <div className="relative flex-1 min-w-0">
              <p className="text-sm font-medium text-white truncate drop-shadow-sm">系统管理员</p>
              <p className="text-xs text-slate-300/80 truncate">admin@skybridge.com</p>
            </div>
          </div>
        ) : (
          <div className="flex justify-center">
            <div className="relative w-8 h-8 bg-gradient-to-br from-green-500 to-emerald-500 rounded-full flex items-center justify-center shadow-lg shadow-green-500/25">
              {/* 头像内部高光 */}
              <div className="absolute inset-0 bg-gradient-to-br from-white/20 to-transparent rounded-full" />
              <span className="relative text-sm font-bold text-white drop-shadow-sm">管</span>
            </div>
          </div>
        )}
      </div>
    </aside>
  )
}