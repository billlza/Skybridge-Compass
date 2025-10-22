/**
 * API 服务层 - 真实数据接口
 * 替换所有模拟数据，提供与后端API的集成
 */

// API 基础配置
const API_BASE_URL = process.env.NEXT_PUBLIC_API_BASE_URL || 'http://localhost:8080/api'
const API_TIMEOUT = 10000 // 10秒超时

// API 请求配置
interface ApiConfig {
  method?: 'GET' | 'POST' | 'PUT' | 'DELETE' | 'PATCH'
  headers?: Record<string, string>
  body?: any
  timeout?: number
}

// 通用API请求函数
async function apiRequest<T>(endpoint: string, config: ApiConfig = {}): Promise<T> {
  const {
    method = 'GET',
    headers = {},
    body,
    timeout = API_TIMEOUT
  } = config

  const controller = new AbortController()
  const timeoutId = setTimeout(() => controller.abort(), timeout)

  try {
    const response = await fetch(`${API_BASE_URL}${endpoint}`, {
      method,
      headers: {
        'Content-Type': 'application/json',
        ...headers
      },
      body: body ? JSON.stringify(body) : undefined,
      signal: controller.signal
    })

    clearTimeout(timeoutId)

    if (!response.ok) {
      throw new Error(`API请求失败: ${response.status} ${response.statusText}`)
    }

    return await response.json()
  } catch (error) {
    clearTimeout(timeoutId)
    if (error instanceof Error) {
      if (error.name === 'AbortError') {
        throw new Error('请求超时')
      }
      throw error
    }
    throw new Error('未知错误')
  }
}

// 数据类型定义
export interface Device {
  id: string
  name: string
  type: 'mobile' | 'laptop' | 'tablet' | 'desktop' | 'server'
  status: 'online' | 'offline' | 'connecting' | 'error'
  ip: string
  os: string
  lastSeen: string
  cpu: number
  memory: number
  disk: number
  uptime: string
}

export interface SystemMetrics {
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

export interface Alert {
  id: string
  type: 'critical' | 'warning' | 'info'
  title: string
  message: string
  timestamp: string
  resolved: boolean
}

export interface FileItem {
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
  children?: FileItem[]
}

export interface RemoteConnection {
  id: string
  name: string
  type: 'rdp' | 'vnc' | 'ssh'
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

export interface UserProfile {
  id: string
  username: string
  email: string
  fullName: string
  avatar: string
  phone: string
  department: string
  position: string
  location: string
  timezone: string
  language: string
  joinDate: string
  lastLogin: string
  status: 'online' | 'offline' | 'away'
  bio: string
  website: string
  socialLinks: {
    github?: string
    linkedin?: string
  }
}

// API 服务类
export class ApiService {
  // 设备管理 API
  static async getDevices(): Promise<Device[]> {
    return apiRequest<Device[]>('/devices')
  }

  static async getDevice(id: string): Promise<Device> {
    return apiRequest<Device>(`/devices/${id}`)
  }

  static async updateDevice(id: string, data: Partial<Device>): Promise<Device> {
    return apiRequest<Device>(`/devices/${id}`, {
      method: 'PUT',
      body: data
    })
  }

  static async deleteDevice(id: string): Promise<void> {
    return apiRequest<void>(`/devices/${id}`, {
      method: 'DELETE'
    })
  }

  // 系统监控 API
  static async getSystemMetrics(): Promise<SystemMetrics> {
    return apiRequest<SystemMetrics>('/system/metrics')
  }

  static async getAlerts(): Promise<Alert[]> {
    return apiRequest<Alert[]>('/system/alerts')
  }

  static async resolveAlert(id: string): Promise<void> {
    return apiRequest<void>(`/system/alerts/${id}/resolve`, {
      method: 'POST'
    })
  }

  // 文件管理 API
  static async getFiles(path: string = '/'): Promise<FileItem[]> {
    return apiRequest<FileItem[]>(`/files?path=${encodeURIComponent(path)}`)
  }

