'use client'

import React, { useState, useEffect } from 'react'
import { cn } from '@/lib/utils'
import { useDevices, useDataSourceInfo } from '@/hooks/use-dashboard-data'
import DeviceDiscovery from '../DeviceDiscovery'
import {
  Monitor,
  Smartphone,
  Tablet,
  Laptop,
  Server,
  Wifi,
  WifiOff,
  Power,
  Settings,
  Activity,
  Users,
  Shield,
  AlertTriangle,
  CheckCircle,
  Clock,
  Zap,
  HardDrive,
  Cpu,
  MemoryStick,
  RefreshCw,
  Database,
  Search
} from 'lucide-react'

// 设备类型定义 - 使用API中的Device类型
interface Device {
  id: string
  name: string
  type: 'desktop' | 'mobile' | 'tablet' | 'laptop' | 'server'
  status: 'online' | 'offline' | 'connecting' | 'error'
  ip: string
  os: string
  lastSeen: string
  cpu: number
  memory: number
  disk: number
  uptime: string
}

// 连接状态统计
interface ConnectionStats {
  total: number
  online: number
  offline: number
  connecting: number
  error: number
}

// 获取设备图标
const getDeviceIcon = (type: Device['type']) => {
  switch (type) {
    case 'desktop':
      return Monitor
    case 'mobile':
      return Smartphone
    case 'tablet':
      return Tablet
    case 'laptop':
      return Laptop
    case 'server':
      return Server
    default:
      return Monitor
  }
}

// 获取状态颜色
const getStatusColor = (status: Device['status']) => {
  switch (status) {
    case 'online':
      return 'text-green-400'
    case 'offline':
      return 'text-slate-400'
    case 'connecting':
      return 'text-yellow-400'
    case 'error':
      return 'text-red-400'
    default:
      return 'text-slate-400'
  }
}

// 获取状态图标
const getStatusIcon = (status: Device['status']) => {
  switch (status) {
    case 'online':
      return CheckCircle
    case 'offline':
      return WifiOff
    case 'connecting':
      return Clock
    case 'error':
      return AlertTriangle
    default:
      return WifiOff
  }
}

