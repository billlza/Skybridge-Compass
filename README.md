# SkyBridge Compass Pro

SkyBridge Compass Pro 是一个跨平台设备管理和远程控制解决方案，支持 macOS、iOS、Android、Windows 和 Linux 设备之间的安全连接与协作。

## 仓库内容概览

- `Sources/`：核心应用与模块源码
- `Docs/`：论文与技术文档、图表素材
- `Tests/`：测试用例
- `Sources/Vendor/`：随项目分发的第三方框架

---

# SkyBridge Agent 技术文档

## 概述

SkyBridge Agent 是一个本地运行的服务，作为 Web 端与 Mac 端云桥司南 APP 之间的桥梁。它提供：

1. **WebSocket 信令服务** - 转发 WebRTC 信令消息
2. **mDNS/Bonjour 设备发现** - 扫描本地网络中的设备
3. **设备注册表** - 管理发现的设备列表

## 技术栈

- **语言**: Rust 1.82+
- **异步运行时**: Tokio
- **WebSocket**: tokio-tungstenite
- **HTTP 服务**: Axum
- **mDNS**: mdns-sd

## 服务端点

| 端点 | 协议 | 说明 |
|------|------|------|
| `ws://127.0.0.1:7002/agent` | WebSocket | 信令通道 |
| `http://127.0.0.1:7002/health` | HTTP GET | 健康检查 |
| `http://127.0.0.1:7002/devices` | HTTP GET | 获取设备列表 |

## 编译和运行

```bash
# 开发模式
cd agent
cargo run

# 发布模式（优化）
cargo build --release
./target/release/skybridge-agent
```

## 信令协议

### 消息格式

所有消息使用 JSON 格式，通过 WebSocket 传输。

### 1. 认证消息 (auth)

客户端连接后首先发送认证消息。

```json
{
  "type": "auth",
  "token": "用户认证令牌"
}
```

**响应:**
```json
{
  "type": "auth-ok",
  "message": "Authenticated successfully"
}
```

### 2. 加入会话 (session-join)

加入一个信令会话，用于 WebRTC 连接建立。

```json
{
  "type": "session-join",
  "sessionId": "会话UUID",
  "deviceId": "设备ID"
}
```

**响应:**
```json
{
  "type": "session-joined",
  "sessionId": "会话UUID"
}
```

### 3. SDP Offer (sdp-offer)

发送 WebRTC SDP Offer。

```json
{
  "type": "sdp-offer",
  "sessionId": "会话UUID",
  "deviceId": "发送方设备ID",
  "authToken": "认证令牌",
  "offer": {
    "type": "offer",
    "sdp": "v=0\\r\\no=- ..."
  }
}
```

### 4. SDP Answer (sdp-answer)

响应 SDP Offer。

```json
{
  "type": "sdp-answer",
  "sessionId": "会话UUID",
  "deviceId": "响应方设备ID",
  "authToken": "认证令牌",
  "answer": {
    "type": "answer",
    "sdp": "v=0\\r\\no=- ..."
  }
}
```

### 5. ICE Candidate (ice-candidate)

交换 ICE 候选。

```json
{
  "type": "ice-candidate",
  "sessionId": "会话UUID",
  "deviceId": "设备ID",
  "authToken": "认证令牌",
  "candidate": {
    "candidate": "candidate:...",
    "sdpMid": "0",
    "sdpMLineIndex": 0
  }
}
```

### 6. 设备列表推送 (devices)

Agent 自动推送发现的设备列表。

```json
{
  "type": "devices",
  "devices": [
    {
      "id": "设备唯一标识",
      "name": "设备名称",
      "ipv4": "192.168.1.100",
      "ipv6": "fe80::1",
      "services": ["SkyBridge", "AirPlay"],
      "portMap": {"SkyBridge": 7002, "AirPlay": 7000},
      "connectionTypes": ["Wi-Fi"],
      "source": "SkyBridge Bonjour",
      "isLocalDevice": false,
      "deviceId": "UUID",
      "pubKeyFP": "公钥指纹"
    }
  ]
}
```

