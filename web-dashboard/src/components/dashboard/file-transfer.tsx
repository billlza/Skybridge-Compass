'use client'

import React, { useState, useRef, useCallback } from 'react'
import { cn } from '@/lib/utils'
import { useFiles, useDataSourceInfo } from '@/hooks/use-dashboard-data'
import {
  Upload,
  Download,
  File,
  Folder,
  FolderOpen,
  Image,
  Video,
  Music,
  Archive,
  FileText,
  Code,
  Database,
  Settings,
  Trash2,
  Edit,
  Copy,
  Move,
  Share2,
  Eye,
  MoreVertical,
  Search,
  Filter,
  Grid,
  List,
  ArrowUp,
  ArrowDown,
  ArrowLeft,
  ArrowRight,
  Home,
  RefreshCw,
  Plus,
  X,
  Check,
  AlertTriangle,
  Clock,
  Pause,
  Play,
  Square,
  RotateCcw,
  HardDrive,
  Server,
  Cloud,
  Wifi,
  WifiOff,
  Lock,
  Unlock,
  Star,
  StarOff,
  Tag,
  Calendar,
  User,
  Users,
  Info,
  ExternalLink,
  Maximize2,
  Minimize2
} from 'lucide-react'

// 文件/文件夹类型
interface FileItem {
  id: string
  name: string
  type: 'file' | 'folder'
  size: number
  modified: string
  created: string
  owner: string
  permissions: string
  path: string
  extension?: string
  mimeType?: string
  isHidden: boolean
  isReadonly: boolean
  isShared: boolean
  isFavorite: boolean
  tags: string[]
  thumbnail?: string
  children?: FileItem[]
}

// 传输任务
interface TransferTask {
  id: string
  type: 'upload' | 'download'
  fileName: string
  fileSize: number
  progress: number
  speed: number
  status: 'pending' | 'transferring' | 'completed' | 'paused' | 'error' | 'cancelled'
  startTime: string
  estimatedTime: string
  source: string
  destination: string
  error?: string
}

// 连接信息
interface ConnectionInfo {
  id: string
  name: string
  type: 'local' | 'remote' | 'ftp' | 'sftp' | 'cloud'
  host?: string
  port?: number
  username?: string
  status: 'connected' | 'connecting' | 'disconnected' | 'error'
  currentPath: string
  totalSpace: number
  usedSpace: number
  freeSpace: number
}

// 模拟文件数据
const mockFiles: FileItem[] = [
  {
    id: '1',
    name: '文档',
    type: 'folder',
    size: 0,
    modified: '2024-01-20 14:30',
    created: '2024-01-15 10:00',
    owner: '当前用户',
    permissions: 'rwxr-xr-x',
    path: '/文档',
    isHidden: false,
    isReadonly: false,
    isShared: true,
    isFavorite: true,
    tags: ['工作', '重要'],
    children: [
      {
        id: '1-1',
        name: '项目报告.docx',
        type: 'file',
        size: 2048576,
        modified: '2024-01-20 14:30',
        created: '2024-01-20 09:00',
        owner: '当前用户',
        permissions: 'rw-r--r--',
        path: '/文档/项目报告.docx',
        extension: 'docx',
        mimeType: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
        isHidden: false,
        isReadonly: false,
        isShared: false,
        isFavorite: false,
        tags: ['报告', '项目']
      }
    ]
  },
  {
    id: '2',
    name: '图片',
    type: 'folder',
    size: 0,
    modified: '2024-01-19 16:45',
    created: '2024-01-10 12:00',
    owner: '当前用户',
    permissions: 'rwxr-xr-x',
    path: '/图片',
    isHidden: false,
    isReadonly: false,
    isShared: false,
    isFavorite: false,
    tags: ['媒体'],
    children: []
  },
  {
    id: '3',
    name: 'config.json',
    type: 'file',
    size: 1024,
    modified: '2024-01-20 11:20',
    created: '2024-01-18 15:30',
    owner: '当前用户',
    permissions: 'rw-r--r--',
    path: '/config.json',
    extension: 'json',
    mimeType: 'application/json',
    isHidden: false,
    isReadonly: true,
    isShared: false,
    isFavorite: true,
    tags: ['配置', '系统']
  },
  {
    id: '4',
    name: 'presentation.pptx',
    type: 'file',
    size: 15728640,
    modified: '2024-01-19 09:15',
    created: '2024-01-19 08:00',
    owner: '当前用户',
    permissions: 'rw-r--r--',
    path: '/presentation.pptx',
    extension: 'pptx',
    mimeType: 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    isHidden: false,
    isReadonly: false,
    isShared: true,
    isFavorite: false,
    tags: ['演示', '会议']
  },
  {
    id: '5',
    name: 'video.mp4',
    type: 'file',
    size: 104857600,
    modified: '2024-01-18 20:30',
    created: '2024-01-18 19:45',
    owner: '当前用户',
    permissions: 'rw-r--r--',
    path: '/video.mp4',
    extension: 'mp4',
    mimeType: 'video/mp4',
    isHidden: false,
    isReadonly: false,
    isShared: false,
    isFavorite: true,
    tags: ['视频', '媒体']
  }
]

