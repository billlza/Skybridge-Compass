'use client'

import { Suspense } from 'react'
import { SystemMonitoring } from '@/components/dashboard/system-monitoring'
import { Sidebar } from '@/components/layout/sidebar'
import { Header } from '@/components/layout/header'
import { useDashboardStore } from '@/stores/dashboard-store'
import { cn } from '@/lib/utils'

/**
 * 系统监控页面
 * 提供实时性能指标、资源使用情况和告警系统
 */
export default function SystemMonitoringPage() {
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
            <h1 className="text-3xl font-bold text-white mb-2">系统监控</h1>
            <p className="text-slate-400">实时性能监控和系统状态</p>
          </div>
          
          <Suspense fallback={<SystemMonitoringSkeleton />}>
            <SystemMonitoring />
          </Suspense>
        </main>
      </div>
    </div>
  )
}

/**
 * 系统监控加载骨架屏
 */
function SystemMonitoringSkeleton() {
  return (
    <div className="space-y-6">
      {/* 性能指标卡片骨架 */}
      <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-6">
        {[...Array(8)].map((_, i) => (
          <div key={i} className="bg-slate-800 rounded-lg p-6">
            <div className="flex items-center justify-between mb-4">
              <div className="flex items-center space-x-3">
                <div className="w-10 h-10 bg-slate-700 rounded animate-pulse" />
                <div className="space-y-1">
                  <div className="h-4 w-16 bg-slate-700 rounded animate-pulse" />
                  <div className="h-3 w-12 bg-slate-700 rounded animate-pulse" />
                </div>
              </div>
            </div>
            <div className="space-y-2">
              <div className="h-8 w-20 bg-slate-700 rounded animate-pulse" />
              <div className="h-2 w-full bg-slate-700 rounded animate-pulse" />
            </div>
          </div>
        ))}
      </div>
      
      {/* 图表区域骨架 */}
      <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
        <div className="bg-slate-800 rounded-lg p-6">
          <div className="h-6 w-32 bg-slate-700 rounded animate-pulse mb-4" />
          <div className="h-64 w-full bg-slate-700 rounded animate-pulse" />
        </div>
        <div className="bg-slate-800 rounded-lg p-6">
          <div className="h-6 w-28 bg-slate-700 rounded animate-pulse mb-4" />
          <div className="h-64 w-full bg-slate-700 rounded animate-pulse" />
        </div>
      </div>
      
      {/* 告警列表骨架 */}
      <div className="bg-slate-800 rounded-lg p-6">
        <div className="h-6 w-24 bg-slate-700 rounded animate-pulse mb-4" />
        <div className="space-y-3">
          {[...Array(5)].map((_, i) => (
            <div key={i} className="flex items-center justify-between p-4 bg-slate-700/50 rounded-lg">
              <div className="flex items-center space-x-3">
                <div className="w-8 h-8 bg-slate-600 rounded animate-pulse" />
                <div className="space-y-1">
                  <div className="h-4 w-40 bg-slate-600 rounded animate-pulse" />
                  <div className="h-3 w-24 bg-slate-600 rounded animate-pulse" />
                </div>
              </div>
              <div className="flex items-center space-x-2">
                <div className="h-6 w-16 bg-slate-600 rounded animate-pulse" />
                <div className="h-8 w-8 bg-slate-600 rounded animate-pulse" />
              </div>
            </div>
          ))}
        </div>
      </div>
    </div>
  )
}