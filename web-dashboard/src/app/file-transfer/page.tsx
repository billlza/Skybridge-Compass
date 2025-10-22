'use client'

import { Suspense } from 'react'
import { FileTransfer } from '@/components/dashboard/file-transfer'
import { Sidebar } from '@/components/layout/sidebar'
import { Header } from '@/components/layout/header'
import { useDashboardStore } from '@/stores/dashboard-store'
import { cn } from '@/lib/utils'

/**
 * 文件传输页面
 * 提供文件上传下载、进度显示和文件管理功能
 */
export default function FileTransferPage() {
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
            <h1 className="text-3xl font-bold text-white mb-2">文件传输</h1>
            <p className="text-slate-400">高效的文件上传下载管理</p>
          </div>
          
          <Suspense fallback={<FileTransferSkeleton />}>
            <FileTransfer />
          </Suspense>
        </main>
      </div>
    </div>
  )
}

/**
 * 文件传输加载骨架屏
 */
function FileTransferSkeleton() {
  return (
    <div className="space-y-6">
      {/* 工具栏骨架 */}
      <div className="bg-slate-800 rounded-lg p-4">
        <div className="flex items-center justify-between">
          <div className="flex items-center space-x-4">
            <div className="h-8 w-32 bg-slate-700 rounded animate-pulse" />
            <div className="h-8 w-24 bg-slate-700 rounded animate-pulse" />
          </div>
          <div className="flex items-center space-x-2">
            <div className="h-8 w-8 bg-slate-700 rounded animate-pulse" />
            <div className="h-8 w-8 bg-slate-700 rounded animate-pulse" />
          </div>
        </div>
      </div>
      
      {/* 文件列表骨架 */}
      <div className="bg-slate-800 rounded-lg p-6">
        <div className="space-y-4">
          {[...Array(8)].map((_, i) => (
            <div key={i} className="flex items-center justify-between p-3 bg-slate-700/50 rounded-lg">
              <div className="flex items-center space-x-3">
                <div className="w-8 h-8 bg-slate-600 rounded animate-pulse" />
                <div className="space-y-1">
                  <div className="h-4 w-32 bg-slate-600 rounded animate-pulse" />
                  <div className="h-3 w-20 bg-slate-600 rounded animate-pulse" />
                </div>
              </div>
              <div className="flex items-center space-x-2">
                <div className="h-6 w-16 bg-slate-600 rounded animate-pulse" />
                <div className="h-6 w-6 bg-slate-600 rounded animate-pulse" />
              </div>
            </div>
          ))}
        </div>
      </div>
      
      {/* 传输面板骨架 */}
      <div className="bg-slate-800 rounded-lg p-6">
        <div className="h-6 w-24 bg-slate-700 rounded animate-pulse mb-4" />
        <div className="space-y-3">
          {[...Array(3)].map((_, i) => (
            <div key={i} className="flex items-center justify-between p-3 bg-slate-700/50 rounded-lg">
              <div className="flex items-center space-x-3">
                <div className="w-6 h-6 bg-slate-600 rounded animate-pulse" />
                <div className="space-y-1">
                  <div className="h-4 w-28 bg-slate-600 rounded animate-pulse" />
                  <div className="h-2 w-40 bg-slate-600 rounded animate-pulse" />
                </div>
              </div>
              <div className="h-6 w-12 bg-slate-600 rounded animate-pulse" />
            </div>
          ))}
        </div>
      </div>
    </div>
  )
}