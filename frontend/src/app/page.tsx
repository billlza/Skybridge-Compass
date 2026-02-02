'use client';

import StatusCard from '@/components/dashboard/StatusCard';
import WeatherWidget from '@/components/dashboard/WeatherWidget';
import DeviceDiscovery from '@/components/dashboard/DeviceDiscovery';
import { Laptop, MessageSquare, Briefcase, CheckCircle2 } from 'lucide-react';
import AppShell from '@/components/layout/AppShell';

export default function Home() {
  return (
    <AppShell>
      <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-6 max-w-7xl mx-auto">
        
        {/* Top Row Stats */}
        <StatusCard 
          title="在线设备" 
          value="0" 
          icon={<Laptop className="w-5 h-5" />} 
          statusColor="blue"
        />
        <StatusCard 
          title="活跃会话" 
          value="0" 
          icon={<MessageSquare className="w-5 h-5" />} 
          statusColor="green"
        />
        <StatusCard 
          title="传输任务" 
          value="0" 
          icon={<Briefcase className="w-5 h-5" />} 
          statusColor="yellow"
        />
        <StatusCard 
          title="系统状态" 
          value="极佳" 
          icon={<CheckCircle2 className="w-5 h-5" />} 
          statusText="Running Smoothly"
          statusColor="green"
        />

        {/* Middle Row: Weather takes full width */}
        <WeatherWidget />

        {/* Bottom Row: Device Discovery & Remote Session Placeholder */}
        <DeviceDiscovery />

        <div className="glass-panel p-6 rounded-3xl col-span-full md:col-span-2 min-h-[300px] flex flex-col">
            <div className="flex items-center gap-2 mb-6">
                <Laptop className="w-5 h-5 text-white" />
                <h3 className="font-bold text-lg">远程会话</h3>
            </div>
            <div className="flex-1 flex items-center justify-center">
                <div className="w-12 h-12 border-4 border-slate-700 border-t-accent rounded-full animate-spin" />
            </div>
        </div>

      </div>
    </AppShell>
  );
}
