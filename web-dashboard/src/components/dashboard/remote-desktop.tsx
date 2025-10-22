'use client'

import React, { useState, useEffect, useRef } from 'react'
import { cn } from '@/lib/utils'
import {
  Monitor,
  Maximize2,
  Minimize2,
  Volume2,
  VolumeX,
  Settings,
  Power,
  RotateCcw,
  Camera,
  Download,
  Upload,
  Keyboard,
  Mouse,
  Wifi,
  WifiOff,
  Play,
  Pause,
  Square,
  MoreVertical,
  Fullscreen,
  Minimize,
  Zap,
  Clock,
  Activity,
  Users,
  Lock,
  Unlock,
  Eye,
  EyeOff,
  Clipboard,
  Copy,
  ClipboardCopy,
  FileText,
  Image,
  Video,
  Mic,
  MicOff,
  CameraOff,
  Share2,
  X,
  Plus,
  Minus,
  RotateCw,
  Move,
  Hand,
  MousePointer
} from 'lucide-react'

// 远程连接类型
interface RemoteConnection {
  id: string
  name: string
  type: 'vnc' | 'rdp' | 'ssh' | 'web'
  host: string
  port: number
  username: string
  status: 'connected' | 'connecting' | 'disconnected' | 'error'
  quality: 'low' | 'medium' | 'high' | 'ultra'
  resolution: string
  colorDepth: number
  bandwidth: number
  latency: number
  lastConnected: string
  sessionDuration: string
  isRecording: boolean
  isFullscreen: boolean
  audioEnabled: boolean
  clipboardSync: boolean
  fileTransferEnabled: boolean
}

// 远程桌面设置
interface RemoteSettings {
  quality: 'low' | 'medium' | 'high' | 'ultra'
  colorDepth: 8 | 16 | 24 | 32
  compression: boolean
  audioEnabled: boolean
  clipboardSync: boolean
  fileTransfer: boolean
  keyboardLayout: string
  mouseMode: 'relative' | 'absolute'
  scaling: 'fit' | 'stretch' | 'original'
  viewOnly: boolean
}

// 模拟连接数据
const mockConnections: RemoteConnection[] = [
  {
    id: '1',
    name: 'Windows Desktop - 办公室',
    type: 'rdp',
    host: '192.168.1.100',
    port: 3389,
    username: 'admin',
    status: 'connected',
    quality: 'high',
    resolution: '1920x1080',
    colorDepth: 24,
    bandwidth: 1.2,
    latency: 15,
    lastConnected: '2024-01-20 14:30',
    sessionDuration: '2小时 15分钟',
    isRecording: false,
    isFullscreen: false,
    audioEnabled: true,
    clipboardSync: true,
    fileTransferEnabled: true
  },
  {
    id: '2',
    name: 'Ubuntu Server - 数据中心',
    type: 'vnc',
    host: '192.168.1.101',
    port: 5900,
    username: 'root',
    status: 'connecting',
    quality: 'medium',
    resolution: '1366x768',
    colorDepth: 16,
    bandwidth: 0.8,
    latency: 25,
    lastConnected: '2024-01-20 13:45',
    sessionDuration: '-',
    isRecording: false,
    isFullscreen: false,
    audioEnabled: false,
    clipboardSync: true,
    fileTransferEnabled: false
  },
  {
    id: '3',
    name: 'MacBook Pro - 会议室',
    type: 'vnc',
    host: '192.168.1.102',
    port: 5900,
    username: 'user',
    status: 'disconnected',
    quality: 'ultra',
    resolution: '2560x1600',
    colorDepth: 32,
    bandwidth: 0,
    latency: 0,
    lastConnected: '2024-01-20 12:20',
    sessionDuration: '-',
    isRecording: false,
    isFullscreen: false,
    audioEnabled: true,
    clipboardSync: true,
    fileTransferEnabled: true
  }
]

