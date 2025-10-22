'use client'

import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { ReactQueryDevtools } from '@tanstack/react-query-devtools'
import { useState } from 'react'

// 创建QueryClient实例的工厂函数
function makeQueryClient() {
  return new QueryClient({
    defaultOptions: {
      queries: {
        // 默认情况下，查询在窗口重新获得焦点时会自动重新获取
        refetchOnWindowFocus: false,
        // 默认情况下，查询在重新连接时会自动重新获取
        refetchOnReconnect: true,
        // 默认重试次数
        retry: 3,
        // 默认重试延迟
        retryDelay: (attemptIndex) => Math.min(1000 * 2 ** attemptIndex, 30000),
        // 默认stale时间
        staleTime: 5 * 60 * 1000, // 5分钟
        // 默认缓存时间
        gcTime: 10 * 60 * 1000, // 10分钟
      },
      mutations: {
        // 默认重试次数
        retry: 1,
        // 默认重试延迟
        retryDelay: (attemptIndex) => Math.min(1000 * 2 ** attemptIndex, 30000),
      },
    },
  })
}

let browserQueryClient: QueryClient | undefined = undefined

function getQueryClient() {
  if (typeof window === 'undefined') {
    // 服务器端：总是创建新的查询客户端
    return makeQueryClient()
  } else {
    // 浏览器端：如果没有现有的客户端，则创建一个新的
    if (!browserQueryClient) browserQueryClient = makeQueryClient()
    return browserQueryClient
  }
}

interface QueryProviderProps {
  children: React.ReactNode
}

export function QueryProvider({ children }: QueryProviderProps) {
  // 注意：不要在这里使用useState，因为这会在服务器和客户端之间创建不匹配
  const queryClient = getQueryClient()

  return (
    <QueryClientProvider client={queryClient}>
      {children}
      {/* 开发环境下显示React Query开发工具 */}
      {process.env.NODE_ENV === 'development' && (
        <ReactQueryDevtools 
          initialIsOpen={false}
          buttonPosition="bottom-right"
        />
      )}
    </QueryClientProvider>
  )
}

// 导出QueryClient实例，供其他地方使用
export { getQueryClient }