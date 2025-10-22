/**
 * 数据适配器 - 模拟数据与真实数据的无缝切换
 * 根据环境配置自动选择数据源
 */

import { ApiService, checkApiConfiguration } from './api'
import type { 
  Device, 
  SystemMetrics, 
  Alert, 
  FileItem, 
  RemoteConnection, 
  UserProfile 
} from './api'

// 环境配置
const ENABLE_REAL_DATA = process.env.NEXT_PUBLIC_ENABLE_REAL_DATA === 'true'
const ENABLE_MOCK_FALLBACK = process.env.NEXT_PUBLIC_ENABLE_MOCK_FALLBACK === 'true'

// 模拟数据生成器 (保留原有逻辑)
class MockDataGenerator {
  // 生成模拟设备数据
  static generateDevices(): Device[] {
    return [
      {
        id: '1',
        name: 'Xiaomi 14 Ultra',
        type: 'mobile',
        status: 'online',
        ip: '192.168.1.100',
        os: 'Android 14',
        lastSeen: '刚刚',
        cpu: Math.random() * 80 + 10,
        memory: Math.random() * 80 + 10,
        disk: Math.random() * 80 + 10,
        uptime: '2天 14小时'
      },
      {
        id: '2',
        name: 'MacBook Pro M3',
        type: 'laptop',
        status: 'online',
        ip: '192.168.1.101',
        os: 'macOS Sonoma',
        lastSeen: '1分钟前',
        cpu: Math.random() * 60 + 15,
        memory: Math.random() * 70 + 20,
        disk: Math.random() * 50 + 30,
        uptime: '5天 8小时'
      },
      {
        id: '3',
        name: 'iPad Pro',
        type: 'tablet',
        status: 'offline',
        ip: '192.168.1.102',
        os: 'iPadOS 17',
        lastSeen: '30分钟前',
        cpu: 0,
        memory: 0,
        disk: 0,
        uptime: '-'
      },
      {
        id: '4',
        name: 'Windows Desktop',
        type: 'desktop',
        status: 'connecting',
        ip: '192.168.1.103',
        os: 'Windows 11',
        lastSeen: '正在连接...',
        cpu: 0,
        memory: 0,
        disk: 0,
        uptime: '-'
      },
      {
        id: '5',
        name: 'Ubuntu Server',
        type: 'server',
        status: 'error',
        ip: '192.168.1.104',
        os: 'Ubuntu 22.04',
        lastSeen: '1小时前',
        cpu: 0,
        memory: 0,
        disk: 0,
        uptime: '-'
      }
    ]
  }

  // 生成模拟系统指标
  static generateSystemMetrics(): SystemMetrics {
    return {
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
    }
  }

  // 生成模拟告警数据
  static generateAlerts(): Alert[] {
    return [
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
      }
    ]
  }

  // 生成模拟用户资料
  static generateUserProfile(): UserProfile {
    return {
      id: '1',
      username: 'admin',
      email: 'admin@skybridge.com',
      fullName: '系统管理员',
      avatar: '/api/placeholder/100/100',
      phone: '+86 138 0013 8000',
      department: 'IT部门',
      position: '系统管理员',
      location: '北京, 中国',
      timezone: 'Asia/Shanghai',
      language: 'zh-CN',
      joinDate: '2023-01-15',
      lastLogin: new Date().toLocaleString('zh-CN'),
      status: 'online',
      bio: '负责SkyBridge Compass系统的运维和管理工作',
      website: 'https://skybridge.com',
      socialLinks: {
        github: 'https://github.com/skybridge',
        linkedin: 'https://linkedin.com/in/skybridge'
      }
    }
  }
}

// 数据适配器类
export class DataAdapter {
  private static isApiAvailable: boolean | null = null

  // 检查API可用性
  private static async checkApiAvailability(): Promise<boolean> {
    if (!ENABLE_REAL_DATA) {
      return false
    }

    if (this.isApiAvailable !== null) {
      return this.isApiAvailable
    }

    try {
      const config = checkApiConfiguration()
      if (!config.isConfigured) {
        console.warn('API配置不完整:', config.issues)
        this.isApiAvailable = false
        return false
      }

      // 尝试健康检查
      await ApiService.healthCheck()
      this.isApiAvailable = true
      return true
    } catch (error) {
      console.warn('API不可用，将使用模拟数据:', error)
      this.isApiAvailable = false
      return false
    }
  }

  // 获取设备数据
  static async getDevices(): Promise<Device[]> {
    const isApiAvailable = await this.checkApiAvailability()
    
    if (isApiAvailable) {
      try {
        return await ApiService.getDevices()
      } catch (error) {
        console.error('获取真实设备数据失败:', error)
        if (!ENABLE_MOCK_FALLBACK) {
          throw error
        }
      }
    }

    // 返回模拟数据
    return MockDataGenerator.generateDevices()
  }

