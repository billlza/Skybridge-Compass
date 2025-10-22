'use client'

import { Suspense } from 'react'
import { MainControlPanel } from '@/components/dashboard/main-control-panel'
import { ErrorBoundary } from '@/components/error-boundary'
import { LazyWrapper } from '@/components/lazy-components'
import { Sidebar } from '@/components/layout/sidebar'
import { Header } from '@/components/layout/header'
import { useDashboardStore } from '@/stores/dashboard-store'
import { cn } from '@/lib/utils'

/**
 * 主控制台页面 - SkyBridge Compass Pro 2025
 * 提供设备概览、连接状态和快速操作功能
 */
export default function MainControlPanelPage() {
  const { sidebarCollapsed } = useDashboardStore()

  return (
    <div className="min-h-screen bg-slate-950 text-white">
      {/* 侧边栏 */}
      <Sidebar />
      
      {/* 主内容区域 - 根据侧边栏状态自动调整左边距 */}
      <div 
        className={cn(
          "flex flex-col transition-all duration-300 ease-in-out min-h-screen",
          // 桌面端根据侧边栏状态调整边距
          sidebarCollapsed ? 'md:ml-16' : 'md:ml-64',
          // 移动端不设置左边距，让侧边栏覆盖显示
          'max-md:ml-0'
        )}
      >
        {/* 顶部导航 */}
        <Header />
        
        {/* 页面内容 */}
        <main className="flex-1 p-6 bg-slate-950">
          <div className="mb-6">
            <h1 className="text-3xl font-bold text-white mb-2">主控制台</h1>
            <p className="text-slate-400">远程桌面与文件传输管理中心</p>
          </div>
          
          <ErrorBoundary>
            <LazyWrapper>
              <Suspense fallback={<MainControlPanelSkeleton />}>
                <MainControlPanel />
              </Suspense>
            </LazyWrapper>
          </ErrorBoundary>
        </main>
      </div>
    </div>
  )
}

/**
 * 主控制台加载骨架屏
 */
function MainControlPanelSkeleton() {
  return (
    <div className="space-y-6">
      {/* 设备概览骨架 */}
      <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-6">
        {[...Array(4)].map((_, i) => (
          <div key={i} className="bg-slate-800 rounded-lg p-6">
            <div className="flex items-center justify-between mb-4">
              <div className="flex items-center space-x-3">
                <div className="w-10 h-10 bg-slate-700 rounded animate-pulse" />
                <div className="space-y-1">
                  <div className="h-4 w-20 bg-slate-700 rounded animate-pulse" />
                  <div className="h-3 w-16 bg-slate-700 rounded animate-pulse" />
                </div>
              </div>
              <div className="w-3 h-3 bg-slate-700 rounded-full animate-pulse" />
            </div>
            <div className="space-y-2">
              <div className="h-6 w-16 bg-slate-700 rounded animate-pulse" />
              <div className="h-3 w-24 bg-slate-700 rounded animate-pulse" />
            </div>
          </div>
        ))}
      </div>
      
      {/* 连接状态骨架 */}
      <div className="bg-slate-800 rounded-lg p-6">
        <div className="h-6 w-24 bg-slate-700 rounded animate-pulse mb-4" />
        <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
          {[...Array(3)].map((_, i) => (
            <div key={i} className="text-center p-4 bg-slate-700/50 rounded-lg">
              <div className="h-8 w-16 bg-slate-600 rounded animate-pulse mx-auto mb-2" />
              <div className="h-4 w-20 bg-slate-600 rounded animate-pulse mx-auto" />
            </div>
          ))}
        </div>
      </div>
      
      {/* 快速操作面板骨架 */}
      <div className="bg-slate-800 rounded-lg p-6">
        <div className="h-6 w-28 bg-slate-700 rounded animate-pulse mb-4" />
        <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
          {[...Array(8)].map((_, i) => (
            <div key={i} className="p-4 bg-slate-700/50 rounded-lg text-center">
              <div className="w-8 h-8 bg-slate-600 rounded animate-pulse mx-auto mb-2" />
              <div className="h-4 w-16 bg-slate-600 rounded animate-pulse mx-auto" />
            </div>
          ))}
        </div>
      </div>
    </div>
  )
}