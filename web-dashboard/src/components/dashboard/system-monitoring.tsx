'use client'

import React, { useState, useEffect } from 'react'
import { cn } from '@/lib/utils'
import { useSystemMetrics, useAlerts, useDataSourceInfo } from '@/hooks/use-dashboard-data'
import {
  Activity,
  Cpu,
  MemoryStick,
  HardDrive,
  Wifi,
  Thermometer,
  Zap,
  AlertTriangle,
  CheckCircle,
  Clock,
  TrendingUp,
  TrendingDown,
  Server,
  Network,
  Database,
  Shield,
  Eye,
  Bell,
  Settings,
  RefreshCw
} from 'lucide-react'

// 系统指标数据类型
interface SystemMetrics {
  cpu: {
    usage: number
    cores: number
    temperature: number
    frequency: number
  }
  memory: {
    used: number
    total: number
    available: number
    usage: number
  }
  disk: {
    used: number
    total: number
    available: number
    usage: number
    readSpeed: number
    writeSpeed: number
  }
  network: {
    upload: number
    download: number
    latency: number
    packetsLost: number
  }
  system: {
    uptime: string
    processes: number
    threads: number
    loadAverage: number[]
  }
}

// 告警类型
interface Alert {
  id: string
  type: 'critical' | 'warning' | 'info'
  title: string
  message: string
  timestamp: string
  resolved: boolean
}

// 性能历史数据点
interface PerformanceDataPoint {
  timestamp: string
  cpu: number
  memory: number
  disk: number
  network: number
}

// 模拟系统指标数据
const generateMockMetrics = (): SystemMetrics => ({
  cpu: {
    usage: Math.random() * 80 + 10,
    cores: 8,
    temperature: Math.random() * 20 + 45,
    frequency: Math.random() * 1000 + 2400
  },
  memory: {
    used: Math.random() * 12 + 4,
    total: 16,
    available: 0,
    usage: 0
  },
  disk: {
    used: Math.random() * 200 + 300,
    total: 512,
    available: 0,
    usage: 0,
    readSpeed: Math.random() * 100 + 50,
    writeSpeed: Math.random() * 80 + 30
  },
  network: {
    upload: Math.random() * 50 + 10,
    download: Math.random() * 100 + 20,
    latency: Math.random() * 20 + 5,
    packetsLost: Math.random() * 0.1
  },
  system: {
    uptime: '5天 12小时 34分钟',
    processes: Math.floor(Math.random() * 50 + 150),
    threads: Math.floor(Math.random() * 500 + 800),
    loadAverage: [
      Math.random() * 2 + 0.5,
      Math.random() * 2 + 0.8,
      Math.random() * 2 + 1.2
    ]
  }
})

// 模拟告警数据
const mockAlerts: Alert[] = [
  {
    id: '1',
    type: 'critical',
    title: 'CPU使用率过高',
    message: 'CPU使用率已达到85%，建议检查运行的进程',
    timestamp: '2分钟前',
    resolved: false
  },
  {
    id: '2',
    type: 'warning',
    title: '内存使用率警告',
    message: '内存使用率达到75%，可能影响系统性能',
    timestamp: '15分钟前',
    resolved: false
  },
  {
    id: '3',
    type: 'info',
    title: '系统更新可用',
    message: '检测到新的系统更新，建议在维护窗口期间安装',
    timestamp: '1小时前',
    resolved: true
  },
  {
    id: '4',
    type: 'warning',
    title: '磁盘空间不足',
    message: '系统磁盘剩余空间不足20%，请清理不必要的文件',
    timestamp: '2小时前',
    resolved: false
  }
]

