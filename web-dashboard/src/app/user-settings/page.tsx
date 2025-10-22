'use client'

import { Suspense } from 'react'
import { UserSettings } from '@/components/dashboard/user-settings'
import { Sidebar } from '@/components/layout/sidebar'
import { Header } from '@/components/layout/header'
import { useDashboardStore } from '@/stores/dashboard-store'
import { cn } from '@/lib/utils'

/**
 * 用户设置页面
 * 提供个人资料、系统配置和主题设置功能
 */
export default function UserSettingsPage() {
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
            <h1 className="text-3xl font-bold text-white mb-2">用户设置</h1>
            <p className="text-slate-400">个人资料和系统配置</p>
          </div>
          
          <Suspense fallback={<UserSettingsSkeleton />}>
            <UserSettings />
          </Suspense>
        </main>
      </div>
    </div>
  )
}

/**
 * 用户设置加载骨架屏
 */
function UserSettingsSkeleton() {
  return (
    <div className="max-w-4xl mx-auto space-y-6">
      {/* 标签页导航骨架 */}
      <div className="bg-slate-800 rounded-lg p-1">
        <div className="flex space-x-1">
          {[...Array(3)].map((_, i) => (
            <div key={i} className="h-10 w-24 bg-slate-700 rounded animate-pulse" />
          ))}
        </div>
      </div>
      
      {/* 设置内容骨架 */}
      <div className="bg-slate-800 rounded-lg p-6">
        <div className="space-y-8">
          {/* 个人资料部分 */}
          <div className="space-y-4">
            <div className="h-6 w-24 bg-slate-700 rounded animate-pulse" />
            <div className="flex items-center space-x-4">
              <div className="w-20 h-20 bg-slate-700 rounded-full animate-pulse" />
              <div className="space-y-2">
                <div className="h-4 w-32 bg-slate-700 rounded animate-pulse" />
                <div className="h-3 w-24 bg-slate-700 rounded animate-pulse" />
              </div>
            </div>
          </div>
          
          {/* 表单字段骨架 */}
          <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
            {[...Array(6)].map((_, i) => (
              <div key={i} className="space-y-2">
                <div className="h-4 w-20 bg-slate-700 rounded animate-pulse" />
                <div className="h-10 w-full bg-slate-700 rounded animate-pulse" />
              </div>
            ))}
          </div>
          
          {/* 开关设置骨架 */}
          <div className="space-y-4">
            <div className="h-6 w-28 bg-slate-700 rounded animate-pulse" />
            {[...Array(4)].map((_, i) => (
              <div key={i} className="flex items-center justify-between p-4 bg-slate-700/50 rounded-lg">
                <div className="space-y-1">
                  <div className="h-4 w-32 bg-slate-600 rounded animate-pulse" />
                  <div className="h-3 w-48 bg-slate-600 rounded animate-pulse" />
                </div>
                <div className="w-12 h-6 bg-slate-600 rounded-full animate-pulse" />
              </div>
            ))}
          </div>
          
          {/* 按钮组骨架 */}
          <div className="flex justify-end space-x-3 pt-6 border-t border-slate-700">
            <div className="h-10 w-20 bg-slate-700 rounded animate-pulse" />
            <div className="h-10 w-24 bg-slate-700 rounded animate-pulse" />
          </div>
        </div>
      </div>
    </div>
  )
}