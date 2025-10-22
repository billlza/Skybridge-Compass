'use client'

import { Suspense } from 'react'
import { DeviceManagement } from '@/components/dashboard/device-management'
import { Sidebar } from '@/components/layout/sidebar'
import { Header } from '@/components/layout/header'
import { useDashboardStore } from '@/stores/dashboard-store'
import { cn } from '@/lib/utils'

/**
 * 设备管理页面
 * 提供设备列表、连接管理和设备信息展示功能
 */
export default function DeviceManagementPage() {
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
            <h1 className="text-3xl font-bold text-white mb-2">设备管理</h1>
            <p className="text-slate-400">管理和监控所有连接的设备</p>
          </div>
          
          <Suspense fallback={<DeviceManagementSkeleton />}>
            <DeviceManagement />
          </Suspense>
        </main>
      </div>
    </div>
  )
}

/**
 * 设备管理加载骨架屏
 */
function DeviceManagementSkeleton() {
  return (
    <div className="space-y-6">
      {/* 搜索和过滤栏骨架 */}
      <div className="bg-slate-800 rounded-lg p-4">
        <div className="flex items-center justify-between">
          <div className="flex items-center space-x-4">
            <div className="h-10 w-64 bg-slate-700 rounded animate-pulse" />
            <div className="h-10 w-32 bg-slate-700 rounded animate-pulse" />
          </div>
          <div className="flex items-center space-x-2">
            <div className="h-10 w-10 bg-slate-700 rounded animate-pulse" />
            <div className="h-10 w-10 bg-slate-700 rounded animate-pulse" />
          </div>
        </div>
      </div>
      
      {/* 设备网格骨架 */}
      <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4 gap-6">
        {[...Array(12)].map((_, i) => (
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
            
            <div className="space-y-3">
              <div className="flex justify-between">
                <div className="h-3 w-12 bg-slate-700 rounded animate-pulse" />
                <div className="h-3 w-16 bg-slate-700 rounded animate-pulse" />
              </div>
              <div className="flex justify-between">
                <div className="h-3 w-10 bg-slate-700 rounded animate-pulse" />
                <div className="h-3 w-14 bg-slate-700 rounded animate-pulse" />
              </div>
              <div className="flex justify-between">
                <div className="h-3 w-14 bg-slate-700 rounded animate-pulse" />
                <div className="h-3 w-12 bg-slate-700 rounded animate-pulse" />
              </div>
            </div>
            
            <div className="mt-4 pt-4 border-t border-slate-700">
              <div className="flex space-x-2">
                <div className="h-8 w-16 bg-slate-700 rounded animate-pulse" />
                <div className="h-8 w-16 bg-slate-700 rounded animate-pulse" />
                <div className="h-8 w-16 bg-slate-700 rounded animate-pulse" />
              </div>
            </div>
          </div>
        ))}
      </div>
    </div>
  )
}