export function SystemMonitoring() {
  // 使用真实数据适配器
  const { data: metrics, isLoading: metricsLoading, error: metricsError, refetch: refetchMetrics } = useSystemMetrics()
  const { data: alerts, isLoading: alertsLoading, error: alertsError, refetch: refetchAlerts } = useAlerts()
  const dataSourceInfo = useDataSourceInfo()
  
  const [performanceHistory, setPerformanceHistory] = useState<PerformanceDataPoint[]>([])
  const [isRefreshing, setIsRefreshing] = useState(false)
  const [selectedTimeRange, setSelectedTimeRange] = useState<'1h' | '6h' | '24h' | '7d'>('1h')

  // 刷新数据
  const handleRefresh = async () => {
    setIsRefreshing(true)
    try {
      await Promise.all([refetchMetrics(), refetchAlerts()])
    } catch (error) {
      console.error('刷新数据失败:', error)
    } finally {
      setIsRefreshing(false)
    }
  }

  // 解决告警
  const resolveAlert = (alertId: string) => {
    // TODO: 实现告警解决逻辑
    console.log('解决告警:', alertId)
  }

  // 添加到性能历史记录
  useEffect(() => {
    if (metrics) {
      const now = new Date()
      const dataPoint: PerformanceDataPoint = {
        timestamp: now.toLocaleTimeString(),
        cpu: metrics.cpu.usage,
        memory: (metrics.memory.used / metrics.memory.total) * 100,
        disk: (metrics.disk.used / metrics.disk.total) * 100,
        network: metrics.network.download + metrics.network.upload
      }
      
      setPerformanceHistory(prev => {
        const updated = [...prev, dataPoint]
        // 保持最近100个数据点
        return updated.slice(-100)
      })
    }
  }, [metrics])

  // 如果数据加载中，显示加载状态
  if (metricsLoading || alertsLoading) {
    return (
      <div className="space-y-6">
        {/* 性能指标卡片骨架 */}
        <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-6">
          {[...Array(8)].map((_, i) => (
            <div key={i} className="bg-slate-800 rounded-lg p-6">
              <div className="flex items-center justify-between mb-4">
                <div className="flex items-center space-x-3">
                  <div className="w-10 h-10 bg-slate-700 rounded animate-pulse" />
                  <div className="space-y-1">
                    <div className="h-4 w-16 bg-slate-700 rounded animate-pulse" />
                    <div className="h-3 w-12 bg-slate-700 rounded animate-pulse" />
                  </div>
                </div>
              </div>
              <div className="space-y-2">
                <div className="h-8 w-20 bg-slate-700 rounded animate-pulse" />
                <div className="h-2 w-full bg-slate-700 rounded animate-pulse" />
              </div>
            </div>
          ))}
        </div>
      </div>
    )
  }

  // 如果没有数据，显示错误状态
  if (!metrics) {
    return (
      <div className="flex items-center justify-center h-64">
        <div className="text-center">
          <AlertTriangle className="w-12 h-12 text-yellow-400 mx-auto mb-4" />
          <h3 className="text-lg font-medium text-white mb-2">无法加载系统指标</h3>
          <p className="text-slate-400 mb-4">
            {metricsError ? `错误: ${metricsError.message}` : '数据获取失败'}
          </p>
          <button
            onClick={handleRefresh}
            className="px-4 py-2 bg-blue-600 hover:bg-blue-700 text-white rounded-lg"
          >
            重试
          </button>
        </div>
      </div>
    )
  }

  // 获取告警图标
  const getAlertIcon = (type: Alert['type']) => {
    switch (type) {
      case 'critical':
        return AlertTriangle
      case 'warning':
        return AlertTriangle
      case 'info':
        return CheckCircle
      default:
        return AlertTriangle
    }
  }

  // 获取告警颜色
  const getAlertColor = (type: Alert['type']) => {
    switch (type) {
      case 'critical':
        return 'text-red-400 bg-red-500/20'
      case 'warning':
        return 'text-yellow-400 bg-yellow-500/20'
      case 'info':
        return 'text-blue-400 bg-blue-500/20'
      default:
        return 'text-slate-400 bg-slate-500/20'
    }
  }

  return (
    <div className="space-y-6">
      {/* 页面标题 */}
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold text-white">系统监控</h1>
          <p className="text-slate-400 mt-1">实时监控系统性能和资源使用情况</p>
        </div>
        <div className="flex items-center space-x-2">
          <select
            value={selectedTimeRange}
            onChange={(e) => setSelectedTimeRange(e.target.value as any)}
            className="px-3 py-2 bg-slate-700 border border-slate-600 rounded-lg text-white text-sm focus:outline-none focus:ring-2 focus:ring-blue-500"
          >
            <option value="1h">最近1小时</option>
            <option value="6h">最近6小时</option>
            <option value="24h">最近24小时</option>
            <option value="7d">最近7天</option>
          </select>
          <button
            onClick={handleRefresh}
            disabled={isRefreshing}
            className="flex items-center space-x-2 px-4 py-2 bg-blue-600 hover:bg-blue-700 disabled:bg-blue-600/50 text-white rounded-lg transition-colors"
          >
            <RefreshCw className={cn('w-4 h-4', isRefreshing && 'animate-spin')} />
            <span>刷新</span>
          </button>
          <button className="flex items-center space-x-2 px-4 py-2 bg-slate-700 hover:bg-slate-600 text-white rounded-lg transition-colors">
            <Settings className="w-4 h-4" />
            <span>设置</span>
          </button>
        </div>
      </div>

      {/* 核心指标卡片 */}
      <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-4">
        {/* CPU使用率 */}
        <div className="bg-slate-800/50 border border-slate-700 rounded-xl p-6">
          <div className="flex items-center justify-between mb-4">
            <div className="flex items-center space-x-3">
              <div className="p-2 bg-blue-500/20 rounded-lg">
                <Cpu className="w-5 h-5 text-blue-400" />
              </div>
              <div>
                <p className="text-slate-400 text-sm">CPU使用率</p>
                <p className="text-2xl font-bold text-white">{metrics.cpu.usage.toFixed(1)}%</p>
              </div>
            </div>
            <div className="text-right">
              <p className="text-xs text-slate-500">温度</p>
              <p className="text-sm text-slate-300">{metrics.cpu.temperature.toFixed(1)}°C</p>
            </div>
          </div>
          <div className="w-full bg-slate-700 rounded-full h-2 mb-2">
            <div
              className="bg-blue-500 h-2 rounded-full transition-all duration-300"
              style={{ width: `${metrics.cpu.usage}%` }}
            />
          </div>
          <div className="flex justify-between text-xs text-slate-500">
            <span>{metrics.cpu.cores} 核心</span>
            <span>{metrics.cpu.frequency.toFixed(0)} MHz</span>
          </div>
        </div>

        {/* 内存使用率 */}
        <div className="bg-slate-800/50 border border-slate-700 rounded-xl p-6">
          <div className="flex items-center justify-between mb-4">
            <div className="flex items-center space-x-3">
              <div className="p-2 bg-green-500/20 rounded-lg">
                <MemoryStick className="w-5 h-5 text-green-400" />
              </div>
              <div>
                <p className="text-slate-400 text-sm">内存使用率</p>
                <p className="text-2xl font-bold text-white">{metrics.memory.usage.toFixed(1)}%</p>
              </div>
            </div>
            <div className="text-right">
              <p className="text-xs text-slate-500">可用</p>
              <p className="text-sm text-slate-300">{metrics.memory.available.toFixed(1)} GB</p>
            </div>
          </div>
          <div className="w-full bg-slate-700 rounded-full h-2 mb-2">
            <div
              className="bg-green-500 h-2 rounded-full transition-all duration-300"
              style={{ width: `${metrics.memory.usage}%` }}
            />
          </div>
          <div className="flex justify-between text-xs text-slate-500">
            <span>{metrics.memory.used.toFixed(1)} GB 已用</span>
            <span>{metrics.memory.total} GB 总计</span>
          </div>
        </div>

        {/* 磁盘使用率 */}
        <div className="bg-slate-800/50 border border-slate-700 rounded-xl p-6">
          <div className="flex items-center justify-between mb-4">
            <div className="flex items-center space-x-3">
              <div className="p-2 bg-yellow-500/20 rounded-lg">
                <HardDrive className="w-5 h-5 text-yellow-400" />
              </div>
              <div>
                <p className="text-slate-400 text-sm">磁盘使用率</p>
                <p className="text-2xl font-bold text-white">{metrics.disk.usage.toFixed(1)}%</p>
              </div>
            </div>
            <div className="text-right">
              <p className="text-xs text-slate-500">可用</p>
              <p className="text-sm text-slate-300">{metrics.disk.available.toFixed(0)} GB</p>
            </div>
          </div>
          <div className="w-full bg-slate-700 rounded-full h-2 mb-2">
            <div
              className="bg-yellow-500 h-2 rounded-full transition-all duration-300"
              style={{ width: `${metrics.disk.usage}%` }}
            />
          </div>
          <div className="flex justify-between text-xs text-slate-500">
            <span>读: {metrics.disk.readSpeed.toFixed(0)} MB/s</span>
            <span>写: {metrics.disk.writeSpeed.toFixed(0)} MB/s</span>
          </div>
        </div>

        {/* 网络使用率 */}
        <div className="bg-slate-800/50 border border-slate-700 rounded-xl p-6">
          <div className="flex items-center justify-between mb-4">
            <div className="flex items-center space-x-3">
              <div className="p-2 bg-purple-500/20 rounded-lg">
                <Network className="w-5 h-5 text-purple-400" />
              </div>
              <div>
                <p className="text-slate-400 text-sm">网络活动</p>
                <p className="text-2xl font-bold text-white">{(metrics.network.download + metrics.network.upload).toFixed(0)} MB/s</p>
              </div>
            </div>
            <div className="text-right">
              <p className="text-xs text-slate-500">延迟</p>
              <p className="text-sm text-slate-300">{metrics.network.latency.toFixed(0)} ms</p>
            </div>
          </div>
          <div className="space-y-1">
            <div className="flex justify-between text-xs">
              <span className="text-slate-500">下载</span>
              <span className="text-green-400">{metrics.network.download.toFixed(1)} MB/s</span>
            </div>
            <div className="flex justify-between text-xs">
              <span className="text-slate-500">上传</span>
              <span className="text-blue-400">{metrics.network.upload.toFixed(1)} MB/s</span>
            </div>
            <div className="flex justify-between text-xs">
              <span className="text-slate-500">丢包率</span>
              <span className="text-red-400">{metrics.network.packetsLost.toFixed(2)}%</span>
            </div>
          </div>
        </div>
      </div>

      {/* 系统信息和告警 */}
      <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
        {/* 系统信息 */}
        <div className="lg:col-span-1">
          <div className="bg-slate-900/50 backdrop-blur-sm border border-slate-800 rounded-xl">
            <div className="p-6 border-b border-slate-800">
              <h2 className="text-lg font-semibold text-white">系统信息</h2>
            </div>
            <div className="p-6 space-y-4">
              <div className="flex items-center justify-between">
                <div className="flex items-center space-x-2">
                  <Clock className="w-4 h-4 text-blue-400" />
                  <span className="text-sm text-slate-300">运行时间</span>
                </div>
                <span className="text-sm text-white">{metrics.system.uptime}</span>
              </div>
              
              <div className="flex items-center justify-between">
                <div className="flex items-center space-x-2">
                  <Activity className="w-4 h-4 text-green-400" />
                  <span className="text-sm text-slate-300">进程数</span>
                </div>
                <span className="text-sm text-white">{metrics.system.processes}</span>
              </div>
              
              <div className="flex items-center justify-between">
                <div className="flex items-center space-x-2">
                  <Server className="w-4 h-4 text-yellow-400" />
                  <span className="text-sm text-slate-300">线程数</span>
                </div>
                <span className="text-sm text-white">{metrics.system.threads}</span>
              </div>
              
              <div className="pt-4 border-t border-slate-700">
                <div className="flex items-center space-x-2 mb-2">
                  <TrendingUp className="w-4 h-4 text-purple-400" />
                  <span className="text-sm text-slate-300">负载平均值</span>
                </div>
                <div className="grid grid-cols-3 gap-2">
                  <div className="text-center">
                    <p className="text-xs text-slate-500">1分钟</p>
                    <p className="text-sm text-white">{metrics.system.loadAverage[0].toFixed(2)}</p>
                  </div>
                  <div className="text-center">
                    <p className="text-xs text-slate-500">5分钟</p>
                    <p className="text-sm text-white">{metrics.system.loadAverage[1].toFixed(2)}</p>
                  </div>
                  <div className="text-center">
                    <p className="text-xs text-slate-500">15分钟</p>
                    <p className="text-sm text-white">{metrics.system.loadAverage[2].toFixed(2)}</p>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>

        {/* 告警中心 */}
        <div className="lg:col-span-2">
          <div className="bg-slate-900/50 backdrop-blur-sm border border-slate-800 rounded-xl">
            <div className="p-6 border-b border-slate-800">
              <div className="flex items-center justify-between">
                  <h2 className="text-lg font-semibold text-white">告警中心</h2>
                  <div className="flex items-center space-x-2">
                    <span className="text-sm text-slate-400">
                      {alerts ? alerts.filter(alert => !alert.resolved).length : 0} 个未解决
                    </span>
                    <Bell className="w-4 h-4 text-yellow-400" />
                  </div>
                </div>
              </div>
              <div className="p-6">
                <div className="space-y-3 max-h-80 overflow-y-auto">
                  {alerts && alerts.length > 0 ? alerts.map((alert) => {
                  const AlertIcon = getAlertIcon(alert.type)
                  const alertColor = getAlertColor(alert.type)

                  return (
                    <div
                      key={alert.id}
                      className={cn(
                        'flex items-start space-x-3 p-4 rounded-lg border transition-all',
                        alert.resolved
                          ? 'bg-slate-800/30 border-slate-700 opacity-60'
                          : 'bg-slate-800/50 border-slate-600'
                      )}
                    >
                      <div className={cn('p-2 rounded-lg', alertColor)}>
                        <AlertIcon className="w-4 h-4" />
                      </div>
                      <div className="flex-1 min-w-0">
                        <div className="flex items-center justify-between">
                          <h3 className={cn(
                            'font-medium',
                            alert.resolved ? 'text-slate-400' : 'text-white'
                          )}>
                            {alert.title}
                          </h3>
                          <span className="text-xs text-slate-500">{alert.timestamp}</span>
                        </div>
                        <p className={cn(
                          'text-sm mt-1',
                          alert.resolved ? 'text-slate-500' : 'text-slate-300'
                        )}>
                          {alert.message}
                        </p>
                        {!alert.resolved && (
                          <button
                            onClick={() => resolveAlert(alert.id)}
                            className="text-xs text-blue-400 hover:text-blue-300 mt-2"
                          >
                            标记为已解决
                          </button>
                        )}
                      </div>
                    </div>
                  )
                }) : (
                  <div className="text-center py-8">
                    <p className="text-slate-400">暂无告警信息</p>
                  </div>
                )}
              </div>
            </div>
          </div>
        </div>
      </div>

      {/* 性能趋势图表 */}
      <div className="bg-slate-900/50 backdrop-blur-sm border border-slate-800 rounded-xl">
        <div className="p-6 border-b border-slate-800">
          <h2 className="text-lg font-semibold text-white">性能趋势</h2>
          <p className="text-slate-400 text-sm mt-1">实时系统资源使用情况</p>
        </div>
        <div className="p-6">
          <div className="h-64 flex items-end justify-between space-x-1">
            {performanceHistory.slice(-20).map((point, index) => (
              <div key={index} className="flex-1 flex flex-col items-center space-y-1">
                {/* CPU柱状图 */}
                <div className="w-full bg-slate-700 rounded-t relative" style={{ height: '60px' }}>
                  <div
                    className="bg-blue-500 rounded-t transition-all duration-300"
                    style={{
                      height: `${(point.cpu / 100) * 60}px`,
                      position: 'absolute',
                      bottom: 0,
                      left: 0,
                      right: 0
                    }}
                  />
                </div>
                {/* 内存柱状图 */}
                <div className="w-full bg-slate-700 relative" style={{ height: '60px' }}>
                  <div
                    className="bg-green-500 transition-all duration-300"
                    style={{
                      height: `${(point.memory / 100) * 60}px`,
                      position: 'absolute',
                      bottom: 0,
                      left: 0,
                      right: 0
                    }}
                  />
                </div>
                {/* 磁盘柱状图 */}
                <div className="w-full bg-slate-700 rounded-b relative" style={{ height: '60px' }}>
                  <div
                    className="bg-yellow-500 rounded-b transition-all duration-300"
                    style={{
                      height: `${(point.disk / 100) * 60}px`,
                      position: 'absolute',
                      bottom: 0,
                      left: 0,
                      right: 0
                    }}
                  />
                </div>
                <span className="text-xs text-slate-500 transform -rotate-45 origin-center">
                  {point.timestamp}
                </span>
              </div>
            ))}
          </div>
          
          {/* 图例 */}
          <div className="flex items-center justify-center space-x-6 mt-6 pt-4 border-t border-slate-700">
            <div className="flex items-center space-x-2">
              <div className="w-3 h-3 bg-blue-500 rounded" />
              <span className="text-sm text-slate-300">CPU</span>
            </div>
            <div className="flex items-center space-x-2">
              <div className="w-3 h-3 bg-green-500 rounded" />
              <span className="text-sm text-slate-300">内存</span>
            </div>
            <div className="flex items-center space-x-2">
              <div className="w-3 h-3 bg-yellow-500 rounded" />
              <span className="text-sm text-slate-300">磁盘</span>
            </div>
          </div>
        </div>
      </div>
    </div>
  )
}