'use client'

import { motion } from 'framer-motion'
import {
  LineChart,
  Line,
  AreaChart,
  Area,
  BarChart,
  Bar,
  PieChart,
  Pie,
  Cell,
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip,
  ResponsiveContainer,
  Legend
} from 'recharts'

// 航班流量数据
const flightTrafficData = [
  { time: '00:00', flights: 12, passengers: 1200 },
  { time: '04:00', flights: 8, passengers: 800 },
  { time: '08:00', flights: 45, passengers: 4500 },
  { time: '12:00', flights: 67, passengers: 6700 },
  { time: '16:00', flights: 52, passengers: 5200 },
  { time: '20:00', flights: 38, passengers: 3800 },
]

// 收入数据
const revenueData = [
  { month: '1月', revenue: 2400000, profit: 400000 },
  { month: '2月', revenue: 1398000, profit: 300000 },
  { month: '3月', revenue: 9800000, profit: 200000 },
  { month: '4月', revenue: 3908000, profit: 278000 },
  { month: '5月', revenue: 4800000, profit: 189000 },
  { month: '6月', revenue: 3800000, profit: 239000 },
]

// 航线分布数据
const routeDistributionData = [
  { name: '国内航线', value: 65, color: '#3B82F6' },
  { name: '国际航线', value: 25, color: '#10B981' },
  { name: '地区航线', value: 10, color: '#F59E0B' },
]

// 机型使用率数据
const aircraftUsageData = [
  { type: 'A320', usage: 85, total: 100 },
  { type: 'B737', usage: 92, total: 100 },
  { type: 'A330', usage: 78, total: 100 },
  { type: 'B777', usage: 88, total: 100 },
  { type: 'A350', usage: 95, total: 100 },
]

