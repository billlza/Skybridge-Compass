'use client'

import { motion } from 'framer-motion'
import { Search, Bell, Settings, User, Moon, Sun } from 'lucide-react'
import { useState } from 'react'

export default function Header() {
  const [isDarkMode, setIsDarkMode] = useState(true)
  const [notifications] = useState(3)

  return (
    <motion.header
      initial={{ opacity: 0, y: -20 }}
      animate={{ opacity: 1, y: 0 }}
      className="bg-slate-900/50 backdrop-blur-sm border-b border-slate-800 px-6 py-4"
    >
      <div className="flex items-center justify-between">
        {/* 左侧：面包屑导航 */}
        <div className="flex items-center space-x-4">
          <div className="text-sm text-slate-400">
            <span>仪表板</span>
            <span className="mx-2">/</span>
            <span className="text-white">概览</span>
          </div>
        </div>

        {/* 中间：搜索框 */}
        <div className="flex-1 max-w-md mx-8">
          <div className="relative">
            <Search className="absolute left-3 top-1/2 transform -translate-y-1/2 w-4 h-4 text-slate-400" />
            <input
              type="text"
              placeholder="搜索设备、连接或文件..."
              className="w-full pl-10 pr-4 py-2 bg-slate-800/50 border border-slate-700 rounded-lg text-white placeholder-slate-400 focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent transition-all"
            />
          </div>
        </div>

        {/* 右侧：操作按钮 */}
        <div className="flex items-center space-x-3">
          {/* 主题切换 */}
          <motion.button
            whileHover={{ scale: 1.05 }}
            whileTap={{ scale: 0.95 }}
            onClick={() => setIsDarkMode(!isDarkMode)}
            className="p-2 rounded-lg bg-slate-800/50 hover:bg-slate-700 transition-colors"
          >
            {isDarkMode ? (
              <Sun className="w-5 h-5 text-yellow-400" />
            ) : (
              <Moon className="w-5 h-5 text-slate-400" />
            )}
          </motion.button>

          {/* 通知 */}
          <motion.button
            whileHover={{ scale: 1.05 }}
            whileTap={{ scale: 0.95 }}
            className="relative p-2 rounded-lg bg-slate-800/50 hover:bg-slate-700 transition-colors"
          >
            <Bell className="w-5 h-5 text-slate-400" />
            {notifications > 0 && (
              <motion.span
                initial={{ scale: 0 }}
                animate={{ scale: 1 }}
                className="absolute -top-1 -right-1 w-5 h-5 bg-red-500 text-white text-xs rounded-full flex items-center justify-center"
              >
                {notifications}
              </motion.span>
            )}
          </motion.button>

          {/* 设置 */}
          <motion.button
            whileHover={{ scale: 1.05 }}
            whileTap={{ scale: 0.95 }}
            className="p-2 rounded-lg bg-slate-800/50 hover:bg-slate-700 transition-colors"
          >
            <Settings className="w-5 h-5 text-slate-400" />
          </motion.button>

          {/* 用户头像 */}
          <motion.button
            whileHover={{ scale: 1.05 }}
            whileTap={{ scale: 0.95 }}
            className="flex items-center space-x-2 p-2 rounded-lg bg-slate-800/50 hover:bg-slate-700 transition-colors"
          >
            <div className="w-8 h-8 bg-gradient-to-br from-blue-500 to-purple-600 rounded-full flex items-center justify-center">
              <User className="w-4 h-4 text-white" />
            </div>
            <span className="text-white text-sm font-medium hidden md:block">管理员</span>
          </motion.button>
        </div>
      </div>

      {/* 实时状态栏 */}
      <motion.div
        initial={{ opacity: 0 }}
        animate={{ opacity: 1 }}
        transition={{ delay: 0.2 }}
        className="mt-4 flex items-center justify-between text-sm"
      >
        <div className="flex items-center space-x-6">
          <div className="flex items-center space-x-2">
            <div className="w-2 h-2 bg-green-400 rounded-full animate-pulse"></div>
            <span className="text-slate-400">系统状态：</span>
            <span className="text-green-400">正常运行</span>
          </div>
          
          <div className="flex items-center space-x-2">
            <span className="text-slate-400">在线设备：</span>
            <span className="text-blue-400 font-medium">247</span>
          </div>
          
          <div className="flex items-center space-x-2">
            <span className="text-slate-400">活跃连接：</span>
            <span className="text-cyan-400 font-medium">1,234</span>
          </div>
        </div>

        <div className="text-slate-400">
          最后更新：{new Date().toLocaleTimeString('zh-CN')}
        </div>
      </motion.div>
    </motion.header>
  )
}