### 7. 文件传输控制消息

#### file-meta (文件元数据)
```json
{
  "type": "file-meta",
  "name": "文件名.zip",
  "size": 1024000
}
```

#### file-ack-meta (确认元数据)
```json
{
  "type": "file-ack-meta"
}
```

#### file-end (传输结束)
```json
{
  "type": "file-end",
  "name": "文件名.zip"
}
```

## 设备发现

Agent 扫描以下 Bonjour 服务类型：

| 服务类型 | 说明 |
|----------|------|
| `_skybridge._tcp` | SkyBridge 设备 |
| `_airplay._tcp` | AirPlay 设备 |
| `_raop._tcp` | AirPlay 音频 |
| `_companion-link._tcp` | Apple Companion |
| `_homekit._tcp` | HomeKit 设备 |
| `_smb._tcp` | SMB 共享 |
| `_afpovertcp._tcp` | AFP 共享 |
| `_sftp-ssh._tcp` | SFTP |
| `_ssh._tcp` | SSH |
| `_http._tcp` | HTTP 服务 |

## 设备信息结构

```typescript
interface DeviceInfo {
  id: string;              // 设备唯一标识
  name: string;            // 设备名称
  ipv4?: string;           // IPv4 地址
  ipv6?: string;           // IPv6 地址
  services: string[];      // 可用服务列表
  portMap: Record<string, number>;  // 服务端口映射
  connectionTypes: string[];  // 连接类型 ["Wi-Fi", "有线", "USB"]
  uniqueIdentifier?: string;  // 唯一标识符
  signalStrength?: number;    // 信号强度 (0-100)
  source: DeviceSource;       // 设备来源
  isLocalDevice: boolean;     // 是否为本机
  deviceId?: string;          // 设备 UUID
  pubKeyFP?: string;          // 公钥指纹
  macSet: string[];           // MAC 地址集合
}

type DeviceSource =
  | "SkyBridge Bonjour"
  | "SkyBridge P2P"
  | "SkyBridge USB"
  | "SkyBridge iCloud"
  | "第三方 Bonjour"
  | "未知来源";
```

---

# Mac 端 APP 对接指南

## 需要实现的功能

### 1. 注册 Bonjour 服务

Mac 端 APP 需要注册 `_skybridge._tcp` 服务，以便被 Agent 发现。

**Swift 示例:**
```swift
import Network

class BonjourService {
    private var listener: NWListener?
    
    func start() throws {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        
        listener = try NWListener(using: parameters, on: 7002)
        
        // 设置 TXT 记录
        let txtRecord = NWTXTRecord([
            "deviceId": UIDevice.current.identifierForVendor?.uuidString ?? "",
            "pubKeyFP": getPublicKeyFingerprint(),
            "uniqueId": getUniqueIdentifier()
        ])
        
        listener?.service = NWListener.Service(
            name: UIDevice.current.name,
            type: "_skybridge._tcp",
            txtRecord: txtRecord
        )
        
        listener?.stateUpdateHandler = { state in
            print("Bonjour state: \(state)")
        }
        
        listener?.start(queue: .main)
    }
}
```

### 2. 连接 Agent WebSocket

Mac 端 APP 需要连接到 Agent 的 WebSocket 服务。

