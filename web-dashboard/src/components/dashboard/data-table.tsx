'use client'

import React, { memo, useMemo, useCallback, useState } from 'react'
import { motion } from 'framer-motion'
import { 
  Search, 
  Filter, 
  Download,
  MoreHorizontal,
  Plane,
  Clock,
  MapPin
} from 'lucide-react'

// 航班数据类型定义
interface FlightData {
  id: string
  route: string
  departure: string
  arrival: string
  status: 'on-time' | 'delayed' | 'boarding' | 'scheduled' | 'cancelled'
  statusText: string
  aircraft: string
  passengers: string
  gate: string
}

// 航班数据
const flightData: FlightData[] = [
  {
    id: 'CA1234',
    route: '北京 → 上海',
    departure: '08:30',
    arrival: '11:15',
    status: 'on-time',
    statusText: '准点',
    aircraft: 'A320',
    passengers: '156/180',
    gate: 'A12'
  },
  {
    id: 'MU5678',
    route: '上海 → 广州',
    departure: '14:20',
    arrival: '17:05',
    status: 'delayed',
    statusText: '延误',
    aircraft: 'B737',
    passengers: '142/168',
    gate: 'B08'
  },
  {
    id: 'CZ9012',
    route: '广州 → 深圳',
    departure: '19:45',
    arrival: '20:30',
    status: 'boarding',
    statusText: '登机中',
    aircraft: 'A330',
    passengers: '234/280',
    gate: 'C15'
  },
  {
    id: 'HU3456',
    route: '深圳 → 成都',
    departure: '21:10',
    arrival: '23:45',
    status: 'scheduled',
    statusText: '计划中',
    aircraft: 'B777',
    passengers: '298/350',
    gate: 'D22'
  },
  {
    id: 'SC7890',
    route: '成都 → 西安',
    departure: '06:15',
    arrival: '07:50',
    status: 'cancelled',
    statusText: '取消',
    aircraft: 'A350',
    passengers: '0/315',
    gate: '--'
  }
]

const statusColors = {
  'on-time': 'bg-green-500/20 text-green-400 border-green-500/30',
  'delayed': 'bg-red-500/20 text-red-400 border-red-500/30',
  'boarding': 'bg-blue-500/20 text-blue-400 border-blue-500/30',
  'scheduled': 'bg-yellow-500/20 text-yellow-400 border-yellow-500/30',
  'cancelled': 'bg-gray-500/20 text-gray-400 border-gray-500/30'
} as const

/**
 * 优化的航班行组件 - 使用React.memo防止不必要的重渲染
 */
const FlightRow = memo(function FlightRow({
  flight,
  index,
  isSelected,
  onToggleSelection
}: {
  flight: FlightData
  index: number
  isSelected: boolean
  onToggleSelection: (id: string) => void
}) {
  const handleToggle = useCallback(() => {
    onToggleSelection(flight.id)
  }, [flight.id, onToggleSelection])

  return (
    <motion.tr
      key={flight.id}
      initial={{ opacity: 0, y: 20 }}
      animate={{ opacity: 1, y: 0 }}
      transition={{ delay: index * 0.05 }}
      className={`border-b border-slate-800/50 hover:bg-slate-800/30 transition-colors ${
        isSelected ? 'bg-blue-500/10' : ''
      }`}
    >
      <td className="p-4">
        <input
          type="checkbox"
          checked={isSelected}
          onChange={handleToggle}
          className="rounded border-slate-600 bg-slate-800"
        />
      </td>
      <td className="p-4">
        <div className="flex items-center space-x-2">
          <Plane className="w-4 h-4 text-blue-400" />
          <span className="text-white font-medium">{flight.id}</span>
        </div>
      </td>
      <td className="p-4">
        <div className="flex items-center space-x-2">
          <MapPin className="w-4 h-4 text-slate-400" />
          <span className="text-slate-300">{flight.route}</span>
        </div>
      </td>
      <td className="p-4">
        <div className="flex items-center space-x-2">
          <Clock className="w-4 h-4 text-slate-400" />
          <span className="text-slate-300">{flight.departure}</span>
        </div>
      </td>
      <td className="p-4 text-slate-300">{flight.arrival}</td>
      <td className="p-4">
        <span className={`px-2 py-1 rounded-full text-xs font-medium border ${statusColors[flight.status]}`}>
          {flight.statusText}
        </span>
      </td>
      <td className="p-4 text-slate-300">{flight.aircraft}</td>
      <td className="p-4 text-slate-300">{flight.passengers}</td>
      <td className="p-4 text-slate-300">{flight.gate}</td>
      <td className="p-4">
        <motion.button
          whileHover={{ scale: 1.05 }}
          whileTap={{ scale: 0.95 }}
          className="p-1 rounded-lg hover:bg-slate-700 transition-colors"
        >
          <MoreHorizontal className="w-4 h-4 text-slate-400" />
        </motion.button>
      </td>
    </motion.tr>
  )
})

/**
 * 优化的数据表格组件 - 2025年性能优化版本
 */
