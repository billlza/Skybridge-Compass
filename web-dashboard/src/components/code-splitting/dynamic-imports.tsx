'use client'

import React, { type ComponentType, type ReactNode } from 'react'
import { LoadingSpinner } from '@/components/ui/loading-spinner'

/**
 * 动态导入配置选项
 */
export interface DynamicImportOptions {
  /** 加载状态组件 */
  loading?: ComponentType
  /** 错误状态组件 */
  error?: ComponentType<{ error: Error; retry: () => void }>
  /** 延迟时间（毫秒），防止闪烁 */
  delay?: number
  /** 超时时间（毫秒） */
  timeout?: number
  /** 是否启用服务端渲染 */
  ssr?: boolean
  /** 预加载策略 */
  preload?: 'hover' | 'visible' | 'intent' | 'none'
}

/**
 * 默认加载组件
 */
const DefaultLoading: React.FC = () => (
  <div className="flex items-center justify-center p-8">
    <LoadingSpinner size="md" />
  </div>
)

/**
 * 默认错误组件
 */
const DefaultError: React.FC<{ error: Error; retry: () => void }> = ({ error, retry }) => (
  <div className="flex flex-col items-center justify-center p-8 text-center">
    <div className="text-red-400 mb-2">加载失败</div>
    <div className="text-slate-400 text-sm mb-4">{error.message}</div>
    <button
      onClick={retry}
      className="px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 transition-colors"
    >
      重试
    </button>
  </div>
)

/**
 * 创建动态导入组件
 */
export function createDynamicImport<P extends object>(
  importFn: () => Promise<{ default: ComponentType<P> }>,
  options: DynamicImportOptions = {}
): ComponentType<P> {
  const {
    loading: LoadingComponent = DefaultLoading,
    error: ErrorComponent = DefaultError,
    delay = 200,
    timeout = 10000,
    ssr = false,
    preload = 'none'
  } = options

  const DynamicComponent = React.lazy(() => {
    const importPromise = importFn()

    // 添加超时处理
    const timeoutPromise = new Promise<never>((_, reject) => {
      setTimeout(() => {
        reject(new Error(`组件加载超时 (${timeout}ms)`))
      }, timeout)
    })

    return Promise.race([importPromise, timeoutPromise])
  })

  const WrappedComponent: React.FC<P> = (props) => {
    const [showFallback, setShowFallback] = React.useState(!delay)
    const [error, setError] = React.useState<Error | null>(null)
    const [retryKey, setRetryKey] = React.useState(0)

    // 延迟显示加载状态，防止闪烁
    React.useEffect(() => {
      if (delay > 0) {
        const timer = setTimeout(() => {
          setShowFallback(true)
        }, delay)
        return () => clearTimeout(timer)
      }
    }, [])

    // 重试函数
    const retry = React.useCallback(() => {
      setError(null)
      setRetryKey(prev => prev + 1)
    }, [])

    // 错误边界
    const ErrorBoundary: React.FC<{ children: ReactNode }> = ({ children }) => {
      React.useEffect(() => {
        const handleError = (event: ErrorEvent) => {
          setError(new Error(event.message))
        }

        window.addEventListener('error', handleError)
        return () => window.removeEventListener('error', handleError)
      }, [])

      return <>{children}</>
    }

    if (error) {
      return <ErrorComponent error={error} retry={retry} />
    }

    return (
      <ErrorBoundary>
        <React.Suspense
          key={retryKey}
          fallback={showFallback ? <LoadingComponent /> : null}
        >
          <DynamicComponent {...(props as any)} />
        </React.Suspense>
      </ErrorBoundary>
    )
  }

  // 预加载功能
  if (preload !== 'none') {
    const PreloadWrapper: React.FC<P & { children?: ReactNode }> = (props) => {
      const ref = React.useRef<HTMLDivElement>(null)
      const [hasPreloaded, setHasPreloaded] = React.useState(false)

      const handlePreload = React.useCallback(() => {
        if (!hasPreloaded) {
          importFn().catch(() => {
            // 静默处理预加载错误
          })
          setHasPreloaded(true)
        }
      }, [hasPreloaded])

      React.useEffect(() => {
        const element = ref.current
        if (!element) return

        switch (preload) {
          case 'hover':
            element.addEventListener('mouseenter', handlePreload)
            return () => element.removeEventListener('mouseenter', handlePreload)

          case 'visible':
            const observer = new IntersectionObserver(
              ([entry]) => {
                if (entry.isIntersecting) {
                  handlePreload()
                  observer.disconnect()
                }
              },
              { threshold: 0.1 }
            )
            observer.observe(element)
            return () => observer.disconnect()

          case 'intent':
            const handleMouseMove = () => {
              handlePreload()
              element.removeEventListener('mousemove', handleMouseMove)
            }
            element.addEventListener('mousemove', handleMouseMove)
            return () => element.removeEventListener('mousemove', handleMouseMove)
        }
      }, [handlePreload])

      return (
        <div ref={ref}>
          <WrappedComponent {...props} />
        </div>
      )
    }

    PreloadWrapper.displayName = `PreloadWrapper(${(DynamicComponent as any).displayName || 'Component'})`
    return PreloadWrapper as ComponentType<P>
  }

  WrappedComponent.displayName = `Dynamic(${(DynamicComponent as any).displayName || 'Component'})`
  return WrappedComponent
}

