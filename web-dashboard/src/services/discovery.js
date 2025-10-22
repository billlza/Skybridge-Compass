/**
 * SkyBridge 设备发现服务
 * 
 * 实现Web端的设备发现功能，通过多种方式发现局域网内的SkyBridge设备：
 * 1. 本地发现代理 (推荐)
 * 2. WebRTC ICE 候选发现
 * 3. 手动设备添加
 */

// 设备类型定义
export const DeviceType = {
  MACOS: 'macOS',
  IOS: 'iOS',
  IPADOS: 'iPadOS',
  ANDROID: 'Android',
  WINDOWS: 'Windows',
  LINUX: 'Linux'
};

// 设备状态
export const DeviceStatus = {
  ONLINE: 'online',
  OFFLINE: 'offline',
  CONNECTING: 'connecting',
  UNKNOWN: 'unknown'
};

// NAT穿透难度
export const TraversalDifficulty = {
  EASY: 'easy',
  MEDIUM: 'medium',
  HARD: 'hard',
  UNKNOWN: 'unknown'
};

/**
 * 发现的设备信息
 */
export class DiscoveredDevice {
  constructor(data) {
    this.id = data.id || this.generateDeviceId(data);
    this.name = data.name || 'Unknown Device';
    this.type = data.type || DeviceType.UNKNOWN;
    this.address = data.address;
    this.port = data.port || 3000;
    this.services = data.services || [];
    this.capabilities = data.capabilities || [];
    this.lastSeen = data.lastSeen || new Date();
    this.status = data.status || DeviceStatus.UNKNOWN;
    this.natType = data.natType || 'unknown';
    this.traversalDifficulty = data.traversalDifficulty || TraversalDifficulty.UNKNOWN;
    this.metadata = data.metadata || {};
  }

  generateDeviceId(data) {
    // 基于设备信息生成唯一ID
    const identifier = `${data.address}:${data.port}:${data.name}`;
    return btoa(identifier).replace(/[^a-zA-Z0-9]/g, '').substring(0, 16);
  }

  getDisplayName() {
    const typeMap = {
      [DeviceType.MACOS]: 'Mac',
      [DeviceType.IOS]: 'iPhone',
      [DeviceType.IPADOS]: 'iPad',
      [DeviceType.ANDROID]: 'Android',
      [DeviceType.WINDOWS]: 'Windows',
      [DeviceType.LINUX]: 'Linux'
    };
    return typeMap[this.type] || this.type;
  }

  getIconName() {
    const iconMap = {
      [DeviceType.MACOS]: 'desktopcomputer',
      [DeviceType.IOS]: 'iphone',
      [DeviceType.IPADOS]: 'ipad',
      [DeviceType.ANDROID]: 'smartphone',
      [DeviceType.WINDOWS]: 'pc',
      [DeviceType.LINUX]: 'server.rack'
    };
    return iconMap[this.type] || 'device';
  }

  isOnline() {
    return this.status === DeviceStatus.ONLINE;
  }

  updateLastSeen() {
    this.lastSeen = new Date();
  }
}

/**
 * 设备发现服务
 */
export class DeviceDiscoveryService {
  constructor() {
    this.devices = new Map();
    this.listeners = new Set();
    this.isScanning = false;
    this.scanInterval = null;
    this.websocket = null;
    
    // 配置
    this.config = {
      localProxyUrl: 'http://localhost:3001',
      websocketUrl: 'ws://localhost:3001/ws',
      scanIntervalMs: 5000,
      deviceTimeoutMs: 30000,
      stunServers: [
        'stun:stun.l.google.com:19302',
        'stun:stun1.l.google.com:19302',
        'stun:stun.cloudflare.com:3478'
      ]
    };
  }

  /**
   * 添加设备变化监听器
   */
  addListener(callback) {
    this.listeners.add(callback);
    return () => this.listeners.delete(callback);
  }

  /**
   * 通知所有监听器
   */
  notifyListeners(event, data) {
    this.listeners.forEach(callback => {
      try {
        callback(event, data);
      } catch (error) {
        console.error('设备发现监听器错误:', error);
      }
    });
  }

  /**
   * 开始设备发现
   */
  async startDiscovery() {
    if (this.isScanning) {
      console.log('设备发现已在运行中');
      return;
    }

    console.log('开始设备发现...');
    this.isScanning = true;

    // 尝试连接本地发现代理
    await this.connectToLocalProxy();

    // 启动定期扫描
    this.scanInterval = setInterval(() => {
      this.performDiscoveryScan();
    }, this.config.scanIntervalMs);

    // 立即执行一次扫描
    await this.performDiscoveryScan();

    this.notifyListeners('discoveryStarted', {});
  }

