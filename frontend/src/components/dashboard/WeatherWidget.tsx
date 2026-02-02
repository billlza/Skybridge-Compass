import { CloudSun, Wind, Droplets, Eye, Gauge } from 'lucide-react';

export default function WeatherWidget() {
  return (
    <div className="glass-panel p-8 rounded-3xl relative overflow-hidden col-span-full">
      {/* Background Gradient & Stars */}
      <div className="absolute inset-0 bg-gradient-to-br from-indigo-900/30 to-purple-900/30 -z-10" />
      <div className="absolute inset-0 opacity-30" style={{ backgroundImage: 'radial-gradient(white 1px, transparent 1px)', backgroundSize: '50px 50px' }}></div>

      <div className="flex flex-col md:flex-row md:items-center justify-between gap-8 z-10 relative">
        
        {/* Main Info */}
        <div className="flex items-center gap-6">
            <CloudSun className="w-24 h-24 text-yellow-400" />
            <div>
                <div className="flex items-center gap-2 text-blue-300 font-medium mb-1">
                    <span className="text-blue-400">1</span> Tianjin
                </div>
                <div className="text-lg text-slate-300 font-medium">晴朗</div>
                <div className="text-6xl font-thin text-white mt-2">11°</div>
                <div className="text-xs text-slate-500 mt-2">(t) wttr.in + AQI</div>
            </div>
        </div>

        {/* Stats Grid */}
        <div className="grid grid-cols-2 gap-x-12 gap-y-6">
            <div className="flex items-center gap-3">
                <Droplets className="text-blue-400 w-5 h-5" />
                <div>
                    <div className="text-xs text-slate-400">湿度</div>
                    <div className="font-bold">16%</div>
                </div>
            </div>
            <div className="flex items-center gap-3">
                <Wind className="text-green-400 w-5 h-5" />
                <div>
                    <div className="text-xs text-slate-400">风速</div>
                    <div className="font-bold">36km/h</div>
                </div>
            </div>
            <div className="flex items-center gap-3">
                <Eye className="text-purple-400 w-5 h-5" />
                <div>
                    <div className="text-xs text-slate-400">能见度</div>
                    <div className="font-bold">10km</div>
                </div>
            </div>
            <div className="flex items-center gap-3">
                <Gauge className="text-yellow-400 w-5 h-5" />
                <div>
                    <div className="text-xs text-slate-400">AQI</div>
                    <div className="font-bold">50</div>
                </div>
            </div>
        </div>
      </div>
      
      <div className="absolute top-4 right-4 p-2 hover:bg-white/10 rounded-full cursor-pointer transition-colors text-slate-400">
        <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M21 12a9 9 0 0 0-9-9 9.75 9.75 0 0 0-6.74 2.74L3 8"/><path d="M3 3v5h5"/><path d="M3 12a9 9 0 0 0 9 9 9.75 9.75 0 0 0 6.74-2.74L21 16"/><path d="M16 16h5v5"/></svg>
      </div>
    </div>
  );
}




