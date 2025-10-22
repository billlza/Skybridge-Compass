import React, { useState, useEffect, useCallback } from 'react';
import { 
  Search, 
  Wifi, 
  WifiOff, 
  Plus, 
  RefreshCw, 
  Monitor, 
  Smartphone, 
  Tablet, 
  Server,
  AlertCircle,
  CheckCircle,
  Clock,
  Settings
} from 'lucide-react';
import { deviceDiscovery, DeviceStatus, DeviceType } from '../services/discovery';

// 设备图标映射
const DeviceIcons = {
  [DeviceType.MACOS]: Monitor,
  [DeviceType.IOS]: Smartphone,
  [DeviceType.IPADOS]: Tablet,
  [DeviceType.ANDROID]: Smartphone,
  [DeviceType.WINDOWS]: Monitor,
  [DeviceType.LINUX]: Server,
};

// 状态图标映射
const StatusIcons = {
  [DeviceStatus.ONLINE]: CheckCircle,
  [DeviceStatus.OFFLINE]: AlertCircle,
  [DeviceStatus.CONNECTING]: Clock,
  [DeviceStatus.UNKNOWN]: AlertCircle,
};

// 状态颜色映射
const StatusColors = {
  [DeviceStatus.ONLINE]: 'text-green-500',
  [DeviceStatus.OFFLINE]: 'text-red-500',
  [DeviceStatus.CONNECTING]: 'text-yellow-500',
  [DeviceStatus.UNKNOWN]: 'text-gray-500',
};

/**
 * 设备卡片组件
 */
const DeviceCard = ({ device, onConnect, onRemove }) => {
  const DeviceIcon = DeviceIcons[device.type] || Monitor;
  const StatusIcon = StatusIcons[device.status] || AlertCircle;
  const statusColor = StatusColors[device.status] || 'text-gray-500';

  const handleConnect = () => {
    onConnect && onConnect(device);
  };

  const handleRemove = (e) => {
    e.stopPropagation();
    onRemove && onRemove(device);
  };

  return (
    <div 
      className="bg-white dark:bg-gray-800 rounded-lg shadow-md p-4 border border-gray-200 dark:border-gray-700 hover:shadow-lg transition-shadow cursor-pointer"
      onClick={handleConnect}
    >
      <div className="flex items-start justify-between mb-3">
        <div className="flex items-center space-x-3">
          <div className="p-2 bg-blue-100 dark:bg-blue-900 rounded-lg">
            <DeviceIcon className="w-6 h-6 text-blue-600 dark:text-blue-400" />
          </div>
          <div>
            <h3 className="font-semibold text-gray-900 dark:text-white">
              {device.name}
            </h3>
            <p className="text-sm text-gray-500 dark:text-gray-400">
              {device.getDisplayName()}
            </p>
          </div>
        </div>
        <div className="flex items-center space-x-2">
          <StatusIcon className={`w-4 h-4 ${statusColor}`} />
          <button
            onClick={handleRemove}
            className="text-gray-400 hover:text-red-500 transition-colors"
            title="移除设备"
          >
            ×
          </button>
        </div>
      </div>

      <div className="space-y-2 text-sm text-gray-600 dark:text-gray-300">
        <div className="flex justify-between">
          <span>地址:</span>
          <span className="font-mono">{device.address}:{device.port}</span>
        </div>
        
        {device.services.length > 0 && (
          <div className="flex justify-between">
            <span>服务:</span>
            <span className="text-xs bg-gray-100 dark:bg-gray-700 px-2 py-1 rounded">
              {device.services.length} 个
            </span>
          </div>
        )}

        <div className="flex justify-between">
          <span>最后发现:</span>
          <span className="text-xs">
            {new Date(device.lastSeen).toLocaleTimeString()}
          </span>
        </div>

        {device.natType && device.natType !== 'unknown' && (
          <div className="flex justify-between">
            <span>NAT类型:</span>
            <span className="text-xs bg-yellow-100 dark:bg-yellow-900 text-yellow-800 dark:text-yellow-200 px-2 py-1 rounded">
              {device.natType}
            </span>
          </div>
        )}
      </div>

      {device.capabilities.length > 0 && (
        <div className="mt-3 pt-3 border-t border-gray-200 dark:border-gray-600">
          <div className="flex flex-wrap gap-1">
            {device.capabilities.map((capability, index) => (
              <span
                key={index}
                className="text-xs bg-blue-100 dark:bg-blue-900 text-blue-800 dark:text-blue-200 px-2 py-1 rounded"
              >
                {capability}
              </span>
            ))}
          </div>
        </div>
      )}
    </div>
  );
};

