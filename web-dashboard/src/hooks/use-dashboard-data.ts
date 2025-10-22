import { useQuery, useQueryClient, useMutation } from '@tanstack/react-query'
import { useDashboardStore } from '@/stores/dashboard-store'
import { useEffect } from 'react'
import { DataAdapter, getDataSourceInfo } from '@/lib/data-adapter'
import type { Device, SystemMetrics, Alert, UserProfile } from '@/lib/api'

// 查询键常量
const QUERY_KEYS = {
  devices: ['devices'],
  systemMetrics: ['systemMetrics'],
  alerts: ['alerts'],
  userProfile: ['userProfile'],
  files: ['files'],
  remoteConnections: ['remoteConnections'],
  flights: ['flights'], // 保留原有的航班数据
  stats: ['stats'],
  activities: ['activities'],
  flightDetails: (id: string) => ['flights', id] as const,
} as const

// 保留原有数据类型定义
export interface Flight {
  id: string
  route: string
  departure: string
  arrival: string
  status: 'on-time' | 'delayed' | 'boarding' | 'scheduled' | 'cancelled'
  statusText: string
  aircraft: string
  passengers: string
  gate: string
}

export interface Stats {
  todayFlights: number
  totalPassengers: number
  onTimeRate: number
  revenue: number
  flightChange: string
  passengerChange: string
  onTimeChange: string
  revenueChange: string
}

export interface Activity {
  id: number
  type: 'flight' | 'passenger' | 'system' | 'alert'
  title: string
  description: string
  timestamp: string
  status: 'success' | 'warning' | 'error' | 'info'
  // 为了兼容dashboard-store，添加这些属性
  time: string
  color: string
  bgColor: string
}

// 保留原有的模拟API服务（用于航班等特定数据）
class DashboardAPI {
  // 获取航班数据
  static async getFlights(): Promise<Flight[]> {
    // 模拟网络延迟
    await new Promise(resolve => setTimeout(resolve, 1000))
    
    // 模拟数据
    return [
      {
        id: 'CA1234',
        route: '北京 → 上海',
        departure: '08:30',
        arrival: '11:15',
        status: 'on-time',
        statusText: '准点',
        aircraft: 'A320',
        passengers: '156/180',
        gate: 'A12'
      },
      {
        id: 'MU5678',
        route: '上海 → 广州',
        departure: '14:20',
        arrival: '17:05',
        status: 'delayed',
        statusText: '延误',
        aircraft: 'B737',
        passengers: '142/168',
        gate: 'B08'
      },
      {
        id: 'CZ9012',
        route: '广州 → 深圳',
        departure: '19:45',
        arrival: '20:30',
        status: 'boarding',
        statusText: '登机中',
        aircraft: 'A330',
        passengers: '234/280',
        gate: 'C15'
      },
      {
        id: 'HU3456',
        route: '深圳 → 成都',
        departure: '21:10',
        arrival: '23:45',
        status: 'scheduled',
        statusText: '计划中',
        aircraft: 'B777',
        passengers: '298/350',
        gate: 'D22'
      },
      {
        id: 'SC7890',
        route: '成都 → 西安',
        departure: '06:15',
        arrival: '07:50',
        status: 'cancelled',
        statusText: '取消',
        aircraft: 'A350',
        passengers: '0/315',
        gate: '--'
      }
    ]
  }

  // 获取统计数据
  static async getStats(): Promise<Stats> {
    await new Promise(resolve => setTimeout(resolve, 800))
    
    return {
      todayFlights: 247,
      totalPassengers: 45231,
      onTimeRate: 94.5,
      revenue: 2400000,
      flightChange: '+12%',
      passengerChange: '+8.2%',
      onTimeChange: '+2.1%',
      revenueChange: '-1.3%'
    }
  }

  // 获取活动数据
  static async getActivities(): Promise<Activity[]> {
    await new Promise(resolve => setTimeout(resolve, 600))
    
    return [
      {
        id: 1,
        type: 'flight',
        title: '航班 CA1234 已起飞',
        description: '北京 → 上海，预计11:15到达',
        timestamp: '刚刚',
        status: 'success',
        time: '刚刚',
        color: 'text-green-400',
        bgColor: 'bg-green-500/10'
      },
      {
        id: 2,
        type: 'passenger',
        title: '乘客登机完成',
        description: '航班 MU5678 所有乘客已登机',
        timestamp: '2分钟前',
        status: 'info',
        time: '2分钟前',
        color: 'text-blue-400',
        bgColor: 'bg-blue-500/10'
      },
      {
        id: 3,
        type: 'alert',
        title: '天气预警',
        description: '上海地区有雷雨天气，可能影响航班',
        timestamp: '5分钟前',
        status: 'warning',
        time: '5分钟前',
        color: 'text-yellow-400',
        bgColor: 'bg-yellow-500/10'
      },
      {
        id: 4,
        type: 'system',
        title: '系统维护完成',
        description: '登机口显示系统维护已完成',
        timestamp: '10分钟前',
        status: 'success',
        time: '10分钟前',
        color: 'text-green-400',
        bgColor: 'bg-green-500/10'
      },
      {
        id: 5,
        type: 'flight',
        title: '航班延误通知',
        description: '航班 HU7890 因天气原因延误30分钟',
        timestamp: '15分钟前',
        status: 'error',
        time: '15分钟前',
        color: 'text-red-400',
        bgColor: 'bg-red-500/10'
      }
    ]
  }
}

