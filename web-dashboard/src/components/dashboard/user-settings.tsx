'use client'

import React, { useState } from 'react'
import { cn } from '@/lib/utils'
import {
  User,
  Settings,
  Palette,
  Shield,
  Bell,
  Globe,
  Monitor,
  Smartphone,
  Wifi,
  Database,
  Key,
  Lock,
  Unlock,
  Eye,
  EyeOff,
  Save,
  RefreshCw,
  Upload,
  Download,
  Trash2,
  Edit,
  Check,
  X,
  AlertTriangle,
  Info,
  HelpCircle,
  ExternalLink,
  Moon,
  Sun,
  Laptop,
  Volume2,
  VolumeX,
  Camera,
  Mic,
  MicOff,
  Languages,
  Clock,
  Calendar,
  MapPin,
  Mail,
  Phone,
  Building,
  CreditCard,
  FileText,
  History,
  Activity,
  BarChart3,
  PieChart,
  TrendingUp,
  Zap,
  Cpu,
  HardDrive,
  MemoryStick,
  Network,
  Server,
  Cloud,
  Folder,
  Image,
  Video,
  Music,
  Archive,
  Code,
  Terminal,
  Chrome
} from 'lucide-react'

// 用户信息接口
interface UserProfile {
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
  status: 'online' | 'offline' | 'away' | 'busy'
  bio: string
  website: string
  socialLinks: {
    github?: string
    linkedin?: string
    twitter?: string
  }
}

// 系统设置接口
interface SystemSettings {
  theme: 'light' | 'dark' | 'auto'
  language: string
  timezone: string
  dateFormat: string
  timeFormat: '12h' | '24h'
  currency: string
  notifications: {
    email: boolean
    push: boolean
    desktop: boolean
    sound: boolean
    vibration: boolean
  }
  privacy: {
    profileVisibility: 'public' | 'private' | 'friends'
    activityTracking: boolean
    dataCollection: boolean
    analytics: boolean
  }
  performance: {
    animations: boolean
    autoSave: boolean
    cacheSize: number
    backgroundSync: boolean
  }
  security: {
    twoFactorAuth: boolean
    sessionTimeout: number
    passwordExpiry: number
    loginNotifications: boolean
  }
}

// 应用设置接口
interface AppSettings {
  dashboard: {
    defaultView: 'grid' | 'list'
    refreshInterval: number
    showWelcome: boolean
    compactMode: boolean
  }
  remoteDesktop: {
    quality: 'low' | 'medium' | 'high' | 'ultra'
    compression: boolean
    fullscreen: boolean
    soundEnabled: boolean
    clipboardSync: boolean
  }
  fileTransfer: {
    defaultLocation: string
    autoResume: boolean
    parallelTransfers: number
    compressionLevel: number
  }
  monitoring: {
    updateInterval: number
    alertThresholds: {
      cpu: number
      memory: number
      disk: number
      network: number
    }
    retentionPeriod: number
  }
}

// 模拟用户数据
const mockUserProfile: UserProfile = {
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
  lastLogin: '2024-01-20 14:30:25',
  status: 'online',
  bio: '负责SkyBridge Compass系统的运维和管理工作',
  website: 'https://skybridge.com',
  socialLinks: {
    github: 'https://github.com/skybridge',
    linkedin: 'https://linkedin.com/in/skybridge'
  }
}

// 模拟系统设置
const mockSystemSettings: SystemSettings = {
  theme: 'dark',
  language: 'zh-CN',
  timezone: 'Asia/Shanghai',
  dateFormat: 'YYYY-MM-DD',
  timeFormat: '24h',
  currency: 'CNY',
  notifications: {
    email: true,
    push: true,
    desktop: true,
    sound: true,
    vibration: false
  },
  privacy: {
    profileVisibility: 'private',
    activityTracking: true,
    dataCollection: false,
    analytics: true
  },
  performance: {
    animations: true,
    autoSave: true,
    cacheSize: 100,
    backgroundSync: true
  },
  security: {
    twoFactorAuth: true,
    sessionTimeout: 30,
    passwordExpiry: 90,
    loginNotifications: true
  }
}

// 模拟应用设置
const mockAppSettings: AppSettings = {
  dashboard: {
    defaultView: 'grid',
    refreshInterval: 30,
    showWelcome: true,
    compactMode: false
  },
  remoteDesktop: {
    quality: 'high',
    compression: true,
    fullscreen: false,
    soundEnabled: true,
    clipboardSync: true
  },
  fileTransfer: {
    defaultLocation: '/home/admin/Downloads',
    autoResume: true,
    parallelTransfers: 3,
    compressionLevel: 6
  },
  monitoring: {
    updateInterval: 5,
    alertThresholds: {
      cpu: 80,
      memory: 85,
      disk: 90,
      network: 95
    },
    retentionPeriod: 30
  }
}