/**
 * 手动添加设备对话框
 */
const AddDeviceDialog = ({ isOpen, onClose, onAdd }) => {
  const [address, setAddress] = useState('');
  const [port, setPort] = useState('3000');
  const [name, setName] = useState('');
  const [isAdding, setIsAdding] = useState(false);

  const handleSubmit = async (e) => {
    e.preventDefault();
    if (!address.trim()) return;

    setIsAdding(true);
    try {
      await onAdd(address.trim(), parseInt(port) || 3000, name.trim());
      setAddress('');
      setPort('3000');
      setName('');
      onClose();
    } catch (error) {
      console.error('添加设备失败:', error);
      alert('添加设备失败: ' + error.message);
    } finally {
      setIsAdding(false);
    }
  };

  if (!isOpen) return null;

  return (
    <div className="fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center z-50">
      <div className="bg-white dark:bg-gray-800 rounded-lg p-6 w-full max-w-md mx-4">
        <h2 className="text-xl font-semibold mb-4 text-gray-900 dark:text-white">
          手动添加设备
        </h2>
        
        <form onSubmit={handleSubmit} className="space-y-4">
          <div>
            <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
              IP地址 *
            </label>
            <input
              type="text"
              value={address}
              onChange={(e) => setAddress(e.target.value)}
              placeholder="192.168.1.100"
              className="w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-md focus:outline-none focus:ring-2 focus:ring-blue-500 dark:bg-gray-700 dark:text-white"
              required
            />
          </div>

          <div>
            <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
              端口
            </label>
            <input
              type="number"
              value={port}
              onChange={(e) => setPort(e.target.value)}
              placeholder="3000"
              min="1"
              max="65535"
              className="w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-md focus:outline-none focus:ring-2 focus:ring-blue-500 dark:bg-gray-700 dark:text-white"
            />
          </div>

          <div>
            <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
              设备名称 (可选)
            </label>
            <input
              type="text"
              value={name}
              onChange={(e) => setName(e.target.value)}
              placeholder="我的设备"
              className="w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-md focus:outline-none focus:ring-2 focus:ring-blue-500 dark:bg-gray-700 dark:text-white"
            />
          </div>

          <div className="flex space-x-3 pt-4">
            <button
              type="button"
              onClick={onClose}
              className="flex-1 px-4 py-2 text-gray-700 dark:text-gray-300 bg-gray-100 dark:bg-gray-700 rounded-md hover:bg-gray-200 dark:hover:bg-gray-600 transition-colors"
            >
              取消
            </button>
            <button
              type="submit"
              disabled={isAdding || !address.trim()}
              className="flex-1 px-4 py-2 bg-blue-600 text-white rounded-md hover:bg-blue-700 disabled:opacity-50 disabled:cursor-not-allowed transition-colors"
            >
              {isAdding ? '添加中...' : '添加'}
            </button>
          </div>
        </form>
      </div>
    </div>
  );
};

/**
 * 设备发现主组件
 */
