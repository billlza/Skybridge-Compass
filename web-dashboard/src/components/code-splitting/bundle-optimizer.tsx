'use client'

import React, { type ReactNode } from 'react'

/**
 * 资源优先级枚举
 */
export enum ResourcePriority {
  CRITICAL = 'critical',
  HIGH = 'high',
  MEDIUM = 'medium',
  LOW = 'low'
}

/**
 * 资源类型枚举
 */
export enum ResourceType {
  SCRIPT = 'script',
  STYLE = 'style',
  IMAGE = 'image',
  FONT = 'font',
  DATA = 'data'
}

/**
 * 资源配置接口
 */
interface ResourceConfig {
  /** 资源URL */
  url: string
  /** 资源类型 */
  type: ResourceType
  /** 优先级 */
  priority: ResourcePriority
  /** 是否预加载 */
  preload?: boolean
  /** 是否预连接 */
  preconnect?: boolean
  /** 媒体查询条件 */
  media?: string
  /** 跨域设置 */
  crossOrigin?: 'anonymous' | 'use-credentials'
}

/**
 * 性能指标接口
 */
interface PerformanceMetrics {
  /** 首次内容绘制时间 */
  fcp?: number
  /** 最大内容绘制时间 */
  lcp?: number
  /** 首次输入延迟 */
  fid?: number
  /** 累积布局偏移 */
  cls?: number
  /** 总阻塞时间 */
  tbt?: number
  /** 交互时间 */
  tti?: number
}

/**
 * 打包优化管理器
 */
class BundleOptimizer {
  private static instance: BundleOptimizer
  private resources = new Map<string, ResourceConfig>()
  private loadedResources = new Set<string>()
  private performanceObserver?: PerformanceObserver
  private metrics: PerformanceMetrics = {}

  static getInstance(): BundleOptimizer {
    if (!BundleOptimizer.instance) {
      BundleOptimizer.instance = new BundleOptimizer()
    }
    return BundleOptimizer.instance
  }

  constructor() {
    if (typeof window !== 'undefined') {
      this.initPerformanceMonitoring()
    }
  }

  /**
   * 初始化性能监控
   */
  private initPerformanceMonitoring(): void {
    // 监控核心Web指标
    if ('PerformanceObserver' in window) {
      // 监控LCP
      const lcpObserver = new PerformanceObserver((list) => {
        const entries = list.getEntries()
        const lastEntry = entries[entries.length - 1] as any
        this.metrics.lcp = lastEntry.startTime
      })
      lcpObserver.observe({ entryTypes: ['largest-contentful-paint'] })

      // 监控FID
      const fidObserver = new PerformanceObserver((list) => {
        const entries = list.getEntries()
        entries.forEach((entry: any) => {
          this.metrics.fid = entry.processingStart - entry.startTime
        })
      })
      fidObserver.observe({ entryTypes: ['first-input'] })

      // 监控CLS
      const clsObserver = new PerformanceObserver((list) => {
        let clsValue = 0
        const entries = list.getEntries()
        entries.forEach((entry: any) => {
          if (!entry.hadRecentInput) {
            clsValue += entry.value
          }
        })
        this.metrics.cls = clsValue
      })
      clsObserver.observe({ entryTypes: ['layout-shift'] })
    }

    // 监控FCP
    if ('performance' in window && 'getEntriesByType' in performance) {
      const paintEntries = performance.getEntriesByType('paint')
      const fcpEntry = paintEntries.find(entry => entry.name === 'first-contentful-paint')
      if (fcpEntry) {
        this.metrics.fcp = fcpEntry.startTime
      }
    }
  }

  /**
   * 注册资源
   */
  registerResource(config: ResourceConfig): void {
    this.resources.set(config.url, config)
  }

  /**
   * 批量注册资源
   */
  registerResources(configs: ResourceConfig[]): void {
    configs.forEach(config => this.registerResource(config))
  }

