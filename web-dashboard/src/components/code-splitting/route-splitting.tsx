'use client'

import React, { type ComponentType, type ReactNode } from 'react'
import { usePathname, useRouter } from 'next/navigation'
import { LoadingSpinner } from '@/components/ui/loading-spinner'
import { createDynamicImport, type DynamicImportOptions } from './dynamic-imports'

/**
 * 路由配置接口
 */
interface RouteConfig {
  /** 路由路径 */
  path: string
  /** 组件导入函数 */
  component: () => Promise<{ default: ComponentType<any> }>
  /** 动态导入选项 */
  options?: DynamicImportOptions
  /** 预加载条件 */
  preload?: boolean | ((pathname: string) => boolean)
  /** 路由元数据 */
  meta?: {
    title?: string
    description?: string
    keywords?: string[]
  }
}

/**
 * 路由分割管理器
 */
class RouteSplittingManager {
  private static instance: RouteSplittingManager
  private routes = new Map<string, RouteConfig>()
  private preloadedRoutes = new Set<string>()

  static getInstance(): RouteSplittingManager {
    if (!RouteSplittingManager.instance) {
      RouteSplittingManager.instance = new RouteSplittingManager()
    }
    return RouteSplittingManager.instance
  }

  /**
   * 注册路由
   */
  register(config: RouteConfig): void {
    this.routes.set(config.path, config)
  }

  /**
   * 批量注册路由
   */
  registerRoutes(configs: RouteConfig[]): void {
    configs.forEach(config => this.register(config))
  }

  /**
   * 获取路由配置
   */
  getRoute(path: string): RouteConfig | undefined {
    return this.routes.get(path)
  }

  /**
   * 获取所有路由
   */
  getAllRoutes(): RouteConfig[] {
    return Array.from(this.routes.values())
  }

  /**
   * 预加载路由
   */
  async preloadRoute(path: string): Promise<void> {
    if (this.preloadedRoutes.has(path)) {
      return
    }

    const route = this.routes.get(path)
    if (route) {
      try {
        await route.component()
        this.preloadedRoutes.add(path)
      } catch (error) {
        console.warn(`预加载路由 ${path} 失败:`, error)
      }
    }
  }

  /**
   * 智能预加载相关路由
   */
  async smartPreload(currentPath: string): Promise<void> {
    const preloadPromises: Promise<void>[] = []

    this.routes.forEach((route, path) => {
      if (path === currentPath) return

      let shouldPreload = false

      if (typeof route.preload === 'boolean') {
        shouldPreload = route.preload
      } else if (typeof route.preload === 'function') {
        shouldPreload = route.preload(currentPath)
      } else {
        // 默认预加载策略：预加载相似路径的路由
        shouldPreload = this.isSimilarPath(currentPath, path)
      }

      if (shouldPreload) {
        preloadPromises.push(this.preloadRoute(path))
      }
    })

    await Promise.allSettled(preloadPromises)
  }

  /**
   * 判断路径是否相似
   */
  private isSimilarPath(currentPath: string, targetPath: string): boolean {
    const currentSegments = currentPath.split('/').filter(Boolean)
    const targetSegments = targetPath.split('/').filter(Boolean)

    // 如果有共同的父路径，则认为相似
    if (currentSegments.length > 0 && targetSegments.length > 0) {
      return currentSegments[0] === targetSegments[0]
    }

    return false
  }

  /**
   * 清除预加载缓存
   */
  clearPreloadCache(): void {
    this.preloadedRoutes.clear()
  }
}

/**
 * 路由分割组件属性
 */
interface RouteSplitterProps {
  /** 路由配置 */
  routes: RouteConfig[]
  /** 默认加载组件 */
  fallback?: ReactNode
  /** 404页面组件 */
  notFound?: ComponentType
  /** 是否启用智能预加载 */
  enableSmartPreload?: boolean
  /** 子组件 */
  children?: ReactNode
}

/**
 * 默认404组件
 */
const DefaultNotFound: React.FC = () => (
  <div className="flex flex-col items-center justify-center min-h-[400px] text-center">
    <div className="text-6xl font-bold text-slate-600 mb-4">404</div>
    <div className="text-xl text-slate-400 mb-2">页面未找到</div>
    <div className="text-slate-500 mb-6">您访问的页面不存在或已被移除</div>
    <button
      onClick={() => window.history.back()}
      className="px-6 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 transition-colors"
    >
      返回上一页
    </button>
  </div>
)

/**
 * 路由分割组件
 */
