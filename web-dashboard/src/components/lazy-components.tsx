'use client'

import React, { lazy, Suspense, useEffect } from 'react'

/**
 * 懒加载包装器组件的属性接口
 */
export interface LazyWrapperProps {
  /** 子组件 */
  children: React.ReactNode
  /** 加载时显示的回退组件 */
  fallback?: React.ReactNode
  /** 组件名称，用于调试 */
  componentName?: string
}

/**
 * 懒加载包装器组件
 * 提供统一的懒加载体验和错误边界
 */
export function LazyWrapper({ 
  children, 
  fallback = <div className="flex items-center justify-center p-8">
    <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-blue-600"></div>
  </div>,
  componentName = 'Component'
}: LazyWrapperProps) {
  return (
    <Suspense fallback={fallback}>
      {children}
    </Suspense>
  )
}

// 预加载组件映射
const preloadComponents = {
  'main-control-panel': () => import('@/components/dashboard/main-control-panel'),
  'system-monitoring': () => import('@/components/dashboard/system-monitoring'),
  'device-management': () => import('@/components/dashboard/device-management'),
  'remote-desktop': () => import('@/components/dashboard/remote-desktop'),
  'file-transfer': () => import('@/components/dashboard/file-transfer'),
  'user-settings': () => import('@/components/dashboard/user-settings'),
  'dashboard': () => import('@/components/dashboard/dashboard'),
  'charts-section': () => import('@/components/dashboard/charts-section'),
  'data-table': () => import('@/components/dashboard/data-table'),
  'activity-feed': () => import('@/components/dashboard/activity-feed'),
  'stats-cards': () => import('@/components/dashboard/stats-cards')
} as const

type PreloadComponentKey = keyof typeof preloadComponents

/**
 * 组件预加载Hook
 * @param componentKeys 要预加载的组件键名数组
 */
export function usePreloadComponents(componentKeys: PreloadComponentKey[]) {
  useEffect(() => {
    // 预加载指定的组件
    componentKeys.forEach(key => {
      if (preloadComponents[key]) {
        preloadComponents[key]()
      }
    })
  }, [componentKeys])
}

/**
 * 基于Intersection Observer的懒加载组件
 * 只有当组件进入视口时才开始加载
 */
interface IntersectionLazyProps {
  children: React.ReactNode
  fallback?: React.ReactNode
  rootMargin?: string
  threshold?: number
  className?: string
}

export function IntersectionLazy({
  children,
  fallback = <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-blue-600"></div>,
  rootMargin = '50px',
  threshold = 0.1,
  className
}: IntersectionLazyProps) {
  const [isVisible, setIsVisible] = React.useState(false)
  const ref = React.useRef<HTMLDivElement>(null)

  React.useEffect(() => {
    const observer = new IntersectionObserver(
      ([entry]) => {
        if (entry.isIntersecting) {
          setIsVisible(true)
          observer.disconnect()
        }
      },
      {
        rootMargin,
        threshold
      }
    )

    if (ref.current) {
      observer.observe(ref.current)
    }

    return () => observer.disconnect()
  }, [rootMargin, threshold])

  return (
    <div ref={ref} className={className}>
      {isVisible ? (
        <Suspense fallback={fallback}>
          {children}
        </Suspense>
      ) : (
        fallback
      )}
    </div>
  )
}

/**
 * 渐进式加载组件
 * 按优先级逐步加载组件，提升感知性能
 */
interface ProgressiveLoadProps {
  components: Array<{
    component: React.LazyExoticComponent<any>
    priority: number
    fallback?: React.ReactNode
  }>
  className?: string
}

export function ProgressiveLoad({ components, className }: ProgressiveLoadProps) {
  const [loadedPriorities, setLoadedPriorities] = React.useState<Set<number>>(new Set([1]))

  React.useEffect(() => {
    const sortedPriorities = [...new Set(components.map(c => c.priority))].sort((a, b) => a - b)
    
    sortedPriorities.forEach((priority, index) => {
      const delay = index * 200 // 每个优先级延迟200ms
      setTimeout(() => {
        setLoadedPriorities(prev => new Set([...prev, priority]))
      }, delay)
    })
  }, [components])

  return (
    <div className={className}>
      {components.map((item, index) => {
        const shouldLoad = loadedPriorities.has(item.priority)
        const Component = item.component
        
        return (
          <div key={index}>
            {shouldLoad ? (
              <Suspense fallback={item.fallback || <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-blue-600"></div>}>
                <Component />
              </Suspense>
            ) : (
              item.fallback || <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-blue-600"></div>
            )}
          </div>
        )
      })}
    </div>
  )
}