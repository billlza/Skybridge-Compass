'use client'

import React, { useState, useEffect } from 'react'
import { cn } from '@/lib/utils'
import { useDevices, useDataSourceInfo } from '@/hooks/use-dashboard-data'
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
  Plus,
  Search,
  Filter,
  MoreVertical,
  Edit,
  Trash2,
  Eye,
  Activity,
  Shield,
  Clock,
  MapPin,
  User,
  HardDrive,
  Cpu,
  MemoryStick,
  Network,
  CheckCircle,
  AlertTriangle,
  RefreshCw,
  Download,
  Upload,
  Database
} from 'lucide-react'

// 设备详细信息类型
interface DeviceInfo {
  id: string
  name: string
  type: 'desktop' | 'mobile' | 'tablet' | 'laptop' | 'server'
  status: 'online' | 'offline' | 'connecting' | 'error' | 'maintenance'
  ip: string
  mac: string
  os: string
  version: string
  location: string
  owner: string
  lastSeen: string
  firstConnected: string
  totalConnections: number
  uptime: string
  // 硬件信息
  hardware: {
    cpu: string
    memory: string
    storage: string
    gpu?: string
  }
  // 性能指标
  performance: {
    cpu: number
    memory: number
    disk: number
    network: {
      upload: number
      download: number
    }
  }
  // 安全信息
  security: {
    encrypted: boolean
    authenticated: boolean
    lastSecurityScan: string
    vulnerabilities: number
  }
  // 标签
  tags: string[]
}

// 设备分组
interface DeviceGroup {
  id: string
  name: string
  color: string
  deviceCount: number
}

