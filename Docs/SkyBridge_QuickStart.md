# SkyBridge 云桥司南 - 快速接入指南

> 5 分钟快速接入云桥司南跨平台协作网络

## 快速开始

### 步骤 1: 实现设备发现

注册 mDNS 服务，让其他设备能发现你：

```
服务类型: _skybridge._tcp
TXT 记录:
  - deviceId=<你的设备UUID>
  - pubKeyFP=<公钥指纹hex>
  - uniqueId=<实例ID>
  - platform=<android|windows|linux|ios>
```

### 步骤 2: 连接 WebSocket

```javascript
// 连接到 SkyBridge Agent
const ws = new WebSocket('ws://127.0.0.1:7002/agent');

ws.onopen = () => {
  // 发送认证
  ws.send(JSON.stringify({
    type: 'auth',
    token: 'your-auth-token'
  }));
};

ws.onmessage = (event) => {
  const msg = JSON.parse(event.data);
  
  switch (msg.type) {
    case 'auth-ok':
      console.log('认证成功！');
      break;
    case 'devices':
      console.log('发现设备:', msg.devices);
      break;
  }
};
```


### 步骤 3: 加入会话

```javascript
// 加入远程控制会话
ws.send(JSON.stringify({
  type: 'session-join',
  session_id: 'session-uuid',
  device_id: 'your-device-id'
}));
```

### 步骤 4: WebRTC 信令

```javascript
// 发送 SDP Offer
ws.send(JSON.stringify({
  type: 'sdp-offer',
  session_id: 'session-uuid',
  device_id: 'your-device-id',
  auth_token: 'token',
  offer: {
    type: 'offer',
    sdp: peerConnection.localDescription.sdp
  }
}));

// 处理 SDP Answer
ws.onmessage = (event) => {
  const msg = JSON.parse(event.data);
  if (msg.type === 'sdp-answer') {
    peerConnection.setRemoteDescription(msg.answer);
  }
};
```

---

## 核心概念

### 消息类型速查

| 类型 | 用途 |
|------|------|
| `auth` | 认证 |
| `session-join` | 加入会话 |
| `sdp-offer/answer` | WebRTC 信令 |
| `ice-candidate` | ICE 候选 |
| `devices` | 设备列表 |
| `file-meta` | 文件传输 |

### 坐标系统

所有坐标使用 **归一化坐标 (0.0-1.0)**：

```
鼠标位置 = (x / 屏幕宽度, y / 屏幕高度)
```

### 加密模式

| 模式 | 安全级别 | 说明 |
|------|----------|------|
| classic | 基础 | P-256 + AES-GCM |
| pqc | 抗量子 | ML-KEM + ML-DSA |
| hybrid | 最高 | 经典 + PQC |

---

## 平台 SDK

| 平台 | 语言 | 依赖 |
|------|------|------|
| Windows | C++ | Bonjour SDK, websocketpp |
| Android | Kotlin | NsdManager, Java-WebSocket |
| Linux | Rust/C | avahi, tokio-tungstenite |
| iOS | Swift | Network.framework, Starscream |

---

## 详细文档

- [完整 API 文档](SkyBridge_CrossPlatform_API.md)
- [设备发现指南](SkyBridge_Device_Discovery.md)
- [跨平台设备发现与连接技术说明](跨平台设备发现与连接技术说明.md)

---

## 测试连接

```bash
# 检查 mDNS 服务
dns-sd -B _skybridge._tcp

# 测试 WebSocket
wscat -c ws://127.0.0.1:7002/agent
```

---

**需要帮助?** 查看完整文档或联系开发团队。