**Swift 示例:**
```swift
import Foundation

class AgentConnection: NSObject, URLSessionWebSocketDelegate {
    private var webSocket: URLSessionWebSocketTask?
    private let deviceId: String
    
    init(deviceId: String) {
        self.deviceId = deviceId
        super.init()
    }
    
    func connect() {
        let url = URL(string: "ws://127.0.0.1:7002/agent")!
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        webSocket = session.webSocketTask(with: url)
        webSocket?.resume()
        
        // 发送认证
        sendAuth()
        
        // 开始接收消息
        receiveMessage()
    }
    
    private func sendAuth() {
        let auth: [String: Any] = [
            "type": "auth",
            "token": getAuthToken()
        ]
        send(auth)
    }
    
    func joinSession(_ sessionId: String) {
        let msg: [String: Any] = [
            "type": "session-join",
            "sessionId": sessionId,
            "deviceId": deviceId
        ]
        send(msg)
    }
    
    func sendSDPOffer(_ offer: RTCSessionDescription, sessionId: String) {
        let msg: [String: Any] = [
            "type": "sdp-offer",
            "sessionId": sessionId,
            "deviceId": deviceId,
            "authToken": getAuthToken(),
            "offer": [
                "type": offer.type.rawValue,
                "sdp": offer.sdp
            ]
        ]
        send(msg)
    }
    
    func sendSDPAnswer(_ answer: RTCSessionDescription, sessionId: String) {
        let msg: [String: Any] = [
            "type": "sdp-answer",
            "sessionId": sessionId,
            "deviceId": deviceId,
            "authToken": getAuthToken(),
            "answer": [
                "type": answer.type.rawValue,
                "sdp": answer.sdp
            ]
        ]
        send(msg)
    }
    
    func sendICECandidate(_ candidate: RTCIceCandidate, sessionId: String) {
        let msg: [String: Any] = [
            "type": "ice-candidate",
            "sessionId": sessionId,
            "deviceId": deviceId,
            "authToken": getAuthToken(),
            "candidate": [
                "candidate": candidate.sdp,
                "sdpMid": candidate.sdpMid ?? "",
                "sdpMLineIndex": candidate.sdpMLineIndex
            ]
        ]
        send(msg)
    }
    
    private func send(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let string = String(data: data, encoding: .utf8) else { return }
        webSocket?.send(.string(string)) { error in
            if let error = error {
                print("Send error: \(error)")
            }
        }
    }
    
    private func receiveMessage() {
        webSocket?.receive { [weak self] result in
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self?.handleMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self?.handleMessage(text)
                    }
                @unknown default:
                    break
                }
                self?.receiveMessage()
            case .failure(let error):
                print("Receive error: \(error)")
            }
        }
    }
    
    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }
        
        switch type {
        case "sdp-offer":
            // 处理收到的 SDP Offer
            handleSDPOffer(json)
        case "sdp-answer":
            // 处理收到的 SDP Answer
            handleSDPAnswer(json)
        case "ice-candidate":
            // 处理收到的 ICE Candidate
            handleICECandidate(json)
        case "devices":
            // 处理设备列表更新
            handleDevices(json)
        default:
            break
        }
    }
}
```

### 3. 实现远程桌面（屏幕捕获）

Mac 端需要使用 ScreenCaptureKit 捕获屏幕并通过 WebRTC 发送。

**Swift 示例:**
```swift
import ScreenCaptureKit
import WebRTC

class ScreenCapture: NSObject, SCStreamDelegate, SCStreamOutput {
    private var stream: SCStream?
    private var videoTrack: RTCVideoTrack?
    private var videoSource: RTCVideoSource?
    
    func startCapture(peerConnection: RTCPeerConnection) async throws {
        // 获取可共享内容
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        
        guard let display = content.displays.first else {
            throw NSError(domain: "ScreenCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: "No display found"])
        }
        
        // 配置捕获
        let config = SCStreamConfiguration()
        config.width = Int(display.width)
        config.height = Int(display.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60) // 60fps
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true
        
        // 创建过滤器
        let filter = SCContentFilter(display: display, excludingWindows: [])
        
        // 创建流
        stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream?.addStreamOutput(self, type: .screen, sampleHandlerQueue: .main)
        
        // 创建 WebRTC 视频源
        let factory = RTCPeerConnectionFactory()
        videoSource = factory.videoSource()
        videoTrack = factory.videoTrack(with: videoSource!, trackId: "screen")
        
        // 添加到 PeerConnection
        peerConnection.add(videoTrack!, streamIds: ["screen-share"])
        
        // 开始捕获
        try await stream?.startCapture()
    }
    
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        
        // 转换为 RTCVideoFrame 并发送
        let rtcBuffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer)
        let frame = RTCVideoFrame(buffer: rtcBuffer, rotation: ._0, timeStampNs: Int64(CACurrentMediaTime() * 1_000_000_000))
        videoSource?.capturer(RTCVideoCapturer(), didCapture: frame)
    }
    
    func stopCapture() {
        stream?.stopCapture()
        stream = nil
    }
}
```

