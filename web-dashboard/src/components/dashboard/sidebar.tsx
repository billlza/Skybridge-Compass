'use client'

import { motion } from 'framer-motion'
import { 
  Home, 
  BarChart3, 
  Users, 
  Settings, 
  Bell, 
  FileText,
  Monitor,
  MapPin,
  Calendar,
  ChevronLeft,
  ChevronRight
} from 'lucide-react'

interface SidebarProps {
  collapsed: boolean
  onToggle: () => void
}

const menuItems = [
  { icon: Home, label: '主控制台', active: true },
  { icon: Monitor, label: '设备管理' },
  { icon: FileText, label: '文件传输' },
  { icon: Users, label: '远程桌面' },
  { icon: BarChart3, label: '系统监控' },
  { icon: Calendar, label: '连接调度' },
  { icon: Bell, label: '通知中心' },
  { icon: Settings, label: '系统设置' },
]

export default function Sidebar({ collapsed, onToggle }: SidebarProps) {
  return (
    <motion.div
      initial={{ x: -300 }}
      animate={{ x: 0 }}
      className={`fixed left-0 top-0 h-full bg-slate-900/95 backdrop-blur-sm border-r border-slate-800 z-50 transition-all duration-300 ${
        collapsed ? 'w-16' : 'w-64'
      }`}
    >
      {/* Logo 区域 */}
      <div className="p-4 border-b border-slate-800">
        <div className="flex items-center justify-between">
          {!collapsed && (
            <motion.div
              initial={{ opacity: 0 }}
              animate={{ opacity: 1 }}
              exit={{ opacity: 0 }}
              className="flex items-center space-x-3"
            >
              <div className="w-8 h-8 bg-gradient-to-br from-blue-500 to-cyan-400 rounded-lg flex items-center justify-center">
                <Monitor className="w-5 h-5 text-white" />
              </div>
              <span className="font-bold text-lg text-white">SkyBridge</span>
            </motion.div>
          )}
          
          <button
            onClick={onToggle}
            className="p-1.5 rounded-lg hover:bg-slate-800 transition-colors"
          >
            {collapsed ? (
              <ChevronRight className="w-5 h-5 text-slate-400" />
            ) : (
              <ChevronLeft className="w-5 h-5 text-slate-400" />
            )}
          </button>
        </div>
      </div>

      {/* 导航菜单 */}
      <nav className="p-4 space-y-2">
        {menuItems.map((item, index) => {
          const Icon = item.icon
          return (
            <motion.button
              key={item.label}
              initial={{ opacity: 0, x: -20 }}
              animate={{ opacity: 1, x: 0 }}
              transition={{ delay: index * 0.05 }}
              className={`w-full flex items-center space-x-3 px-3 py-2.5 rounded-lg transition-all duration-200 group ${
                item.active
                  ? 'bg-blue-600 text-white shadow-lg shadow-blue-600/25'
                  : 'text-slate-400 hover:text-white hover:bg-slate-800'
              }`}
            >
              <Icon className={`w-5 h-5 ${item.active ? 'text-white' : 'text-slate-400 group-hover:text-white'}`} />
              
              {!collapsed && (
                <motion.span
                  initial={{ opacity: 0 }}
                  animate={{ opacity: 1 }}
                  exit={{ opacity: 0 }}
                  className="font-medium"
                >
                  {item.label}
                </motion.span>
              )}
              
              {item.active && (
                <motion.div
                  layoutId="activeIndicator"
                  className="absolute right-0 w-1 h-8 bg-white rounded-l-full"
                />
              )}
            </motion.button>
          )
        })}
      </nav>

      {/* 底部用户信息 */}
      {!collapsed && (
        <motion.div
          initial={{ opacity: 0 }}
          animate={{ opacity: 1 }}
          className="absolute bottom-4 left-4 right-4"
        >
          <div className="bg-slate-800/50 rounded-lg p-3 border border-slate-700">
            <div className="flex items-center space-x-3">
              <div className="w-8 h-8 bg-gradient-to-br from-green-500 to-emerald-400 rounded-full flex items-center justify-center">
                <span className="text-white text-sm font-medium">管</span>
              </div>
              <div className="flex-1 min-w-0">
                <p className="text-white text-sm font-medium truncate">系统管理员</p>
                <p className="text-slate-400 text-xs truncate">admin@skybridge.com</p>
              </div>
            </div>
          </div>
        </motion.div>
      )}
    </motion.div>
  )
}