// 模拟设备数据
const mockDevices: DeviceInfo[] = [
  {
    id: '1',
    name: 'Xiaomi 14 Ultra',
    type: 'mobile',
    status: 'online',
    ip: '192.168.1.100',
    mac: '00:1B:44:11:3A:B7',
    os: 'Android',
    version: '14.0',
    location: '办公室',
    owner: '张三',
    lastSeen: '刚刚',
    firstConnected: '2024-01-15',
    totalConnections: 1247,
    uptime: '2天 14小时',
    hardware: {
      cpu: 'Snapdragon 8 Gen 3',
      memory: '12GB',
      storage: '512GB',
    },
    performance: {
      cpu: 45,
      memory: 68,
      disk: 72,
      network: { upload: 15.2, download: 45.8 }
    },
    security: {
      encrypted: true,
      authenticated: true,
      lastSecurityScan: '2024-01-20',
      vulnerabilities: 0
    },
    tags: ['移动设备', '高优先级', '开发']
  },
  {
    id: '2',
    name: 'MacBook Pro M3',
    type: 'laptop',
    status: 'online',
    ip: '192.168.1.101',
    mac: '00:1B:44:11:3A:B8',
    os: 'macOS',
    version: 'Sonoma 14.2',
    location: '会议室A',
    owner: '李四',
    lastSeen: '1分钟前',
    firstConnected: '2023-12-01',
    totalConnections: 2156,
    uptime: '5天 8小时',
    hardware: {
      cpu: 'Apple M3 Pro',
      memory: '18GB',
      storage: '1TB SSD',
      gpu: 'Apple M3 Pro GPU'
    },
    performance: {
      cpu: 23,
      memory: 56,
      disk: 45,
      network: { upload: 8.7, download: 32.1 }
    },
    security: {
      encrypted: true,
      authenticated: true,
      lastSecurityScan: '2024-01-19',
      vulnerabilities: 1
    },
    tags: ['笔记本', '设计', '高性能']
  },
  {
    id: '3',
    name: 'iPad Pro 12.9',
    type: 'tablet',
    status: 'offline',
    ip: '192.168.1.102',
    mac: '00:1B:44:11:3A:B9',
    os: 'iPadOS',
    version: '17.2',
    location: '展示厅',
    owner: '王五',
    lastSeen: '30分钟前',
    firstConnected: '2024-01-10',
    totalConnections: 456,
    uptime: '-',
    hardware: {
      cpu: 'Apple M2',
      memory: '8GB',
      storage: '256GB'
    },
    performance: {
      cpu: 0,
      memory: 0,
      disk: 0,
      network: { upload: 0, download: 0 }
    },
    security: {
      encrypted: true,
      authenticated: false,
      lastSecurityScan: '2024-01-18',
      vulnerabilities: 0
    },
    tags: ['平板', '展示', '客户端']
  },
  {
    id: '4',
    name: 'Windows Desktop',
    type: 'desktop',
    status: 'maintenance',
    ip: '192.168.1.103',
    mac: '00:1B:44:11:3A:BA',
    os: 'Windows',
    version: '11 Pro',
    location: '技术部',
    owner: '赵六',
    lastSeen: '维护中',
    firstConnected: '2023-11-15',
    totalConnections: 3421,
    uptime: '-',
    hardware: {
      cpu: 'Intel i7-13700K',
      memory: '32GB DDR5',
      storage: '2TB NVMe SSD',
      gpu: 'RTX 4070'
    },
    performance: {
      cpu: 0,
      memory: 0,
      disk: 0,
      network: { upload: 0, download: 0 }
    },
    security: {
      encrypted: true,
      authenticated: true,
      lastSecurityScan: '2024-01-17',
      vulnerabilities: 2
    },
    tags: ['台式机', '游戏', '高性能', '维护']
  },
  {
    id: '5',
    name: 'Ubuntu Server',
    type: 'server',
    status: 'error',
    ip: '192.168.1.104',
    mac: '00:1B:44:11:3A:BB',
    os: 'Ubuntu',
    version: '22.04 LTS',
    location: '数据中心',
    owner: '系统管理员',
    lastSeen: '1小时前',
    firstConnected: '2023-10-01',
    totalConnections: 8765,
    uptime: '-',
    hardware: {
      cpu: 'AMD EPYC 7543',
      memory: '128GB ECC',
      storage: '4TB RAID 10'
    },
    performance: {
      cpu: 0,
      memory: 0,
      disk: 0,
      network: { upload: 0, download: 0 }
    },
    security: {
      encrypted: true,
      authenticated: true,
      lastSecurityScan: '2024-01-16',
      vulnerabilities: 3
    },
    tags: ['服务器', '生产环境', '关键']
  }
]

// 设备分组数据
const mockGroups: DeviceGroup[] = [
  { id: 'all', name: '全部设备', color: 'blue', deviceCount: 5 },
  { id: 'mobile', name: '移动设备', color: 'green', deviceCount: 2 },
  { id: 'desktop', name: '桌面设备', color: 'purple', deviceCount: 2 },
  { id: 'server', name: '服务器', color: 'red', deviceCount: 1 }
]

// 获取设备图标
const getDeviceIcon = (type: DeviceInfo['type']) => {
  switch (type) {
    case 'desktop': return Monitor
    case 'mobile': return Smartphone
    case 'tablet': return Tablet
    case 'laptop': return Laptop
    case 'server': return Server
    default: return Monitor
  }
}

// 获取状态颜色和图标
const getStatusInfo = (status: DeviceInfo['status']) => {
  switch (status) {
    case 'online':
      return { color: 'text-green-400 bg-green-500/20', icon: CheckCircle, text: '在线' }
    case 'offline':
      return { color: 'text-slate-400 bg-slate-500/20', icon: WifiOff, text: '离线' }
    case 'connecting':
      return { color: 'text-yellow-400 bg-yellow-500/20', icon: Clock, text: '连接中' }
    case 'error':
      return { color: 'text-red-400 bg-red-500/20', icon: AlertTriangle, text: '错误' }
    case 'maintenance':
      return { color: 'text-blue-400 bg-blue-500/20', icon: Settings, text: '维护中' }
    default:
      return { color: 'text-slate-400 bg-slate-500/20', icon: WifiOff, text: '未知' }
  }
}