// 获取连接状态信息
const getConnectionStatusInfo = (status: RemoteConnection['status']) => {
  switch (status) {
    case 'connected':
      return { color: 'text-green-400 bg-green-500/20', icon: Wifi, text: '已连接' }
    case 'connecting':
      return { color: 'text-yellow-400 bg-yellow-500/20', icon: Clock, text: '连接中' }
    case 'disconnected':
      return { color: 'text-slate-400 bg-slate-500/20', icon: WifiOff, text: '已断开' }
    case 'error':
      return { color: 'text-red-400 bg-red-500/20', icon: X, text: '连接错误' }
    default:
      return { color: 'text-slate-400 bg-slate-500/20', icon: WifiOff, text: '未知' }
  }
}

// 获取连接类型图标
const getConnectionTypeIcon = (type: RemoteConnection['type']) => {
  switch (type) {
    case 'rdp': return Monitor
    case 'vnc': return Monitor
    case 'ssh': return FileText
    case 'web': return Monitor
    default: return Monitor
  }
}

export function RemoteDesktop() {
  const [connections, setConnections] = useState<RemoteConnection[]>(mockConnections)
  const [activeConnection, setActiveConnection] = useState<RemoteConnection | null>(null)
  const [showSettings, setShowSettings] = useState(false)
  const [showConnectionDialog, setShowConnectionDialog] = useState(false)
  const [isFullscreen, setIsFullscreen] = useState(false)
  const [mouseMode, setMouseMode] = useState<'pointer' | 'hand' | 'move'>('pointer')
  const [zoomLevel, setZoomLevel] = useState(100)
  const [settings, setSettings] = useState<RemoteSettings>({
    quality: 'high',
    colorDepth: 24,
    compression: true,
    audioEnabled: true,
    clipboardSync: true,
    fileTransfer: true,
    keyboardLayout: 'us',
    mouseMode: 'relative',
    scaling: 'fit',
    viewOnly: false
  })

  const canvasRef = useRef<HTMLCanvasElement>(null)
  const containerRef = useRef<HTMLDivElement>(null)

  // 连接到远程桌面
  const connectToRemote = (connection: RemoteConnection) => {
    console.log(`连接到: ${connection.name}`)
    setActiveConnection(connection)
    // 这里可以添加实际的连接逻辑
  }

  // 断开连接
  const disconnectRemote = () => {
    if (activeConnection) {
      console.log(`断开连接: ${activeConnection.name}`)
      setActiveConnection(null)
    }
  }

  // 切换全屏
  const toggleFullscreen = () => {
    if (!document.fullscreenElement) {
      containerRef.current?.requestFullscreen()
      setIsFullscreen(true)
    } else {
      document.exitFullscreen()
      setIsFullscreen(false)
    }
  }

  // 截图
  const takeScreenshot = () => {
    if (canvasRef.current) {
      const link = document.createElement('a')
      link.download = `screenshot-${Date.now()}.png`
      link.href = canvasRef.current.toDataURL()
      link.click()
    }
  }

  // 录制控制
  const toggleRecording = () => {
    if (activeConnection) {
      const updatedConnection = { ...activeConnection, isRecording: !activeConnection.isRecording }
      setActiveConnection(updatedConnection)
      console.log(`${updatedConnection.isRecording ? '开始' : '停止'}录制`)
    }
  }

  // 缩放控制
  const handleZoom = (delta: number) => {
    const newZoom = Math.max(25, Math.min(400, zoomLevel + delta))
    setZoomLevel(newZoom)
  }

  return (
    <div className="h-full flex flex-col">
      {/* 顶部工具栏 */}
      <div className="flex items-center justify-between p-4 bg-slate-900/50 border-b border-slate-800">
        <div className="flex items-center space-x-4">
          <h1 className="text-xl font-bold text-white">远程桌面</h1>
          {activeConnection && (
            <div className="flex items-center space-x-2">
              <div className={cn('flex items-center space-x-1 px-2 py-1 rounded-full text-xs', getConnectionStatusInfo(activeConnection.status).color)}>
                {React.createElement(getConnectionStatusInfo(activeConnection.status).icon, {
                  className: 'w-3 h-3'
                })}
                <span>{getConnectionStatusInfo(activeConnection.status).text}</span>
              </div>
              <span className="text-slate-400">|</span>
              <span className="text-sm text-white">{activeConnection.name}</span>
              <span className="text-slate-400">|</span>
              <span className="text-sm text-slate-400">{activeConnection.resolution}</span>
              <span className="text-slate-400">|</span>
              <span className="text-sm text-slate-400">{activeConnection.latency}ms</span>
            </div>
          )}
        </div>

        <div className="flex items-center space-x-2">
          {activeConnection ? (
            <>
              {/* 连接控制 */}
              <div className="flex items-center space-x-1 bg-slate-800 rounded-lg p-1">
                <button
                  onClick={() => setMouseMode('pointer')}
                  className={cn('p-2 rounded text-sm', mouseMode === 'pointer' ? 'bg-slate-600 text-white' : 'text-slate-400')}
                  title="指针模式"
                >
                  <MousePointer className="w-4 h-4" />
                </button>
                <button
                  onClick={() => setMouseMode('hand')}
                  className={cn('p-2 rounded text-sm', mouseMode === 'hand' ? 'bg-slate-600 text-white' : 'text-slate-400')}
                  title="拖拽模式"
                >
                  <Hand className="w-4 h-4" />
                </button>
                <button
                  onClick={() => setMouseMode('move')}
                  className={cn('p-2 rounded text-sm', mouseMode === 'move' ? 'bg-slate-600 text-white' : 'text-slate-400')}
                  title="移动模式"
                >
                  <Move className="w-4 h-4" />
                </button>
              </div>

              {/* 缩放控制 */}
              <div className="flex items-center space-x-1 bg-slate-800 rounded-lg p-1">
                <button
                  onClick={() => handleZoom(-25)}
                  className="p-2 hover:bg-slate-600 rounded text-slate-400"
                  title="缩小"
                >
                  <Minus className="w-4 h-4" />
                </button>
                <span className="px-2 text-sm text-white min-w-[60px] text-center">{zoomLevel}%</span>
                <button
                  onClick={() => handleZoom(25)}
                  className="p-2 hover:bg-slate-600 rounded text-slate-400"
                  title="放大"
                >
                  <Plus className="w-4 h-4" />
                </button>
              </div>

              {/* 功能按钮 */}
              <button
                onClick={takeScreenshot}
                className="p-2 bg-slate-800 hover:bg-slate-700 rounded-lg text-slate-400"
                title="截图"
              >
                <Camera className="w-4 h-4" />
              </button>

              <button
                onClick={toggleRecording}
                className={cn('p-2 rounded-lg', activeConnection.isRecording ? 'bg-red-600 text-white' : 'bg-slate-800 hover:bg-slate-700 text-slate-400')}
                title={activeConnection.isRecording ? '停止录制' : '开始录制'}
              >
                {activeConnection.isRecording ? <Square className="w-4 h-4" /> : <Video className="w-4 h-4" />}
              </button>

              <button
                onClick={() => setSettings(prev => ({ ...prev, audioEnabled: !prev.audioEnabled }))}
                className={cn('p-2 rounded-lg', settings.audioEnabled ? 'bg-blue-600 text-white' : 'bg-slate-800 hover:bg-slate-700 text-slate-400')}
                title={settings.audioEnabled ? '关闭音频' : '开启音频'}
              >
                {settings.audioEnabled ? <Volume2 className="w-4 h-4" /> : <VolumeX className="w-4 h-4" />}
              </button>

              <button
                onClick={toggleFullscreen}
                className="p-2 bg-slate-800 hover:bg-slate-700 rounded-lg text-slate-400"
                title={isFullscreen ? '退出全屏' : '全屏'}
              >
                {isFullscreen ? <Minimize className="w-4 h-4" /> : <Fullscreen className="w-4 h-4" />}
              </button>

              <button
                onClick={() => setShowSettings(true)}
                className="p-2 bg-slate-800 hover:bg-slate-700 rounded-lg text-slate-400"
                title="设置"
              >
                <Settings className="w-4 h-4" />
              </button>

              <button
                onClick={disconnectRemote}
                className="p-2 bg-red-600 hover:bg-red-700 rounded-lg text-white"
                title="断开连接"
              >
                <Power className="w-4 h-4" />
              </button>
            </>
          ) : (
            <button
              onClick={() => setShowConnectionDialog(true)}
              className="flex items-center space-x-2 px-4 py-2 bg-blue-600 hover:bg-blue-700 text-white rounded-lg"
            >
              <Plus className="w-4 h-4" />
              <span>新建连接</span>
            </button>
          )}
        </div>
      </div>

      {/* 主内容区域 */}
      <div className="flex-1 flex" ref={containerRef}>
        {activeConnection ? (
          /* 远程桌面显示区域 */
          <div className="flex-1 bg-slate-900 relative overflow-hidden">
            {/* 模拟远程桌面画布 */}
            <div className="w-full h-full flex items-center justify-center">
              <canvas
                ref={canvasRef}
                className="border border-slate-700 rounded-lg shadow-2xl"
                style={{
                  transform: `scale(${zoomLevel / 100})`,
                  transformOrigin: 'center',
                  cursor: mouseMode === 'pointer' ? 'default' : mouseMode === 'hand' ? 'grab' : 'move'
                }}
                width={1920}
                height={1080}
              />
            </div>

            {/* 连接状态覆盖层 */}
            {activeConnection.status !== 'connected' && (
              <div className="absolute inset-0 bg-slate-900/80 flex items-center justify-center">
                <div className="text-center">
                  <div className="animate-spin w-8 h-8 border-2 border-blue-500 border-t-transparent rounded-full mx-auto mb-4" />
                  <p className="text-white text-lg">{getConnectionStatusInfo(activeConnection.status).text}</p>
                  <p className="text-slate-400 mt-2">正在连接到 {activeConnection.name}</p>
                </div>
              </div>
            )}

            {/* 性能信息覆盖层 */}
            <div className="absolute top-4 right-4 bg-slate-900/80 backdrop-blur-sm rounded-lg p-3 text-sm">
              <div className="flex items-center space-x-4 text-slate-300">
                <div className="flex items-center space-x-1">
                  <Activity className="w-4 h-4" />
                  <span>{activeConnection.bandwidth.toFixed(1)} MB/s</span>
                </div>
                <div className="flex items-center space-x-1">
                  <Clock className="w-4 h-4" />
                  <span>{activeConnection.latency}ms</span>
                </div>
                <div className="flex items-center space-x-1">
                  <Monitor className="w-4 h-4" />
                  <span>{activeConnection.resolution}</span>
                </div>
              </div>
            </div>
          </div>
        ) : (
          /* 连接列表 */
          <div className="flex-1 p-6">
            <div className="max-w-4xl mx-auto">
              <div className="text-center mb-8">
                <div className="inline-flex p-4 bg-slate-800 rounded-xl mb-4">
                  <Monitor className="w-12 h-12 text-slate-400" />
                </div>
                <h2 className="text-2xl font-bold text-white mb-2">选择远程连接</h2>
                <p className="text-slate-400">选择一个已保存的连接或创建新的连接</p>
              </div>

              {/* 连接卡片 */}
              <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6">
                {connections.map((connection) => {
                  const TypeIcon = getConnectionTypeIcon(connection.type)
                  const statusInfo = getConnectionStatusInfo(connection.status)

                  return (
                    <div
                      key={connection.id}
                      className="bg-slate-800/50 border border-slate-700 rounded-xl p-6 hover:bg-slate-800/70 transition-all cursor-pointer group"
                      onClick={() => connectToRemote(connection)}
                    >
                      {/* 连接头部 */}
                      <div className="flex items-center justify-between mb-4">
                        <div className="flex items-center space-x-3">
                          <div className="p-2 bg-slate-700 rounded-lg">
                            <TypeIcon className="w-5 h-5 text-slate-300" />
                          </div>
                          <div>
                            <h3 className="font-medium text-white">{connection.name}</h3>
                            <p className="text-sm text-slate-400">{connection.host}:{connection.port}</p>
                          </div>
                        </div>
                        <div className="relative opacity-0 group-hover:opacity-100 transition-opacity">
                          <button className="p-1 hover:bg-slate-700 rounded">
                            <MoreVertical className="w-4 h-4 text-slate-400" />
                          </button>
                        </div>
                      </div>

                      {/* 连接信息 */}
                      <div className="space-y-3">
                        <div className="flex items-center justify-between">
                          <span className="text-sm text-slate-400">状态</span>
                          <div className={cn('flex items-center space-x-1 px-2 py-1 rounded-full text-xs', statusInfo.color)}>
                            <statusInfo.icon className="w-3 h-3" />
                            <span>{statusInfo.text}</span>
                          </div>
                        </div>

                        <div className="flex items-center justify-between">
                          <span className="text-sm text-slate-400">协议</span>
                          <span className="text-sm text-white uppercase">{connection.type}</span>
                        </div>

                        <div className="flex items-center justify-between">
                          <span className="text-sm text-slate-400">分辨率</span>
                          <span className="text-sm text-white">{connection.resolution}</span>
                        </div>

                        <div className="flex items-center justify-between">
                          <span className="text-sm text-slate-400">用户</span>
                          <span className="text-sm text-white">{connection.username}</span>
                        </div>

                        <div className="flex items-center justify-between">
                          <span className="text-sm text-slate-400">最后连接</span>
                          <span className="text-sm text-white">{connection.lastConnected}</span>
                        </div>
                      </div>

                      {/* 功能标识 */}
                      <div className="mt-4 pt-4 border-t border-slate-700">
                        <div className="flex items-center justify-between text-xs">
                          <div className="flex items-center space-x-2">
                            {connection.audioEnabled && (
                              <div className="flex items-center space-x-1 text-green-400">
                                <Volume2 className="w-3 h-3" />
                                <span>音频</span>
                              </div>
                            )}
                            {connection.clipboardSync && (
                              <div className="flex items-center space-x-1 text-blue-400">
                                <Clipboard className="w-3 h-3" />
                                <span>剪贴板</span>
                              </div>
                            )}
                            {connection.fileTransferEnabled && (
                              <div className="flex items-center space-x-1 text-purple-400">
                                <Upload className="w-3 h-3" />
                                <span>文件</span>
                              </div>
                            )}
                          </div>
                          <span className="text-slate-500">{connection.quality}</span>
                        </div>
                      </div>
                    </div>
                  )
                })}

                {/* 添加新连接卡片 */}
                <div
                  onClick={() => setShowConnectionDialog(true)}
                  className="bg-slate-800/30 border-2 border-dashed border-slate-600 rounded-xl p-6 hover:bg-slate-800/50 hover:border-slate-500 transition-all cursor-pointer flex flex-col items-center justify-center text-center min-h-[280px]"
                >
                  <div className="p-4 bg-slate-700 rounded-xl mb-4">
                    <Plus className="w-8 h-8 text-slate-400" />
                  </div>
                  <h3 className="font-medium text-white mb-2">添加新连接</h3>
                  <p className="text-sm text-slate-400">创建新的远程桌面连接</p>
                </div>
              </div>
            </div>
          </div>
        )}
      </div>

      {/* 设置对话框 */}
      {showSettings && (
        <div className="fixed inset-0 bg-black/50 flex items-center justify-center z-50">
          <div className="bg-slate-900 border border-slate-700 rounded-xl p-6 w-full max-w-md">
            <div className="flex items-center justify-between mb-6">
              <h2 className="text-lg font-semibold text-white">连接设置</h2>
              <button
                onClick={() => setShowSettings(false)}
                className="p-1 hover:bg-slate-700 rounded"
              >
                <X className="w-5 h-5 text-slate-400" />
              </button>
            </div>

            <div className="space-y-4">
              {/* 显示质量 */}
              <div>
                <label className="block text-sm font-medium text-slate-300 mb-2">显示质量</label>
                <select
                  value={settings.quality}
                  onChange={(e) => setSettings(prev => ({ ...prev, quality: e.target.value as any }))}
                  className="w-full p-2 bg-slate-800 border border-slate-700 rounded-lg text-white"
                >
                  <option value="low">低质量 (快速)</option>
                  <option value="medium">中等质量</option>
                  <option value="high">高质量</option>
                  <option value="ultra">超高质量 (慢速)</option>
                </select>
              </div>

              {/* 颜色深度 */}
              <div>
                <label className="block text-sm font-medium text-slate-300 mb-2">颜色深度</label>
                <select
                  value={settings.colorDepth}
                  onChange={(e) => setSettings(prev => ({ ...prev, colorDepth: parseInt(e.target.value) as any }))}
                  className="w-full p-2 bg-slate-800 border border-slate-700 rounded-lg text-white"
                >
                  <option value={8}>8位 (256色)</option>
                  <option value={16}>16位 (65K色)</option>
                  <option value={24}>24位 (16M色)</option>
                  <option value={32}>32位 (真彩色)</option>
                </select>
              </div>

              {/* 缩放模式 */}
              <div>
                <label className="block text-sm font-medium text-slate-300 mb-2">缩放模式</label>
                <select
                  value={settings.scaling}
                  onChange={(e) => setSettings(prev => ({ ...prev, scaling: e.target.value as any }))}
                  className="w-full p-2 bg-slate-800 border border-slate-700 rounded-lg text-white"
                >
                  <option value="fit">适应窗口</option>
                  <option value="stretch">拉伸填充</option>
                  <option value="original">原始大小</option>
                </select>
              </div>

              {/* 功能开关 */}
              <div className="space-y-3">
                <div className="flex items-center justify-between">
                  <span className="text-sm text-slate-300">启用音频</span>
                  <button
                    onClick={() => setSettings(prev => ({ ...prev, audioEnabled: !prev.audioEnabled }))}
                    className={cn('w-12 h-6 rounded-full transition-colors', settings.audioEnabled ? 'bg-blue-600' : 'bg-slate-600')}
                  >
                    <div className={cn('w-5 h-5 bg-white rounded-full transition-transform', settings.audioEnabled ? 'translate-x-6' : 'translate-x-1')} />
                  </button>
                </div>

                <div className="flex items-center justify-between">
                  <span className="text-sm text-slate-300">剪贴板同步</span>
                  <button
                    onClick={() => setSettings(prev => ({ ...prev, clipboardSync: !prev.clipboardSync }))}
                    className={cn('w-12 h-6 rounded-full transition-colors', settings.clipboardSync ? 'bg-blue-600' : 'bg-slate-600')}
                  >
                    <div className={cn('w-5 h-5 bg-white rounded-full transition-transform', settings.clipboardSync ? 'translate-x-6' : 'translate-x-1')} />
                  </button>
                </div>

                <div className="flex items-center justify-between">
                  <span className="text-sm text-slate-300">文件传输</span>
                  <button
                    onClick={() => setSettings(prev => ({ ...prev, fileTransfer: !prev.fileTransfer }))}
                    className={cn('w-12 h-6 rounded-full transition-colors', settings.fileTransfer ? 'bg-blue-600' : 'bg-slate-600')}
                  >
                    <div className={cn('w-5 h-5 bg-white rounded-full transition-transform', settings.fileTransfer ? 'translate-x-6' : 'translate-x-1')} />
                  </button>
                </div>

                <div className="flex items-center justify-between">
                  <span className="text-sm text-slate-300">压缩传输</span>
                  <button
                    onClick={() => setSettings(prev => ({ ...prev, compression: !prev.compression }))}
                    className={cn('w-12 h-6 rounded-full transition-colors', settings.compression ? 'bg-blue-600' : 'bg-slate-600')}
                  >
                    <div className={cn('w-5 h-5 bg-white rounded-full transition-transform', settings.compression ? 'translate-x-6' : 'translate-x-1')} />
                  </button>
                </div>

                <div className="flex items-center justify-between">
                  <span className="text-sm text-slate-300">只读模式</span>
                  <button
                    onClick={() => setSettings(prev => ({ ...prev, viewOnly: !prev.viewOnly }))}
                    className={cn('w-12 h-6 rounded-full transition-colors', settings.viewOnly ? 'bg-blue-600' : 'bg-slate-600')}
                  >
                    <div className={cn('w-5 h-5 bg-white rounded-full transition-transform', settings.viewOnly ? 'translate-x-6' : 'translate-x-1')} />
                  </button>
                </div>
              </div>
            </div>

            <div className="flex justify-end space-x-3 mt-6">
              <button
                onClick={() => setShowSettings(false)}
                className="px-4 py-2 bg-slate-700 hover:bg-slate-600 text-white rounded-lg"
              >
                取消
              </button>
              <button
                onClick={() => setShowSettings(false)}
                className="px-4 py-2 bg-blue-600 hover:bg-blue-700 text-white rounded-lg"
              >
                保存
              </button>
            </div>
          </div>
        </div>
      )}

      {/* 新建连接对话框 */}
      {showConnectionDialog && (
        <div className="fixed inset-0 bg-black/50 flex items-center justify-center z-50">
          <div className="bg-slate-900 border border-slate-700 rounded-xl p-6 w-full max-w-lg">
            <div className="flex items-center justify-between mb-6">
              <h2 className="text-lg font-semibold text-white">新建远程连接</h2>
              <button
                onClick={() => setShowConnectionDialog(false)}
                className="p-1 hover:bg-slate-700 rounded"
              >
                <X className="w-5 h-5 text-slate-400" />
              </button>
            </div>

            <div className="space-y-4">
              <div>
                <label className="block text-sm font-medium text-slate-300 mb-2">连接名称</label>
                <input
                  type="text"
                  placeholder="输入连接名称"
                  className="w-full p-3 bg-slate-800 border border-slate-700 rounded-lg text-white placeholder-slate-400"
                />
              </div>

              <div>
                <label className="block text-sm font-medium text-slate-300 mb-2">连接类型</label>
                <select className="w-full p-3 bg-slate-800 border border-slate-700 rounded-lg text-white">
                  <option value="rdp">RDP (Windows远程桌面)</option>
                  <option value="vnc">VNC (跨平台)</option>
                  <option value="ssh">SSH (命令行)</option>
                  <option value="web">Web (浏览器)</option>
                </select>
              </div>

              <div className="grid grid-cols-2 gap-4">
                <div>
                  <label className="block text-sm font-medium text-slate-300 mb-2">主机地址</label>
                  <input
                    type="text"
                    placeholder="192.168.1.100"
                    className="w-full p-3 bg-slate-800 border border-slate-700 rounded-lg text-white placeholder-slate-400"
                  />
                </div>
                <div>
                  <label className="block text-sm font-medium text-slate-300 mb-2">端口</label>
                  <input
                    type="number"
                    placeholder="3389"
                    className="w-full p-3 bg-slate-800 border border-slate-700 rounded-lg text-white placeholder-slate-400"
                  />
                </div>
              </div>

              <div className="grid grid-cols-2 gap-4">
                <div>
                  <label className="block text-sm font-medium text-slate-300 mb-2">用户名</label>
                  <input
                    type="text"
                    placeholder="输入用户名"
                    className="w-full p-3 bg-slate-800 border border-slate-700 rounded-lg text-white placeholder-slate-400"
                  />
                </div>
                <div>
                  <label className="block text-sm font-medium text-slate-300 mb-2">密码</label>
                  <input
                    type="password"
                    placeholder="输入密码"
                    className="w-full p-3 bg-slate-800 border border-slate-700 rounded-lg text-white placeholder-slate-400"
                  />
                </div>
              </div>
            </div>

            <div className="flex justify-end space-x-3 mt-6">
              <button
                onClick={() => setShowConnectionDialog(false)}
                className="px-4 py-2 bg-slate-700 hover:bg-slate-600 text-white rounded-lg"
              >
                取消
              </button>
              <button
                onClick={() => {
                  setShowConnectionDialog(false)
                  // 这里可以添加保存连接的逻辑
                }}
                className="px-4 py-2 bg-blue-600 hover:bg-blue-700 text-white rounded-lg"
              >
                连接
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  )
}