export function MainControlPanel() {
  // 使用新的数据hooks
  const { data: devicesData, isLoading, error, refetch } = useDevices()
  const dataSourceInfo = useDataSourceInfo()
  
  const [selectedDevice, setSelectedDevice] = useState<Device | null>(null)
  const [activeTab, setActiveTab] = useState<'overview' | 'discovery'>('overview')
  const [connectionStats, setConnectionStats] = useState<ConnectionStats>({
    total: 0,
    online: 0,
    offline: 0,
    connecting: 0,
    error: 0
  })

  // 使用真实数据或空数组作为fallback
  const devices = devicesData || []

  // 计算连接统计
  useEffect(() => {
    const stats = devices.reduce(
      (acc, device) => {
        acc.total++
        acc[device.status]++
        return acc
      },
      { total: 0, online: 0, offline: 0, connecting: 0, error: 0 }
    )
    setConnectionStats(stats)
  }, [devices])

  // 处理设备选择
  const handleDeviceSelect = (device: Device) => {
    setSelectedDevice(device)
  }

  // 处理刷新
  const handleRefresh = () => {
    refetch()
  }

  // 处理设备发现连接
  const handleDeviceConnect = (device: any) => {
    console.log('连接设备:', device)
    // 这里可以添加连接逻辑
  }

  return (
    <div className="space-y-6 p-6 min-h-screen bg-slate-900 text-white">
      {/* 页面标题和标签页 */}
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold text-white">主控制台</h1>
          <p className="text-slate-400 mt-1">
            管理和监控所有连接的设备 
            {dataSourceInfo && (
              <span className="ml-2 inline-flex items-center space-x-1">
                <Database className="w-3 h-3" />
                <span className="text-xs">
                  {dataSourceInfo.isUsingRealData ? '真实数据' : '模拟数据'}
                  {dataSourceInfo.isApiConfigured ? ' (API已配置)' : ' (API未配置)'}
                </span>
              </span>
            )}
          </p>
          
          {/* 标签页导航 */}
          <div className="flex space-x-1 mt-4 bg-slate-800 rounded-lg p-1">
            <button
              onClick={() => setActiveTab('overview')}
              className={cn(
                "px-4 py-2 rounded-md text-sm font-medium transition-colors",
                activeTab === 'overview'
                  ? "bg-blue-600 text-white"
                  : "text-slate-400 hover:text-white hover:bg-slate-700"
              )}
            >
              设备概览
            </button>
            <button
              onClick={() => setActiveTab('discovery')}
              className={cn(
                "px-4 py-2 rounded-md text-sm font-medium transition-colors flex items-center space-x-2",
                activeTab === 'discovery'
                  ? "bg-blue-600 text-white"
                  : "text-slate-400 hover:text-white hover:bg-slate-700"
              )}
            >
              <Search className="w-4 h-4" />
              <span>设备发现</span>
            </button>
          </div>
        </div>
        <div className="flex items-center space-x-2">
          <button 
            onClick={handleRefresh}
            disabled={isLoading}
            className="flex items-center space-x-2 px-4 py-2 bg-green-600 hover:bg-green-700 disabled:bg-green-800 text-white rounded-lg transition-colors"
          >
            <RefreshCw className={cn("w-4 h-4", isLoading && "animate-spin")} />
            <span>刷新数据</span>
          </button>
          <button className="flex items-center space-x-2 px-4 py-2 bg-blue-600 hover:bg-blue-700 text-white rounded-lg transition-colors">
            <Wifi className="w-4 h-4" />
            <span>扫描设备</span>
          </button>
          <button className="flex items-center space-x-2 px-4 py-2 bg-slate-700 hover:bg-slate-600 text-white rounded-lg transition-colors">
            <Settings className="w-4 h-4" />
            <span>设置</span>
          </button>
        </div>
      </div>

      {/* 错误状态显示 */}
      {error && (
        <div className="mb-6 p-4 bg-red-500/10 border border-red-500/30 rounded-lg">
          <div className="flex items-center space-x-2">
            <AlertTriangle className="w-5 h-5 text-red-400" />
            <span className="text-red-400">数据加载失败: {error.message}</span>
          </div>
        </div>
      )}

      {/* 加载状态 */}
      {isLoading && devices.length === 0 && (
        <div className="mb-6 p-8 text-center">
          <RefreshCw className="w-8 h-8 text-blue-400 animate-spin mx-auto mb-2" />
          <p className="text-slate-400">正在加载设备数据...</p>
        </div>
      )}

      {/* 根据activeTab显示不同内容 */}
      {activeTab === 'overview' ? (
        <>
          {/* 连接状态统计卡片 */}
          <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-5 gap-4">
        <div className="bg-slate-800/50 border border-slate-700 rounded-xl p-4">
          <div className="flex items-center space-x-3">
            <div className="p-2 bg-blue-500/20 rounded-lg">
              <Activity className="w-5 h-5 text-blue-400" />
            </div>
            <div>
              <p className="text-slate-400 text-sm">总设备数</p>
              <p className="text-2xl font-bold text-white">{connectionStats.total}</p>
            </div>
          </div>
        </div>

        <div className="bg-slate-800/50 border border-slate-700 rounded-xl p-4">
          <div className="flex items-center space-x-3">
            <div className="p-2 bg-green-500/20 rounded-lg">
              <CheckCircle className="w-5 h-5 text-green-400" />
            </div>
            <div>
              <p className="text-slate-400 text-sm">在线设备</p>
              <p className="text-2xl font-bold text-green-400">{connectionStats.online}</p>
            </div>
          </div>
        </div>

        <div className="bg-slate-800/50 border border-slate-700 rounded-xl p-4">
          <div className="flex items-center space-x-3">
            <div className="p-2 bg-slate-500/20 rounded-lg">
              <WifiOff className="w-5 h-5 text-slate-400" />
            </div>
            <div>
              <p className="text-slate-400 text-sm">离线设备</p>
              <p className="text-2xl font-bold text-slate-400">{connectionStats.offline}</p>
            </div>
          </div>
        </div>

        <div className="bg-slate-800/50 border border-slate-700 rounded-xl p-4">
          <div className="flex items-center space-x-3">
            <div className="p-2 bg-yellow-500/20 rounded-lg">
              <Clock className="w-5 h-5 text-yellow-400" />
            </div>
            <div>
              <p className="text-slate-400 text-sm">连接中</p>
              <p className="text-2xl font-bold text-yellow-400">{connectionStats.connecting}</p>
            </div>
          </div>
        </div>

        <div className="bg-slate-800/50 border border-slate-700 rounded-xl p-4">
          <div className="flex items-center space-x-3">
            <div className="p-2 bg-red-500/20 rounded-lg">
              <AlertTriangle className="w-5 h-5 text-red-400" />
            </div>
            <div>
              <p className="text-slate-400 text-sm">错误设备</p>
              <p className="text-2xl font-bold text-red-400">{connectionStats.error}</p>
            </div>
          </div>
        </div>
      </div>

      {/* 设备列表和详情 */}
      <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
        {/* 设备列表 */}
        <div className="lg:col-span-2">
          <div className="bg-slate-900/50 backdrop-blur-sm border border-slate-800 rounded-xl">
            <div className="p-6 border-b border-slate-800">
              <h2 className="text-lg font-semibold text-white">设备列表</h2>
              <p className="text-slate-400 text-sm mt-1">点击设备查看详细信息</p>
            </div>
            <div className="p-6">
              <div className="space-y-3">
                {devices.map((device) => {
                  const DeviceIcon = getDeviceIcon(device.type)
                  const StatusIcon = getStatusIcon(device.status)
                  const statusColor = getStatusColor(device.status)

                  return (
                    <div
                      key={device.id}
                      onClick={() => handleDeviceSelect(device)}
                      className={cn(
                        'flex items-center justify-between p-4 rounded-lg border cursor-pointer transition-all',
                        selectedDevice?.id === device.id
                          ? 'bg-blue-500/10 border-blue-500/30'
                          : 'bg-slate-800/30 border-slate-700 hover:bg-slate-800/50'
                      )}
                    >
                      <div className="flex items-center space-x-4">
                        <div className="p-2 bg-slate-700 rounded-lg">
                          <DeviceIcon className="w-5 h-5 text-slate-300" />
                        </div>
                        <div>
                          <h3 className="font-medium text-white">{device.name}</h3>
                          <p className="text-sm text-slate-400">{device.ip} • {device.os}</p>
                        </div>
                      </div>
                      <div className="flex items-center space-x-3">
                        <div className="text-right">
                          <p className="text-sm text-slate-400">最后连接</p>
                          <p className="text-sm text-white">{device.lastSeen}</p>
                        </div>
                        <StatusIcon className={cn('w-5 h-5', statusColor)} />
                      </div>
                    </div>
                  )
                })}
              </div>
            </div>
          </div>
        </div>

        {/* 设备详情面板 */}
        <div className="lg:col-span-1">
          <div className="bg-slate-900/50 backdrop-blur-sm border border-slate-800 rounded-xl">
            <div className="p-6 border-b border-slate-800">
              <h2 className="text-lg font-semibold text-white">设备详情</h2>
            </div>
            <div className="p-6">
              {selectedDevice ? (
                <div className="space-y-6">
                  {/* 设备基本信息 */}
                  <div className="text-center">
                    <div className="inline-flex p-4 bg-slate-700 rounded-xl mb-4">
                      {React.createElement(getDeviceIcon(selectedDevice.type), {
                        className: 'w-8 h-8 text-slate-300'
                      })}
                    </div>
                    <h3 className="text-lg font-semibold text-white">{selectedDevice.name}</h3>
                    <p className="text-slate-400">{selectedDevice.os}</p>
                    <div className={cn('inline-flex items-center space-x-2 mt-2 px-3 py-1 rounded-full text-sm', {
                      'bg-green-500/20 text-green-400': selectedDevice.status === 'online',
                      'bg-slate-500/20 text-slate-400': selectedDevice.status === 'offline',
                      'bg-yellow-500/20 text-yellow-400': selectedDevice.status === 'connecting',
                      'bg-red-500/20 text-red-400': selectedDevice.status === 'error'
                    })}>
                      {React.createElement(getStatusIcon(selectedDevice.status), {
                        className: 'w-4 h-4'
                      })}
                      <span>{selectedDevice.status === 'online' ? '在线' : 
                             selectedDevice.status === 'offline' ? '离线' :
                             selectedDevice.status === 'connecting' ? '连接中' : '错误'}</span>
                    </div>
                  </div>

                  {/* 系统资源使用情况 */}
                  {selectedDevice.status === 'online' && (
                    <div className="space-y-4">
                      <h4 className="text-sm font-medium text-slate-300">系统资源</h4>
                      
                      {/* CPU使用率 */}
                      <div className="space-y-2">
                        <div className="flex items-center justify-between">
                          <div className="flex items-center space-x-2">
                            <Cpu className="w-4 h-4 text-blue-400" />
                            <span className="text-sm text-slate-300">CPU</span>
                          </div>
                          <span className="text-sm text-white">{selectedDevice.cpu}%</span>
                        </div>
                        <div className="w-full bg-slate-700 rounded-full h-2">
                          <div
                            className="bg-blue-500 h-2 rounded-full transition-all duration-300"
                            style={{ width: `${selectedDevice.cpu}%` }}
                          />
                        </div>
                      </div>

                      {/* 内存使用率 */}
                      <div className="space-y-2">
                        <div className="flex items-center justify-between">
                          <div className="flex items-center space-x-2">
                            <MemoryStick className="w-4 h-4 text-green-400" />
                            <span className="text-sm text-slate-300">内存</span>
                          </div>
                          <span className="text-sm text-white">{selectedDevice.memory}%</span>
                        </div>
                        <div className="w-full bg-slate-700 rounded-full h-2">
                          <div
                            className="bg-green-500 h-2 rounded-full transition-all duration-300"
                            style={{ width: `${selectedDevice.memory}%` }}
                          />
                        </div>
                      </div>

                      {/* 磁盘使用率 */}
                      <div className="space-y-2">
                        <div className="flex items-center justify-between">
                          <div className="flex items-center space-x-2">
                            <HardDrive className="w-4 h-4 text-yellow-400" />
                            <span className="text-sm text-slate-300">磁盘</span>
                          </div>
                          <span className="text-sm text-white">{selectedDevice.disk}%</span>
                        </div>
                        <div className="w-full bg-slate-700 rounded-full h-2">
                          <div
                            className="bg-yellow-500 h-2 rounded-full transition-all duration-300"
                            style={{ width: `${selectedDevice.disk}%` }}
                          />
                        </div>
                      </div>

                      {/* 运行时间 */}
                      <div className="flex items-center justify-between pt-2 border-t border-slate-700">
                        <div className="flex items-center space-x-2">
                          <Zap className="w-4 h-4 text-purple-400" />
                          <span className="text-sm text-slate-300">运行时间</span>
                        </div>
                        <span className="text-sm text-white">{selectedDevice.uptime}</span>
                      </div>
                    </div>
                  )}

                  {/* 快速操作按钮 */}
                  <div className="space-y-3">
                    <h4 className="text-sm font-medium text-slate-300">快速操作</h4>
                    <div className="grid grid-cols-2 gap-3">
                      <button
                        disabled={selectedDevice.status !== 'online'}
                        className="flex items-center justify-center space-x-2 p-3 bg-blue-600 hover:bg-blue-700 disabled:bg-slate-700 disabled:text-slate-500 text-white rounded-lg transition-colors text-sm"
                      >
                        <Monitor className="w-4 h-4" />
                        <span>远程桌面</span>
                      </button>
                      <button
                        disabled={selectedDevice.status !== 'online'}
                        className="flex items-center justify-center space-x-2 p-3 bg-green-600 hover:bg-green-700 disabled:bg-slate-700 disabled:text-slate-500 text-white rounded-lg transition-colors text-sm"
                      >
                        <HardDrive className="w-4 h-4" />
                        <span>文件传输</span>
                      </button>
                      <button
                        disabled={selectedDevice.status !== 'online'}
                        className="flex items-center justify-center space-x-2 p-3 bg-purple-600 hover:bg-purple-700 disabled:bg-slate-700 disabled:text-slate-500 text-white rounded-lg transition-colors text-sm"
                      >
                        <Settings className="w-4 h-4" />
                        <span>系统设置</span>
                      </button>
                      <button
                        className="flex items-center justify-center space-x-2 p-3 bg-red-600 hover:bg-red-700 text-white rounded-lg transition-colors text-sm"
                      >
                        <Power className="w-4 h-4" />
                        <span>断开连接</span>
                      </button>
                    </div>
                  </div>
                </div>
              ) : (
                <div className="text-center py-12">
                  <div className="p-4 bg-slate-700 rounded-xl inline-block mb-4">
                    <Monitor className="w-8 h-8 text-slate-400" />
                  </div>
                  <p className="text-slate-400">选择一个设备查看详细信息</p>
                </div>
              )}
            </div>
          </div>
        </div>
      </div>
        </>
      ) : (
        /* 设备发现标签页 */
        <DeviceDiscovery onDeviceConnect={handleDeviceConnect} />
      )}
    </div>
  )
}