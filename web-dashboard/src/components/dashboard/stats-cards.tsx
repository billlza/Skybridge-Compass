'use client'

import React, { memo, useMemo, useCallback } from 'react'
import { cn, formatNumber, formatPercentage } from '@/lib/utils'
import { useDashboardStore } from '@/stores/dashboard-store'
import {
  Plane,
  Users,
  Clock,
  TrendingUp,
  TrendingDown,
  AlertTriangle,
  CheckCircle,
  DollarSign,
  Calendar,
  MapPin
} from 'lucide-react'

interface StatCardProps {
  title: string
  value: string | number
  change?: number
  changeType?: 'increase' | 'decrease' | 'neutral'
  icon: React.ElementType
  description?: string
  trend?: Array<{ value: number; label: string }>
  className?: string
}

/**
 * 优化的统计卡片组件 - 使用React.memo防止不必要的重渲染
 */
const StatCard = memo(function StatCard({
  title,
  value,
  change,
  changeType = 'neutral',
  icon: Icon,
  description,
  trend,
  className
}: StatCardProps) {
  // 使用useCallback缓存函数
  const getChangeColor = useCallback(() => {
    switch (changeType) {
      case 'increase':
        return 'text-green-400'
      case 'decrease':
        return 'text-red-400'
      default:
        return 'text-slate-400'
    }
  }, [changeType])

  const getChangeIcon = useCallback(() => {
    switch (changeType) {
      case 'increase':
        return <TrendingUp className="w-3 h-3" />
      case 'decrease':
        return <TrendingDown className="w-3 h-3" />
      default:
        return null
    }
  }, [changeType])

  // 使用useMemo缓存趋势图计算
  const trendBars = useMemo(() => {
    if (!trend || trend.length === 0) return null
    
    const maxValue = Math.max(...trend.map(t => t.value))
    return trend.map((point, index) => (
      <div
        key={index}
        className="flex-1 bg-blue-500/30 rounded-sm"
        style={{
          height: `${(point.value / maxValue) * 100}%`,
          minHeight: '2px'
        }}
        title={`${point.label}: ${point.value}`}
      />
    ))
  }, [trend])

  return (
    <div className={cn(
      'bg-slate-800/50 border border-slate-700 rounded-xl p-6 hover:bg-slate-800/70 transition-all duration-200',
      className
    )}>
      {/* 卡片头部 */}
      <div className="flex items-center justify-between mb-4">
        <div className="flex items-center space-x-3">
          <div className="p-2 bg-blue-500/10 rounded-lg">
            <Icon className="w-5 h-5 text-blue-400" />
          </div>
          <h3 className="text-sm font-medium text-slate-300">{title}</h3>
        </div>
        
        {change !== undefined && (
          <div className={cn('flex items-center space-x-1 text-xs', getChangeColor())}>
            {getChangeIcon()}
            <span>{formatPercentage(Math.abs(change))}</span>
          </div>
        )}
      </div>

      {/* 主要数值 */}
      <div className="mb-2">
        <p className="text-2xl font-bold text-white">
          {typeof value === 'number' ? formatNumber(value) : value}
        </p>
        {description && (
          <p className="text-sm text-slate-400 mt-1">{description}</p>
        )}
      </div>

      {/* 趋势图（简化版） */}
      {trend && trend.length > 0 && (
        <div className="mt-4">
          <div className="flex items-end space-x-1 h-8">
            {trend.map((point, index) => (
              <div
                key={index}
                className="flex-1 bg-blue-500/30 rounded-sm"
                style={{
                  height: `${(point.value / Math.max(...trend.map(t => t.value))) * 100}%`,
                  minHeight: '2px'
                }}
                title={`${point.label}: ${point.value}`}
              />
            ))}
          </div>
        </div>
      )}
    </div>
  )
})

/**
 * 统计卡片容器组件 - 2025年性能优化版本
 */
export const StatsCards = memo(function StatsCards() {
  const { stats, isLoading } = useDashboardStore()

  // 使用useMemo缓存趋势数据生成函数
  const generateTrend = useCallback((base: number, variance: number = 0.2) => {
    return Array.from({ length: 7 }, (_, i) => ({
      value: Math.floor(base * (1 + (Math.random() - 0.5) * variance)),
      label: `Day ${i + 1}`
    }))
  }, [])

  // 使用useMemo缓存统计卡片数据
  const statsCardsData = useMemo(() => {
    if (!stats) return []
    
    return [
      {
        title: "今日航班数",
        value: stats.todayFlights,
        change: 5.2,
        changeType: "increase" as const,
        icon: Plane,
        description: "今日执行航班",
        trend: generateTrend(stats.todayFlights)
      },
      {
        title: "准点率",
        value: `${stats.onTimeRate}%`,
        change: 2.1,
        changeType: "increase" as const,
        icon: CheckCircle,
        description: "过去24小时",
        trend: generateTrend(stats.onTimeRate, 0.1)
      },
      {
        title: "总乘客数",
        value: stats.totalPassengers,
        change: 8.5,
        changeType: "increase" as const,
        icon: Users,
        description: "今日乘客",
        trend: generateTrend(stats.totalPassengers)
      },
      {
        title: "今日收入",
        value: `¥${formatNumber(stats.revenue)}`,
        change: 6.3,
        changeType: "increase" as const,
        icon: DollarSign,
        description: "预计收入",
        trend: generateTrend(stats.revenue, 0.15)
      },
      {
        title: "延误航班",
        value: "12",
        change: -1.8,
        changeType: "decrease" as const,
        icon: AlertTriangle,
        description: "当前延误中",
        trend: generateTrend(12)
      },
      {
        title: "活跃机组",
        value: "156",
        change: 3.5,
        changeType: "increase" as const,
        icon: Users,
        description: "当前值班人员",
        trend: generateTrend(156)
      },
      {
        title: "平均延误",
        value: "15分钟",
        change: -12.3,
        changeType: "decrease" as const,
        icon: Clock,
        description: "相比昨日",
        trend: generateTrend(15)
      },
      {
        title: "航线覆盖",
        value: "156条",
        change: 0.6,
        changeType: "increase" as const,
        icon: MapPin,
        description: "活跃航线",
        trend: generateTrend(156, 0.05)
      }
    ]
  }, [stats, generateTrend])

  // 加载状态骨架屏
  const loadingSkeleton = useMemo(() => (
    <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-6">
      {Array.from({ length: 8 }).map((_, index) => (
        <div
          key={index}
          className="bg-slate-800/50 border border-slate-700 rounded-xl p-6 animate-pulse"
        >
          <div className="flex items-center space-x-3 mb-4">
            <div className="w-9 h-9 bg-slate-700 rounded-lg" />
            <div className="h-4 bg-slate-700 rounded w-20" />
          </div>
          <div className="h-8 bg-slate-700 rounded w-16 mb-2" />
          <div className="h-3 bg-slate-700 rounded w-24" />
        </div>
      ))}
    </div>
  ), [])

  if (isLoading || !stats) {
    return loadingSkeleton
  }

  return (
    <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-6">
      {statsCardsData.map((cardData, index) => (
        <StatCard
          key={cardData.title}
          {...cardData}
        />
      ))}
    </div>
  )
})