export const RouteSplitter: React.FC<RouteSplitterProps> = ({
  routes,
  fallback = <LoadingSpinner size="lg" />,
  notFound: NotFoundComponent = DefaultNotFound,
  enableSmartPreload = true,
  children
}) => {
  const pathname = usePathname()
  const router = useRouter()
  const manager = RouteSplittingManager.getInstance()

  // 注册路由
  React.useEffect(() => {
    manager.registerRoutes(routes)
  }, [routes])

  // 智能预加载
  React.useEffect(() => {
    if (enableSmartPreload) {
      manager.smartPreload(pathname)
    }
  }, [pathname, enableSmartPreload])

  // 查找匹配的路由
  const matchedRoute = React.useMemo(() => {
    return routes.find(route => {
      if (route.path === pathname) return true
      
      // 支持动态路由匹配（简单实现）
      const routePattern = route.path.replace(/\[([^\]]+)\]/g, '([^/]+)')
      const regex = new RegExp(`^${routePattern}$`)
      return regex.test(pathname)
    })
  }, [pathname, routes])

  // 创建动态组件
  const DynamicComponent = React.useMemo(() => {
    if (!matchedRoute) return null
    return createDynamicImport(matchedRoute.component, {
      delay: 200,
      timeout: 10000,
      ...matchedRoute.options
    })
  }, [matchedRoute])

  if (!matchedRoute) {
    return <NotFoundComponent />
  }

  if (!DynamicComponent) {
    return <NotFoundComponent />
  }

  return (
    <React.Suspense fallback={fallback}>
      <DynamicComponent />
      {children}
    </React.Suspense>
  )
}

/**
 * 路由预加载Hook
 */
export function useRoutePreload() {
  const manager = RouteSplittingManager.getInstance()
  const pathname = usePathname()

  const preloadRoute = React.useCallback((path: string) => {
    return manager.preloadRoute(path)
  }, [manager])

  const preloadRoutes = React.useCallback((paths: string[]) => {
    return Promise.allSettled(paths.map(path => manager.preloadRoute(path)))
  }, [manager])

  const smartPreload = React.useCallback(() => {
    return manager.smartPreload(pathname)
  }, [manager, pathname])

  return {
    preloadRoute,
    preloadRoutes,
    smartPreload
  }
}

/**
 * 路由链接组件（带预加载功能）
 */
interface RouteLinkProps {
  href: string
  children: ReactNode
  preload?: boolean
  className?: string
  onClick?: () => void
}

export const RouteLink: React.FC<RouteLinkProps> = ({
  href,
  children,
  preload = true,
  className = '',
  onClick
}) => {
  const router = useRouter()
  const { preloadRoute } = useRoutePreload()

  const handleMouseEnter = React.useCallback(() => {
    if (preload) {
      preloadRoute(href)
    }
  }, [href, preload, preloadRoute])

  const handleClick = React.useCallback((e: React.MouseEvent) => {
    e.preventDefault()
    onClick?.()
    router.push(href)
  }, [href, onClick, router])

  return (
    <a
      href={href}
      className={className}
      onMouseEnter={handleMouseEnter}
      onClick={handleClick}
    >
      {children}
    </a>
  )
}

/**
 * 预定义的路由配置
 */
export const createRouteConfig = (
  path: string,
  componentPath: string,
  options?: Partial<RouteConfig>
): RouteConfig => ({
  path,
  component: () => import(componentPath),
  preload: true,
  options: {
    delay: 200,
    timeout: 10000,
    preload: 'hover'
  },
  ...options
})

/**
 * 常用路由配置模板
 */
export const routeTemplates = {
  /** 仪表板路由 */
  dashboard: (componentPath: string) => createRouteConfig(
    '/dashboard',
    componentPath,
    {
      preload: true,
      options: {
        delay: 100,
        timeout: 5000,
        preload: 'intent'
      },
      meta: {
        title: '仪表板',
        description: '系统概览和数据监控'
      }
    }
  ),

  /** 设置页面路由 */
  settings: (componentPath: string) => createRouteConfig(
    '/settings',
    componentPath,
    {
      preload: false,
      options: {
        delay: 300,
        timeout: 8000,
        preload: 'visible'
      },
      meta: {
        title: '设置',
        description: '系统配置和用户偏好'
      }
    }
  ),

  /** 详情页面路由 */
  detail: (basePath: string, componentPath: string) => createRouteConfig(
    `${basePath}/[id]`,
    componentPath,
    {
      preload: (currentPath: string) => currentPath.startsWith(basePath),
      options: {
        delay: 200,
        timeout: 10000,
        preload: 'hover'
      }
    }
  )
}