// 新增的数据获取hooks，使用DataAdapter
export const useDevices = () => {
  return useQuery({
    queryKey: QUERY_KEYS.devices,
    queryFn: () => DataAdapter.getDevices(),
    staleTime: 5 * 60 * 1000, // 5分钟
    refetchInterval: 30 * 1000, // 30秒自动刷新
  })
}

export const useSystemMetrics = () => {
  return useQuery({
    queryKey: QUERY_KEYS.systemMetrics,
    queryFn: () => DataAdapter.getSystemMetrics(),
    staleTime: 1 * 60 * 1000, // 1分钟
    refetchInterval: 10 * 1000, // 10秒自动刷新
  })
}

export const useAlerts = () => {
  return useQuery({
    queryKey: QUERY_KEYS.alerts,
    queryFn: () => DataAdapter.getAlerts(),
    staleTime: 2 * 60 * 1000, // 2分钟
    refetchInterval: 15 * 1000, // 15秒自动刷新
  })
}

export const useUserProfile = () => {
  return useQuery({
    queryKey: QUERY_KEYS.userProfile,
    queryFn: () => DataAdapter.getUserProfile(),
    staleTime: 10 * 60 * 1000, // 10分钟
  })
}

export const useFiles = (path?: string) => {
  return useQuery({
    queryKey: [...QUERY_KEYS.files, path || '/'],
    queryFn: () => DataAdapter.getFiles(path),
    staleTime: 5 * 60 * 1000, // 5分钟
  })
}

export const useRemoteConnections = () => {
  return useQuery({
    queryKey: QUERY_KEYS.remoteConnections,
    queryFn: () => DataAdapter.getRemoteConnections(),
    staleTime: 3 * 60 * 1000, // 3分钟
    refetchInterval: 20 * 1000, // 20秒自动刷新
  })
}

// 保留原有的hooks，使用原有的DashboardAPI
export const useFlights = () => {
  return useQuery({
    queryKey: QUERY_KEYS.flights,
    queryFn: DashboardAPI.getFlights,
    staleTime: 5 * 60 * 1000, // 5分钟
    refetchInterval: 30 * 1000, // 30秒自动刷新
  })
}

export const useStats = () => {
  return useQuery({
    queryKey: QUERY_KEYS.stats,
    queryFn: DashboardAPI.getStats,
    staleTime: 5 * 60 * 1000, // 5分钟
    refetchInterval: 60 * 1000, // 1分钟自动刷新
  })
}

export const useActivities = () => {
  return useQuery({
    queryKey: QUERY_KEYS.activities,
    queryFn: DashboardAPI.getActivities,
    staleTime: 2 * 60 * 1000, // 2分钟
    refetchInterval: 30 * 1000, // 30秒自动刷新
  })
}

// 获取数据源信息的hook
export const useDataSourceInfo = () => {
  try {
    return getDataSourceInfo()
  } catch (error) {
    console.warn('Failed to get data source info:', error)
    // 返回默认值
    return {
      isUsingRealData: false,
      isApiConfigured: false,
      fallbackEnabled: true
    }
  }
}

// 批量刷新所有数据的hook
export const useRefreshAllData = () => {
  const queryClient = useQueryClient()
  
  return useMutation({
    mutationFn: async () => {
      // 刷新所有查询
      await Promise.all([
        queryClient.invalidateQueries({ queryKey: QUERY_KEYS.devices }),
        queryClient.invalidateQueries({ queryKey: QUERY_KEYS.systemMetrics }),
        queryClient.invalidateQueries({ queryKey: QUERY_KEYS.alerts }),
        queryClient.invalidateQueries({ queryKey: QUERY_KEYS.userProfile }),
        queryClient.invalidateQueries({ queryKey: QUERY_KEYS.files }),
        queryClient.invalidateQueries({ queryKey: QUERY_KEYS.remoteConnections }),
        queryClient.invalidateQueries({ queryKey: QUERY_KEYS.flights }),
        queryClient.invalidateQueries({ queryKey: QUERY_KEYS.stats }),
        queryClient.invalidateQueries({ queryKey: QUERY_KEYS.activities }),
      ])
    },
  })
}

// 与dashboard store同步的hook
export const useDashboardSync = () => {
  const store = useDashboardStore()
  const { data: flights } = useFlights()
  const { data: stats } = useStats()
  const { data: activities } = useActivities()

  useEffect(() => {
    if (flights) {
      store.setFlights(flights)
    }
  }, [flights, store])

  useEffect(() => {
    if (stats) {
      store.setStats(stats)
    }
  }, [stats, store])

  useEffect(() => {
    if (activities) {
      store.setActivities(activities)
    }
  }, [activities, store])
}