'use client'

import { Sidebar } from '../layout/sidebar'
import { Header } from '../layout/header'
import { StatsCards } from './stats-cards'
import ChartsSection from './charts-section'
import DataTable from './data-table'
import ActivityFeed from './activity-feed'

export default function Dashboard() {
  return (
    <div className="flex h-screen bg-gray-50">
      {/* 侧边栏 */}
      <Sidebar />
      
      {/* 主内容区域 */}
      <div className="flex-1 flex flex-col overflow-hidden">
        {/* 头部 */}
        <Header />
        
        {/* 主内容 */}
        <main className="flex-1 overflow-x-hidden overflow-y-auto bg-gray-50 p-6">
          <div className="max-w-7xl mx-auto">
            {/* 统计卡片 */}
            <StatsCards />
            
            {/* 图表区域 */}
            <ChartsSection />
            
            {/* 数据表格和活动动态 */}
            <div className="grid grid-cols-1 lg:grid-cols-2 gap-6 mt-6">
              <DataTable />
              <ActivityFeed />
            </div>
          </div>
        </main>
      </div>
    </div>
  )
}