const DataTable = memo(function DataTable() {
  const [searchTerm, setSearchTerm] = useState('')
  const [selectedRows, setSelectedRows] = useState<string[]>([])

  // 使用useMemo缓存过滤后的数据
  const filteredData = useMemo(() => {
    return flightData.filter(flight =>
      flight.id.toLowerCase().includes(searchTerm.toLowerCase()) ||
      flight.route.toLowerCase().includes(searchTerm.toLowerCase())
    )
  }, [searchTerm])

  // 使用useCallback缓存事件处理函数
  const toggleRowSelection = useCallback((id: string) => {
    setSelectedRows(prev =>
      prev.includes(id)
        ? prev.filter(rowId => rowId !== id)
        : [...prev, id]
    )
  }, [])

  const handleSelectAll = useCallback((checked: boolean) => {
    if (checked) {
      setSelectedRows(filteredData.map(f => f.id))
    } else {
      setSelectedRows([])
    }
  }, [filteredData])

  const handleSearchChange = useCallback((e: React.ChangeEvent<HTMLInputElement>) => {
    setSearchTerm(e.target.value)
  }, [])

  // 使用useMemo缓存表头复选框状态
  const selectAllState = useMemo(() => {
    const selectedCount = selectedRows.length
    const totalCount = filteredData.length
    
    if (selectedCount === 0) return { checked: false, indeterminate: false }
    if (selectedCount === totalCount) return { checked: true, indeterminate: false }
    return { checked: false, indeterminate: true }
  }, [selectedRows.length, filteredData.length])

  return (
    <motion.div
      initial={{ opacity: 0, y: 20 }}
      animate={{ opacity: 1, y: 0 }}
      className="bg-slate-900/50 backdrop-blur-sm border border-slate-800 rounded-xl overflow-hidden"
    >
      {/* 表格头部 */}
      <div className="p-6 border-b border-slate-800">
        <div className="flex items-center justify-between mb-4">
          <h3 className="text-lg font-semibold text-white">实时航班信息</h3>
          <div className="flex items-center space-x-3">
            <motion.button
              whileHover={{ scale: 1.05 }}
              whileTap={{ scale: 0.95 }}
              className="p-2 rounded-lg bg-slate-800/50 hover:bg-slate-700 transition-colors"
              title="筛选"
            >
              <Filter className="w-4 h-4 text-slate-400" />
            </motion.button>
            <motion.button
              whileHover={{ scale: 1.05 }}
              whileTap={{ scale: 0.95 }}
              className="p-2 rounded-lg bg-slate-800/50 hover:bg-slate-700 transition-colors"
              title="导出"
            >
              <Download className="w-4 h-4 text-slate-400" />
            </motion.button>
          </div>
        </div>

        {/* 搜索框 */}
        <div className="relative">
          <Search className="absolute left-3 top-1/2 transform -translate-y-1/2 w-4 h-4 text-slate-400" />
          <input
            type="text"
            placeholder="搜索航班号或航线..."
            value={searchTerm}
            onChange={handleSearchChange}
            className="w-full pl-10 pr-4 py-2 bg-slate-800/50 border border-slate-700 rounded-lg text-white placeholder-slate-400 focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent transition-all"
          />
        </div>
      </div>

      {/* 表格内容 */}
      <div className="overflow-x-auto">
        <table className="w-full">
          <thead>
            <tr className="border-b border-slate-800">
              <th className="text-left p-4 text-slate-400 font-medium">
                <input
                  type="checkbox"
                  checked={selectAllState.checked}
                  ref={(input) => {
                    if (input) input.indeterminate = selectAllState.indeterminate
                  }}
                  onChange={(e) => handleSelectAll(e.target.checked)}
                  className="rounded border-slate-600 bg-slate-800"
                />
              </th>
              <th className="text-left p-4 text-slate-400 font-medium">航班号</th>
              <th className="text-left p-4 text-slate-400 font-medium">航线</th>
              <th className="text-left p-4 text-slate-400 font-medium">起飞时间</th>
              <th className="text-left p-4 text-slate-400 font-medium">到达时间</th>
              <th className="text-left p-4 text-slate-400 font-medium">状态</th>
              <th className="text-left p-4 text-slate-400 font-medium">机型</th>
              <th className="text-left p-4 text-slate-400 font-medium">乘客</th>
              <th className="text-left p-4 text-slate-400 font-medium">登机口</th>
              <th className="text-left p-4 text-slate-400 font-medium">操作</th>
            </tr>
          </thead>
          <tbody>
            {filteredData.map((flight, index) => (
              <FlightRow
                key={flight.id}
                flight={flight}
                index={index}
                isSelected={selectedRows.includes(flight.id)}
                onToggleSelection={toggleRowSelection}
              />
            ))}
          </tbody>
        </table>
        
        {/* 空状态 */}
        {filteredData.length === 0 && (
          <div className="text-center py-12">
            <Plane className="w-12 h-12 text-slate-600 mx-auto mb-4" />
            <p className="text-slate-400">没有找到匹配的航班</p>
          </div>
        )}
      </div>

      {/* 表格底部信息 */}
      <div className="px-6 py-4 border-t border-slate-800 flex items-center justify-between text-sm text-slate-400">
        <div>
          显示 {filteredData.length} 条航班信息
          {selectedRows.length > 0 && (
            <span className="ml-2">
              已选择 {selectedRows.length} 条
            </span>
          )}
        </div>
        <div className="flex items-center space-x-2">
          <span>每页显示</span>
          <select className="bg-slate-800 border border-slate-700 rounded px-2 py-1 text-white">
            <option>10</option>
            <option>25</option>
            <option>50</option>
          </select>
        </div>
      </div>
    </motion.div>
  )
})

export default DataTable