  /**
   * 预加载资源
   */
  async preloadResource(url: string): Promise<void> {
    if (this.loadedResources.has(url)) {
      return
    }

    const config = this.resources.get(url)
    if (!config) {
      console.warn(`资源配置未找到: ${url}`)
      return
    }

    try {
      switch (config.type) {
        case ResourceType.SCRIPT:
          await this.preloadScript(config)
          break
        case ResourceType.STYLE:
          await this.preloadStyle(config)
          break
        case ResourceType.IMAGE:
          await this.preloadImage(config)
          break
        case ResourceType.FONT:
          await this.preloadFont(config)
          break
        case ResourceType.DATA:
          await this.preloadData(config)
          break
      }
      this.loadedResources.add(url)
    } catch (error) {
      console.error(`预加载资源失败 ${url}:`, error)
    }
  }

  /**
   * 预加载脚本
   */
  private preloadScript(config: ResourceConfig): Promise<void> {
    return new Promise((resolve, reject) => {
      const link = document.createElement('link')
      link.rel = 'preload'
      link.as = 'script'
      link.href = config.url
      if (config.crossOrigin) {
        link.crossOrigin = config.crossOrigin
      }
      link.onload = () => resolve()
      link.onerror = reject
      document.head.appendChild(link)
    })
  }

  /**
   * 预加载样式
   */
  private preloadStyle(config: ResourceConfig): Promise<void> {
    return new Promise((resolve, reject) => {
      const link = document.createElement('link')
      link.rel = 'preload'
      link.as = 'style'
      link.href = config.url
      if (config.media) {
        link.media = config.media
      }
      link.onload = () => resolve()
      link.onerror = reject
      document.head.appendChild(link)
    })
  }

  /**
   * 预加载图片
   */
  private preloadImage(config: ResourceConfig): Promise<void> {
    return new Promise((resolve, reject) => {
      const img = new Image()
      img.onload = () => resolve()
      img.onerror = reject
      img.src = config.url
    })
  }

  /**
   * 预加载字体
   */
  private preloadFont(config: ResourceConfig): Promise<void> {
    return new Promise((resolve, reject) => {
      const link = document.createElement('link')
      link.rel = 'preload'
      link.as = 'font'
      link.href = config.url
      link.crossOrigin = 'anonymous'
      link.onload = () => resolve()
      link.onerror = reject
      document.head.appendChild(link)
    })
  }

  /**
   * 预加载数据
   */
  private preloadData(config: ResourceConfig): Promise<void> {
    return fetch(config.url, {
      mode: config.crossOrigin ? 'cors' : 'same-origin'
    }).then(() => {})
  }

  /**
   * 智能预加载
   */
  async smartPreload(): Promise<void> {
    const criticalResources = Array.from(this.resources.values())
      .filter(config => config.priority === ResourcePriority.CRITICAL)
      .map(config => config.url)

    const highPriorityResources = Array.from(this.resources.values())
      .filter(config => config.priority === ResourcePriority.HIGH)
      .map(config => config.url)

    // 立即加载关键资源
    await Promise.allSettled(
      criticalResources.map(url => this.preloadResource(url))
    )

    // 延迟加载高优先级资源
    setTimeout(() => {
      Promise.allSettled(
        highPriorityResources.map(url => this.preloadResource(url))
      )
    }, 100)
  }

  /**
   * 获取性能指标
   */
  getMetrics(): PerformanceMetrics {
    return { ...this.metrics }
  }

  /**
   * 获取资源加载状态
   */
  getLoadingStatus(): {
    total: number
    loaded: number
    pending: number
    percentage: number
  } {
    const total = this.resources.size
    const loaded = this.loadedResources.size
    const pending = total - loaded
    const percentage = total > 0 ? Math.round((loaded / total) * 100) : 0

    return { total, loaded, pending, percentage }
  }