// 设置选项卡
type SettingsTab = 'profile' | 'system' | 'app' | 'security' | 'about'

export function UserSettings() {
  const [activeTab, setActiveTab] = useState<SettingsTab>('profile')
  const [userProfile, setUserProfile] = useState<UserProfile>(mockUserProfile)
  const [systemSettings, setSystemSettings] = useState<SystemSettings>(mockSystemSettings)
  const [appSettings, setAppSettings] = useState<AppSettings>(mockAppSettings)
  const [isEditing, setIsEditing] = useState(false)
  const [showPassword, setShowPassword] = useState(false)
  const [hasUnsavedChanges, setHasUnsavedChanges] = useState(false)

  // 保存设置
  const handleSaveSettings = () => {
    // 这里可以添加实际的保存逻辑
    setHasUnsavedChanges(false)
    setIsEditing(false)
    // 显示保存成功提示
  }

  // 重置设置
  const handleResetSettings = () => {
    setUserProfile(mockUserProfile)
    setSystemSettings(mockSystemSettings)
    setAppSettings(mockAppSettings)
    setHasUnsavedChanges(false)
    setIsEditing(false)
  }

  // 更新用户资料
  const updateUserProfile = (field: keyof UserProfile, value: any) => {
    setUserProfile(prev => ({ ...prev, [field]: value }))
    setHasUnsavedChanges(true)
  }

  // 更新系统设置
  const updateSystemSettings = (field: keyof SystemSettings, value: any) => {
    setSystemSettings(prev => ({ ...prev, [field]: value }))
    setHasUnsavedChanges(true)
  }

  // 更新应用设置
  const updateAppSettings = (field: keyof AppSettings, value: any) => {
    setAppSettings(prev => ({ ...prev, [field]: value }))
    setHasUnsavedChanges(true)
  }

  // 选项卡配置
  const tabs = [
    { id: 'profile', label: '个人资料', icon: User },
    { id: 'system', label: '系统设置', icon: Settings },
    { id: 'app', label: '应用设置', icon: Monitor },
    { id: 'security', label: '安全设置', icon: Shield },
    { id: 'about', label: '关于', icon: Info }
  ]

  return (
    <div className="h-full flex">
      {/* 侧边栏 */}
      <div className="w-64 bg-slate-900/50 border-r border-slate-800 flex flex-col">
        <div className="p-4 border-b border-slate-800">
          <h1 className="text-xl font-bold text-white">用户设置</h1>
        </div>

        <div className="flex-1 p-4">
          <nav className="space-y-2">
            {tabs.map((tab) => {
              const Icon = tab.icon
              return (
                <button
                  key={tab.id}
                  onClick={() => setActiveTab(tab.id as SettingsTab)}
                  className={cn(
                    'w-full flex items-center space-x-3 px-3 py-2 rounded-lg text-left transition-colors',
                    activeTab === tab.id
                      ? 'bg-blue-600 text-white'
                      : 'text-slate-300 hover:bg-slate-800/50'
                  )}
                >
                  <Icon className="w-5 h-5" />
                  <span>{tab.label}</span>
                </button>
              )
            })}
          </nav>
        </div>

        {/* 保存按钮 */}
        {hasUnsavedChanges && (
          <div className="p-4 border-t border-slate-800">
            <div className="flex space-x-2">
              <button
                onClick={handleSaveSettings}
                className="flex-1 flex items-center justify-center space-x-2 px-4 py-2 bg-green-600 hover:bg-green-700 text-white rounded-lg"
              >
                <Save className="w-4 h-4" />
                <span>保存</span>
              </button>
              <button
                onClick={handleResetSettings}
                className="px-4 py-2 bg-slate-700 hover:bg-slate-600 text-white rounded-lg"
              >
                <RefreshCw className="w-4 h-4" />
              </button>
            </div>
          </div>
        )}
      </div>

      {/* 主内容区域 */}
      <div className="flex-1 overflow-y-auto">
        {/* 个人资料 */}
        {activeTab === 'profile' && (
          <div className="p-6">
            <div className="max-w-4xl mx-auto">
              <div className="flex items-center justify-between mb-6">
                <h2 className="text-2xl font-bold text-white">个人资料</h2>
                <button
                  onClick={() => setIsEditing(!isEditing)}
                  className="flex items-center space-x-2 px-4 py-2 bg-blue-600 hover:bg-blue-700 text-white rounded-lg"
                >
                  <Edit className="w-4 h-4" />
                  <span>{isEditing ? '取消编辑' : '编辑资料'}</span>
                </button>
              </div>

              <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
                {/* 头像和基本信息 */}
                <div className="lg:col-span-1">
                  <div className="bg-slate-900/50 border border-slate-800 rounded-xl p-6">
                    <div className="text-center">
                      <div className="relative inline-block">
                        <div className="w-24 h-24 bg-slate-700 rounded-full flex items-center justify-center mb-4">
                          <User className="w-12 h-12 text-slate-400" />
                        </div>
                        {isEditing && (
                          <button className="absolute bottom-0 right-0 p-2 bg-blue-600 rounded-full text-white">
                            <Camera className="w-4 h-4" />
                          </button>
                        )}
                      </div>
                      <h3 className="text-xl font-semibold text-white mb-1">{userProfile.fullName}</h3>
                      <p className="text-slate-400 mb-2">@{userProfile.username}</p>
                      <div className={cn(
                        'inline-flex items-center space-x-1 px-2 py-1 rounded-full text-xs',
                        userProfile.status === 'online' ? 'bg-green-500/20 text-green-400' :
                        userProfile.status === 'away' ? 'bg-yellow-500/20 text-yellow-400' :
                        userProfile.status === 'busy' ? 'bg-red-500/20 text-red-400' :
                        'bg-slate-500/20 text-slate-400'
                      )}>
                        <div className={cn(
                          'w-2 h-2 rounded-full',
                          userProfile.status === 'online' ? 'bg-green-400' :
                          userProfile.status === 'away' ? 'bg-yellow-400' :
                          userProfile.status === 'busy' ? 'bg-red-400' :
                          'bg-slate-400'
                        )} />
                        <span>{
                          userProfile.status === 'online' ? '在线' :
                          userProfile.status === 'away' ? '离开' :
                          userProfile.status === 'busy' ? '忙碌' : '离线'
                        }</span>
                      </div>
                    </div>

                    <div className="mt-6 space-y-3">
                      <div className="flex items-center space-x-3 text-sm">
                        <Building className="w-4 h-4 text-slate-400" />
                        <span className="text-slate-300">{userProfile.department}</span>
                      </div>
                      <div className="flex items-center space-x-3 text-sm">
                        <MapPin className="w-4 h-4 text-slate-400" />
                        <span className="text-slate-300">{userProfile.location}</span>
                      </div>
                      <div className="flex items-center space-x-3 text-sm">
                        <Calendar className="w-4 h-4 text-slate-400" />
                        <span className="text-slate-300">加入于 {userProfile.joinDate}</span>
                      </div>
                    </div>
                  </div>
                </div>

                {/* 详细信息 */}
                <div className="lg:col-span-2">
                  <div className="bg-slate-900/50 border border-slate-800 rounded-xl p-6">
                    <h4 className="text-lg font-semibold text-white mb-4">基本信息</h4>
                    
                    <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
                      <div>
                        <label className="block text-sm font-medium text-slate-300 mb-2">全名</label>
                        <input
                          type="text"
                          value={userProfile.fullName}
                          onChange={(e) => updateUserProfile('fullName', e.target.value)}
                          disabled={!isEditing}
                          className="w-full px-3 py-2 bg-slate-800 border border-slate-700 rounded-lg text-white disabled:opacity-50"
                        />
                      </div>

                      <div>
                        <label className="block text-sm font-medium text-slate-300 mb-2">用户名</label>
                        <input
                          type="text"
                          value={userProfile.username}
                          onChange={(e) => updateUserProfile('username', e.target.value)}
                          disabled={!isEditing}
                          className="w-full px-3 py-2 bg-slate-800 border border-slate-700 rounded-lg text-white disabled:opacity-50"
                        />
                      </div>

                      <div>
                        <label className="block text-sm font-medium text-slate-300 mb-2">邮箱</label>
                        <input
                          type="email"
                          value={userProfile.email}
                          onChange={(e) => updateUserProfile('email', e.target.value)}
                          disabled={!isEditing}
                          className="w-full px-3 py-2 bg-slate-800 border border-slate-700 rounded-lg text-white disabled:opacity-50"
                        />
                      </div>

                      <div>
                        <label className="block text-sm font-medium text-slate-300 mb-2">电话</label>
                        <input
                          type="tel"
                          value={userProfile.phone}
                          onChange={(e) => updateUserProfile('phone', e.target.value)}
                          disabled={!isEditing}
                          className="w-full px-3 py-2 bg-slate-800 border border-slate-700 rounded-lg text-white disabled:opacity-50"
                        />
                      </div>

                      <div>
                        <label className="block text-sm font-medium text-slate-300 mb-2">部门</label>
                        <input
                          type="text"
                          value={userProfile.department}
                          onChange={(e) => updateUserProfile('department', e.target.value)}
                          disabled={!isEditing}
                          className="w-full px-3 py-2 bg-slate-800 border border-slate-700 rounded-lg text-white disabled:opacity-50"
                        />
                      </div>

                      <div>
                        <label className="block text-sm font-medium text-slate-300 mb-2">职位</label>
                        <input
                          type="text"
                          value={userProfile.position}
                          onChange={(e) => updateUserProfile('position', e.target.value)}
                          disabled={!isEditing}
                          className="w-full px-3 py-2 bg-slate-800 border border-slate-700 rounded-lg text-white disabled:opacity-50"
                        />
                      </div>
                    </div>

                    <div className="mt-4">
                      <label className="block text-sm font-medium text-slate-300 mb-2">个人简介</label>
                      <textarea
                        value={userProfile.bio}
                        onChange={(e) => updateUserProfile('bio', e.target.value)}
                        disabled={!isEditing}
                        rows={3}
                        className="w-full px-3 py-2 bg-slate-800 border border-slate-700 rounded-lg text-white disabled:opacity-50"
                      />
                    </div>

                    <div className="mt-4">
                      <label className="block text-sm font-medium text-slate-300 mb-2">个人网站</label>
                      <input
                        type="url"
                        value={userProfile.website}
                        onChange={(e) => updateUserProfile('website', e.target.value)}
                        disabled={!isEditing}
                        className="w-full px-3 py-2 bg-slate-800 border border-slate-700 rounded-lg text-white disabled:opacity-50"
                      />
                    </div>
                  </div>
                </div>
              </div>
            </div>
          </div>
        )}

        {/* 系统设置 */}
        {activeTab === 'system' && (
          <div className="p-6">
            <div className="max-w-4xl mx-auto">
              <h2 className="text-2xl font-bold text-white mb-6">系统设置</h2>

              <div className="space-y-6">
                {/* 外观设置 */}
                <div className="bg-slate-900/50 border border-slate-800 rounded-xl p-6">
                  <h3 className="text-lg font-semibold text-white mb-4 flex items-center space-x-2">
                    <Palette className="w-5 h-5" />
                    <span>外观设置</span>
                  </h3>

                  <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
                    <div>
                      <label className="block text-sm font-medium text-slate-300 mb-2">主题</label>
                      <select
                        value={systemSettings.theme}
                        onChange={(e) => updateSystemSettings('theme', e.target.value)}
                        className="w-full px-3 py-2 bg-slate-800 border border-slate-700 rounded-lg text-white"
                      >
                        <option value="light">浅色</option>
                        <option value="dark">深色</option>
                        <option value="auto">跟随系统</option>
                      </select>
                    </div>

                    <div>
                      <label className="block text-sm font-medium text-slate-300 mb-2">语言</label>
                      <select
                        value={systemSettings.language}
                        onChange={(e) => updateSystemSettings('language', e.target.value)}
                        className="w-full px-3 py-2 bg-slate-800 border border-slate-700 rounded-lg text-white"
                      >
                        <option value="zh-CN">简体中文</option>
                        <option value="zh-TW">繁体中文</option>
                        <option value="en-US">English</option>
                        <option value="ja-JP">日本語</option>
                      </select>
                    </div>
                  </div>
                </div>

                {/* 通知设置 */}
                <div className="bg-slate-900/50 border border-slate-800 rounded-xl p-6">
                  <h3 className="text-lg font-semibold text-white mb-4 flex items-center space-x-2">
                    <Bell className="w-5 h-5" />
                    <span>通知设置</span>
                  </h3>

                  <div className="space-y-4">
                    {Object.entries(systemSettings.notifications).map(([key, value]) => (
                      <div key={key} className="flex items-center justify-between">
                        <div className="flex items-center space-x-3">
                          {key === 'email' && <Mail className="w-4 h-4 text-slate-400" />}
                          {key === 'push' && <Smartphone className="w-4 h-4 text-slate-400" />}
                          {key === 'desktop' && <Monitor className="w-4 h-4 text-slate-400" />}
                          {key === 'sound' && <Volume2 className="w-4 h-4 text-slate-400" />}
                          {key === 'vibration' && <Smartphone className="w-4 h-4 text-slate-400" />}
                          <span className="text-slate-300">
                            {key === 'email' ? '邮件通知' :
                             key === 'push' ? '推送通知' :
                             key === 'desktop' ? '桌面通知' :
                             key === 'sound' ? '声音提醒' :
                             key === 'vibration' ? '震动提醒' : key}
                          </span>
                        </div>
                        <label className="relative inline-flex items-center cursor-pointer">
                          <input
                            type="checkbox"
                            checked={value}
                            onChange={(e) => updateSystemSettings('notifications', {
                              ...systemSettings.notifications,
                              [key]: e.target.checked
                            })}
                            className="sr-only peer"
                          />
                          <div className="w-11 h-6 bg-slate-700 peer-focus:outline-none rounded-full peer peer-checked:after:translate-x-full peer-checked:after:border-white after:content-[''] after:absolute after:top-[2px] after:left-[2px] after:bg-white after:rounded-full after:h-5 after:w-5 after:transition-all peer-checked:bg-blue-600"></div>
                        </label>
                      </div>
                    ))}
                  </div>
                </div>

                {/* 隐私设置 */}
                <div className="bg-slate-900/50 border border-slate-800 rounded-xl p-6">
                  <h3 className="text-lg font-semibold text-white mb-4 flex items-center space-x-2">
                    <Shield className="w-5 h-5" />
                    <span>隐私设置</span>
                  </h3>

                  <div className="space-y-4">
                    <div>
                      <label className="block text-sm font-medium text-slate-300 mb-2">资料可见性</label>
                      <select
                        value={systemSettings.privacy.profileVisibility}
                        onChange={(e) => updateSystemSettings('privacy', {
                          ...systemSettings.privacy,
                          profileVisibility: e.target.value
                        })}
                        className="w-full px-3 py-2 bg-slate-800 border border-slate-700 rounded-lg text-white"
                      >
                        <option value="public">公开</option>
                        <option value="private">私有</option>
                        <option value="friends">仅好友</option>
                      </select>
                    </div>

                    {Object.entries(systemSettings.privacy).filter(([key]) => key !== 'profileVisibility').map(([key, value]) => (
                      <div key={key} className="flex items-center justify-between">
                        <span className="text-slate-300">
                          {key === 'activityTracking' ? '活动跟踪' :
                           key === 'dataCollection' ? '数据收集' :
                           key === 'analytics' ? '分析统计' : key}
                        </span>
                        <label className="relative inline-flex items-center cursor-pointer">
                          <input
                            type="checkbox"
                            checked={value as boolean}
                            onChange={(e) => updateSystemSettings('privacy', {
                              ...systemSettings.privacy,
                              [key]: e.target.checked
                            })}
                            className="sr-only peer"
                          />
                          <div className="w-11 h-6 bg-slate-700 peer-focus:outline-none rounded-full peer peer-checked:after:translate-x-full peer-checked:after:border-white after:content-[''] after:absolute after:top-[2px] after:left-[2px] after:bg-white after:rounded-full after:h-5 after:w-5 after:transition-all peer-checked:bg-blue-600"></div>
                        </label>
                      </div>
                    ))}
                  </div>
                </div>
              </div>
            </div>
          </div>
        )}

        {/* 应用设置 */}
        {activeTab === 'app' && (
          <div className="p-6">
            <div className="max-w-4xl mx-auto">
              <h2 className="text-2xl font-bold text-white mb-6">应用设置</h2>

              <div className="space-y-6">
                {/* 仪表板设置 */}
                <div className="bg-slate-900/50 border border-slate-800 rounded-xl p-6">
                  <h3 className="text-lg font-semibold text-white mb-4 flex items-center space-x-2">
                    <BarChart3 className="w-5 h-5" />
                    <span>仪表板设置</span>
                  </h3>

                  <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
                    <div>
                      <label className="block text-sm font-medium text-slate-300 mb-2">默认视图</label>
                      <select
                        value={appSettings.dashboard.defaultView}
                        onChange={(e) => updateAppSettings('dashboard', {
                          ...appSettings.dashboard,
                          defaultView: e.target.value
                        })}
                        className="w-full px-3 py-2 bg-slate-800 border border-slate-700 rounded-lg text-white"
                      >
                        <option value="grid">网格视图</option>
                        <option value="list">列表视图</option>
                      </select>
                    </div>

                    <div>
                      <label className="block text-sm font-medium text-slate-300 mb-2">刷新间隔 (秒)</label>
                      <input
                        type="number"
                        value={appSettings.dashboard.refreshInterval}
                        onChange={(e) => updateAppSettings('dashboard', {
                          ...appSettings.dashboard,
                          refreshInterval: parseInt(e.target.value)
                        })}
                        className="w-full px-3 py-2 bg-slate-800 border border-slate-700 rounded-lg text-white"
                      />
                    </div>
                  </div>

                  <div className="mt-4 space-y-3">
                    <div className="flex items-center justify-between">
                      <span className="text-slate-300">显示欢迎信息</span>
                      <label className="relative inline-flex items-center cursor-pointer">
                        <input
                          type="checkbox"
                          checked={appSettings.dashboard.showWelcome}
                          onChange={(e) => updateAppSettings('dashboard', {
                            ...appSettings.dashboard,
                            showWelcome: e.target.checked
                          })}
                          className="sr-only peer"
                        />
                        <div className="w-11 h-6 bg-slate-700 peer-focus:outline-none rounded-full peer peer-checked:after:translate-x-full peer-checked:after:border-white after:content-[''] after:absolute after:top-[2px] after:left-[2px] after:bg-white after:rounded-full after:h-5 after:w-5 after:transition-all peer-checked:bg-blue-600"></div>
                      </label>
                    </div>

                    <div className="flex items-center justify-between">
                      <span className="text-slate-300">紧凑模式</span>
                      <label className="relative inline-flex items-center cursor-pointer">
                        <input
                          type="checkbox"
                          checked={appSettings.dashboard.compactMode}
                          onChange={(e) => updateAppSettings('dashboard', {
                            ...appSettings.dashboard,
                            compactMode: e.target.checked
                          })}
                          className="sr-only peer"
                        />
                        <div className="w-11 h-6 bg-slate-700 peer-focus:outline-none rounded-full peer peer-checked:after:translate-x-full peer-checked:after:border-white after:content-[''] after:absolute after:top-[2px] after:left-[2px] after:bg-white after:rounded-full after:h-5 after:w-5 after:transition-all peer-checked:bg-blue-600"></div>
                      </label>
                    </div>
                  </div>
                </div>

                {/* 远程桌面设置 */}
                <div className="bg-slate-900/50 border border-slate-800 rounded-xl p-6">
                  <h3 className="text-lg font-semibold text-white mb-4 flex items-center space-x-2">
                    <Monitor className="w-5 h-5" />
                    <span>远程桌面设置</span>
                  </h3>

                  <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
                    <div>
                      <label className="block text-sm font-medium text-slate-300 mb-2">画质</label>
                      <select
                        value={appSettings.remoteDesktop.quality}
                        onChange={(e) => updateAppSettings('remoteDesktop', {
                          ...appSettings.remoteDesktop,
                          quality: e.target.value
                        })}
                        className="w-full px-3 py-2 bg-slate-800 border border-slate-700 rounded-lg text-white"
                      >
                        <option value="low">低</option>
                        <option value="medium">中</option>
                        <option value="high">高</option>
                        <option value="ultra">超高</option>
                      </select>
                    </div>
                  </div>

                  <div className="mt-4 space-y-3">
                    {Object.entries(appSettings.remoteDesktop).filter(([key]) => typeof appSettings.remoteDesktop[key as keyof typeof appSettings.remoteDesktop] === 'boolean').map(([key, value]) => (
                      <div key={key} className="flex items-center justify-between">
                        <span className="text-slate-300">
                          {key === 'compression' ? '启用压缩' :
                           key === 'fullscreen' ? '默认全屏' :
                           key === 'soundEnabled' ? '启用声音' :
                           key === 'clipboardSync' ? '剪贴板同步' : key}
                        </span>
                        <label className="relative inline-flex items-center cursor-pointer">
                          <input
                            type="checkbox"
                            checked={value as boolean}
                            onChange={(e) => updateAppSettings('remoteDesktop', {
                              ...appSettings.remoteDesktop,
                              [key]: e.target.checked
                            })}
                            className="sr-only peer"
                          />
                          <div className="w-11 h-6 bg-slate-700 peer-focus:outline-none rounded-full peer peer-checked:after:translate-x-full peer-checked:after:border-white after:content-[''] after:absolute after:top-[2px] after:left-[2px] after:bg-white after:rounded-full after:h-5 after:w-5 after:transition-all peer-checked:bg-blue-600"></div>
                        </label>
                      </div>
                    ))}
                  </div>
                </div>

                {/* 文件传输设置 */}
                <div className="bg-slate-900/50 border border-slate-800 rounded-xl p-6">
                  <h3 className="text-lg font-semibold text-white mb-4 flex items-center space-x-2">
                    <Folder className="w-5 h-5" />
                    <span>文件传输设置</span>
                  </h3>

                  <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
                    <div>
                      <label className="block text-sm font-medium text-slate-300 mb-2">默认下载位置</label>
                      <input
                        type="text"
                        value={appSettings.fileTransfer.defaultLocation}
                        onChange={(e) => updateAppSettings('fileTransfer', {
                          ...appSettings.fileTransfer,
                          defaultLocation: e.target.value
                        })}
                        className="w-full px-3 py-2 bg-slate-800 border border-slate-700 rounded-lg text-white"
                      />
                    </div>

                    <div>
                      <label className="block text-sm font-medium text-slate-300 mb-2">并行传输数</label>
                      <input
                        type="number"
                        value={appSettings.fileTransfer.parallelTransfers}
                        onChange={(e) => updateAppSettings('fileTransfer', {
                          ...appSettings.fileTransfer,
                          parallelTransfers: parseInt(e.target.value)
                        })}
                        className="w-full px-3 py-2 bg-slate-800 border border-slate-700 rounded-lg text-white"
                      />
                    </div>
                  </div>

                  <div className="mt-4">
                    <div className="flex items-center justify-between">
                      <span className="text-slate-300">自动恢复传输</span>
                      <label className="relative inline-flex items-center cursor-pointer">
                        <input
                          type="checkbox"
                          checked={appSettings.fileTransfer.autoResume}
                          onChange={(e) => updateAppSettings('fileTransfer', {
                            ...appSettings.fileTransfer,
                            autoResume: e.target.checked
                          })}
                          className="sr-only peer"
                        />
                        <div className="w-11 h-6 bg-slate-700 peer-focus:outline-none rounded-full peer peer-checked:after:translate-x-full peer-checked:after:border-white after:content-[''] after:absolute after:top-[2px] after:left-[2px] after:bg-white after:rounded-full after:h-5 after:w-5 after:transition-all peer-checked:bg-blue-600"></div>
                      </label>
                    </div>
                  </div>
                </div>
              </div>
            </div>
          </div>
        )}

        {/* 安全设置 */}
        {activeTab === 'security' && (
          <div className="p-6">
            <div className="max-w-4xl mx-auto">
              <h2 className="text-2xl font-bold text-white mb-6">安全设置</h2>

              <div className="space-y-6">
                {/* 密码设置 */}
                <div className="bg-slate-900/50 border border-slate-800 rounded-xl p-6">
                  <h3 className="text-lg font-semibold text-white mb-4 flex items-center space-x-2">
                    <Key className="w-5 h-5" />
                    <span>密码设置</span>
                  </h3>

                  <div className="space-y-4">
                    <div>
                      <label className="block text-sm font-medium text-slate-300 mb-2">当前密码</label>
                      <div className="relative">
                        <input
                          type={showPassword ? 'text' : 'password'}
                          className="w-full px-3 py-2 bg-slate-800 border border-slate-700 rounded-lg text-white pr-10"
                        />
                        <button
                          onClick={() => setShowPassword(!showPassword)}
                          className="absolute right-3 top-1/2 transform -translate-y-1/2"
                        >
                          {showPassword ? <EyeOff className="w-4 h-4 text-slate-400" /> : <Eye className="w-4 h-4 text-slate-400" />}
                        </button>
                      </div>
                    </div>

                    <div>
                      <label className="block text-sm font-medium text-slate-300 mb-2">新密码</label>
                      <input
                        type="password"
                        className="w-full px-3 py-2 bg-slate-800 border border-slate-700 rounded-lg text-white"
                      />
                    </div>

                    <div>
                      <label className="block text-sm font-medium text-slate-300 mb-2">确认新密码</label>
                      <input
                        type="password"
                        className="w-full px-3 py-2 bg-slate-800 border border-slate-700 rounded-lg text-white"
                      />
                    </div>

                    <button className="px-4 py-2 bg-blue-600 hover:bg-blue-700 text-white rounded-lg">
                      更新密码
                    </button>
                  </div>
                </div>

                {/* 两步验证 */}
                <div className="bg-slate-900/50 border border-slate-800 rounded-xl p-6">
                  <h3 className="text-lg font-semibold text-white mb-4 flex items-center space-x-2">
                    <Shield className="w-5 h-5" />
                    <span>两步验证</span>
                  </h3>

                  <div className="flex items-center justify-between">
                    <div>
                      <p className="text-slate-300">为您的账户添加额外的安全保护</p>
                      <p className="text-sm text-slate-400 mt-1">
                        {systemSettings.security.twoFactorAuth ? '已启用两步验证' : '未启用两步验证'}
                      </p>
                    </div>
                    <button
                      className={cn(
                        'px-4 py-2 rounded-lg',
                        systemSettings.security.twoFactorAuth
                          ? 'bg-red-600 hover:bg-red-700 text-white'
                          : 'bg-green-600 hover:bg-green-700 text-white'
                      )}
                    >
                      {systemSettings.security.twoFactorAuth ? '禁用' : '启用'}
                    </button>
                  </div>
                </div>

                {/* 会话管理 */}
                <div className="bg-slate-900/50 border border-slate-800 rounded-xl p-6">
                  <h3 className="text-lg font-semibold text-white mb-4 flex items-center space-x-2">
                    <Clock className="w-5 h-5" />
                    <span>会话管理</span>
                  </h3>

                  <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
                    <div>
                      <label className="block text-sm font-medium text-slate-300 mb-2">会话超时 (分钟)</label>
                      <input
                        type="number"
                        value={systemSettings.security.sessionTimeout}
                        onChange={(e) => updateSystemSettings('security', {
                          ...systemSettings.security,
                          sessionTimeout: parseInt(e.target.value)
                        })}
                        className="w-full px-3 py-2 bg-slate-800 border border-slate-700 rounded-lg text-white"
                      />
                    </div>

                    <div>
                      <label className="block text-sm font-medium text-slate-300 mb-2">密码过期 (天)</label>
                      <input
                        type="number"
                        value={systemSettings.security.passwordExpiry}
                        onChange={(e) => updateSystemSettings('security', {
                          ...systemSettings.security,
                          passwordExpiry: parseInt(e.target.value)
                        })}
                        className="w-full px-3 py-2 bg-slate-800 border border-slate-700 rounded-lg text-white"
                      />
                    </div>
                  </div>

                  <div className="mt-4">
                    <div className="flex items-center justify-between">
                      <span className="text-slate-300">登录通知</span>
                      <label className="relative inline-flex items-center cursor-pointer">
                        <input
                          type="checkbox"
                          checked={systemSettings.security.loginNotifications}
                          onChange={(e) => updateSystemSettings('security', {
                            ...systemSettings.security,
                            loginNotifications: e.target.checked
                          })}
                          className="sr-only peer"
                        />
                        <div className="w-11 h-6 bg-slate-700 peer-focus:outline-none rounded-full peer peer-checked:after:translate-x-full peer-checked:after:border-white after:content-[''] after:absolute after:top-[2px] after:left-[2px] after:bg-white after:rounded-full after:h-5 after:w-5 after:transition-all peer-checked:bg-blue-600"></div>
                      </label>
                    </div>
                  </div>
                </div>
              </div>
            </div>
          </div>
        )}

        {/* 关于 */}
        {activeTab === 'about' && (
          <div className="p-6">
            <div className="max-w-4xl mx-auto">
              <h2 className="text-2xl font-bold text-white mb-6">关于</h2>

              <div className="space-y-6">
                {/* 应用信息 */}
                <div className="bg-slate-900/50 border border-slate-800 rounded-xl p-6">
                  <div className="text-center">
                    <div className="w-16 h-16 bg-blue-600 rounded-xl flex items-center justify-center mx-auto mb-4">
                      <Monitor className="w-8 h-8 text-white" />
                    </div>
                    <h3 className="text-2xl font-bold text-white mb-2">SkyBridge Compass Pro</h3>
                    <p className="text-slate-400 mb-4">专业的远程管理和监控平台</p>
                    <div className="inline-flex items-center space-x-2 px-3 py-1 bg-blue-500/20 text-blue-400 rounded-full text-sm">
                      <span>版本 2.1.0</span>
                    </div>
                  </div>

                  <div className="mt-8 grid grid-cols-1 md:grid-cols-3 gap-6 text-center">
                    <div>
                      <div className="text-2xl font-bold text-white">99.9%</div>
                      <div className="text-sm text-slate-400">系统可用性</div>
                    </div>
                    <div>
                      <div className="text-2xl font-bold text-white">24/7</div>
                      <div className="text-sm text-slate-400">技术支持</div>
                    </div>
                    <div>
                      <div className="text-2xl font-bold text-white">1000+</div>
                      <div className="text-sm text-slate-400">活跃用户</div>
                    </div>
                  </div>
                </div>

                {/* 系统信息 */}
                <div className="bg-slate-900/50 border border-slate-800 rounded-xl p-6">
                  <h3 className="text-lg font-semibold text-white mb-4">系统信息</h3>
                  
                  <div className="grid grid-cols-1 md:grid-cols-2 gap-4 text-sm">
                    <div className="flex justify-between">
                      <span className="text-slate-400">操作系统:</span>
                      <span className="text-white">macOS 14.2</span>
                    </div>
                    <div className="flex justify-between">
                      <span className="text-slate-400">浏览器:</span>
                      <span className="text-white">Chrome 120.0</span>
                    </div>
                    <div className="flex justify-between">
                      <span className="text-slate-400">Node.js:</span>
                      <span className="text-white">v20.10.0</span>
                    </div>
                    <div className="flex justify-between">
                      <span className="text-slate-400">React:</span>
                      <span className="text-white">v18.2.0</span>
                    </div>
                    <div className="flex justify-between">
                      <span className="text-slate-400">构建时间:</span>
                      <span className="text-white">2024-01-20 14:30</span>
                    </div>
                    <div className="flex justify-between">
                      <span className="text-slate-400">Git 提交:</span>
                      <span className="text-white font-mono">a1b2c3d</span>
                    </div>
                  </div>
                </div>

                {/* 许可证和法律 */}
                <div className="bg-slate-900/50 border border-slate-800 rounded-xl p-6">
                  <h3 className="text-lg font-semibold text-white mb-4">许可证和法律</h3>
                  
                  <div className="space-y-3 text-sm">
                    <div className="flex items-center justify-between">
                      <span className="text-slate-300">软件许可证</span>
                      <button className="text-blue-400 hover:text-blue-300 flex items-center space-x-1">
                        <span>查看</span>
                        <ExternalLink className="w-3 h-3" />
                      </button>
                    </div>
                    <div className="flex items-center justify-between">
                      <span className="text-slate-300">隐私政策</span>
                      <button className="text-blue-400 hover:text-blue-300 flex items-center space-x-1">
                        <span>查看</span>
                        <ExternalLink className="w-3 h-3" />
                      </button>
                    </div>
                    <div className="flex items-center justify-between">
                      <span className="text-slate-300">服务条款</span>
                      <button className="text-blue-400 hover:text-blue-300 flex items-center space-x-1">
                        <span>查看</span>
                        <ExternalLink className="w-3 h-3" />
                      </button>
                    </div>
                  </div>

                  <div className="mt-6 pt-4 border-t border-slate-700 text-center text-xs text-slate-500">
                    © 2024 SkyBridge Technologies. All rights reserved.
                  </div>
                </div>
              </div>
            </div>
          </div>
        )}
      </div>
    </div>
  )
}