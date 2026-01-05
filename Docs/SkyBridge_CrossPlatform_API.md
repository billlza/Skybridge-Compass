# SkyBridge 云桥司南 - 跨平台 API 文档

> 版本: 1.0.0 | 更新日期: 2025-12-13

本文档为 Windows、Android、Linux、iOS 平台接入云桥司南提供完整的 API 规范。

## 目录

1. [协议概述](#1-协议概述)
2. [设备发现 (Bonjour/mDNS)](#2-设备发现-bonjourmdns)
3. [WebSocket 信令协议](#3-websocket-信令协议)
4. [能力协商](#4-能力协商)
5. [远程输入事件](#5-远程输入事件)
6. [文件传输](#6-文件传输)
7. [加密与安全](#7-加密与安全)
8. [平台实现指南](#8-平台实现指南)

---

## 1. 协议概述

### 1.1 架构图

```
┌─────────────────────────────────────────────────────────────────┐
│                    SkyBridge Agent (Rust)                       │
│                   ws://127.0.0.1:7002/agent                     │
└─────────────────────────────────────────────────────────────────┘
         ▲              ▲              ▲              ▲
         │              │              │              │
    WebSocket      WebSocket      WebSocket      WebSocket
         │              │              │              │
    ┌────┴────┐   ┌────┴────┐   ┌────┴────┐   ┌────┴────┐
    │  macOS  │   │ Windows │   │ Android │   │  Linux  │
    │   App   │   │   App   │   │   App   │   │   App   │
    └─────────┘   └─────────┘   └─────────┘   └─────────┘
```


### 1.2 协议版本

| 字段 | 值 | 说明 |
|------|-----|------|
| major | 1 | 主版本号，不兼容变更时递增 |
| minor | 0 | 次版本号，向后兼容新功能时递增 |
| patch | 0 | 补丁版本号，bug 修复时递增 |

**兼容性规则**: 主版本号相同即兼容。

### 1.3 数据格式

- 所有消息使用 **JSON** 格式
- 字符编码: **UTF-8**
- 字段命名: **snake_case**
- 时间戳: **Unix 时间戳 (秒)**
- 坐标系: **归一化坐标 (0.0-1.0)**

---

## 2. 设备发现 (Bonjour/mDNS)

### 2.1 服务类型

```
_skybridge._tcp.local.
```

### 2.2 TXT 记录字段

| 字段 | 必需 | 类型 | 说明 |
|------|------|------|------|
| `deviceId` | ✅ | string | 设备唯一标识符 (UUID) |
| `pubKeyFP` | ✅ | string | 公钥指纹 (hex 小写) |
| `uniqueId` | ✅ | string | 实例唯一 ID |
| `platform` | ❌ | string | 平台类型: `macos`, `ios`, `android`, `windows`, `linux`, `web` |
| `version` | ❌ | string | 协议版本: `1.0.0` |
| `capabilities` | ❌ | string | 能力列表 (逗号分隔) |
| `name` | ❌ | string | 设备显示名称 |

### 2.3 TXT 记录示例

```
deviceId=550e8400-e29b-41d4-a716-446655440000
pubKeyFP=a1b2c3d4e5f6789012345678
uniqueId=instance-001
platform=macos
version=1.0.0
capabilities=remote_desktop,file_transfer,screen_sharing
name=MacBook Pro
```

### 2.4 平台实现

| 平台 | 推荐库 |
|------|--------|
| Windows | [Bonjour SDK for Windows](https://developer.apple.com/bonjour/) 或 [dns-sd](https://github.com/nickelc/dns-sd) |
| Android | `android.net.nsd.NsdManager` |
| Linux | `avahi-client` 或 `libdns_sd` |
| iOS | `Network.framework` 或 `NetService` |


---

## 3. WebSocket 信令协议

### 3.1 连接端点

```
ws://127.0.0.1:7002/agent
```

### 3.2 连接状态机

```
┌──────────────┐
│ disconnected │
└──────┬───────┘
       │ connect()
       ▼
┌──────────────┐
│  connecting  │
└──────┬───────┘
       │ WebSocket opened
       ▼
┌──────────────┐
│  connected   │
└──────┬───────┘
       │ send auth
       ▼
┌──────────────────┐
│  authenticating  │
└──────┬───────────┘
       │ auth-ok
       ▼
┌──────────────────┐
│  authenticated   │◄─── 可以发送其他消息
└──────────────────┘
```

### 3.3 消息类型

#### 3.3.1 认证消息

**请求 (auth)**
```json
{
  "type": "auth",
  "token": "your-auth-token"
}
```

**成功响应 (auth-ok)**
```json
{
  "type": "auth-ok",
  "message": "认证成功"
}
```

**失败响应 (auth-failed)**
```json
{
  "type": "auth-failed",
  "reason": "无效的令牌"
}
```

#### 3.3.2 会话消息

**加入会话 (session-join)**
```json
{
  "type": "session-join",
  "session_id": "session-uuid",
  "device_id": "device-uuid"
}
```

**已加入会话 (session-joined)**
```json
{
  "type": "session-joined",
  "session_id": "session-uuid",
  "device_id": "device-uuid"
}
```

**离开会话 (session-leave)**
```json
{
  "type": "session-leave",
  "session_id": "session-uuid",
  "device_id": "device-uuid"
}
```


#### 3.3.3 WebRTC 信令消息

**SDP Offer**
```json
{
  "type": "sdp-offer",
  "session_id": "session-uuid",
  "device_id": "device-uuid",
  "auth_token": "token",
  "offer": {
    "type": "offer",
    "sdp": "v=0\r\no=- 123456 2 IN IP4 127.0.0.1\r\n..."
  }
}
```

**SDP Answer**
```json
{
  "type": "sdp-answer",
  "session_id": "session-uuid",
  "device_id": "device-uuid",
  "auth_token": "token",
  "answer": {
    "type": "answer",
    "sdp": "v=0\r\no=- 654321 2 IN IP4 127.0.0.1\r\n..."
  }
}
```

**ICE Candidate**
```json
{
  "type": "ice-candidate",
  "session_id": "session-uuid",
  "device_id": "device-uuid",
  "auth_token": "token",
  "candidate": {
    "candidate": "candidate:1 1 UDP 2122252543 192.168.1.100 54321 typ host",
    "sdp_mid": "0",
    "sdp_m_line_index": 0
  }
}
```

#### 3.3.4 设备消息

**设备列表 (devices)**
```json
{
  "type": "devices",
  "devices": [
    {
      "id": "device-uuid",
      "name": "MacBook Pro",
      "ipv4": "192.168.1.100",
      "ipv6": "fe80::1",
      "services": ["_skybridge._tcp"],
      "port_map": {"_skybridge._tcp": 7002},
      "connection_types": ["lan", "webrtc"],
      "source": "bonjour",
      "is_local_device": false,
      "device_id": "device-uuid",
      "pub_key_fp": "a1b2c3d4e5f6"
    }
  ]
}
```

**设备更新 (device-update)**
```json
{
  "type": "device-update",
  "device": { /* SBDeviceInfo */ },
  "action": "added"  // "added", "removed", "updated"
}
```


#### 3.3.5 错误消息

```json
{
  "type": "error",
  "code": "AUTH_FAILED",
  "message": "认证失败",
  "details": "令牌已过期"
}
```

### 3.4 重连机制

| 参数 | 值 | 说明 |
|------|-----|------|
| 重连延迟 | 5 秒 | 断开后等待时间 |
| 最大重试次数 | 3 次 | 超过后状态变为 failed |
| 指数退避 | 可选 | 建议实现 |

---

## 4. 能力协商

### 4.1 能力枚举

| 能力 | 值 | 说明 |
|------|-----|------|
| `remote_desktop` | 0x01 | 远程桌面控制 |
| `file_transfer` | 0x02 | 文件传输 |
| `screen_sharing` | 0x04 | 屏幕共享（只读） |
| `input_injection` | 0x08 | 输入注入 |
| `system_control` | 0x10 | 系统控制 |
| `pqc_encryption` | 0x20 | PQC 加密支持 |
| `hybrid_encryption` | 0x40 | 混合加密支持 |
| `audio_transfer` | 0x80 | 音频传输 |
| `clipboard_sync` | 0x100 | 剪贴板同步 |

### 4.2 协商请求

```json
{
  "protocolVersion": {"major": 1, "minor": 0, "patch": 0},
  "deviceId": "device-uuid",
  "platform": "android",
  "capabilities": ["remote_desktop", "file_transfer", "screen_sharing"],
  "encryptionModes": ["classic", "hybrid"],
  "pqcAlgorithms": ["ML-KEM-768", "ML-DSA-65"]
}
```

### 4.3 协商响应

```json
{
  "protocolVersion": {"major": 1, "minor": 0, "patch": 0},
  "negotiatedCapabilities": ["file_transfer", "screen_sharing"],
  "negotiatedEncryptionMode": "hybrid",
  "negotiatedPQCAlgorithms": ["ML-KEM-768"],
  "success": true,
  "errorMessage": null
}
```

### 4.4 协商规则

1. **能力协商**: 取双方能力的**交集**
2. **加密模式**: 选择双方都支持的**最高安全级别**
   - hybrid (3) > pqc (2) > classic (1)
3. **协议版本**: 主版本号必须相同


---

## 5. 远程输入事件

### 5.1 坐标系统

**归一化坐标**: 所有坐标使用 0.0-1.0 范围，确保跨平台兼容。

```
(0.0, 0.0) ─────────────────────── (1.0, 0.0)
    │                                   │
    │                                   │
    │         屏幕区域                   │
    │                                   │
    │                                   │
(0.0, 1.0) ─────────────────────── (1.0, 1.0)
```

**坐标转换公式**:
```
归一化: normalized = absolute / screen_dimension
反归一化: absolute = normalized * screen_dimension
```

### 5.2 鼠标事件

```json
{
  "type": "mouse-move",  // mouse-move, mouse-click, mouse-double-click, mouse-down, mouse-up, mouse-scroll
  "x": 0.5,              // 归一化 X 坐标 (0.0-1.0)
  "y": 0.5,              // 归一化 Y 坐标 (0.0-1.0)
  "button": "left",      // left, right, middle (可选)
  "delta_x": 0.0,        // X 方向增量 (可选)
  "delta_y": 0.0,        // Y 方向增量 (可选)
  "modifiers": {
    "ctrl": false,
    "alt": false,
    "shift": false,
    "meta": false
  },
  "timestamp": 1702483200.123
}
```

### 5.3 键盘事件

```json
{
  "type": "key-down",    // key-down, key-up
  "key_code": 65,        // 虚拟键码
  "key": "A",            // 按键字符 (可选)
  "modifiers": {
    "ctrl": false,
    "alt": false,
    "shift": true,
    "meta": false
  },
  "timestamp": 1702483200.456
}
```

### 5.4 滚动事件

```json
{
  "delta_x": 0.0,
  "delta_y": -120.0,     // 负值向上滚动
  "modifiers": {
    "ctrl": false,
    "alt": false,
    "shift": false,
    "meta": false
  },
  "timestamp": 1702483200.789
}
```

### 5.5 修饰键映射

| 修饰键 | macOS | Windows | Linux | Android |
|--------|-------|---------|-------|---------|
| `ctrl` | Control | Ctrl | Ctrl | Ctrl |
| `alt` | Option | Alt | Alt | Alt |
| `shift` | Shift | Shift | Shift | Shift |
| `meta` | Command | Windows | Super | Meta |


---

## 6. 文件传输

### 6.1 传输流程

```
发送方                          接收方
   │                              │
   │──── file-meta ──────────────►│
   │                              │ 检查空间/权限
   │◄─── file-ack-meta ───────────│
   │                              │
   │==== WebRTC DataChannel =====>│ 传输文件数据
   │                              │
   │──── file-end ───────────────►│
   │                              │
```

### 6.2 文件元数据 (file-meta)

```json
{
  "type": "file-meta",
  "file_id": "file-uuid",
  "file_name": "document.pdf",
  "file_size": 1048576,
  "mime_type": "application/pdf",
  "checksum": "sha256:a1b2c3d4..."
}
```

### 6.3 元数据确认 (file-ack-meta)

```json
{
  "type": "file-ack-meta",
  "file_id": "file-uuid",
  "accepted": true,
  "reason": null
}
```

**拒绝示例**:
```json
{
  "type": "file-ack-meta",
  "file_id": "file-uuid",
  "accepted": false,
  "reason": "存储空间不足"
}
```

### 6.4 传输结束 (file-end)

```json
{
  "type": "file-end",
  "file_id": "file-uuid",
  "success": true,
  "bytes_transferred": 1048576
}
```

---

## 7. 加密与安全

### 7.1 加密模式

| 模式 | 说明 | 安全级别 |
|------|------|----------|
| `classic` | P-256 ECDH + AES-256-GCM | 1 (基础) |
| `pqc` | ML-KEM-768 + ML-DSA-65 | 2 (抗量子) |
| `hybrid` | 经典 + PQC 组合 | 3 (最高) |

### 7.2 混合密钥交换

```
发起方                                    响应方
   │                                        │
   │ 生成 P-256 密钥对                       │
   │ 生成 ML-KEM-768 密钥对                  │
   │                                        │
   │──── classicPubKey + pqcPubKey ────────►│
   │                                        │ 生成 P-256 密钥对
   │                                        │ ECDH 派生 classicSecret
   │                                        │ ML-KEM 封装 pqcSecret
   │◄─── classicPubKey + pqcEncapsulated ───│
   │                                        │
   │ ECDH 派生 classicSecret                 │
   │ ML-KEM 解封装 pqcSecret                 │
   │                                        │
   │ combinedSecret = HKDF(classic || pqc)  │ combinedSecret = HKDF(classic || pqc)
   │                                        │
```


### 7.3 混合签名

**签名格式**: `[4字节经典签名长度][经典签名][PQC签名]`

```
┌────────────────┬─────────────────────┬─────────────────────┐
│ Length (4B BE) │ P-256 ECDSA (64B)   │ ML-DSA-65 (3309B)   │
└────────────────┴─────────────────────┴─────────────────────┘
```

### 7.4 PQC 算法参数

| 算法 | 公钥大小 | 私钥大小 | 密文/签名大小 |
|------|----------|----------|---------------|
| ML-KEM-768 | 1184 B | 2400 B | 1088 B |
| ML-DSA-65 | 1952 B | 4032 B | 3309 B |
| X-Wing | 1216 B | 2464 B | 1120 B |

### 7.5 降级策略

当一方不支持 PQC 时，自动降级到经典模式：

1. 检查对方能力声明
2. 如果不支持 `pqc_encryption` 或 `hybrid_encryption`
3. 降级到 `classic` 模式
4. 记录警告日志

---

## 8. 平台实现指南

### 8.1 Windows 实现

#### 依赖库
```
- WebSocket: websocketpp 或 Boost.Beast
- mDNS: Bonjour SDK for Windows
- 加密: OpenSSL 3.x + liboqs
- 屏幕捕获: DXGI Desktop Duplication
- 输入注入: SendInput API
```

#### 权限要求
- 屏幕捕获: 无特殊权限
- 输入注入: 需要 UIAccess 或管理员权限

#### 示例代码 (C++)
```cpp
// WebSocket 连接
#include <websocketpp/client.hpp>

class SkyBridgeClient {
public:
    void connect(const std::string& url) {
        client_.init_asio();
        client_.set_open_handler([this](auto hdl) {
            send_auth(hdl);
        });
        client_.set_message_handler([this](auto hdl, auto msg) {
            handle_message(msg->get_payload());
        });
        
        websocketpp::lib::error_code ec;
        auto con = client_.get_connection(url, ec);
        client_.connect(con);
        client_.run();
    }
    
private:
    void send_auth(connection_hdl hdl) {
        json auth = {{"type", "auth"}, {"token", token_}};
        client_.send(hdl, auth.dump(), websocketpp::frame::opcode::text);
    }
};
```


### 8.2 Android 实现

#### 依赖库
```gradle
dependencies {
    implementation 'org.java-websocket:Java-WebSocket:1.5.4'
    implementation 'com.google.code.gson:gson:2.10.1'
    implementation 'org.bouncycastle:bcprov-jdk18on:1.77'
}
```

#### 权限要求
```xml
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
<uses-permission android:name="android.permission.ACCESS_WIFI_STATE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
<uses-permission android:name="android.permission.MEDIA_PROJECTION" /> <!-- 屏幕捕获 -->
```

#### 示例代码 (Kotlin)
```kotlin
class SkyBridgeService : Service() {
    private lateinit var webSocket: WebSocketClient
    private lateinit var nsdManager: NsdManager
    
    // mDNS 服务发现
    private val discoveryListener = object : NsdManager.DiscoveryListener {
        override fun onServiceFound(service: NsdServiceInfo) {
            if (service.serviceType == "_skybridge._tcp.") {
                nsdManager.resolveService(service, resolveListener)
            }
        }
        // ... 其他回调
    }
    
    // WebSocket 连接
    fun connect(url: String) {
        webSocket = object : WebSocketClient(URI(url)) {
            override fun onOpen(handshakedata: ServerHandshake) {
                sendAuth()
            }
            
            override fun onMessage(message: String) {
                handleMessage(Gson().fromJson(message, JsonObject::class.java))
            }
        }
        webSocket.connect()
    }
    
    private fun sendAuth() {
        val auth = JsonObject().apply {
            addProperty("type", "auth")
            addProperty("token", authToken)
        }
        webSocket.send(auth.toString())
    }
}
```


### 8.3 Linux 实现

#### 依赖库
```bash
# Ubuntu/Debian
sudo apt install libavahi-client-dev libwebsocketpp-dev libssl-dev

# Fedora/RHEL
sudo dnf install avahi-devel websocketpp-devel openssl-devel
```

#### 权限要求
- 屏幕捕获: PipeWire/XDG Portal (Wayland) 或 X11 (Xorg)
- 输入注入: uinput 设备访问权限

#### 示例代码 (Rust)
```rust
use tokio_tungstenite::{connect_async, tungstenite::Message};
use serde::{Deserialize, Serialize};

#[derive(Serialize)]
struct AuthMessage {
    #[serde(rename = "type")]
    msg_type: String,
    token: String,
}

#[derive(Deserialize)]
struct AuthOKMessage {
    #[serde(rename = "type")]
    msg_type: String,
    message: String,
}

async fn connect_to_agent(url: &str, token: &str) -> Result<(), Box<dyn std::error::Error>> {
    let (mut ws_stream, _) = connect_async(url).await?;
    
    // 发送认证
    let auth = AuthMessage {
        msg_type: "auth".to_string(),
        token: token.to_string(),
    };
    ws_stream.send(Message::Text(serde_json::to_string(&auth)?)).await?;
    
    // 接收响应
    while let Some(msg) = ws_stream.next().await {
        match msg? {
            Message::Text(text) => {
                let response: serde_json::Value = serde_json::from_str(&text)?;
                match response["type"].as_str() {
                    Some("auth-ok") => println!("认证成功"),
                    Some("auth-failed") => println!("认证失败: {}", response["reason"]),
                    _ => {}
                }
            }
            _ => {}
        }
    }
    Ok(())
}
```


### 8.4 iOS 实现

#### 依赖库
```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/daltoniam/Starscream.git", from: "4.0.0"),
]
```

#### 权限要求
```xml
<!-- Info.plist -->
<key>NSLocalNetworkUsageDescription</key>
<string>用于发现局域网内的云桥司南设备</string>
<key>NSBonjourServices</key>
<array>
    <string>_skybridge._tcp</string>
</array>
```

#### 示例代码 (Swift)
```swift
import Network
import Starscream

class SkyBridgeClient: WebSocketDelegate {
    private var socket: WebSocket!
    private var browser: NWBrowser!
    
    // mDNS 服务发现
    func startDiscovery() {
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        
        browser = NWBrowser(for: .bonjour(type: "_skybridge._tcp", domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { results, changes in
            for result in results {
                if case .service(let name, let type, let domain, _) = result.endpoint {
                    print("发现设备: \(name)")
                }
            }
        }
        browser.start(queue: .main)
    }
    
    // WebSocket 连接
    func connect(url: URL) {
        var request = URLRequest(url: url)
        socket = WebSocket(request: request)
        socket.delegate = self
        socket.connect()
    }
    
    func didReceive(event: WebSocketEvent, client: WebSocketClient) {
        switch event {
        case .connected:
            sendAuth()
        case .text(let text):
            handleMessage(text)
        default:
            break
        }
    }
    
    private func sendAuth() {
        let auth: [String: Any] = ["type": "auth", "token": authToken]
        if let data = try? JSONSerialization.data(withJSONObject: auth),
           let text = String(data: data, encoding: .utf8) {
            socket.write(string: text)
        }
    }
}
```


---

## 附录 A: 完整消息类型列表

| 类型 | 方向 | 说明 |
|------|------|------|
| `auth` | C→S | 客户端认证请求 |
| `auth-ok` | S→C | 认证成功 |
| `auth-failed` | S→C | 认证失败 |
| `session-join` | C→S | 加入会话 |
| `session-joined` | S→C | 已加入会话 |
| `session-leave` | C→S | 离开会话 |
| `sdp-offer` | C↔C | SDP Offer |
| `sdp-answer` | C↔C | SDP Answer |
| `ice-candidate` | C↔C | ICE Candidate |
| `devices` | S→C | 设备列表 |
| `device-update` | S→C | 设备更新 |
| `file-meta` | C↔C | 文件元数据 |
| `file-ack-meta` | C↔C | 文件元数据确认 |
| `file-end` | C↔C | 文件传输结束 |
| `error` | S→C | 错误消息 |

---

## 附录 B: 错误码列表

| 错误码 | 说明 |
|--------|------|
| `AUTH_FAILED` | 认证失败 |
| `AUTH_EXPIRED` | 令牌已过期 |
| `SESSION_NOT_FOUND` | 会话不存在 |
| `DEVICE_NOT_FOUND` | 设备不存在 |
| `PROTOCOL_ERROR` | 协议错误 |
| `CAPABILITY_MISMATCH` | 能力不匹配 |
| `ENCRYPTION_ERROR` | 加密错误 |
| `FILE_TOO_LARGE` | 文件过大 |
| `STORAGE_FULL` | 存储空间不足 |
| `PERMISSION_DENIED` | 权限被拒绝 |

---

## 附录 C: 平台能力矩阵

| 能力 | macOS | Windows | Linux | Android | iOS |
|------|-------|---------|-------|---------|-----|
| 远程桌面 | ✅ | ✅ | ✅ | ⚠️ | ❌ |
| 文件传输 | ✅ | ✅ | ✅ | ✅ | ✅ |
| 屏幕共享 | ✅ | ✅ | ✅ | ✅ | ⚠️ |
| 输入注入 | ✅ | ✅ | ✅ | ⚠️ | ❌ |
| PQC 加密 | ✅ | ✅ | ✅ | ✅ | ✅ |
| 混合加密 | ✅ | ✅ | ✅ | ✅ | ✅ |
| 剪贴板同步 | ✅ | ✅ | ✅ | ✅ | ⚠️ |

**图例**: ✅ 完全支持 | ⚠️ 部分支持/需要特殊权限 | ❌ 不支持

---

## 附录 D: 版本历史

| 版本 | 日期 | 变更 |
|------|------|------|
| 1.0.0 | 2025-12-13 | 初始版本 |

---

## 联系方式

如有问题或建议，请联系云桥司南开发团队。

**文档维护**: SkyBridge Compass Team