### 4. 实现远程输入注入

Mac 端需要使用 Accessibility API 注入鼠标和键盘事件。

**Swift 示例:**
```swift
import CoreGraphics
import ApplicationServices

class InputInjector {
    
    /// 处理远程输入事件
    func handleInputEvent(_ event: [String: Any]) {
        guard let type = event["type"] as? String else { return }
        
        switch type {
        case "mouse-move":
            handleMouseMove(event)
        case "mouse-click":
            handleMouseClick(event)
        case "mouse-scroll":
            handleMouseScroll(event)
        case "key-down":
            handleKeyDown(event)
        case "key-up":
            handleKeyUp(event)
        default:
            break
        }
    }
    
    private func handleMouseMove(_ event: [String: Any]) {
        guard let x = event["x"] as? Double,
              let y = event["y"] as? Double else { return }
        
        // 转换归一化坐标到屏幕坐标
        let screenSize = NSScreen.main?.frame.size ?? CGSize(width: 1920, height: 1080)
        let point = CGPoint(x: x * screenSize.width, y: y * screenSize.height)
        
        // 创建鼠标移动事件
        if let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) {
            moveEvent.post(tap: .cghidEventTap)
        }
    }
    
    private func handleMouseClick(_ event: [String: Any]) {
        guard let x = event["x"] as? Double,
              let y = event["y"] as? Double,
              let button = event["button"] as? String else { return }
        
        let screenSize = NSScreen.main?.frame.size ?? CGSize(width: 1920, height: 1080)
        let point = CGPoint(x: x * screenSize.width, y: y * screenSize.height)
        
        let mouseButton: CGMouseButton = button == "right" ? .right : button == "middle" ? .center : .left
        let downType: CGEventType = button == "right" ? .rightMouseDown : button == "middle" ? .otherMouseDown : .leftMouseDown
        let upType: CGEventType = button == "right" ? .rightMouseUp : button == "middle" ? .otherMouseUp : .leftMouseUp
        
        // 鼠标按下
        if let downEvent = CGEvent(mouseEventSource: nil, mouseType: downType, mouseCursorPosition: point, mouseButton: mouseButton) {
            downEvent.post(tap: .cghidEventTap)
        }
        
        // 鼠标释放
        if let upEvent = CGEvent(mouseEventSource: nil, mouseType: upType, mouseCursorPosition: point, mouseButton: mouseButton) {
            upEvent.post(tap: .cghidEventTap)
        }
    }
    
    private func handleMouseScroll(_ event: [String: Any]) {
        guard let deltaX = event["deltaX"] as? Double,
              let deltaY = event["deltaY"] as? Double else { return }
        
        if let scrollEvent = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(-deltaY), wheel2: Int32(-deltaX), wheel3: 0) {
            scrollEvent.post(tap: .cghidEventTap)
        }
    }
    
    private func handleKeyDown(_ event: [String: Any]) {
        guard let keyCode = event["keyCode"] as? Int else { return }
        let modifiers = parseModifiers(event["modifiers"] as? [String: Bool] ?? [:])
        
        if let keyEvent = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: true) {
            keyEvent.flags = modifiers
            keyEvent.post(tap: .cghidEventTap)
        }
    }
    
    private func handleKeyUp(_ event: [String: Any]) {
        guard let keyCode = event["keyCode"] as? Int else { return }
        let modifiers = parseModifiers(event["modifiers"] as? [String: Bool] ?? [:])
        
        if let keyEvent = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: false) {
            keyEvent.flags = modifiers
            keyEvent.post(tap: .cghidEventTap)
        }
    }
    
    private func parseModifiers(_ modifiers: [String: Bool]) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers["ctrl"] == true { flags.insert(.maskControl) }
        if modifiers["alt"] == true { flags.insert(.maskAlternate) }
        if modifiers["shift"] == true { flags.insert(.maskShift) }
        if modifiers["meta"] == true { flags.insert(.maskCommand) }
        return flags
    }
}
```

