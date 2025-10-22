'use client'

import { useState } from 'react'
import { cn } from '@/lib/utils'
import { useDashboardStore } from '@/stores/dashboard-store'
import {
  Search,
  Bell,
  Settings,
  User,
  LogOut,
  Moon,
  Sun,
  Globe,
  ChevronDown,
  Filter,
  Calendar,
  RefreshCw
} from 'lucide-react'

interface HeaderProps {
  className?: string
}

export function Header({ className }: HeaderProps) {
  const { sidebarCollapsed, selectedTimeRange, setTimeRange } = useDashboardStore()
  const [searchQuery, setSearchQuery] = useState('')
  const [showUserMenu, setShowUserMenu] = useState(false)
  const [showNotifications, setShowNotifications] = useState(false)
  const [isDarkMode, setIsDarkMode] = useState(true)

  // 时间范围选项
  const timeRangeOptions = [
    { value: '24h', label: '最近24小时' },
    { value: '7d', label: '最近7天' },
    { value: '30d', label: '最近30天' },
    { value: '90d', label: '最近90天' }
  ]

  // 模拟通知数据
  const notifications = [
    {
      id: '1',
      title: '设备连接异常预警',
      message: '服务器192.168.1.100连接中断，已通知相关人员',
      time: '5分钟前',
      type: 'warning',
      unread: true
    },
    {
      id: '2',
      title: '新的远程连接请求',
      message: '用户申请连接到工作站WS-001',
      time: '1小时前',
      type: 'info',
      unread: true
    },
    {
      id: '3',
      title: '系统维护通知',
      message: '文件传输服务将于今晚23:00进行维护',
      time: '2小时前',
      type: 'info',
      unread: false
    }
  ]

  const unreadCount = notifications.filter(n => n.unread).length

  return (
    <header
      className={cn(
        'fixed top-0 right-0 z-30 h-16 transition-all duration-300 ease-in-out',
        'bg-slate-900/95 backdrop-blur-xl',
        'border-b border-slate-700/50 shadow-lg shadow-black/10',
        // 响应式左边距 - 与侧边栏宽度保持一致
        sidebarCollapsed ? 'left-16' : 'left-64',
        // 移动端适配 - 小屏幕下占满宽度
        'max-md:left-0',
        className
      )}
    >
      <div className="flex items-center justify-between h-16 px-6">
        {/* 左侧：搜索和过滤器 */}
        <div className="flex items-center space-x-4 flex-1">
          {/* 搜索框 */}
          <div className="relative max-w-md w-full">
            <Search className="absolute left-3 top-1/2 transform -translate-y-1/2 w-4 h-4 text-slate-400" />
            <input
              type="text"
              placeholder="搜索设备、连接、文件..."
              value={searchQuery}
              onChange={(e) => setSearchQuery(e.target.value)}
              className="w-full pl-10 pr-4 py-2 bg-slate-800 border border-slate-700 rounded-lg text-white placeholder-slate-400 focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent"
            />
          </div>

          {/* 时间范围选择器 */}
          <div className="relative">
            <select
              value={selectedTimeRange}
              onChange={(e) => setTimeRange(e.target.value as any)}
              className="appearance-none bg-slate-800 border border-slate-700 rounded-lg px-4 py-2 pr-8 text-white focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent"
            >
              {timeRangeOptions.map((option) => (
                <option key={option.value} value={option.value}>
                  {option.label}
                </option>
              ))}
            </select>
            <ChevronDown className="absolute right-2 top-1/2 transform -translate-y-1/2 w-4 h-4 text-slate-400 pointer-events-none" />
          </div>

          {/* 过滤器按钮 */}
          <button className="flex items-center space-x-2 px-3 py-2 bg-slate-800 border border-slate-700 rounded-lg text-slate-300 hover:text-white hover:bg-slate-700 transition-colors">
            <Filter className="w-4 h-4" />
            <span className="text-sm">过滤器</span>
          </button>
        </div>

        {/* 右侧：操作按钮和用户菜单 */}
        <div className="flex items-center space-x-3">
          {/* 刷新按钮 */}
          <button
            className="p-2 text-slate-400 hover:text-white hover:bg-slate-800 rounded-lg transition-colors"
            title="刷新数据"
          >
            <RefreshCw className="w-5 h-5" />
          </button>

          {/* 日历按钮 */}
          <button
            className="p-2 text-slate-400 hover:text-white hover:bg-slate-800 rounded-lg transition-colors"
            title="日程安排"
          >
            <Calendar className="w-5 h-5" />
          </button>

          {/* 主题切换 */}
          <button
            onClick={() => setIsDarkMode(!isDarkMode)}
            className="p-2 text-slate-400 hover:text-white hover:bg-slate-800 rounded-lg transition-colors"
            title={isDarkMode ? '切换到亮色模式' : '切换到暗色模式'}
          >
            {isDarkMode ? <Sun className="w-5 h-5" /> : <Moon className="w-5 h-5" />}
          </button>

          {/* 通知中心 */}
          <div className="relative">
            <button
              onClick={() => setShowNotifications(!showNotifications)}
              className="relative p-2 text-slate-400 hover:text-white hover:bg-slate-800 rounded-lg transition-colors"
              title="通知中心"
            >
              <Bell className="w-5 h-5" />
              {unreadCount > 0 && (
                <span className="absolute -top-1 -right-1 w-5 h-5 bg-red-500 text-white text-xs font-bold rounded-full flex items-center justify-center">
                  {unreadCount}
                </span>
              )}
            </button>

            {/* 通知下拉菜单 */}
            {showNotifications && (
              <div className="absolute right-0 top-full mt-2 w-80 bg-slate-800 border border-slate-700 rounded-lg shadow-xl z-50">
                <div className="p-4 border-b border-slate-700">
                  <div className="flex items-center justify-between">
                    <h3 className="text-lg font-semibold text-white">通知中心</h3>
                    <span className="text-sm text-slate-400">{unreadCount} 条未读</span>
                  </div>
                </div>
                <div className="max-h-96 overflow-y-auto">
                  {notifications.map((notification) => (
                    <div
                      key={notification.id}
                      className={cn(
                        'p-4 border-b border-slate-700 hover:bg-slate-700/50 transition-colors',
                        notification.unread && 'bg-blue-500/5'
                      )}
                    >
                      <div className="flex items-start justify-between">
                        <div className="flex-1">
                          <div className="flex items-center space-x-2">
                            <h4 className="text-sm font-medium text-white">{notification.title}</h4>
                            {notification.unread && (
                              <div className="w-2 h-2 bg-blue-500 rounded-full"></div>
                            )}
                          </div>
                          <p className="text-sm text-slate-400 mt-1">{notification.message}</p>
                          <p className="text-xs text-slate-500 mt-2">{notification.time}</p>
                        </div>
                      </div>
                    </div>
                  ))}
                </div>
                <div className="p-3 border-t border-slate-700">
                  <button className="w-full text-center text-sm text-blue-400 hover:text-blue-300 transition-colors">
                    查看全部通知
                  </button>
                </div>
              </div>
            )}
          </div>

          {/* 用户菜单 */}
          <div className="relative">
            <button
              onClick={() => setShowUserMenu(!showUserMenu)}
              className="flex items-center space-x-2 p-2 hover:bg-slate-800 rounded-lg transition-colors"
            >
              <div className="w-8 h-8 bg-gradient-to-br from-green-500 to-emerald-500 rounded-full flex items-center justify-center">
                <span className="text-sm font-bold text-white">管</span>
              </div>
              <ChevronDown className="w-4 h-4 text-slate-400" />
            </button>

            {/* 用户下拉菜单 */}
            {showUserMenu && (
              <div className="absolute right-0 top-full mt-2 w-56 bg-slate-800 border border-slate-700 rounded-lg shadow-xl z-50">
                <div className="p-4 border-b border-slate-700">
                  <div className="flex items-center space-x-3">
                    <div className="w-10 h-10 bg-gradient-to-br from-green-500 to-emerald-500 rounded-full flex items-center justify-center">
                      <span className="text-sm font-bold text-white">管</span>
                    </div>
                    <div>
                      <p className="text-sm font-medium text-white">系统管理员</p>
                      <p className="text-xs text-slate-400">admin@skybridge.com</p>
                    </div>
                  </div>
                </div>
                
                <div className="py-2">
                  <a
                    href="/profile"
                    className="flex items-center space-x-3 px-4 py-2 text-slate-300 hover:text-white hover:bg-slate-700 transition-colors"
                  >
                    <User className="w-4 h-4" />
                    <span className="text-sm">个人资料</span>
                  </a>
                  <a
                    href="/settings"
                    className="flex items-center space-x-3 px-4 py-2 text-slate-300 hover:text-white hover:bg-slate-700 transition-colors"
                  >
                    <Settings className="w-4 h-4" />
                    <span className="text-sm">系统设置</span>
                  </a>
                  <a
                    href="/help"
                    className="flex items-center space-x-3 px-4 py-2 text-slate-300 hover:text-white hover:bg-slate-700 transition-colors"
                  >
                    <Globe className="w-4 h-4" />
                    <span className="text-sm">帮助中心</span>
                  </a>
                </div>
                
                <div className="border-t border-slate-700 py-2">
                  <button className="flex items-center space-x-3 px-4 py-2 w-full text-left text-red-400 hover:text-red-300 hover:bg-slate-700 transition-colors">
                    <LogOut className="w-4 h-4" />
                    <span className="text-sm">退出登录</span>
                  </button>
                </div>
              </div>
            )}
          </div>
        </div>
      </div>

      {/* 点击外部关闭菜单 */}
      {(showUserMenu || showNotifications) && (
        <div
          className="fixed inset-0 z-40"
          onClick={() => {
            setShowUserMenu(false)
            setShowNotifications(false)
          }}
        />
      )}
    </header>
  )
}