  /**
   * 停止设备发现
   */
  stopDiscovery() {
    if (!this.isScanning) {
      return;
    }

    console.log('停止设备发现...');
    this.isScanning = false;

    if (this.scanInterval) {
      clearInterval(this.scanInterval);
      this.scanInterval = null;
    }

    if (this.websocket) {
      this.websocket.close();
      this.websocket = null;
    }

    this.notifyListeners('discoveryStopped', {});
  }

  /**
   * 连接到本地发现代理
   */
  async connectToLocalProxy() {
    try {
      // 检查本地代理是否可用
      const response = await fetch(`${this.config.localProxyUrl}/api/health`, {
        method: 'GET',
        timeout: 2000
      });

      if (response.ok) {
        console.log('本地发现代理连接成功');
        await this.setupWebSocket();
        return true;
      }
    } catch (error) {
      console.warn('本地发现代理不可用，使用备用方案:', error.message);
    }
    return false;
  }

  /**
   * 设置WebSocket连接
   */
  async setupWebSocket() {
    try {
      this.websocket = new WebSocket(this.config.websocketUrl);
      
      this.websocket.onopen = () => {
        console.log('WebSocket连接已建立');
        // 请求设备列表
        this.websocket.send(JSON.stringify({ type: 'requestDevices' }));
      };

      this.websocket.onmessage = (event) => {
        try {
          const message = JSON.parse(event.data);
          this.handleWebSocketMessage(message);
        } catch (error) {
          console.error('WebSocket消息解析错误:', error);
        }
      };

      this.websocket.onclose = () => {
        console.log('WebSocket连接已关闭');
        this.websocket = null;
      };

      this.websocket.onerror = (error) => {
        console.error('WebSocket错误:', error);
      };

    } catch (error) {
      console.error('WebSocket连接失败:', error);
    }
  }

  /**
   * 处理WebSocket消息
   */
  handleWebSocketMessage(message) {
    switch (message.type) {
      case 'deviceList':
        this.updateDevicesFromProxy(message.devices);
        break;
      case 'deviceAdded':
        this.addDevice(new DiscoveredDevice(message.device));
        break;
      case 'deviceRemoved':
        this.removeDevice(message.deviceId);
        break;
      case 'deviceUpdated':
        this.updateDevice(message.device);
        break;
      default:
        console.log('未知WebSocket消息类型:', message.type);
    }
  }

  /**
   * 执行发现扫描
   */
  async performDiscoveryScan() {
    const tasks = [];

    // 1. 通过本地代理发现
    tasks.push(this.discoverViaLocalProxy());

    // 2. WebRTC ICE候选发现
    tasks.push(this.discoverViaWebRTC());

    // 3. 清理过期设备
    tasks.push(this.cleanupExpiredDevices());

    await Promise.allSettled(tasks);
  }

  /**
   * 通过本地代理发现设备
   */
  async discoverViaLocalProxy() {
    try {
      const response = await fetch(`${this.config.localProxyUrl}/api/devices`, {
        method: 'GET',
        timeout: 3000
      });

      if (response.ok) {
        const devices = await response.json();
        this.updateDevicesFromProxy(devices);
      }
    } catch (error) {
      // 本地代理不可用，静默处理
    }
  }

  /**
   * 通过WebRTC发现设备
   */
  async discoverViaWebRTC() {
    try {
      const peerConnection = new RTCPeerConnection({
        iceServers: this.config.stunServers.map(url => ({ urls: url }))
      });

      // 创建数据通道触发ICE候选收集
      peerConnection.createDataChannel('discovery');

      const candidates = [];
      
      peerConnection.onicecandidate = (event) => {
        if (event.candidate) {
          candidates.push(event.candidate);
        }
      };

      // 创建offer触发ICE收集
      const offer = await peerConnection.createOffer();
      await peerConnection.setLocalDescription(offer);

      // 等待ICE收集完成
      await new Promise((resolve) => {
        setTimeout(resolve, 2000);
      });

      // 分析ICE候选，提取可能的设备地址
      this.analyzeICECandidates(candidates);

      peerConnection.close();
    } catch (error) {
      console.warn('WebRTC发现失败:', error);
    }
  }