/**
 * 批量动态导入工具
 */
export class DynamicImportManager {
  private static instance: DynamicImportManager
  private importCache = new Map<string, Promise<any>>()
  private componentCache = new Map<string, ComponentType<any>>()

  static getInstance(): DynamicImportManager {
    if (!DynamicImportManager.instance) {
      DynamicImportManager.instance = new DynamicImportManager()
    }
    return DynamicImportManager.instance
  }

  /**
   * 注册动态导入
   */
  register<P extends object>(
    key: string,
    importFn: () => Promise<{ default: ComponentType<P> }>,
    options?: DynamicImportOptions
  ): ComponentType<P> {
    if (this.componentCache.has(key)) {
      return this.componentCache.get(key)!
    }

    const component = createDynamicImport(importFn, options)
    this.componentCache.set(key, component)
    return component
  }

  /**
   * 预加载组件
   */
  async preload(key: string): Promise<void> {
    if (this.importCache.has(key)) {
      return this.importCache.get(key)
    }

    // 这里需要根据实际的导入函数来实现
    // 由于我们无法直接访问注册时的导入函数，这里提供一个基础实现
    console.warn(`预加载组件 ${key}：需要在注册时提供预加载支持`)
  }

  /**
   * 批量预加载
   */
  async preloadAll(keys: string[]): Promise<void> {
    await Promise.allSettled(keys.map(key => this.preload(key)))
  }

  /**
   * 清除缓存
   */
  clearCache(key?: string): void {
    if (key) {
      this.importCache.delete(key)
      this.componentCache.delete(key)
    } else {
      this.importCache.clear()
      this.componentCache.clear()
    }
  }

  /**
   * 获取缓存状态
   */
  getCacheInfo(): { imports: number; components: number } {
    return {
      imports: this.importCache.size,
      components: this.componentCache.size
    }
  }
}

/**
 * 动态导入Hook
 */
export function useDynamicImport<T>(
  importFn: () => Promise<T>,
  deps: React.DependencyList = []
): {
  data: T | null
  loading: boolean
  error: Error | null
  retry: () => void
} {
  const [data, setData] = React.useState<T | null>(null)
  const [loading, setLoading] = React.useState(false)
  const [error, setError] = React.useState<Error | null>(null)

  const retry = React.useCallback(() => {
    setLoading(true)
    setError(null)
    
    importFn()
      .then(result => {
        setData(result)
        setError(null)
      })
      .catch(err => {
        setError(err instanceof Error ? err : new Error(String(err)))
        setData(null)
      })
      .finally(() => {
        setLoading(false)
      })
  }, deps)

  React.useEffect(() => {
    retry()
  }, [retry])

  return { data, loading, error, retry }
}

/**
 * 预定义的动态导入配置
 */
export const dynamicConfigs = {
  /** 快速加载配置 */
  fast: {
    delay: 100,
    timeout: 5000,
    preload: 'hover' as const
  },

  /** 慢速加载配置 */
  slow: {
    delay: 300,
    timeout: 15000,
    preload: 'visible' as const
  },

  /** 关键组件配置 */
  critical: {
    delay: 0,
    timeout: 3000,
    ssr: true,
    preload: 'intent' as const
  },

  /** 非关键组件配置 */
  nonCritical: {
    delay: 500,
    timeout: 10000,
    ssr: false,
    preload: 'visible' as const
  }
} as const