  static async uploadFile(file: File, path: string): Promise<FileItem> {
    const formData = new FormData()
    formData.append('file', file)
    formData.append('path', path)

    const response = await fetch(`${API_BASE_URL}/files/upload`, {
      method: 'POST',
      body: formData
    })

    if (!response.ok) {
      throw new Error(`文件上传失败: ${response.status}`)
    }

    return response.json()
  }

  static async downloadFile(id: string): Promise<Blob> {
    const response = await fetch(`${API_BASE_URL}/files/${id}/download`)
    
    if (!response.ok) {
      throw new Error(`文件下载失败: ${response.status}`)
    }

    return response.blob()
  }

  static async deleteFile(id: string): Promise<void> {
    return apiRequest<void>(`/files/${id}`, {
      method: 'DELETE'
    })
  }

  // 远程连接 API
  static async getRemoteConnections(): Promise<RemoteConnection[]> {
    return apiRequest<RemoteConnection[]>('/remote/connections')
  }

  static async createConnection(connection: Omit<RemoteConnection, 'id'>): Promise<RemoteConnection> {
    return apiRequest<RemoteConnection>('/remote/connections', {
      method: 'POST',
      body: connection
    })
  }

  static async connectToRemote(id: string): Promise<void> {
    return apiRequest<void>(`/remote/connections/${id}/connect`, {
      method: 'POST'
    })
  }

  static async disconnectFromRemote(id: string): Promise<void> {
    return apiRequest<void>(`/remote/connections/${id}/disconnect`, {
      method: 'POST'
    })
  }

  // 用户管理 API
  static async getUserProfile(): Promise<UserProfile> {
    return apiRequest<UserProfile>('/user/profile')
  }

  static async updateUserProfile(data: Partial<UserProfile>): Promise<UserProfile> {
    return apiRequest<UserProfile>('/user/profile', {
      method: 'PUT',
      body: data
    })
  }

  static async getUserSettings(): Promise<any> {
    return apiRequest<any>('/user/settings')
  }

  static async updateUserSettings(settings: any): Promise<any> {
    return apiRequest<any>('/user/settings', {
      method: 'PUT',
      body: settings
    })
  }

  // 统计数据 API
  static async getDashboardStats(): Promise<any> {
    return apiRequest<any>('/dashboard/stats')
  }

  static async getActivities(): Promise<any[]> {
    return apiRequest<any[]>('/dashboard/activities')
  }

  // 实时数据订阅 (WebSocket)
  static createWebSocketConnection(endpoint: string): WebSocket {
    const wsUrl = API_BASE_URL.replace('http', 'ws') + endpoint
    return new WebSocket(wsUrl)
  }

  // 健康检查
  static async healthCheck(): Promise<{ status: string; timestamp: string }> {
    return apiRequest<{ status: string; timestamp: string }>('/health')
  }
}

// 环境配置检查
export function checkApiConfiguration(): {
  isConfigured: boolean
  baseUrl: string
  issues: string[]
} {
  const issues: string[] = []
  
  if (!process.env.NEXT_PUBLIC_API_BASE_URL) {
    issues.push('未设置 NEXT_PUBLIC_API_BASE_URL 环境变量')
  }

  return {
    isConfigured: issues.length === 0,
    baseUrl: API_BASE_URL,
    issues
  }
}

// 错误处理工具
export class ApiError extends Error {
  constructor(
    message: string,
    public status?: number,
    public code?: string
  ) {
    super(message)
    this.name = 'ApiError'
  }
}

// 重试机制
export async function withRetry<T>(
  fn: () => Promise<T>,
  maxRetries: number = 3,
  delay: number = 1000
): Promise<T> {
  let lastError: Error

  for (let i = 0; i <= maxRetries; i++) {
    try {
      return await fn()
    } catch (error) {
      lastError = error as Error
      
      if (i === maxRetries) {
        break
      }

      // 指数退避
      await new Promise(resolve => setTimeout(resolve, delay * Math.pow(2, i)))
    }
  }

  throw lastError!
}