  /**
   * 分析ICE候选
   */
  analyzeICECandidates(candidates) {
    candidates.forEach(candidate => {
      const match = candidate.candidate.match(/(\d+\.\d+\.\d+\.\d+)/);
      if (match) {
        const ip = match[1];
        // 检查是否为局域网IP
        if (this.isLocalIP(ip)) {
          this.probeDevice(ip);
        }
      }
    });
  }

  /**
   * 检查是否为局域网IP
   */
  isLocalIP(ip) {
    const parts = ip.split('.').map(Number);
    return (
      (parts[0] === 192 && parts[1] === 168) ||
      (parts[0] === 10) ||
      (parts[0] === 172 && parts[1] >= 16 && parts[1] <= 31)
    );
  }

  /**
   * 探测设备
   */
  async probeDevice(ip) {
    const commonPorts = [3000, 3001, 8080, 8000, 5000];
    
    for (const port of commonPorts) {
      try {
        const response = await fetch(`http://${ip}:${port}/api/device-info`, {
          method: 'GET',
          timeout: 1000
        });

        if (response.ok) {
          const deviceInfo = await response.json();
          const device = new DiscoveredDevice({
            ...deviceInfo,
            address: ip,
            port: port,
            status: DeviceStatus.ONLINE
          });
          this.addDevice(device);
          break;
        }
      } catch (error) {
        // 端口不可达，继续尝试下一个
      }
    }
  }

  /**
   * 从代理更新设备列表
   */
  updateDevicesFromProxy(devices) {
    devices.forEach(deviceData => {
      const device = new DiscoveredDevice(deviceData);
      this.addDevice(device);
    });
  }

  /**
   * 添加设备
   */
  addDevice(device) {
    const existing = this.devices.get(device.id);
    if (existing) {
      // 更新现有设备
      Object.assign(existing, device);
      existing.updateLastSeen();
      this.notifyListeners('deviceUpdated', existing);
    } else {
      // 添加新设备
      this.devices.set(device.id, device);
      this.notifyListeners('deviceAdded', device);
    }
  }

  /**
   * 移除设备
   */
  removeDevice(deviceId) {
    const device = this.devices.get(deviceId);
    if (device) {
      this.devices.delete(deviceId);
      this.notifyListeners('deviceRemoved', device);
    }
  }

  /**
   * 更新设备
   */
  updateDevice(deviceData) {
    const device = this.devices.get(deviceData.id);
    if (device) {
      Object.assign(device, deviceData);
      device.updateLastSeen();
      this.notifyListeners('deviceUpdated', device);
    }
  }

  /**
   * 清理过期设备
   */
  cleanupExpiredDevices() {
    const now = Date.now();
    const expiredDevices = [];

    this.devices.forEach((device, id) => {
      if (now - device.lastSeen.getTime() > this.config.deviceTimeoutMs) {
        expiredDevices.push(id);
      }
    });

    expiredDevices.forEach(id => {
      this.removeDevice(id);
    });
  }

  /**
   * 手动添加设备
   */
  async addManualDevice(address, port = 3000, name = '') {
    try {
      const device = new DiscoveredDevice({
        address,
        port,
        name: name || `${address}:${port}`,
        type: DeviceType.UNKNOWN,
        status: DeviceStatus.CONNECTING
      });

      this.addDevice(device);

      // 尝试连接并获取设备信息
      const response = await fetch(`http://${address}:${port}/api/device-info`, {
        method: 'GET',
        timeout: 5000
      });

      if (response.ok) {
        const deviceInfo = await response.json();
        Object.assign(device, deviceInfo);
        device.status = DeviceStatus.ONLINE;
        this.notifyListeners('deviceUpdated', device);
      } else {
        device.status = DeviceStatus.OFFLINE;
        this.notifyListeners('deviceUpdated', device);
      }

      return device;
    } catch (error) {
      console.error('手动添加设备失败:', error);
      throw error;
    }
  }

  /**
   * 获取所有设备
   */
  getDevices() {
    return Array.from(this.devices.values());
  }

  /**
   * 获取在线设备
   */
  getOnlineDevices() {
    return this.getDevices().filter(device => device.isOnline());
  }

  /**
   * 根据ID获取设备
   */
  getDevice(deviceId) {
    return this.devices.get(deviceId);
  }

  /**
   * 刷新设备发现
   */
  async refresh() {
    if (this.isScanning) {
      await this.performDiscoveryScan();
    }
  }
}

// 创建全局实例
export const deviceDiscovery = new DeviceDiscoveryService();

// 默认导出
export default deviceDiscovery;