// 将 API Device 转换为 DeviceInfo 的适配器函数
const adaptDeviceToDeviceInfo = (device: any): DeviceInfo => {
  return {
    id: device.id,
    name: device.name,
    type: device.type,
    status: device.status,
    ip: device.ip,
    mac: device.mac || 'N/A',
    os: device.os,
    version: device.version || 'N/A',
    location: device.location || '未知',
    owner: device.owner || '未分配',
    lastSeen: device.lastSeen,
    firstConnected: device.firstConnected || '未知',
    totalConnections: device.totalConnections || 0,
    uptime: device.uptime,
    hardware: device.hardware || {
      cpu: 'N/A',
      memory: 'N/A',
      storage: 'N/A'
    },
    performance: device.performance || {
      cpu: device.cpu || 0,
      memory: device.memory || 0,
      disk: device.disk || 0,
      network: { upload: 0, download: 0 }
    },
    security: device.security || {
      encrypted: false,
      authenticated: false,
      lastSecurityScan: '未知',
      vulnerabilities: 0
    },
    tags: device.tags || []
  }
}

export function DeviceManagement() {
  const { data: apiDevices = [], isLoading, error, refetch } = useDevices()
  const { isUsingRealData, isApiConfigured } = useDataSourceInfo()
  
  // 转换 API 数据为组件所需格式，如果使用模拟数据则直接使用 mockDevices
  const devices = isUsingRealData && apiDevices.length > 0 
    ? apiDevices.map(adaptDeviceToDeviceInfo)
    : mockDevices
  
  const [selectedDevice, setSelectedDevice] = useState<DeviceInfo | null>(null)
  const [selectedGroup, setSelectedGroup] = useState<string>('all')
  const [searchQuery, setSearchQuery] = useState('')
  const [showFilters, setShowFilters] = useState(false)
  const [viewMode, setViewMode] = useState<'grid' | 'list'>('grid')
  const [isRefreshing, setIsRefreshing] = useState(false)

  // 处理刷新
  const handleRefresh = async () => {
    setIsRefreshing(true)
    try {
      if (isUsingRealData) {
        await refetch()
      }
    } finally {
      setTimeout(() => setIsRefreshing(false), 500)
    }
  }

  // 过滤设备
  const filteredDevices = devices.filter(device => {
    const matchesSearch = device.name.toLowerCase().includes(searchQuery.toLowerCase()) ||
                         device.ip.includes(searchQuery) ||
                         device.owner.toLowerCase().includes(searchQuery.toLowerCase())
    
    const matchesGroup = selectedGroup === 'all' || 
                        (selectedGroup === 'mobile' && ['mobile', 'tablet'].includes(device.type)) ||
                        (selectedGroup === 'desktop' && ['desktop', 'laptop'].includes(device.type)) ||
                        (selectedGroup === 'server' && device.type === 'server')
    
    return matchesSearch && matchesGroup
  })

  // 设备操作
  const handleDeviceAction = (deviceId: string, action: string) => {
    console.log(`执行操作: ${action} 对设备: ${deviceId}`)
    // 这里可以添加实际的设备操作逻辑
  }

  // 加载状态
  if (isLoading) {
    return (
      <div className="space-y-6">
        <div className="flex items-center justify-between">
          <div>
            <h1 className="text-2xl font-bold text-white">设备管理</h1>
            <p className="text-slate-400 mt-1">正在加载设备数据...</p>
          </div>
        </div>
        <div className="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-3 gap-4">
          {[...Array(6)].map((_, i) => (
            <div key={i} className="bg-slate-800/50 border border-slate-700 rounded-xl p-6">
              <div className="animate-pulse">
                <div className="flex items-center space-x-3 mb-4">
                  <div className="w-10 h-10 bg-slate-700 rounded-lg"></div>
                  <div className="space-y-2">
                    <div className="h-4 w-20 bg-slate-700 rounded"></div>
                    <div className="h-3 w-16 bg-slate-700 rounded"></div>
                  </div>
                </div>
                <div className="space-y-2">
                  <div className="h-3 w-full bg-slate-700 rounded"></div>
                  <div className="h-3 w-3/4 bg-slate-700 rounded"></div>
                </div>
              </div>
            </div>
          ))}
        </div>
      </div>
    )
  }

  // 错误状态
  if (error) {
    return (
      <div className="space-y-6">
        <div className="flex items-center justify-between">
          <div>
            <h1 className="text-2xl font-bold text-white">设备管理</h1>
            <p className="text-slate-400 mt-1">加载设备数据时出错</p>
          </div>
        </div>
        <div className="bg-red-900/20 border border-red-800 rounded-xl p-6 text-center">
          <AlertTriangle className="w-12 h-12 text-red-400 mx-auto mb-4" />
          <h3 className="text-lg font-semibold text-white mb-2">无法加载设备数据</h3>
          <p className="text-red-300 mb-4">{error.message}</p>
          <button
            onClick={handleRefresh}
            className="flex items-center space-x-2 px-4 py-2 bg-red-600 hover:bg-red-700 text-white rounded-lg transition-colors mx-auto"
          >
            <RefreshCw className="w-4 h-4" />
            <span>重试</span>
          </button>
        </div>
      </div>
    )
  }

  return (
    <div className="space-y-6">
      {/* 页面标题和操作 */}
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold text-white">设备管理</h1>
          <p className="text-slate-400 mt-1">管理和监控所有连接的设备</p>
        </div>
        <div className="flex items-center space-x-2">
          {/* 数据源信息 */}
          <div className="flex items-center space-x-2 px-3 py-1 bg-slate-800 rounded-lg border border-slate-700">
            <Database className="w-4 h-4 text-slate-400" />
            <span className="text-sm text-slate-300">
              {isUsingRealData ? '真实数据' : '模拟数据'}
            </span>
            {!isApiConfigured && (
              <span className="text-xs text-amber-400">(API未配置)</span>
            )}
          </div>
          <button className="flex items-center space-x-2 px-4 py-2 bg-blue-600 hover:bg-blue-700 text-white rounded-lg transition-colors">
            <Plus className="w-4 h-4" />
            <span>添加设备</span>
          </button>
          <button 
            onClick={handleRefresh}
            className="flex items-center space-x-2 px-4 py-2 bg-slate-700 hover:bg-slate-600 text-white rounded-lg transition-colors"
          >
            <RefreshCw className="w-4 h-4" />
            <span>刷新</span>
          </button>
        </div>
      </div>

      {/* 搜索和过滤 */}
      <div className="flex items-center justify-between space-x-4">
        <div className="flex items-center space-x-4 flex-1">
          {/* 搜索框 */}
          <div className="relative flex-1 max-w-md">
            <Search className="absolute left-3 top-1/2 transform -translate-y-1/2 w-4 h-4 text-slate-400" />
            <input
              type="text"
              placeholder="搜索设备名称、IP或所有者..."
              value={searchQuery}
              onChange={(e) => setSearchQuery(e.target.value)}
              className="w-full pl-10 pr-4 py-2 bg-slate-800 border border-slate-700 rounded-lg text-white placeholder-slate-400 focus:outline-none focus:ring-2 focus:ring-blue-500"
            />
          </div>

          {/* 设备分组 */}
          <div className="flex items-center space-x-2">
            {mockGroups.map((group) => (
              <button
                key={group.id}
                onClick={() => setSelectedGroup(group.id)}
                className={cn(
                  'px-3 py-2 rounded-lg text-sm font-medium transition-colors',
                  selectedGroup === group.id
                    ? 'bg-blue-600 text-white'
                    : 'bg-slate-700 text-slate-300 hover:bg-slate-600'
                )}
              >
                {group.name} ({group.deviceCount})
              </button>
            ))}
          </div>
        </div>

        <div className="flex items-center space-x-2">
          {/* 视图切换 */}
          <div className="flex items-center bg-slate-700 rounded-lg p-1">
            <button
              onClick={() => setViewMode('grid')}
              className={cn(
                'p-2 rounded text-sm',
                viewMode === 'grid' ? 'bg-slate-600 text-white' : 'text-slate-400'
              )}
            >
              网格
            </button>
            <button
              onClick={() => setViewMode('list')}
              className={cn(
                'p-2 rounded text-sm',
                viewMode === 'list' ? 'bg-slate-600 text-white' : 'text-slate-400'
              )}
            >
              列表
            </button>
          </div>

          {/* 过滤器 */}
          <button
            onClick={() => setShowFilters(!showFilters)}
            className="flex items-center space-x-2 px-3 py-2 bg-slate-700 hover:bg-slate-600 text-white rounded-lg transition-colors"
          >
            <Filter className="w-4 h-4" />
            <span>过滤器</span>
          </button>
        </div>
      </div>

      {/* 设备列表 */}
      <div className="grid grid-cols-1 lg:grid-cols-4 gap-6">
        {/* 设备卡片/列表 */}
        <div className="lg:col-span-3">
          {viewMode === 'grid' ? (
            <div className="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-3 gap-4">
              {filteredDevices.map((device) => {
                const DeviceIcon = getDeviceIcon(device.type)
                const statusInfo = getStatusInfo(device.status)

                return (
                  <div
                    key={device.id}
                    onClick={() => setSelectedDevice(device)}
                    className={cn(
                      'bg-slate-800/50 border border-slate-700 rounded-xl p-6 cursor-pointer transition-all hover:bg-slate-800/70',
                      selectedDevice?.id === device.id && 'ring-2 ring-blue-500'
                    )}
                  >
                    {/* 设备头部 */}
                    <div className="flex items-center justify-between mb-4">
                      <div className="flex items-center space-x-3">
                        <div className="p-2 bg-slate-700 rounded-lg">
                          <DeviceIcon className="w-5 h-5 text-slate-300" />
                        </div>
                        <div>
                          <h3 className="font-medium text-white">{device.name}</h3>
                          <p className="text-sm text-slate-400">{device.ip}</p>
                        </div>
                      </div>
                      <div className="relative">
                        <button className="p-1 hover:bg-slate-700 rounded">
                          <MoreVertical className="w-4 h-4 text-slate-400" />
                        </button>
                      </div>
                    </div>

                    {/* 状态和基本信息 */}
                    <div className="space-y-3">
                      <div className="flex items-center justify-between">
                        <span className="text-sm text-slate-400">状态</span>
                        <div className={cn('flex items-center space-x-1 px-2 py-1 rounded-full text-xs', statusInfo.color)}>
                          <statusInfo.icon className="w-3 h-3" />
                          <span>{statusInfo.text}</span>
                        </div>
                      </div>

                      <div className="flex items-center justify-between">
                        <span className="text-sm text-slate-400">系统</span>
                        <span className="text-sm text-white">{device.os} {device.version}</span>
                      </div>

                      <div className="flex items-center justify-between">
                        <span className="text-sm text-slate-400">所有者</span>
                        <span className="text-sm text-white">{device.owner}</span>
                      </div>

                      <div className="flex items-center justify-between">
                        <span className="text-sm text-slate-400">最后连接</span>
                        <span className="text-sm text-white">{device.lastSeen}</span>
                      </div>
                    </div>

                    {/* 性能指标 */}
                    {device.status === 'online' && (
                      <div className="mt-4 pt-4 border-t border-slate-700">
                        <div className="grid grid-cols-3 gap-2 text-center">
                          <div>
                            <p className="text-xs text-slate-500">CPU</p>
                            <p className="text-sm text-blue-400">{device.performance.cpu}%</p>
                          </div>
                          <div>
                            <p className="text-xs text-slate-500">内存</p>
                            <p className="text-sm text-green-400">{device.performance.memory}%</p>
                          </div>
                          <div>
                            <p className="text-xs text-slate-500">磁盘</p>
                            <p className="text-sm text-yellow-400">{device.performance.disk}%</p>
                          </div>
                        </div>
                      </div>
                    )}

                    {/* 标签 */}
                    {device.tags.length > 0 && (
                      <div className="mt-4 flex flex-wrap gap-1">
                        {device.tags.slice(0, 2).map((tag, index) => (
                          <span
                            key={index}
                            className="px-2 py-1 bg-blue-500/20 text-blue-400 text-xs rounded"
                          >
                            {tag}
                          </span>
                        ))}
                        {device.tags.length > 2 && (
                          <span className="px-2 py-1 bg-slate-600 text-slate-300 text-xs rounded">
                            +{device.tags.length - 2}
                          </span>
                        )}
                      </div>
                    )}
                  </div>
                )
              })}
            </div>
          ) : (
            /* 列表视图 */
            <div className="bg-slate-900/50 backdrop-blur-sm border border-slate-800 rounded-xl overflow-hidden">
              <div className="overflow-x-auto">
                <table className="w-full">
                  <thead className="bg-slate-800/50 border-b border-slate-700">
                    <tr>
                      <th className="text-left p-4 text-sm font-medium text-slate-300">设备</th>
                      <th className="text-left p-4 text-sm font-medium text-slate-300">状态</th>
                      <th className="text-left p-4 text-sm font-medium text-slate-300">IP地址</th>
                      <th className="text-left p-4 text-sm font-medium text-slate-300">系统</th>
                      <th className="text-left p-4 text-sm font-medium text-slate-300">所有者</th>
                      <th className="text-left p-4 text-sm font-medium text-slate-300">最后连接</th>
                      <th className="text-left p-4 text-sm font-medium text-slate-300">操作</th>
                    </tr>
                  </thead>
                  <tbody>
                    {filteredDevices.map((device) => {
                      const DeviceIcon = getDeviceIcon(device.type)
                      const statusInfo = getStatusInfo(device.status)

                      return (
                        <tr
                          key={device.id}
                          onClick={() => setSelectedDevice(device)}
                          className={cn(
                            'border-b border-slate-700 hover:bg-slate-800/30 cursor-pointer',
                            selectedDevice?.id === device.id && 'bg-blue-500/10'
                          )}
                        >
                          <td className="p-4">
                            <div className="flex items-center space-x-3">
                              <div className="p-2 bg-slate-700 rounded-lg">
                                <DeviceIcon className="w-4 h-4 text-slate-300" />
                              </div>
                              <div>
                                <p className="font-medium text-white">{device.name}</p>
                                <p className="text-sm text-slate-400">{device.hardware.cpu}</p>
                              </div>
                            </div>
                          </td>
                          <td className="p-4">
                            <div className={cn('flex items-center space-x-1 px-2 py-1 rounded-full text-xs w-fit', statusInfo.color)}>
                              <statusInfo.icon className="w-3 h-3" />
                              <span>{statusInfo.text}</span>
                            </div>
                          </td>
                          <td className="p-4 text-sm text-white">{device.ip}</td>
                          <td className="p-4 text-sm text-white">{device.os} {device.version}</td>
                          <td className="p-4 text-sm text-white">{device.owner}</td>
                          <td className="p-4 text-sm text-white">{device.lastSeen}</td>
                          <td className="p-4">
                            <div className="flex items-center space-x-2">
                              <button
                                onClick={(e) => {
                                  e.stopPropagation()
                                  handleDeviceAction(device.id, 'connect')
                                }}
                                className="p-1 hover:bg-slate-700 rounded"
                              >
                                <Eye className="w-4 h-4 text-slate-400" />
                              </button>
                              <button
                                onClick={(e) => {
                                  e.stopPropagation()
                                  handleDeviceAction(device.id, 'edit')
                                }}
                                className="p-1 hover:bg-slate-700 rounded"
                              >
                                <Edit className="w-4 h-4 text-slate-400" />
                              </button>
                              <button
                                onClick={(e) => {
                                  e.stopPropagation()
                                  handleDeviceAction(device.id, 'delete')
                                }}
                                className="p-1 hover:bg-slate-700 rounded"
                              >
                                <Trash2 className="w-4 h-4 text-red-400" />
                              </button>
                            </div>
                          </td>
                        </tr>
                      )
                    })}
                  </tbody>
                </table>
              </div>
            </div>
          )}
        </div>

        {/* 设备详情面板 */}
        <div className="lg:col-span-1">
          <div className="bg-slate-900/50 backdrop-blur-sm border border-slate-800 rounded-xl sticky top-6">
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
                    <p className="text-slate-400">{selectedDevice.os} {selectedDevice.version}</p>
                    <div className={cn('inline-flex items-center space-x-2 mt-2 px-3 py-1 rounded-full text-sm', getStatusInfo(selectedDevice.status).color)}>
                      {React.createElement(getStatusInfo(selectedDevice.status).icon, {
                        className: 'w-4 h-4'
                      })}
                      <span>{getStatusInfo(selectedDevice.status).text}</span>
                    </div>
                  </div>

                  {/* 连接信息 */}
                  <div className="space-y-3">
                    <h4 className="text-sm font-medium text-slate-300">连接信息</h4>
                    <div className="space-y-2 text-sm">
                      <div className="flex justify-between">
                        <span className="text-slate-400">IP地址</span>
                        <span className="text-white">{selectedDevice.ip}</span>
                      </div>
                      <div className="flex justify-between">
                        <span className="text-slate-400">MAC地址</span>
                        <span className="text-white font-mono text-xs">{selectedDevice.mac}</span>
                      </div>
                      <div className="flex justify-between">
                        <span className="text-slate-400">位置</span>
                        <span className="text-white">{selectedDevice.location}</span>
                      </div>
                      <div className="flex justify-between">
                        <span className="text-slate-400">所有者</span>
                        <span className="text-white">{selectedDevice.owner}</span>
                      </div>
                    </div>
                  </div>

                  {/* 硬件信息 */}
                  <div className="space-y-3">
                    <h4 className="text-sm font-medium text-slate-300">硬件配置</h4>
                    <div className="space-y-2 text-sm">
                      <div className="flex justify-between">
                        <span className="text-slate-400">处理器</span>
                        <span className="text-white text-right">{selectedDevice.hardware.cpu}</span>
                      </div>
                      <div className="flex justify-between">
                        <span className="text-slate-400">内存</span>
                        <span className="text-white">{selectedDevice.hardware.memory}</span>
                      </div>
                      <div className="flex justify-between">
                        <span className="text-slate-400">存储</span>
                        <span className="text-white">{selectedDevice.hardware.storage}</span>
                      </div>
                      {selectedDevice.hardware.gpu && (
                        <div className="flex justify-between">
                          <span className="text-slate-400">显卡</span>
                          <span className="text-white text-right">{selectedDevice.hardware.gpu}</span>
                        </div>
                      )}
                    </div>
                  </div>

                  {/* 性能监控 */}
                  {selectedDevice.status === 'online' && (
                    <div className="space-y-3">
                      <h4 className="text-sm font-medium text-slate-300">实时性能</h4>
                      <div className="space-y-3">
                        <div>
                          <div className="flex justify-between text-sm mb-1">
                            <span className="text-slate-400">CPU使用率</span>
                            <span className="text-white">{selectedDevice.performance.cpu}%</span>
                          </div>
                          <div className="w-full bg-slate-700 rounded-full h-2">
                            <div
                              className="bg-blue-500 h-2 rounded-full transition-all duration-300"
                              style={{ width: `${selectedDevice.performance.cpu}%` }}
                            />
                          </div>
                        </div>
                        <div>
                          <div className="flex justify-between text-sm mb-1">
                            <span className="text-slate-400">内存使用率</span>
                            <span className="text-white">{selectedDevice.performance.memory}%</span>
                          </div>
                          <div className="w-full bg-slate-700 rounded-full h-2">
                            <div
                              className="bg-green-500 h-2 rounded-full transition-all duration-300"
                              style={{ width: `${selectedDevice.performance.memory}%` }}
                            />
                          </div>
                        </div>
                        <div>
                          <div className="flex justify-between text-sm mb-1">
                            <span className="text-slate-400">磁盘使用率</span>
                            <span className="text-white">{selectedDevice.performance.disk}%</span>
                          </div>
                          <div className="w-full bg-slate-700 rounded-full h-2">
                            <div
                              className="bg-yellow-500 h-2 rounded-full transition-all duration-300"
                              style={{ width: `${selectedDevice.performance.disk}%` }}
                            />
                          </div>
                        </div>
                      </div>
                    </div>
                  )}

                  {/* 安全状态 */}
                  <div className="space-y-3">
                    <h4 className="text-sm font-medium text-slate-300">安全状态</h4>
                    <div className="space-y-2">
                      <div className="flex items-center justify-between">
                        <span className="text-sm text-slate-400">数据加密</span>
                        <div className={cn('flex items-center space-x-1', selectedDevice.security.encrypted ? 'text-green-400' : 'text-red-400')}>
                          <Shield className="w-4 h-4" />
                          <span className="text-sm">{selectedDevice.security.encrypted ? '已启用' : '未启用'}</span>
                        </div>
                      </div>
                      <div className="flex items-center justify-between">
                        <span className="text-sm text-slate-400">身份验证</span>
                        <div className={cn('flex items-center space-x-1', selectedDevice.security.authenticated ? 'text-green-400' : 'text-red-400')}>
                          <CheckCircle className="w-4 h-4" />
                          <span className="text-sm">{selectedDevice.security.authenticated ? '已验证' : '未验证'}</span>
                        </div>
                      </div>
                      <div className="flex items-center justify-between">
                        <span className="text-sm text-slate-400">安全漏洞</span>
                        <span className={cn('text-sm', selectedDevice.security.vulnerabilities === 0 ? 'text-green-400' : 'text-red-400')}>
                          {selectedDevice.security.vulnerabilities} 个
                        </span>
                      </div>
                    </div>
                  </div>

                  {/* 快速操作 */}
                  <div className="space-y-3">
                    <h4 className="text-sm font-medium text-slate-300">快速操作</h4>
                    <div className="grid grid-cols-2 gap-2">
                      <button
                        disabled={selectedDevice.status !== 'online'}
                        className="flex items-center justify-center space-x-1 p-2 bg-blue-600 hover:bg-blue-700 disabled:bg-slate-700 disabled:text-slate-500 text-white rounded-lg transition-colors text-sm"
                      >
                        <Monitor className="w-4 h-4" />
                        <span>远程</span>
                      </button>
                      <button
                        disabled={selectedDevice.status !== 'online'}
                        className="flex items-center justify-center space-x-1 p-2 bg-green-600 hover:bg-green-700 disabled:bg-slate-700 disabled:text-slate-500 text-white rounded-lg transition-colors text-sm"
                      >
                        <HardDrive className="w-4 h-4" />
                        <span>文件</span>
                      </button>
                      <button className="flex items-center justify-center space-x-1 p-2 bg-purple-600 hover:bg-purple-700 text-white rounded-lg transition-colors text-sm">
                        <Edit className="w-4 h-4" />
                        <span>编辑</span>
                      </button>
                      <button className="flex items-center justify-center space-x-1 p-2 bg-red-600 hover:bg-red-700 text-white rounded-lg transition-colors text-sm">
                        <Power className="w-4 h-4" />
                        <span>断开</span>
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
    </div>
  )
}