### 5. 权限要求

Mac 端 APP 需要以下权限：

| 权限 | 用途 | 设置路径 |
|------|------|----------|
| 屏幕录制 | 远程桌面屏幕捕获 | 系统偏好设置 > 隐私与安全性 > 屏幕录制 |
| 辅助功能 | 远程输入注入 | 系统偏好设置 > 隐私与安全性 > 辅助功能 |
| 本地网络 | Bonjour 设备发现 | 首次运行时系统提示 |

**权限检查代码:**
```swift
import ScreenCaptureKit

func checkPermissions() async -> Bool {
    // 检查屏幕录制权限
    do {
        _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    } catch {
        // 无权限，引导用户授权
        return false
    }
    
    // 检查辅助功能权限
    let trusted = AXIsProcessTrusted()
    if !trusted {
        // 打开系统偏好设置
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        AXIsProcessTrustedWithOptions(options as CFDictionary)
        return false
    }
    
    return true
}
```

## 完整流程图

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│   Web 端浏览器   │     │  SkyBridge Agent │     │  Mac 端 APP     │
└────────┬────────┘     └────────┬────────┘     └────────┬────────┘
         │                       │                       │
         │  1. WebSocket 连接    │                       │
         │──────────────────────>│                       │
         │                       │                       │
         │  2. auth              │                       │
         │──────────────────────>│                       │
         │                       │                       │
         │  3. auth-ok           │                       │
         │<──────────────────────│                       │
         │                       │                       │
         │                       │  4. Bonjour 发现      │
         │                       │<──────────────────────│
         │                       │                       │
         │  5. devices (推送)    │                       │
         │<──────────────────────│                       │
         │                       │                       │
         │  6. session-join      │                       │
         │──────────────────────>│                       │
         │                       │                       │
         │                       │  7. WebSocket 连接    │
         │                       │<──────────────────────│
         │                       │                       │
         │                       │  8. session-join      │
         │                       │<──────────────────────│
         │                       │                       │
         │  9. sdp-offer         │                       │
         │──────────────────────>│  10. 转发 sdp-offer   │
         │                       │──────────────────────>│
         │                       │                       │
         │                       │  11. sdp-answer       │
         │  12. 转发 sdp-answer  │<──────────────────────│
         │<──────────────────────│                       │
         │                       │                       │
         │  13. ice-candidate    │                       │
         │<─────────────────────>│<─────────────────────>│
         │                       │                       │
         │  14. WebRTC P2P 连接建立                      │
         │<═══════════════════════════════════════════>│
         │                       │                       │
         │  15. 文件传输 / 远程桌面                      │
         │<═══════════════════════════════════════════>│
         │                       │                       │
```

## 注意事项

1. **Agent 必须在本地运行** - Web 端通过 `127.0.0.1:7002` 连接
2. **PNA 权限** - Chrome 需要用户授权访问本地网络
3. **会话 ID** - 使用 UUID v4 生成，确保唯一性
4. **设备 ID** - 建议使用持久化的 UUID，存储在 Keychain
5. **公钥指纹** - 使用 P-256 公钥的 SHA256 哈希（hex 小写）