// 模拟传输任务
const mockTransferTasks: TransferTask[] = [
  {
    id: '1',
    type: 'upload',
    fileName: 'database_backup.sql',
    fileSize: 52428800,
    progress: 75,
    speed: 2.5,
    status: 'transferring',
    startTime: '2024-01-20 14:25',
    estimatedTime: '2分钟',
    source: '本地',
    destination: '远程服务器'
  },
  {
    id: '2',
    type: 'download',
    fileName: 'system_logs.zip',
    fileSize: 10485760,
    progress: 100,
    speed: 0,
    status: 'completed',
    startTime: '2024-01-20 14:20',
    estimatedTime: '已完成',
    source: '远程服务器',
    destination: '本地'
  },
  {
    id: '3',
    type: 'upload',
    fileName: 'project_files.tar.gz',
    fileSize: 31457280,
    progress: 0,
    speed: 0,
    status: 'paused',
    startTime: '2024-01-20 14:30',
    estimatedTime: '已暂停',
    source: '本地',
    destination: '远程服务器'
  }
]

// 模拟连接信息
const mockConnections: ConnectionInfo[] = [
  {
    id: 'local',
    name: '本地文件',
    type: 'local',
    status: 'connected',
    currentPath: '/',
    totalSpace: 1000000000000,
    usedSpace: 500000000000,
    freeSpace: 500000000000
  },
  {
    id: 'remote1',
    name: '远程服务器',
    type: 'sftp',
    host: '192.168.1.100',
    port: 22,
    username: 'admin',
    status: 'connected',
    currentPath: '/home/admin',
    totalSpace: 500000000000,
    usedSpace: 200000000000,
    freeSpace: 300000000000
  }
]

// 获取文件图标
const getFileIcon = (item: FileItem) => {
  if (item.type === 'folder') {
    return item.children && item.children.length > 0 ? FolderOpen : Folder
  }

  const ext = item.extension?.toLowerCase()
  switch (ext) {
    case 'jpg':
    case 'jpeg':
    case 'png':
    case 'gif':
    case 'bmp':
    case 'svg':
      return Image
    case 'mp4':
    case 'avi':
    case 'mov':
    case 'wmv':
    case 'flv':
      return Video
    case 'mp3':
    case 'wav':
    case 'flac':
    case 'aac':
      return Music
    case 'zip':
    case 'rar':
    case '7z':
    case 'tar':
    case 'gz':
      return Archive
    case 'txt':
    case 'md':
    case 'doc':
    case 'docx':
    case 'pdf':
      return FileText
    case 'js':
    case 'ts':
    case 'html':
    case 'css':
    case 'json':
    case 'xml':
      return Code
    case 'sql':
    case 'db':
    case 'sqlite':
      return Database
    default:
      return File
  }
}