  // 获取系统指标
  static async getSystemMetrics(): Promise<SystemMetrics> {
    const isApiAvailable = await this.checkApiAvailability()
    
    if (isApiAvailable) {
      try {
        return await ApiService.getSystemMetrics()
      } catch (error) {
        console.error('获取真实系统指标失败:', error)
        if (!ENABLE_MOCK_FALLBACK) {
          throw error
        }
      }
    }

    // 返回模拟数据
    return MockDataGenerator.generateSystemMetrics()
  }

  // 获取告警数据
  static async getAlerts(): Promise<Alert[]> {
    const isApiAvailable = await this.checkApiAvailability()
    
    if (isApiAvailable) {
      try {
        return await ApiService.getAlerts()
      } catch (error) {
        console.error('获取真实告警数据失败:', error)
        if (!ENABLE_MOCK_FALLBACK) {
          throw error
        }
      }
    }

    // 返回模拟数据
    return MockDataGenerator.generateAlerts()
  }

  // 获取用户资料
  static async getUserProfile(): Promise<UserProfile> {
    const isApiAvailable = await this.checkApiAvailability()
    
    if (isApiAvailable) {
      try {
        return await ApiService.getUserProfile()
      } catch (error) {
        console.error('获取真实用户资料失败:', error)
        if (!ENABLE_MOCK_FALLBACK) {
          throw error
        }
      }
    }

    // 返回模拟数据
    return MockDataGenerator.generateUserProfile()
  }

  // 获取文件列表
  static async getFiles(path: string = '/'): Promise<FileItem[]> {
    const isApiAvailable = await this.checkApiAvailability()
    
    if (isApiAvailable) {
      try {
        return await ApiService.getFiles(path)
      } catch (error) {
        console.error('获取真实文件数据失败:', error)
        if (!ENABLE_MOCK_FALLBACK) {
          throw error
        }
      }
    }

    // 返回模拟文件数据
    return [
      {
        id: '1',
        name: '文档',
        type: 'folder',
        size: 0,
        modified: new Date().toLocaleString('zh-CN'),
        created: new Date(Date.now() - 86400000).toLocaleString('zh-CN'),
        owner: '当前用户',
        permissions: 'rwxr-xr-x',
        path: '/文档',
        isHidden: false,
        isReadonly: false,
        isShared: true,
        isFavorite: true,
        tags: ['工作', '重要']
      },
      {
        id: '2',
        name: 'config.json',
        type: 'file',
        size: 1024,
        modified: new Date().toLocaleString('zh-CN'),
        created: new Date(Date.now() - 172800000).toLocaleString('zh-CN'),
        owner: '当前用户',
        permissions: 'rw-r--r--',
        path: '/config.json',
        extension: 'json',
        mimeType: 'application/json',
        isHidden: false,
        isReadonly: false,
        isShared: false,
        isFavorite: false,
        tags: ['配置']
      }
    ]
  }

  // 获取远程连接
  static async getRemoteConnections(): Promise<RemoteConnection[]> {
    const isApiAvailable = await this.checkApiAvailability()
    
    if (isApiAvailable) {
      try {
        return await ApiService.getRemoteConnections()
      } catch (error) {
        console.error('获取真实远程连接数据失败:', error)
        if (!ENABLE_MOCK_FALLBACK) {
          throw error
        }
      }
    }

    // 返回模拟远程连接数据
    return [
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
        lastConnected: new Date().toLocaleString('zh-CN'),
        sessionDuration: '2小时 15分钟',
        isRecording: false,
        isFullscreen: false,
        audioEnabled: true,
        clipboardSync: true,
        fileTransferEnabled: true
      }
    ]
  }

  // 重置API可用性检查
  static resetApiAvailability(): void {
    this.isApiAvailable = null
  }

  // 获取数据源信息
  static getDataSourceInfo(): {
    isUsingRealData: boolean
    isApiConfigured: boolean
    fallbackEnabled: boolean
  } {
    const config = checkApiConfiguration()
    
    // 如果 isApiAvailable 还未初始化，先进行同步检查
    if (DataAdapter.isApiAvailable === null) {
      // 同步检查基本配置
      if (!ENABLE_REAL_DATA || !config.isConfigured) {
        DataAdapter.isApiAvailable = false
      } else {
        // 如果配置正确但还未进行健康检查，暂时设为 false
        DataAdapter.isApiAvailable = false
      }
    }
    
    return {
      isUsingRealData: ENABLE_REAL_DATA && DataAdapter.isApiAvailable === true,
      isApiConfigured: config.isConfigured,
      fallbackEnabled: ENABLE_MOCK_FALLBACK
    }
  }
}

// 导出便捷函数
export const {
  getDevices,
  getSystemMetrics,
  getAlerts,
  getUserProfile,
  getFiles,
  getRemoteConnections
} = DataAdapter

// 单独导出 getDataSourceInfo 以保持 this 上下文
export const getDataSourceInfo = () => DataAdapter.getDataSourceInfo()