const DeviceDiscovery = ({ onDeviceConnect }) => {
  const [devices, setDevices] = useState([]);
  const [isScanning, setIsScanning] = useState(false);
  const [showAddDialog, setShowAddDialog] = useState(false);
  const [searchTerm, setSearchTerm] = useState('');
  const [filterStatus, setFilterStatus] = useState('all');

  // 设备发现事件处理
  const handleDiscoveryEvent = useCallback((event, data) => {
    switch (event) {
      case 'discoveryStarted':
        setIsScanning(true);
        break;
      case 'discoveryStopped':
        setIsScanning(false);
        break;
      case 'deviceAdded':
      case 'deviceUpdated':
        setDevices(prev => {
          const index = prev.findIndex(d => d.id === data.id);
          if (index >= 0) {
            const newDevices = [...prev];
            newDevices[index] = data;
            return newDevices;
          } else {
            return [...prev, data];
          }
        });
        break;
      case 'deviceRemoved':
        setDevices(prev => prev.filter(d => d.id !== data.id));
        break;
    }
  }, []);

  // 初始化设备发现服务
  useEffect(() => {
    const unsubscribe = deviceDiscovery.addListener(handleDiscoveryEvent);
    
    // 获取当前设备列表
    setDevices(deviceDiscovery.getDevices());
    
    // 自动开始发现
    deviceDiscovery.startDiscovery();

    return () => {
      unsubscribe();
      deviceDiscovery.stopDiscovery();
    };
  }, [handleDiscoveryEvent]);

  // 过滤设备
  const filteredDevices = devices.filter(device => {
    const matchesSearch = device.name.toLowerCase().includes(searchTerm.toLowerCase()) ||
                         device.address.includes(searchTerm);
    
    const matchesStatus = filterStatus === 'all' || device.status === filterStatus;
    
    return matchesSearch && matchesStatus;
  });

  // 处理设备连接
  const handleDeviceConnect = (device) => {
    onDeviceConnect && onDeviceConnect(device);
  };

  // 处理设备移除
  const handleDeviceRemove = (device) => {
    if (confirm(`确定要移除设备 "${device.name}" 吗？`)) {
      deviceDiscovery.removeDevice(device.id);
    }
  };

  // 处理手动添加设备
  const handleAddDevice = async (address, port, name) => {
    await deviceDiscovery.addManualDevice(address, port, name);
  };

  // 刷新设备列表
  const handleRefresh = () => {
    deviceDiscovery.refresh();
  };

  // 切换扫描状态
  const toggleScanning = () => {
    if (isScanning) {
      deviceDiscovery.stopDiscovery();
    } else {
      deviceDiscovery.startDiscovery();
    }
  };

  return (
    <div className="space-y-6">
      {/* 头部控制栏 */}
      <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between space-y-4 sm:space-y-0">
        <div className="flex items-center space-x-3">
          <h2 className="text-2xl font-bold text-gray-900 dark:text-white">
            设备发现
          </h2>
          <div className="flex items-center space-x-2">
            {isScanning ? (
              <Wifi className="w-5 h-5 text-green-500 animate-pulse" />
            ) : (
              <WifiOff className="w-5 h-5 text-gray-400" />
            )}
            <span className="text-sm text-gray-500 dark:text-gray-400">
              {isScanning ? '正在扫描...' : '已停止'}
            </span>
          </div>
        </div>

        <div className="flex items-center space-x-2">
          <button
            onClick={toggleScanning}
            className={`px-4 py-2 rounded-md transition-colors ${
              isScanning
                ? 'bg-red-600 hover:bg-red-700 text-white'
                : 'bg-green-600 hover:bg-green-700 text-white'
            }`}
          >
            {isScanning ? '停止扫描' : '开始扫描'}
          </button>
          
          <button
            onClick={handleRefresh}
            className="p-2 text-gray-600 dark:text-gray-400 hover:text-gray-900 dark:hover:text-white transition-colors"
            title="刷新"
          >
            <RefreshCw className="w-5 h-5" />
          </button>

          <button
            onClick={() => setShowAddDialog(true)}
            className="p-2 text-gray-600 dark:text-gray-400 hover:text-gray-900 dark:hover:text-white transition-colors"
            title="手动添加设备"
          >
            <Plus className="w-5 h-5" />
          </button>
        </div>
      </div>

      {/* 搜索和过滤 */}
      <div className="flex flex-col sm:flex-row space-y-4 sm:space-y-0 sm:space-x-4">
        <div className="flex-1 relative">
          <Search className="absolute left-3 top-1/2 transform -translate-y-1/2 w-4 h-4 text-gray-400" />
          <input
            type="text"
            placeholder="搜索设备名称或IP地址..."
            value={searchTerm}
            onChange={(e) => setSearchTerm(e.target.value)}
            className="w-full pl-10 pr-4 py-2 border border-gray-300 dark:border-gray-600 rounded-md focus:outline-none focus:ring-2 focus:ring-blue-500 dark:bg-gray-700 dark:text-white"
          />
        </div>

        <select
          value={filterStatus}
          onChange={(e) => setFilterStatus(e.target.value)}
          className="px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-md focus:outline-none focus:ring-2 focus:ring-blue-500 dark:bg-gray-700 dark:text-white"
        >
          <option value="all">所有状态</option>
          <option value={DeviceStatus.ONLINE}>在线</option>
          <option value={DeviceStatus.OFFLINE}>离线</option>
          <option value={DeviceStatus.CONNECTING}>连接中</option>
        </select>
      </div>

      {/* 设备统计 */}
      <div className="grid grid-cols-2 sm:grid-cols-4 gap-4">
        <div className="bg-white dark:bg-gray-800 p-4 rounded-lg border border-gray-200 dark:border-gray-700">
          <div className="text-2xl font-bold text-gray-900 dark:text-white">
            {devices.length}
          </div>
          <div className="text-sm text-gray-500 dark:text-gray-400">
            总设备数
          </div>
        </div>
        
        <div className="bg-white dark:bg-gray-800 p-4 rounded-lg border border-gray-200 dark:border-gray-700">
          <div className="text-2xl font-bold text-green-600">
            {devices.filter(d => d.status === DeviceStatus.ONLINE).length}
          </div>
          <div className="text-sm text-gray-500 dark:text-gray-400">
            在线设备
          </div>
        </div>
        
        <div className="bg-white dark:bg-gray-800 p-4 rounded-lg border border-gray-200 dark:border-gray-700">
          <div className="text-2xl font-bold text-red-600">
            {devices.filter(d => d.status === DeviceStatus.OFFLINE).length}
          </div>
          <div className="text-sm text-gray-500 dark:text-gray-400">
            离线设备
          </div>
        </div>
        
        <div className="bg-white dark:bg-gray-800 p-4 rounded-lg border border-gray-200 dark:border-gray-700">
          <div className="text-2xl font-bold text-yellow-600">
            {devices.filter(d => d.status === DeviceStatus.CONNECTING).length}
          </div>
          <div className="text-sm text-gray-500 dark:text-gray-400">
            连接中
          </div>
        </div>
      </div>

      {/* 设备列表 */}
      <div className="space-y-4">
        {filteredDevices.length === 0 ? (
          <div className="text-center py-12">
            <Search className="w-12 h-12 text-gray-400 mx-auto mb-4" />
            <h3 className="text-lg font-medium text-gray-900 dark:text-white mb-2">
              {devices.length === 0 ? '未发现设备' : '没有匹配的设备'}
            </h3>
            <p className="text-gray-500 dark:text-gray-400 mb-4">
              {devices.length === 0 
                ? '请确保设备在同一网络中，或手动添加设备'
                : '尝试调整搜索条件或过滤器'
              }
            </p>
            {devices.length === 0 && (
              <button
                onClick={() => setShowAddDialog(true)}
                className="inline-flex items-center px-4 py-2 bg-blue-600 text-white rounded-md hover:bg-blue-700 transition-colors"
              >
                <Plus className="w-4 h-4 mr-2" />
                手动添加设备
              </button>
            )}
          </div>
        ) : (
          <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
            {filteredDevices.map(device => (
              <DeviceCard
                key={device.id}
                device={device}
                onConnect={handleDeviceConnect}
                onRemove={handleDeviceRemove}
              />
            ))}
          </div>
        )}
      </div>

      {/* 手动添加设备对话框 */}
      <AddDeviceDialog
        isOpen={showAddDialog}
        onClose={() => setShowAddDialog(false)}
        onAdd={handleAddDevice}
      />
    </div>
  );
};

export default DeviceDiscovery;