import { ReactNode } from 'react';
import { cn } from '@/lib/utils';

interface StatusCardProps {
  title: string;
  value: string | number;
  statusText?: string;
  statusColor?: 'green' | 'red' | 'yellow' | 'blue';
  icon: ReactNode;
  className?: string;
}

export default function StatusCard({ title, value, statusText, statusColor = 'blue', icon, className }: StatusCardProps) {
  const colorMap = {
    green: 'text-green-500 bg-green-500/10 border-green-500/20',
    red: 'text-red-500 bg-red-500/10 border-red-500/20',
    yellow: 'text-yellow-500 bg-yellow-500/10 border-yellow-500/20',
    blue: 'text-blue-500 bg-blue-500/10 border-blue-500/20',
  };

  return (
    <div className={cn("glass-panel p-6 rounded-2xl flex flex-col justify-between relative overflow-hidden group hover:bg-white/5 transition-all", className)}>
      <div className="flex items-start justify-between z-10">
        <span className="text-slate-400 text-sm font-medium">{title}</span>
        <div className={cn("p-2 rounded-lg", colorMap[statusColor].replace('text-', 'text-opacity-80 '))}>
            {icon}
        </div>
      </div>
      
      <div className="mt-4 z-10">
        <div className="text-3xl font-bold">{value}</div>
        {statusText && <div className={cn("text-xs font-medium mt-1", colorMap[statusColor].split(' ')[0])}>{statusText}</div>}
      </div>

      {/* Decorative background glow */}
      <div className={cn("absolute -bottom-4 -right-4 w-24 h-24 rounded-full blur-3xl opacity-20 group-hover:opacity-40 transition-opacity", 
        statusColor === 'green' ? 'bg-green-500' : 
        statusColor === 'red' ? 'bg-red-500' :
        statusColor === 'yellow' ? 'bg-yellow-500' : 'bg-blue-500'
      )} />
    </div>
  );
}




