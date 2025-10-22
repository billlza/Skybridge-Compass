import { create } from 'zustand'
import { devtools, persist } from 'zustand/middleware'

// 航班状态类型
export type FlightStatus = 'on-time' | 'delayed' | 'boarding' | 'cancelled' | 'scheduled'

// 时间范围类型
export type TimeRange = '1h' | '6h' | '24h' | '7d' | '30d'

// 航班数据类型
export interface Flight {
  id: string
  route: string
  departure: string
  arrival: string
  status: FlightStatus
  statusText: string
  aircraft: string
  passengers: string
  gate: string
}

// 统计数据类型
export interface Stats {
  todayFlights: number
  totalPassengers: number
  onTimeRate: number
  revenue: number
  flightChange: string
  passengerChange: string
  onTimeChange: string
  revenueChange: string
}

// 活动数据类型
export interface Activity {
  id: number
  type: string
  title: string
  description: string
  time: string
  color: string
  bgColor: string
}

// 仪表板状态接口
interface DashboardState {
  // 数据状态
  flights: Flight[]
  stats: Stats | null
  activities: Activity[]
  lastUpdated: Date | null
  
  // UI状态
  sidebarCollapsed: boolean
  selectedTimeRange: TimeRange
  isLoading: boolean
  error: string | null
  
  // 数据操作方法
  setFlights: (flights: Flight[]) => void
  setStats: (stats: Stats) => void
  setActivities: (activities: Activity[]) => void
  updateLastUpdated: () => void
  
  // UI操作方法
  toggleSidebar: () => void
  setTimeRange: (range: TimeRange) => void
  setLoading: (loading: boolean) => void
  setError: (error: string | null) => void
  
  // 数据获取方法
  fetchFlights: () => Promise<void>
  fetchStats: () => Promise<void>
  fetchActivities: () => Promise<void>
  refreshAllData: () => Promise<void>
}

// 创建Zustand store
export const useDashboardStore = create<DashboardState>()(
  devtools(
    persist(
      (set, get) => ({
        // 初始状态
        flights: [],
        stats: null,
        activities: [],
        lastUpdated: null,
        sidebarCollapsed: false,
        selectedTimeRange: '24h',
        isLoading: false,
        error: null,
        
        // 数据操作方法
        setFlights: (flights) => set({ flights }, false, 'setFlights'),
        setStats: (stats) => set({ stats }, false, 'setStats'),
        setActivities: (activities) => set({ activities }, false, 'setActivities'),
        updateLastUpdated: () => set({ lastUpdated: new Date() }, false, 'updateLastUpdated'),
        
        // UI操作方法
        toggleSidebar: () => set(
          (state) => ({ sidebarCollapsed: !state.sidebarCollapsed }),
          false,
          'toggleSidebar'
        ),
        setTimeRange: (range) => set({ selectedTimeRange: range }, false, 'setTimeRange'),
        setLoading: (loading) => set({ isLoading: loading }, false, 'setLoading'),
        setError: (error) => set({ error }, false, 'setError'),
        
        // 模拟API调用方法
        fetchFlights: async () => {
          set({ isLoading: true, error: null }, false, 'fetchFlights:start')
          try {
            // 模拟网络延迟
            await new Promise(resolve => setTimeout(resolve, 1000))
            
            // 模拟航班数据
            const mockFlights: Flight[] = [
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
              }
            ]
            
            set({ 
              flights: mockFlights, 
              isLoading: false, 
              lastUpdated: new Date() 
            }, false, 'fetchFlights:success')
          } catch (error) {
            set({ 
              error: error instanceof Error ? error.message : '获取航班数据失败',
              isLoading: false 
            }, false, 'fetchFlights:error')
          }
        },
        
        fetchStats: async () => {
          set({ isLoading: true, error: null }, false, 'fetchStats:start')
          try {
            await new Promise(resolve => setTimeout(resolve, 500))
            
            const mockStats: Stats = {
              todayFlights: 247,
              totalPassengers: 45231,
              onTimeRate: 94.5,
              revenue: 2400000,
              flightChange: '+12%',
              passengerChange: '+8.2%',
              onTimeChange: '+2.1%',
              revenueChange: '-1.3%'
            }
            
            set({ 
              stats: mockStats, 
              isLoading: false, 
              lastUpdated: new Date() 
            }, false, 'fetchStats:success')
          } catch (error) {
            set({ 
              error: error instanceof Error ? error.message : '获取统计数据失败',
              isLoading: false 
            }, false, 'fetchStats:error')
          }
        },
        
        fetchActivities: async () => {
          set({ isLoading: true, error: null }, false, 'fetchActivities:start')
          try {
            await new Promise(resolve => setTimeout(resolve, 800))
            
            const mockActivities: Activity[] = [
              {
                id: 1,
                type: 'flight',
                title: '航班 CA1234 已起飞',
                description: '北京 → 上海，预计11:15到达',
                time: '2分钟前',
                color: 'text-blue-400',
                bgColor: 'bg-blue-500/10'
              },
              {
                id: 2,
                type: 'passenger',
                title: '新增乘客登记',
                description: '156名乘客完成登机手续',
                time: '5分钟前',
                color: 'text-green-400',
                bgColor: 'bg-green-500/10'
              },
              {
                id: 3,
                type: 'alert',
                title: '天气预警',
                description: '上海地区有雷暴天气，可能影响航班',
                time: '8分钟前',
                color: 'text-yellow-400',
                bgColor: 'bg-yellow-500/10'
              }
            ]
            
            set({ 
              activities: mockActivities, 
              isLoading: false, 
              lastUpdated: new Date() 
            }, false, 'fetchActivities:success')
          } catch (error) {
            set({ 
              error: error instanceof Error ? error.message : '获取活动数据失败',
              isLoading: false 
            }, false, 'fetchActivities:error')
          }
        },
        
        refreshAllData: async () => {
          const { fetchFlights, fetchStats, fetchActivities } = get()
          set({ isLoading: true, error: null }, false, 'refreshAllData:start')
          
          try {
            await Promise.all([
              fetchFlights(),
              fetchStats(),
              fetchActivities()
            ])
            set({ isLoading: false }, false, 'refreshAllData:success')
          } catch (error) {
            set({ 
              error: error instanceof Error ? error.message : '刷新数据失败',
              isLoading: false 
            }, false, 'refreshAllData:error')
          }
        }
      }),
      {
        name: 'dashboard-storage', // 本地存储键名
        partialize: (state) => ({
          // 只持久化UI状态，不持久化数据
          sidebarCollapsed: state.sidebarCollapsed,
          selectedTimeRange: state.selectedTimeRange,
        }),
      }
    ),
    {
      name: 'dashboard-store', // DevTools中显示的名称
    }
  )
)

// 导出类型，供其他模块使用
export type { DashboardState }