// 格式化文件大小
const formatFileSize = (bytes: number): string => {
  if (bytes === 0) return '0 B'
  const k = 1024
  const sizes = ['B', 'KB', 'MB', 'GB', 'TB']
  const i = Math.floor(Math.log(bytes) / Math.log(k))
  return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + ' ' + sizes[i]
}

// 获取传输状态信息
const getTransferStatusInfo = (status: TransferTask['status']) => {
  switch (status) {
    case 'transferring':
      return { color: 'text-blue-400 bg-blue-500/20', icon: ArrowUp, text: '传输中' }
    case 'completed':
      return { color: 'text-green-400 bg-green-500/20', icon: Check, text: '已完成' }
    case 'paused':
      return { color: 'text-yellow-400 bg-yellow-500/20', icon: Pause, text: '已暂停' }
    case 'error':
      return { color: 'text-red-400 bg-red-500/20', icon: AlertTriangle, text: '错误' }
    case 'cancelled':
      return { color: 'text-slate-400 bg-slate-500/20', icon: X, text: '已取消' }
    case 'pending':
      return { color: 'text-slate-400 bg-slate-500/20', icon: Clock, text: '等待中' }
    default:
      return { color: 'text-slate-400 bg-slate-500/20', icon: Clock, text: '未知' }
  }
}