export default function ChartsSection() {
  return (
    <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
      {/* 航班流量趋势图 */}
      <motion.div
        initial={{ opacity: 0, scale: 0.95 }}
        animate={{ opacity: 1, scale: 1 }}
        transition={{ delay: 0.1 }}
        className="bg-slate-900/50 backdrop-blur-sm border border-slate-800 rounded-xl p-6"
      >
        <div className="flex items-center justify-between mb-6">
          <h3 className="text-lg font-semibold text-white">航班流量趋势</h3>
          <div className="flex items-center space-x-4 text-sm">
            <div className="flex items-center space-x-2">
              <div className="w-3 h-3 bg-blue-500 rounded-full"></div>
              <span className="text-slate-400">航班数量</span>
            </div>
            <div className="flex items-center space-x-2">
              <div className="w-3 h-3 bg-cyan-400 rounded-full"></div>
              <span className="text-slate-400">乘客数量</span>
            </div>
          </div>
        </div>
        
        <ResponsiveContainer width="100%" height={300}>
          <AreaChart data={flightTrafficData}>
            <defs>
              <linearGradient id="flightGradient" x1="0" y1="0" x2="0" y2="1">
                <stop offset="5%" stopColor="#3B82F6" stopOpacity={0.3}/>
                <stop offset="95%" stopColor="#3B82F6" stopOpacity={0}/>
              </linearGradient>
              <linearGradient id="passengerGradient" x1="0" y1="0" x2="0" y2="1">
                <stop offset="5%" stopColor="#06B6D4" stopOpacity={0.3}/>
                <stop offset="95%" stopColor="#06B6D4" stopOpacity={0}/>
              </linearGradient>
            </defs>
            <CartesianGrid strokeDasharray="3 3" stroke="#374151" />
            <XAxis dataKey="time" stroke="#9CA3AF" />
            <YAxis stroke="#9CA3AF" />
            <Tooltip 
              contentStyle={{ 
                backgroundColor: '#1F2937', 
                border: '1px solid #374151',
                borderRadius: '8px',
                color: '#F9FAFB'
              }} 
            />
            <Area
              type="monotone"
              dataKey="flights"
              stroke="#3B82F6"
              fillOpacity={1}
              fill="url(#flightGradient)"
              strokeWidth={2}
            />
            <Area
              type="monotone"
              dataKey="passengers"
              stroke="#06B6D4"
              fillOpacity={1}
              fill="url(#passengerGradient)"
              strokeWidth={2}
              yAxisId="right"
            />
          </AreaChart>
        </ResponsiveContainer>
      </motion.div>

      {/* 收入统计图 */}
      <motion.div
        initial={{ opacity: 0, scale: 0.95 }}
        animate={{ opacity: 1, scale: 1 }}
        transition={{ delay: 0.2 }}
        className="bg-slate-900/50 backdrop-blur-sm border border-slate-800 rounded-xl p-6"
      >
        <div className="flex items-center justify-between mb-6">
          <h3 className="text-lg font-semibold text-white">收入统计</h3>
          <div className="flex items-center space-x-4 text-sm">
            <div className="flex items-center space-x-2">
              <div className="w-3 h-3 bg-green-500 rounded-full"></div>
              <span className="text-slate-400">总收入</span>
            </div>
            <div className="flex items-center space-x-2">
              <div className="w-3 h-3 bg-purple-500 rounded-full"></div>
              <span className="text-slate-400">净利润</span>
            </div>
          </div>
        </div>
        
        <ResponsiveContainer width="100%" height={300}>
          <BarChart data={revenueData}>
            <CartesianGrid strokeDasharray="3 3" stroke="#374151" />
            <XAxis dataKey="month" stroke="#9CA3AF" />
            <YAxis stroke="#9CA3AF" />
            <Tooltip 
              contentStyle={{ 
                backgroundColor: '#1F2937', 
                border: '1px solid #374151',
                borderRadius: '8px',
                color: '#F9FAFB'
              }}
              formatter={(value: number) => [`¥${(value / 1000000).toFixed(1)}M`, '']}
            />
            <Bar dataKey="revenue" fill="#10B981" radius={[4, 4, 0, 0]} />
            <Bar dataKey="profit" fill="#8B5CF6" radius={[4, 4, 0, 0]} />
          </BarChart>
        </ResponsiveContainer>
      </motion.div>

      {/* 航线分布饼图 */}
      <motion.div
        initial={{ opacity: 0, scale: 0.95 }}
        animate={{ opacity: 1, scale: 1 }}
        transition={{ delay: 0.3 }}
        className="bg-slate-900/50 backdrop-blur-sm border border-slate-800 rounded-xl p-6"
      >
        <h3 className="text-lg font-semibold text-white mb-6">航线分布</h3>
        
        <ResponsiveContainer width="100%" height={300}>
          <PieChart>
            <Pie
              data={routeDistributionData}
              cx="50%"
              cy="50%"
              innerRadius={60}
              outerRadius={100}
              paddingAngle={5}
              dataKey="value"
            >
              {routeDistributionData.map((entry, index) => (
                <Cell key={`cell-${index}`} fill={entry.color} />
              ))}
            </Pie>
            <Tooltip 
              contentStyle={{ 
                backgroundColor: '#1F2937', 
                border: '1px solid #374151',
                borderRadius: '8px',
                color: '#F9FAFB'
              }}
              formatter={(value: number) => [`${value}%`, '']}
            />
            <Legend 
              wrapperStyle={{ color: '#9CA3AF' }}
              formatter={(value) => <span style={{ color: '#9CA3AF' }}>{value}</span>}
            />
          </PieChart>
        </ResponsiveContainer>
      </motion.div>

      {/* 机型使用率 */}
      <motion.div
        initial={{ opacity: 0, scale: 0.95 }}
        animate={{ opacity: 1, scale: 1 }}
        transition={{ delay: 0.4 }}
        className="bg-slate-900/50 backdrop-blur-sm border border-slate-800 rounded-xl p-6"
      >
        <h3 className="text-lg font-semibold text-white mb-6">机型使用率</h3>
        
        <div className="space-y-4">
          {aircraftUsageData.map((aircraft, index) => (
            <motion.div
              key={aircraft.type}
              initial={{ opacity: 0, x: -20 }}
              animate={{ opacity: 1, x: 0 }}
              transition={{ delay: 0.5 + index * 0.1 }}
              className="flex items-center justify-between"
            >
              <div className="flex items-center space-x-3">
                <span className="text-white font-medium w-12">{aircraft.type}</span>
                <div className="flex-1 bg-slate-800 rounded-full h-2 w-32">
                  <motion.div
                    initial={{ width: 0 }}
                    animate={{ width: `${aircraft.usage}%` }}
                    transition={{ delay: 0.7 + index * 0.1, duration: 1 }}
                    className="bg-gradient-to-r from-blue-500 to-cyan-400 h-2 rounded-full"
                  />
                </div>
              </div>
              <span className="text-slate-400 text-sm">{aircraft.usage}%</span>
            </motion.div>
          ))}
        </div>
      </motion.div>
    </div>
  )
}