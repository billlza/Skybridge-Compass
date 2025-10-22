'use client'

import React, { type ReactNode, Suspense } from 'react'
import { LoadingSpinner } from '@/components/ui/loading-spinner'
import { ErrorBoundary } from '@/components/error-boundary'

/**
 * Suspense加载状态配置
 */
interface SuspenseConfig {
  /** 加载提示文本 */
  loadingText?: string
  /** 最小加载时间（毫秒），防止闪烁 */
  minLoadingTime?: number
  /** 是否显示进度条 */
  showProgress?: boolean
  /** 自定义加载组件 */
  customFallback?: ReactNode
}

/**
 * 全局Suspense提供者属性
 */
interface SuspenseProviderProps {
  children: ReactNode
  config?: SuspenseConfig
  className?: string
}

/**
 * 默认加载回退组件
 */
const DefaultFallback: React.FC<{ config?: SuspenseConfig }> = ({ config }) => {
  return (
    <div className="flex flex-col items-center justify-center min-h-[200px] space-y-4">
      <LoadingSpinner size="lg" />
      {config?.loadingText && (
        <p className="text-slate-400 text-sm animate-pulse">
          {config.loadingText}
        </p>
      )}
      {config?.showProgress && (
        <div className="w-48 h-1 bg-slate-700 rounded-full overflow-hidden">
          <div className="h-full bg-blue-500 rounded-full animate-pulse" 
               style={{ width: '60%' }} />
        </div>
      )}
    </div>
  )
}

/**
 * 卡片式加载回退组件
 */
const CardFallback: React.FC = () => (
  <div className="bg-slate-800/50 border border-slate-700 rounded-xl p-6 animate-pulse">
    <div className="flex items-center space-x-3 mb-4">
      <div className="w-9 h-9 bg-slate-700 rounded-lg" />
      <div className="h-4 bg-slate-700 rounded w-20" />
    </div>
    <div className="h-8 bg-slate-700 rounded w-16 mb-2" />
    <div className="h-3 bg-slate-700 rounded w-24" />
  </div>
)

/**
 * 表格式加载回退组件
 */
const TableFallback: React.FC = () => (
  <div className="bg-slate-900/50 backdrop-blur-sm border border-slate-800 rounded-xl p-6">
    <div className="animate-pulse">
      <div className="h-6 bg-slate-700 rounded w-32 mb-4" />
      <div className="space-y-3">
        {Array.from({ length: 5 }).map((_, index) => (
          <div key={index} className="h-12 bg-slate-700 rounded" />
        ))}
      </div>
    </div>
  </div>
)

/**
 * 列表式加载回退组件
 */
const ListFallback: React.FC = () => (
  <div className="bg-slate-900/50 backdrop-blur-sm border border-slate-800 rounded-xl p-6">
    <div className="animate-pulse">
      <div className="h-6 bg-slate-700 rounded w-24 mb-4" />
      <div className="space-y-4">
        {Array.from({ length: 6 }).map((_, index) => (
          <div key={index} className="flex items-center space-x-3">
            <div className="w-8 h-8 bg-slate-700 rounded-full" />
            <div className="flex-1">
              <div className="h-4 bg-slate-700 rounded w-3/4 mb-2" />
              <div className="h-3 bg-slate-700 rounded w-1/2" />
            </div>
          </div>
        ))}
      </div>
    </div>
  </div>
)

/**
 * 全局Suspense提供者组件
 * 为整个应用提供统一的异步组件加载管理
 */
export const SuspenseProvider: React.FC<SuspenseProviderProps> = ({
  children,
  config,
  className = ''
}) => {
  const fallback = config?.customFallback || <DefaultFallback config={config} />

  return (
    <ErrorBoundary>
      <Suspense fallback={fallback}>
        <div className={className}>
          {children}
        </div>
      </Suspense>
    </ErrorBoundary>
  )
}

/**
 * 带有Suspense的高阶组件
 */
export function withSuspense<P extends object>(
  Component: React.ComponentType<P>,
  fallbackConfig?: SuspenseConfig
) {
  const WrappedComponent = (props: P) => (
    <SuspenseProvider config={fallbackConfig}>
      <Component {...props} />
    </SuspenseProvider>
  )

  WrappedComponent.displayName = `withSuspense(${Component.displayName || Component.name})`
  
  return WrappedComponent
}

/**
 * 预定义的Suspense配置
 */
export const suspenseConfigs = {
  /** 快速加载配置 */
  fast: {
    loadingText: '正在加载...',
    minLoadingTime: 300,
    showProgress: false
  } as SuspenseConfig,

  /** 慢速加载配置 */
  slow: {
    loadingText: '正在获取数据，请稍候...',
    minLoadingTime: 800,
    showProgress: true
  } as SuspenseConfig,

  /** 静默加载配置 */
  silent: {
    minLoadingTime: 100,
    showProgress: false
  } as SuspenseConfig,

  /** 卡片加载配置 */
  card: {
    customFallback: <CardFallback />
  } as SuspenseConfig,

  /** 表格加载配置 */
  table: {
    customFallback: <TableFallback />
  } as SuspenseConfig,

  /** 列表加载配置 */
  list: {
    customFallback: <ListFallback />
  } as SuspenseConfig
}

/**
 * Suspense Hook - 用于在组件内部控制加载状态
 */
export function useSuspenseState() {
  const [isLoading, setIsLoading] = React.useState(false)
  const [error, setError] = React.useState<Error | null>(null)

  const startLoading = React.useCallback(() => {
    setIsLoading(true)
    setError(null)
  }, [])

  const stopLoading = React.useCallback(() => {
    setIsLoading(false)
  }, [])

  const setLoadingError = React.useCallback((error: Error) => {
    setError(error)
    setIsLoading(false)
  }, [])

  return {
    isLoading,
    error,
    startLoading,
    stopLoading,
    setLoadingError
  }
}

/**
 * 延迟Suspense组件 - 防止快速加载时的闪烁
 */
export const DelayedSuspense: React.FC<{
  children: ReactNode
  fallback: ReactNode
  delay?: number
}> = ({ children, fallback, delay = 200 }) => {
  const [showFallback, setShowFallback] = React.useState(false)

  React.useEffect(() => {
    const timer = setTimeout(() => {
      setShowFallback(true)
    }, delay)

    return () => clearTimeout(timer)
  }, [delay])

  return (
    <Suspense fallback={showFallback ? fallback : null}>
      {children}
    </Suspense>
  )
}