  /**
   * 清除缓存
   */
  clearCache(): void {
    this.loadedResources.clear()
  }
}

/**
 * 资源优化组件属性
 */
interface ResourceOptimizerProps {
  /** 资源配置列表 */
  resources: ResourceConfig[]
  /** 是否启用智能预加载 */
  enableSmartPreload?: boolean
  /** 是否显示加载进度 */
  showProgress?: boolean
  /** 子组件 */
  children: ReactNode
}

/**
 * 资源优化组件
 */
export const ResourceOptimizer: React.FC<ResourceOptimizerProps> = ({
  resources,
  enableSmartPreload = true,
  showProgress = false,
  children
}) => {
  const [loadingStatus, setLoadingStatus] = React.useState({
    total: 0,
    loaded: 0,
    pending: 0,
    percentage: 0
  })

  const optimizer = BundleOptimizer.getInstance()

  // 注册资源
  React.useEffect(() => {
    optimizer.registerResources(resources)
  }, [resources])

  // 智能预加载
  React.useEffect(() => {
    if (enableSmartPreload) {
      optimizer.smartPreload()
    }
  }, [enableSmartPreload])

  // 更新加载状态
  React.useEffect(() => {
    const updateStatus = () => {
      setLoadingStatus(optimizer.getLoadingStatus())
    }

    updateStatus()
    const interval = setInterval(updateStatus, 1000)
    return () => clearInterval(interval)
  }, [])

  return (
    <>
      {showProgress && loadingStatus.percentage < 100 && (
        <div className="fixed top-0 left-0 right-0 z-50">
          <div className="h-1 bg-slate-700">
            <div
              className="h-full bg-blue-500 transition-all duration-300"
              style={{ width: `${loadingStatus.percentage}%` }}
            />
          </div>
        </div>
      )}
      {children}
    </>
  )
}

/**
 * 性能监控Hook
 */
export function usePerformanceMetrics(): {
  metrics: PerformanceMetrics
  loadingStatus: ReturnType<BundleOptimizer['getLoadingStatus']>
} {
  const [metrics, setMetrics] = React.useState<PerformanceMetrics>({})
  const [loadingStatus, setLoadingStatus] = React.useState({
    total: 0,
    loaded: 0,
    pending: 0,
    percentage: 0
  })

  const optimizer = BundleOptimizer.getInstance()

  React.useEffect(() => {
    const updateMetrics = () => {
      setMetrics(optimizer.getMetrics())
      setLoadingStatus(optimizer.getLoadingStatus())
    }

    updateMetrics()
    const interval = setInterval(updateMetrics, 1000)
    return () => clearInterval(interval)
  }, [])

  return { metrics, loadingStatus }
}

/**
 * 预定义的资源配置
 */
export const resourceConfigs = {
  /** 关键CSS */
  criticalCSS: (url: string): ResourceConfig => ({
    url,
    type: ResourceType.STYLE,
    priority: ResourcePriority.CRITICAL,
    preload: true
  }),

  /** 主要JavaScript */
  mainScript: (url: string): ResourceConfig => ({
    url,
    type: ResourceType.SCRIPT,
    priority: ResourcePriority.HIGH,
    preload: true
  }),

  /** 字体文件 */
  font: (url: string): ResourceConfig => ({
    url,
    type: ResourceType.FONT,
    priority: ResourcePriority.MEDIUM,
    preload: true,
    crossOrigin: 'anonymous'
  }),

  /** 图片资源 */
  image: (url: string, priority: ResourcePriority = ResourcePriority.LOW): ResourceConfig => ({
    url,
    type: ResourceType.IMAGE,
    priority,
    preload: priority === ResourcePriority.CRITICAL || priority === ResourcePriority.HIGH
  }),

  /** API数据 */
  apiData: (url: string): ResourceConfig => ({
    url,
    type: ResourceType.DATA,
    priority: ResourcePriority.HIGH,
    preload: true
  })
}