export function FileTransfer() {
  const { data: apiFiles = [], isLoading, error, refetch } = useFiles()
  const { isUsingRealData, isApiConfigured } = useDataSourceInfo()
  
  // 转换 API 数据为组件所需格式，如果使用模拟数据则直接使用 mockFiles
  const files = isUsingRealData && apiFiles.length > 0 ? apiFiles : mockFiles
  
  const [currentConnection, setCurrentConnection] = useState<ConnectionInfo>(mockConnections[0])
  const [currentPath, setCurrentPath] = useState<string>('/')
  const [selectedFiles, setSelectedFiles] = useState<string[]>([])
  const [transferTasks, setTransferTasks] = useState<TransferTask[]>(mockTransferTasks)
  const [viewMode, setViewMode] = useState<'grid' | 'list'>('list')
  const [showTransferPanel, setShowTransferPanel] = useState(true)
  const [searchQuery, setSearchQuery] = useState('')
  const [sortBy, setSortBy] = useState<'name' | 'size' | 'modified'>('name')
  const [sortOrder, setSortOrder] = useState<'asc' | 'desc'>('asc')
  const [showHidden, setShowHidden] = useState(false)

  const fileInputRef = useRef<HTMLInputElement>(null)

  // 处理刷新
  const handleRefresh = () => {
    if (isUsingRealData) {
      refetch()
    }
  }

  // 过滤和排序文件
  const filteredAndSortedFiles = files
    .filter(file => {
      if (!showHidden && file.isHidden) return false
      if (searchQuery && !file.name.toLowerCase().includes(searchQuery.toLowerCase())) return false
      return true
    })
    .sort((a, b) => {
      let comparison = 0
      switch (sortBy) {
        case 'name':
          comparison = a.name.localeCompare(b.name)
          break
        case 'size':
          comparison = a.size - b.size
          break
        case 'modified':
          comparison = new Date(a.modified).getTime() - new Date(b.modified).getTime()
          break
      }
      return sortOrder === 'asc' ? comparison : -comparison
    })

  // 处理文件选择
  const handleFileSelect = (fileId: string, isMultiple: boolean = false) => {
    if (isMultiple) {
      setSelectedFiles(prev => 
        prev.includes(fileId) 
          ? prev.filter(id => id !== fileId)
          : [...prev, fileId]
      )
    } else {
      setSelectedFiles([fileId])
    }
  }

  // 处理文件上传
  const handleFileUpload = useCallback((event: React.ChangeEvent<HTMLInputElement>) => {
    const files = event.target.files
    if (files) {
      Array.from(files).forEach(file => {
        const newTask: TransferTask = {
          id: Date.now().toString() + Math.random(),
          type: 'upload',
          fileName: file.name,
          fileSize: file.size,
          progress: 0,
          speed: 0,
          status: 'pending',
          startTime: new Date().toLocaleString(),
          estimatedTime: '计算中...',
          source: '本地',
          destination: currentConnection.name
        }
        setTransferTasks(prev => [...prev, newTask])
        
        // 模拟上传进度
        setTimeout(() => {
          setTransferTasks(prev => prev.map(task => 
            task.id === newTask.id ? { ...task, status: 'transferring' as const } : task
          ))
        }, 1000)
      })
    }
  }, [currentConnection.name])

  // 处理文件下载
  const handleFileDownload = (fileIds: string[]) => {
    fileIds.forEach(fileId => {
      const file = files.find(f => f.id === fileId)
      if (file && file.type === 'file') {
        const newTask: TransferTask = {
          id: Date.now().toString() + Math.random(),
          type: 'download',
          fileName: file.name,
          fileSize: file.size,
          progress: 0,
          speed: 0,
          status: 'pending',
          startTime: new Date().toLocaleString(),
          estimatedTime: '计算中...',
          source: currentConnection.name,
          destination: '本地'
        }
        setTransferTasks(prev => [...prev, newTask])
        
        // 模拟下载进度
        setTimeout(() => {
          setTransferTasks(prev => prev.map(task => 
            task.id === newTask.id ? { ...task, status: 'transferring' as const } : task
          ))
        }, 1000)
      }
    })
  }

  // 控制传输任务
  const controlTransferTask = (taskId: string, action: 'pause' | 'resume' | 'cancel') => {
    setTransferTasks(prev => prev.map(task => {
      if (task.id === taskId) {
        switch (action) {
          case 'pause':
            return { ...task, status: 'paused' as const }
          case 'resume':
            return { ...task, status: 'transferring' as const }
          case 'cancel':
            return { ...task, status: 'cancelled' as const }
          default:
            return task
        }
      }
      return task
    }))
  }

  // 导航到文件夹
  const navigateToFolder = (folderPath: string) => {
    setCurrentPath(folderPath)
    // 这里可以添加实际的文件夹导航逻辑
  }

  return (
    <div className="h-full flex flex-col">
      {/* 顶部工具栏 */}
      <div className="flex items-center justify-between p-4 bg-slate-900/50 border-b border-slate-800">
        <div className="flex items-center space-x-4">
          <h1 className="text-xl font-bold text-white">文件传输</h1>
          
          {/* 连接选择 */}
          <select
            value={currentConnection.id}
            onChange={(e) => {
              const connection = mockConnections.find(c => c.id === e.target.value)
              if (connection) setCurrentConnection(connection)
            }}
            className="px-3 py-2 bg-slate-800 border border-slate-700 rounded-lg text-white"
          >
            {mockConnections.map(conn => (
              <option key={conn.id} value={conn.id}>{conn.name}</option>
            ))}
          </select>

          {/* 路径导航 */}
          <div className="flex items-center space-x-1 text-sm">
            <button
              onClick={() => navigateToFolder('/')}
              className="p-1 hover:bg-slate-700 rounded"
            >
              <Home className="w-4 h-4 text-slate-400" />
            </button>
            <span className="text-slate-500">/</span>
            <span className="text-slate-300">{currentPath === '/' ? '根目录' : currentPath}</span>
          </div>
        </div>

        <div className="flex items-center space-x-2">
          {/* 搜索 */}
          <div className="relative">
            <Search className="absolute left-3 top-1/2 transform -translate-y-1/2 w-4 h-4 text-slate-400" />
            <input
              type="text"
              placeholder="搜索文件..."
              value={searchQuery}
              onChange={(e) => setSearchQuery(e.target.value)}
              className="pl-10 pr-4 py-2 bg-slate-800 border border-slate-700 rounded-lg text-white placeholder-slate-400 w-64"
            />
          </div>

          {/* 视图切换 */}
          <div className="flex items-center bg-slate-800 rounded-lg p-1">
            <button
              onClick={() => setViewMode('list')}
              className={cn('p-2 rounded text-sm', viewMode === 'list' ? 'bg-slate-600 text-white' : 'text-slate-400')}
            >
              <List className="w-4 h-4" />
            </button>
            <button
              onClick={() => setViewMode('grid')}
              className={cn('p-2 rounded text-sm', viewMode === 'grid' ? 'bg-slate-600 text-white' : 'text-slate-400')}
            >
              <Grid className="w-4 h-4" />
            </button>
          </div>

          {/* 上传按钮 */}
          <button
            onClick={() => fileInputRef.current?.click()}
            className="flex items-center space-x-2 px-4 py-2 bg-blue-600 hover:bg-blue-700 text-white rounded-lg"
          >
            <Upload className="w-4 h-4" />
            <span>上传</span>
          </button>

          {/* 下载按钮 */}
          <button
            onClick={() => handleFileDownload(selectedFiles)}
            disabled={selectedFiles.length === 0}
            className="flex items-center space-x-2 px-4 py-2 bg-green-600 hover:bg-green-700 disabled:bg-slate-700 disabled:text-slate-500 text-white rounded-lg"
          >
            <Download className="w-4 h-4" />
            <span>下载</span>
          </button>

          {/* 刷新 */}
          <button 
            onClick={handleRefresh}
            className="p-2 bg-slate-800 hover:bg-slate-700 rounded-lg text-slate-400"
          >
            <RefreshCw className="w-4 h-4" />
          </button>
        </div>
      </div>

      {/* 数据源信息 */}
      <div className="px-4 py-2 bg-slate-900/30 border-b border-slate-800">
        <div className="flex items-center justify-between text-sm">
          <div className="flex items-center space-x-4">
            <div className="flex items-center space-x-2">
              <Database className="w-4 h-4 text-slate-400" />
              <span className="text-slate-400">数据源:</span>
              <span className={cn(
                "px-2 py-1 rounded text-xs",
                isUsingRealData ? "bg-green-900/50 text-green-400" : "bg-yellow-900/50 text-yellow-400"
              )}>
                {isUsingRealData ? "真实数据" : "模拟数据"}
              </span>
            </div>
            <div className="flex items-center space-x-2">
              <span className="text-slate-400">API状态:</span>
              <span className={cn(
                "px-2 py-1 rounded text-xs",
                isApiConfigured ? "bg-green-900/50 text-green-400" : "bg-red-900/50 text-red-400"
              )}>
                {isApiConfigured ? "已配置" : "未配置"}
              </span>
            </div>
          </div>
          {isLoading && (
            <div className="flex items-center space-x-2 text-slate-400">
              <RefreshCw className="w-4 h-4 animate-spin" />
              <span>加载中...</span>
            </div>
          )}
          {error && (
            <div className="flex items-center space-x-2 text-red-400">
              <AlertTriangle className="w-4 h-4" />
              <span>数据加载失败</span>
            </div>
          )}
        </div>
      </div>

      {/* 主内容区域 */}
      <div className="flex-1 flex">
        {/* 文件列表 */}
        <div className={cn('flex-1 p-4', showTransferPanel ? 'mr-80' : '')}>
          {/* 排序和过滤选项 */}
          <div className="flex items-center justify-between mb-4">
            <div className="flex items-center space-x-4">
              <div className="flex items-center space-x-2">
                <span className="text-sm text-slate-400">排序:</span>
                <select
                  value={sortBy}
                  onChange={(e) => setSortBy(e.target.value as any)}
                  className="px-2 py-1 bg-slate-800 border border-slate-700 rounded text-white text-sm"
                >
                  <option value="name">名称</option>
                  <option value="size">大小</option>
                  <option value="modified">修改时间</option>
                </select>
                <button
                  onClick={() => setSortOrder(sortOrder === 'asc' ? 'desc' : 'asc')}
                  className="p-1 hover:bg-slate-700 rounded"
                >
                  {sortOrder === 'asc' ? <ArrowUp className="w-4 h-4 text-slate-400" /> : <ArrowDown className="w-4 h-4 text-slate-400" />}
                </button>
              </div>

              <div className="flex items-center space-x-2">
                <input
                  type="checkbox"
                  id="showHidden"
                  checked={showHidden}
                  onChange={(e) => setShowHidden(e.target.checked)}
                  className="rounded"
                />
                <label htmlFor="showHidden" className="text-sm text-slate-400">显示隐藏文件</label>
              </div>
            </div>

            <div className="text-sm text-slate-400">
              {filteredAndSortedFiles.length} 个项目 | {selectedFiles.length} 个已选择
            </div>
          </div>

          {/* 文件列表/网格 */}
          {viewMode === 'list' ? (
            <div className="bg-slate-900/50 backdrop-blur-sm border border-slate-800 rounded-xl overflow-hidden">
              <div className="overflow-x-auto">
                <table className="w-full">
                  <thead className="bg-slate-800/50 border-b border-slate-700">
                    <tr>
                      <th className="text-left p-4 w-8">
                        <input
                          type="checkbox"
                          checked={selectedFiles.length === filteredAndSortedFiles.length}
                          onChange={(e) => {
                            if (e.target.checked) {
                              setSelectedFiles(filteredAndSortedFiles.map(f => f.id))
                            } else {
                              setSelectedFiles([])
                            }
                          }}
                          className="rounded"
                        />
                      </th>
                      <th className="text-left p-4 text-sm font-medium text-slate-300">名称</th>
                      <th className="text-left p-4 text-sm font-medium text-slate-300">大小</th>
                      <th className="text-left p-4 text-sm font-medium text-slate-300">修改时间</th>
                      <th className="text-left p-4 text-sm font-medium text-slate-300">所有者</th>
                      <th className="text-left p-4 text-sm font-medium text-slate-300">权限</th>
                      <th className="text-left p-4 text-sm font-medium text-slate-300">操作</th>
                    </tr>
                  </thead>
                  <tbody>
                    {filteredAndSortedFiles.map((file) => {
                      const FileIcon = getFileIcon(file)
                      const isSelected = selectedFiles.includes(file.id)

                      return (
                        <tr
                          key={file.id}
                          className={cn(
                            'border-b border-slate-700 hover:bg-slate-800/30 cursor-pointer',
                            isSelected && 'bg-blue-500/10'
                          )}
                          onClick={() => handleFileSelect(file.id)}
                        >
                          <td className="p-4">
                            <input
                              type="checkbox"
                              checked={isSelected}
                              onChange={(e) => {
                                e.stopPropagation()
                                handleFileSelect(file.id, true)
                              }}
                              className="rounded"
                            />
                          </td>
                          <td className="p-4">
                            <div className="flex items-center space-x-3">
                              <div className="p-1">
                                <FileIcon className="w-5 h-5 text-slate-400" />
                              </div>
                              <div>
                                <p className="font-medium text-white">{file.name}</p>
                                {file.tags.length > 0 && (
                                  <div className="flex space-x-1 mt-1">
                                    {file.tags.slice(0, 2).map((tag, index) => (
                                      <span
                                        key={index}
                                        className="px-1 py-0.5 bg-blue-500/20 text-blue-400 text-xs rounded"
                                      >
                                        {tag}
                                      </span>
                                    ))}
                                  </div>
                                )}
                              </div>
                            </div>
                          </td>
                          <td className="p-4 text-sm text-white">
                            {file.type === 'folder' ? '-' : formatFileSize(file.size)}
                          </td>
                          <td className="p-4 text-sm text-white">{file.modified}</td>
                          <td className="p-4 text-sm text-white">{file.owner}</td>
                          <td className="p-4 text-sm text-white font-mono">{file.permissions}</td>
                          <td className="p-4">
                            <div className="flex items-center space-x-2">
                              {file.isFavorite && <Star className="w-4 h-4 text-yellow-400" />}
                              {file.isShared && <Share2 className="w-4 h-4 text-green-400" />}
                              {file.isReadonly && <Lock className="w-4 h-4 text-red-400" />}
                              <button className="p-1 hover:bg-slate-700 rounded">
                                <MoreVertical className="w-4 h-4 text-slate-400" />
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
          ) : (
            /* 网格视图 */
            <div className="grid grid-cols-2 md:grid-cols-4 lg:grid-cols-6 xl:grid-cols-8 gap-4">
              {filteredAndSortedFiles.map((file) => {
                const FileIcon = getFileIcon(file)
                const isSelected = selectedFiles.includes(file.id)

                return (
                  <div
                    key={file.id}
                    onClick={() => handleFileSelect(file.id)}
                    className={cn(
                      'bg-slate-800/50 border border-slate-700 rounded-lg p-4 cursor-pointer hover:bg-slate-800/70 transition-all',
                      isSelected && 'ring-2 ring-blue-500'
                    )}
                  >
                    <div className="text-center">
                      <div className="p-3 bg-slate-700 rounded-lg inline-block mb-3">
                        <FileIcon className="w-8 h-8 text-slate-300" />
                      </div>
                      <p className="text-sm text-white truncate">{file.name}</p>
                      <p className="text-xs text-slate-400 mt-1">
                        {file.type === 'folder' ? '文件夹' : formatFileSize(file.size)}
                      </p>
                    </div>
                  </div>
                )
              })}
            </div>
          )}
        </div>

        {/* 传输面板 */}
        {showTransferPanel && (
          <div className="w-80 bg-slate-900/50 border-l border-slate-800 flex flex-col">
            <div className="p-4 border-b border-slate-800">
              <div className="flex items-center justify-between">
                <h2 className="text-lg font-semibold text-white">传输任务</h2>
                <button
                  onClick={() => setShowTransferPanel(false)}
                  className="p-1 hover:bg-slate-700 rounded"
                >
                  <X className="w-4 h-4 text-slate-400" />
                </button>
              </div>
            </div>

            <div className="flex-1 overflow-y-auto p-4">
              <div className="space-y-4">
                {transferTasks.map((task) => {
                  const statusInfo = getTransferStatusInfo(task.status)

                  return (
                    <div key={task.id} className="bg-slate-800/50 border border-slate-700 rounded-lg p-4">
                      {/* 任务头部 */}
                      <div className="flex items-center justify-between mb-3">
                        <div className="flex items-center space-x-2">
                          {task.type === 'upload' ? (
                            <Upload className="w-4 h-4 text-blue-400" />
                          ) : (
                            <Download className="w-4 h-4 text-green-400" />
                          )}
                          <span className="text-sm text-white truncate">{task.fileName}</span>
                        </div>
                        <div className="relative">
                          <button className="p-1 hover:bg-slate-700 rounded">
                            <MoreVertical className="w-3 h-3 text-slate-400" />
                          </button>
                        </div>
                      </div>

                      {/* 状态和进度 */}
                      <div className="space-y-2">
                        <div className="flex items-center justify-between text-sm">
                          <div className={cn('flex items-center space-x-1 px-2 py-1 rounded-full text-xs', statusInfo.color)}>
                            <statusInfo.icon className="w-3 h-3" />
                            <span>{statusInfo.text}</span>
                          </div>
                          <span className="text-slate-400">{task.progress}%</span>
                        </div>

                        {task.status === 'transferring' && (
                          <div className="w-full bg-slate-700 rounded-full h-2">
                            <div
                              className="bg-blue-500 h-2 rounded-full transition-all duration-300"
                              style={{ width: `${task.progress}%` }}
                            />
                          </div>
                        )}

                        <div className="flex items-center justify-between text-xs text-slate-400">
                          <span>{formatFileSize(task.fileSize)}</span>
                          {task.status === 'transferring' && (
                            <span>{task.speed.toFixed(1)} MB/s</span>
                          )}
                        </div>

                        <div className="flex items-center justify-between text-xs text-slate-500">
                          <span>{task.source} → {task.destination}</span>
                          <span>{task.estimatedTime}</span>
                        </div>
                      </div>

                      {/* 控制按钮 */}
                      {task.status === 'transferring' && (
                        <div className="flex items-center space-x-2 mt-3">
                          <button
                            onClick={() => controlTransferTask(task.id, 'pause')}
                            className="flex items-center space-x-1 px-2 py-1 bg-yellow-600 hover:bg-yellow-700 text-white rounded text-xs"
                          >
                            <Pause className="w-3 h-3" />
                            <span>暂停</span>
                          </button>
                          <button
                            onClick={() => controlTransferTask(task.id, 'cancel')}
                            className="flex items-center space-x-1 px-2 py-1 bg-red-600 hover:bg-red-700 text-white rounded text-xs"
                          >
                            <X className="w-3 h-3" />
                            <span>取消</span>
                          </button>
                        </div>
                      )}

                      {task.status === 'paused' && (
                        <div className="flex items-center space-x-2 mt-3">
                          <button
                            onClick={() => controlTransferTask(task.id, 'resume')}
                            className="flex items-center space-x-1 px-2 py-1 bg-green-600 hover:bg-green-700 text-white rounded text-xs"
                          >
                            <Play className="w-3 h-3" />
                            <span>继续</span>
                          </button>
                          <button
                            onClick={() => controlTransferTask(task.id, 'cancel')}
                            className="flex items-center space-x-1 px-2 py-1 bg-red-600 hover:bg-red-700 text-white rounded text-xs"
                          >
                            <X className="w-3 h-3" />
                            <span>取消</span>
                          </button>
                        </div>
                      )}
                    </div>
                  )
                })}

                {transferTasks.length === 0 && (
                  <div className="text-center py-12">
                    <div className="p-4 bg-slate-700 rounded-xl inline-block mb-4">
                      <Upload className="w-8 h-8 text-slate-400" />
                    </div>
                    <p className="text-slate-400">暂无传输任务</p>
                  </div>
                )}
              </div>
            </div>

            {/* 连接状态 */}
            <div className="p-4 border-t border-slate-800">
              <div className="space-y-2">
                <div className="flex items-center justify-between text-sm">
                  <span className="text-slate-400">存储空间</span>
                  <span className="text-white">
                    {formatFileSize(currentConnection.usedSpace)} / {formatFileSize(currentConnection.totalSpace)}
                  </span>
                </div>
                <div className="w-full bg-slate-700 rounded-full h-2">
                  <div
                    className="bg-blue-500 h-2 rounded-full"
                    style={{ width: `${(currentConnection.usedSpace / currentConnection.totalSpace) * 100}%` }}
                  />
                </div>
                <div className="flex items-center justify-between text-xs text-slate-500">
                  <span>可用: {formatFileSize(currentConnection.freeSpace)}</span>
                  <div className="flex items-center space-x-1">
                    <Wifi className="w-3 h-3" />
                    <span>已连接</span>
                  </div>
                </div>
              </div>
            </div>
          </div>
        )}
      </div>

      {/* 隐藏的文件输入 */}
      <input
        ref={fileInputRef}
        type="file"
        multiple
        onChange={handleFileUpload}
        className="hidden"
      />
    </div>
  )
}