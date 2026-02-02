import { Search, Loader2, Monitor, Info, Link2 } from 'lucide-react';

export default function DeviceDiscovery() {
  return (
    <div className="glass-panel p-6 rounded-3xl col-span-full md:col-span-2 relative overflow-hidden min-h-[300px]">
      
      {/* Header */}
      <div className="flex items-center justify-between mb-6">
        <div className="flex items-center gap-2">
            <Search className="w-5 h-5 text-white" />
            <h3 className="font-bold text-lg">发现设备</h3>
        </div>
        <div className="flex items-center gap-2 text-xs text-slate-400">
            <Loader2 className="w-4 h-4 animate-spin text-accent" />
            扫描中...
        </div>
      </div>

      {/* Controls */}
      <div className="flex flex-wrap items-center gap-3 mb-6">
        <div className="flex items-center gap-2 text-xs font-medium text-slate-300 mr-2">
            兼容/
            <br />
            更多
            <br />
            设备
            <div className="w-12 h-6 bg-blue-500 rounded-full relative cursor-pointer ml-1">
                <div className="absolute right-1 top-1 w-4 h-4 bg-white rounded-full shadow-sm" />
            </div>
        </div>

        <button className="px-4 py-2 bg-white/5 hover:bg-white/10 rounded-lg text-sm font-medium transition-colors">
            扩展搜索
        </button>
        <button className="px-4 py-2 bg-white/5 hover:bg-white/10 rounded-lg text-sm font-medium transition-colors">
            手动连接
        </button>
        <div className="relative flex-1 min-w-[140px]">
            <Search className="absolute left-3 top-2.5 w-4 h-4 text-slate-400" />
            <input 
                type="text" 
                placeholder="搜索设备..." 
                className="w-full bg-black/20 border border-white/5 rounded-full pl-9 pr-4 py-2 text-sm focus:outline-none focus:ring-1 focus:ring-accent/50"
            />
        </div>
        <button className="w-9 h-9 flex items-center justify-center bg-white/5 rounded-full hover:bg-white/10">
            <Monitor className="w-4 h-4" />
        </button>
      </div>

      {/* Device List */}
      <div className="bg-black/20 border border-white/5 rounded-xl p-4 flex items-center justify-between group hover:bg-black/30 transition-colors cursor-pointer">
        <div className="flex items-center gap-4">
            <div className="w-12 h-12 rounded-lg bg-slate-800 flex items-center justify-center">
                <Monitor className="text-slate-400 w-6 h-6" />
            </div>
            <div>
                <div className="flex items-center gap-2">
                    <h4 className="font-bold text-white">Lza 的 MacBook Pro</h4>
                    <span className="w-2 h-2 rounded-full bg-red-500" />
                </div>
                <p className="text-xs text-slate-500">未知 IP</p>
            </div>
        </div>
        
        <div className="text-right">
            <div className="text-red-500 text-xs font-medium mb-2 opacity-0 group-hover:opacity-100 transition-opacity flex items-center justify-end gap-1">
               0 个服务 <div className="w-1.5 h-1.5 rounded-full bg-red-500" />
            </div>
            <button className="flex items-center gap-2 px-3 py-1.5 bg-blue-600 hover:bg-blue-500 rounded-lg text-xs font-bold text-white transition-colors">
                <Link2 className="w-3 h-3" />
                device.action.connect
            </button>
        </div>
      </div>
       <div className="mt-2 pl-2">
          <button className="text-xs text-slate-500 flex items-center gap-1 hover:text-slate-300">
             <Info className="w-3 h-3" /> 服务
          </button>
       </div>

    </div>
  );
}




