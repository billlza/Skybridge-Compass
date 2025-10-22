'use client'

import { Suspense } from 'react'
import { RemoteDesktop } from '@/components/dashboard/remote-desktop'
import { Sidebar } from '@/components/layout/sidebar'
import { Header } from '@/components/layout/header'
import { useDashboardStore } from '@/stores/dashboard-store'
import { cn } from '@/lib/utils'

/**
 * 远程桌面页面
 * 提供VNC/RDP连接、屏幕共享和远程控制功能
 */
export default function RemoteDesktopPage() {
  const { sidebarCollapsed } = useDashboardStore()

  return (
    <div className="min-h-screen bg-slate-950 text-white">
      {/* 侧边栏 */}
      <Sidebar />
      
      {/* 主内容区域 - 根据侧边栏状态自动调整左边距 */}
      <div 
        className={cn(
          "flex flex-col transition-all duration-300 ease-in-out",
          // 桌面端根据侧边栏状态调整边距
          sidebarCollapsed ? 'md:ml-16' : 'md:ml-64',
          // 移动端不设置左边距，让侧边栏覆盖显示
          'max-md:ml-0'
        )}
      >
        {/* 顶部导航 */}
        <Header />
        
        {/* 页面内容 */}
        <main className="flex-1 p-6">
          <div className="mb-6">
            <h1 className="text-3xl font-bold text-white mb-2">远程桌面</h1>
            <p className="text-slate-400">VNC/RDP远程连接管理</p>
          </div>
          
          <Suspense fallback={<RemoteDesktopSkeleton />}>
            <RemoteDesktop />
          </Suspense>
        </main>
      </div>
    </div>
  )
}

/**
 * 远程桌面加载骨架屏
 */
function RemoteDesktopSkeleton() {
  return (
    <div className="space-y-6">
      {/* 工具栏骨架 */}
      <div className="bg-slate-800 rounded-lg p-4">
        <div className="flex items-center justify-between">
          <div className="flex items-center space-x-4">
            <div className="h-8 w-24 bg-slate-700 rounded animate-pulse" />
            <div className="h-8 w-20 bg-slate-700 rounded animate-pulse" />
            <div className="h-8 w-16 bg-slate-700 rounded animate-pulse" />
          </div>
          <div className="flex items-center space-x-2">
            <div className="h-8 w-8 bg-slate-700 rounded animate-pulse" />
            <div className="h-8 w-8 bg-slate-700 rounded animate-pulse" />
            <div className="h-8 w-8 bg-slate-700 rounded animate-pulse" />
          </div>
        </div>
      </div>
      
      {/* 主内容区域骨架 */}
      <div className="bg-slate-800 rounded-lg p-6">
        <div className="h-96 w-full bg-slate-700 rounded animate-pulse" />
      </div>
      
      {/* 连接列表骨架 */}
      <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
        {[...Array(6)].map((_, i) => (
          <div key={i} className="bg-slate-800 rounded-lg p-4">
            <div className="flex items-center justify-between mb-3">
              <div className="h-5 w-24 bg-slate-700 rounded animate-pulse" />
              <div className="h-4 w-16 bg-slate-700 rounded animate-pulse" />
            </div>
            <div className="h-4 w-full bg-slate-700 rounded animate-pulse mb-2" />
            <div className="h-4 w-3/4 bg-slate-700 rounded animate-pulse" />
          </div>
        ))}
      </div>
    </div>
  )
}