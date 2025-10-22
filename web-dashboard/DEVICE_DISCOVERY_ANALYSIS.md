# SkyBridge 设备互相发现机制分析

## macOS 应用现有实现分析

### 1. 核心架构

基于对 macOS 版 SkyBridge Compass Pro 的分析，发现其采用了多层次的设备发现机制：

#### 1.1 P2P 发现服务 (`P2PDiscoveryService.swift`)

**主要特性：**
- 使用 Bonjour/mDNS 协议进行局域网设备发现
- 支持多种服务类型同时搜索，提高兼容性
- 基于 Swift 6 Actor 模型，确保线程安全

**支持的服务类型：**
```swift
private let compatibleServiceTypes = [
    "_skybridge._tcp",        // 自定义服务（SkyBridge应用间通信）
    "_companion-link._tcp",   // Apple Continuity设备（iPhone/iPad/Mac）
    "_airplay._tcp",          // AirPlay服务（iPhone/iPad）
    "_apple-mobdev2._tcp",    // Apple移动设备服务
    "_rdlink._tcp",           // 远程桌面链接
    "_http._tcp",             // HTTP服务（可能的Web服务器）
    "_ssh._tcp"               // SSH服务（开发者设备）
]
```

#### 1.2 设备类型支持

**支持的平台：**
- macOS (主机)
- iOS/iPadOS (移动设备)
- Android (通过兼容协议)
- Windows (通过 RDP 协议)
- Linux (通过 SSH/HTTP 服务)

### 2. 技术实现细节

#### 2.1 服务广播机制

```swift
// 创建 NetService 并发布
let serviceName = deviceInfo.name
netService = NetService(domain: "local.", type: "_skybridge._tcp", name: serviceName, port: port)

// 设置 TXT 记录包含设备信息
let txtData = createTXTRecord()
netService?.setTXTRecord(txtData)
netService?.publish()
```

#### 2.2 设备发现机制

```swift
// 为每个服务类型创建浏览器
for serviceType in compatibleServiceTypes {
    let browser = NetServiceBrowser()
    browser.delegate = self
    browser.searchForServices(ofType: serviceType, inDomain: "local.")
    netServiceBrowsers.append(browser)
}
```

#### 2.3 NAT 穿透支持

**STUN 服务器配置：**
```swift
public static let defaultServers = [
    STUNServer(host: "stun.l.google.com"),
    STUNServer(host: "stun1.l.google.com"),
    STUNServer(host: "stun2.l.google.com"),
    STUNServer(host: "stun.cloudflare.com")
]
```

**NAT 类型检测：**
- 完全锥形NAT (简单穿透)
- 限制锥形NAT (中等难度)
- 端口限制锥形NAT (中等难度)
- 对称NAT (困难穿透)

### 3. 安全机制

#### 3.1 设备认证
- 基于 CryptoKit 的加密通信
- TLS 1.3 加密传输 (QUIC 内置)
- 设备指纹验证

#### 3.2 连接安全
- 证书固定 (Certificate Pinning)
- 端到端加密
- 连接请求验证

## Web 仪表板集成方案

### 1. 技术挑战

#### 1.1 浏览器限制
- **mDNS/Bonjour**: 浏览器不支持直接访问 mDNS 协议
- **网络发现**: Web 应用无法直接扫描局域网
- **端口监听**: 浏览器安全策略限制端口访问

#### 1.2 解决方案

**方案 A: WebRTC + 信令服务器**
```javascript
// 使用 WebRTC 的 ICE 候选发现
const peerConnection = new RTCPeerConnection({
  iceServers: [
    { urls: 'stun:stun.l.google.com:19302' },
    { urls: 'stun:stun.cloudflare.com:3478' }
  ]
});
```

**方案 B: WebSocket 代理服务**
```javascript
// 通过 WebSocket 连接到本地代理服务
const ws = new WebSocket('ws://localhost:8080/discovery');
ws.onmessage = (event) => {
  const devices = JSON.parse(event.data);
  updateDeviceList(devices);
};
```

**方案 C: HTTP API 轮询**
```javascript
// 定期轮询本地 HTTP 服务获取设备列表
async function discoverDevices() {
  try {
    const response = await fetch('http://localhost:3001/api/devices');
    const devices = await response.json();
    return devices;
  } catch (error) {
    console.error('设备发现失败:', error);
    return [];
  }
}
```

### 2. 推荐实现方案

#### 2.1 混合架构

**本地发现服务 (Node.js/Electron)**
- 运行在用户本地的轻量级服务
- 负责 mDNS/Bonjour 设备发现
- 提供 HTTP API 和 WebSocket 接口

**Web 仪表板集成**
- 通过 HTTP API 获取设备列表
- 使用 WebSocket 实时更新设备状态
- 支持手动添加远程设备

#### 2.2 实现步骤

1. **创建本地发现服务**
   - 使用 Node.js + mdns 库
   - 实现设备扫描和状态监控
   - 提供 RESTful API

2. **Web 仪表板适配**
   - 添加设备发现 API 调用
   - 实现实时设备状态更新
   - 支持设备连接管理

3. **跨平台兼容**
   - 支持 macOS 原生应用发现
   - 兼容其他平台的发现协议
   - 提供统一的设备信息格式

### 3. 技术规格

#### 3.1 设备信息格式
```typescript
interface DiscoveredDevice {
  id: string;
  name: string;
  type: 'macOS' | 'iOS' | 'iPadOS' | 'Android' | 'Windows' | 'Linux';
  address: string;
  port: number;
  services: string[];
  capabilities: string[];
  lastSeen: Date;
  status: 'online' | 'offline' | 'connecting';
}
```

#### 3.2 发现协议支持
- **mDNS/Bonjour**: 主要发现协议
- **UPnP**: Windows 设备兼容
- **WS-Discovery**: Windows 10+ 设备
- **SSDP**: 网络设备发现
- **手动配置**: IP:Port 直接连接

## 总结

macOS 版 SkyBridge 已经实现了完善的 P2P 设备发现机制，主要基于 Bonjour/mDNS 协议。要在 Web 仪表板中实现类似功能，需要通过本地代理服务来桥接浏览器限制，采用混合架构可以最大化兼容性和功能完整性。