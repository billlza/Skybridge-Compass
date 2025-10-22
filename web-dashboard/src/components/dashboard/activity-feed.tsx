'use client'

import { motion } from 'framer-motion'
import { 
  Plane, 
  Users, 
  AlertTriangle, 
  CheckCircle, 
  Clock,
  TrendingUp,
  Settings,
  Bell
} from 'lucide-react'

// 活动数据
const activities = [
  {
    id: 1,
    type: 'flight',
    icon: Plane,
    title: '航班 CA1234 已起飞',
    description: '北京 → 上海，预计11:15到达',
    time: '2分钟前',
    color: 'text-blue-400',
    bgColor: 'bg-blue-500/10'
  },
  {
    id: 2,
    type: 'passenger',
    icon: Users,
    title: '新增乘客登记',
    description: '156名乘客完成登机手续',
    time: '5分钟前',
    color: 'text-green-400',
    bgColor: 'bg-green-500/10'
  },
  {
    id: 3,
    type: 'alert',
    icon: AlertTriangle,
    title: '天气预警',
    description: '上海地区有雷暴天气，可能影响航班',
    time: '8分钟前',
    color: 'text-yellow-400',
    bgColor: 'bg-yellow-500/10'
  },
  {
    id: 4,
    type: 'success',
    icon: CheckCircle,
    title: '系统维护完成',
    description: '航班调度系统升级成功',
    time: '15分钟前',
    color: 'text-green-400',
    bgColor: 'bg-green-500/10'
  },
  {
    id: 5,
    type: 'delay',
    icon: Clock,
    title: '航班延误通知',
    description: 'MU5678 延误30分钟，原因：流量控制',
    time: '20分钟前',
    color: 'text-red-400',
    bgColor: 'bg-red-500/10'
  },
  {
    id: 6,
    type: 'performance',
    icon: TrendingUp,
    title: '性能指标更新',
    description: '今日准点率达到94.5%',
    time: '25分钟前',
    color: 'text-purple-400',
    bgColor: 'bg-purple-500/10'
  },
  {
    id: 7,
    type: 'system',
    icon: Settings,
    title: '配置更新',
    description: '登机口分配规则已更新',
    time: '30分钟前',
    color: 'text-cyan-400',
    bgColor: 'bg-cyan-500/10'
  },
  {
    id: 8,
    type: 'notification',
    icon: Bell,
    title: '重要通知',
    description: '明日将进行系统例行维护',
    time: '1小时前',
    color: 'text-orange-400',
    bgColor: 'bg-orange-500/10'
  }
]

export default function ActivityFeed() {
  return (
    <motion.div
      initial={{ opacity: 0, x: 20 }}
      animate={{ opacity: 1, x: 0 }}
      className="bg-slate-900/50 backdrop-blur-sm border border-slate-800 rounded-xl overflow-hidden"
    >
      {/* 头部 */}
      <div className="p-6 border-b border-slate-800">
        <div className="flex items-center justify-between">
          <h3 className="text-lg font-semibold text-white">实时活动</h3>
          <div className="flex items-center space-x-2">
            <div className="w-2 h-2 bg-green-400 rounded-full animate-pulse"></div>
            <span className="text-sm text-slate-400">实时更新</span>
          </div>
        </div>
      </div>

      {/* 活动列表 */}
      <div className="max-h-96 overflow-y-auto">
        <div className="p-4 space-y-4">
          {activities.map((activity, index) => {
            const Icon = activity.icon
            
            return (
              <motion.div
                key={activity.id}
                initial={{ opacity: 0, y: 20 }}
                animate={{ opacity: 1, y: 0 }}
                transition={{ delay: index * 0.05 }}
                className="flex items-start space-x-3 p-3 rounded-lg hover:bg-slate-800/30 transition-colors cursor-pointer group"
              >
                {/* 图标 */}
                <div className={`p-2 rounded-lg ${activity.bgColor} flex-shrink-0 group-hover:scale-110 transition-transform`}>
                  <Icon className={`w-4 h-4 ${activity.color}`} />
                </div>

                {/* 内容 */}
                <div className="flex-1 min-w-0">
                  <div className="flex items-center justify-between mb-1">
                    <h4 className="text-white text-sm font-medium truncate">
                      {activity.title}
                    </h4>
                    <span className="text-xs text-slate-400 flex-shrink-0 ml-2">
                      {activity.time}
                    </span>
                  </div>
                  <p className="text-slate-400 text-xs leading-relaxed">
                    {activity.description}
                  </p>
                </div>

                {/* 状态指示器 */}
                <div className="flex-shrink-0">
                  <div className="w-2 h-2 bg-slate-600 rounded-full group-hover:bg-slate-500 transition-colors"></div>
                </div>
              </motion.div>
            )
          })}
        </div>
      </div>

      {/* 底部操作 */}
      <div className="p-4 border-t border-slate-800">
        <div className="flex items-center justify-between">
          <button className="text-sm text-slate-400 hover:text-white transition-colors">
            查看全部活动
          </button>
          <div className="flex items-center space-x-2">
            <motion.button
              whileHover={{ scale: 1.05 }}
              whileTap={{ scale: 0.95 }}
              className="p-1.5 rounded-lg bg-slate-800/50 hover:bg-slate-700 transition-colors"
            >
              <Settings className="w-4 h-4 text-slate-400" />
            </motion.button>
            <motion.button
              whileHover={{ scale: 1.05 }}
              whileTap={{ scale: 0.95 }}
              className="p-1.5 rounded-lg bg-slate-800/50 hover:bg-slate-700 transition-colors"
            >
              <Bell className="w-4 h-4 text-slate-400" />
            </motion.button>
          </div>
        </div>
      </div>

      {/* 快速统计 */}
      <div className="p-4 bg-slate-800/30">
        <div className="grid grid-cols-2 gap-4">
          <div className="text-center">
            <div className="text-lg font-bold text-white">24</div>
            <div className="text-xs text-slate-400">今日事件</div>
          </div>
          <div className="text-center">
            <div className="text-lg font-bold text-green-400">98%</div>
            <div className="text-xs text-slate-400">系统正常</div>
          </div>
        </div>
      </div>
    </motion.div>
  )
}