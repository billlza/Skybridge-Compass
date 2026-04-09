# SkyBridge Compass - Android 跨平台互操作性设计文档

## 概述

本文档详细说明了 Android 端与 iOS/macOS 端在文件传输和远程控制功能上的跨平台互操作性实现。

## 1. 文件传输协议兼容性

### 1.1 协议格式

与 iOS/macOS `FileTransferEngine` 完全兼容的协议格式：

```
+----------------+
| Magic: "SBFT"  |  4 bytes
+----------------+
| Version        |  2 bytes (Little-Endian)
+----------------+
| MessageType    |  1 byte
+----------------+
| Flags          |  1 byte
+----------------+
| PayloadLength  |  4 bytes (Little-Endian)
+----------------+
| Payload        |  [PayloadLength] bytes
+----------------+
```

### 1.2 消息类型

| 类型 | 值 | 说明 |
|------|-----|------|
| METADATA | 0x01 | 文件元数据 |
| CHUNK | 0x02 | 数据块 |
| COMPLETE | 0x03 | 传输完成 |
| ACK | 0x04 | 确认 |
| RESUME_REQ | 0x05 | 断点续传请求 |
| RESUME_ACK | 0x06 | 断点续传确认 |
| ERROR | 0x07 | 错误 |
| CANCEL | 0x08 | 取消 |

### 1.3 数据块头部格式

与 iOS/macOS `FileChunkPacket` 兼容：

```
+------------------+
| transferId       |  36 bytes (UTF-8, 0-padded)
+------------------+
| chunkIndex       |  4 bytes (Big-Endian)
+------------------+
| totalChunks      |  4 bytes (Big-Endian)
+------------------+
| dataLength       |  8 bytes (Big-Endian)
+------------------+
| checksum         |  64 bytes (SHA-256 hex, space-padded)
+------------------+
| flags            |  1 byte
+------------------+
| timestamp        |  8 bytes (Double, Unix timestamp in seconds)
+------------------+
```

### 1.4 加密与压缩

| 特性 | Android 实现 | iOS/macOS 实现 | 兼容性 |
|------|-------------|---------------|--------|
| 加密 | AES-256-GCM | AES-256-GCM | ✅ 完全兼容 |
| 压缩 | DEFLATE | LZFSE/DEFLATE | ✅ DEFLATE 互通 |
| 校验和 | SHA-256 | SHA-256 | ✅ 完全兼容 |
| Merkle 树 | SHA-256 | SHA-256 | ✅ 完全兼容 |

### 1.5 关键实现文件

- `CrossPlatformFileTransferProtocol.kt` - 协议定义和序列化
- `CrossPlatformFileTransferService.kt` - 完整的文件传输服务

## 2. 远程控制协议兼容性

### 2.1 协议格式

与 iOS/macOS `RemoteDesktopManager` 兼容的协议格式：

```
+----------------+
| Magic: "SBRC"  |  4 bytes
+----------------+
| Version        |  2 bytes (Little-Endian)
+----------------+
| EventType      |  1 byte
+----------------+
| Flags          |  1 byte
+----------------+
| Timestamp      |  8 bytes (Double, Unix timestamp in seconds)
+----------------+
| PayloadLength  |  4 bytes (Little-Endian)
+----------------+
| Payload        |  [PayloadLength] bytes
+----------------+
```

### 2.2 事件类型

| 事件 | 值 | 说明 |
|------|-----|------|
| MOUSE_MOVE | 0x01 | 鼠标移动 |
| MOUSE_DOWN | 0x02 | 鼠标按下 |
| MOUSE_UP | 0x03 | 鼠标释放 |
| MOUSE_SCROLL | 0x04 | 鼠标滚轮 |
| KEY_DOWN | 0x10 | 按键按下 |
| KEY_UP | 0x11 | 按键释放 |
| KEY_REPEAT | 0x12 | 按键重复 |
| TOUCH_BEGIN | 0x20 | 触摸开始 |
| TOUCH_MOVE | 0x21 | 触摸移动 |
| TOUCH_END | 0x22 | 触摸结束 |
| SESSION_START | 0x80 | 会话开始 |
| SESSION_END | 0x81 | 会话结束 |

### 2.3 键码映射

完整的 Android KeyCode ↔ macOS Virtual Key Code 映射：

```kotlin
// 示例映射
29 (A) -> 0x00
30 (B) -> 0x0B
62 (SPACE) -> 0x31
66 (ENTER) -> 0x24
67 (DELETE) -> 0x33
```

### 2.4 修饰键映射

| Android Meta State | macOS ModifierFlags |
|-------------------|---------------------|
| META_SHIFT_* | 0x00020000 (Shift) |
| META_CTRL_* | 0x00040000 (Control) |
| META_ALT_* | 0x00080000 (Option) |
| META_META_* | 0x00100000 (Command) |
| META_CAPS_LOCK | 0x00010000 (Caps Lock) |

### 2.5 事件转换

| macOS 事件 | Android 转换 |
|-----------|-------------|
| 鼠标左键点击 | 触摸点击 (TAP) |
| 鼠标右键点击 | 长按 (LONG_PRESS) |
| 鼠标滚轮 | 滑动手势 (SWIPE) |
| 键盘输入 | 文本注入 / 全局操作 |

### 2.6 关键实现文件

- `CrossPlatformRemoteControlProtocol.kt` - 协议定义和键码映射
- `CrossPlatformRemoteControlService.kt` - 远程控制服务

## 3. AccessibilityService 要求

远程控制功能需要 `AccessibilityService` 来注入输入事件：

```xml
<service
    android:name=".remotecontrol.service.SkyBridgeAccessibilityService"
    android:permission="android.permission.BIND_ACCESSIBILITY_SERVICE">
    <intent-filter>
        <action android:name="android.accessibilityservice.AccessibilityService"/>
    </intent-filter>
    <meta-data
        android:name="android.accessibilityservice"
        android:resource="@xml/accessibility_service_config"/>
</service>
```

### 3.1 支持的操作

| 操作 | API 级别 | 实现方式 |
|------|---------|---------|
| 触摸手势 | 24+ | dispatchGesture() |
| 滑动手势 | 24+ | dispatchGesture() |
| 返回键 | 16+ | GLOBAL_ACTION_BACK |
| Home 键 | 16+ | GLOBAL_ACTION_HOME |
| 最近任务 | 16+ | GLOBAL_ACTION_RECENTS |
| 文本输入 | 21+ | ACTION_SET_TEXT |

## 4. 设置界面占位符修复

### 4.1 已识别的占位符

| 模块 | 文件 | 问题 | 状态 |
|------|------|------|------|
| 文件传输 | FileTransferProtocolManager.kt | 网络发送为占位实现 | ✅ 已用 CrossPlatformFileTransferService 替代 |
| 文件传输 | FileTransferNetworkServiceImpl.kt | 加密/压缩服务为占位 | ✅ 已在协议层实现 |
| 远程控制 | RemoteControlManager.kt | 事件注入为占位 | ✅ 已用 CrossPlatformRemoteControlService 替代 |

### 4.2 设置界面功能状态

| 设置项 | 状态 | 备注 |
|--------|------|------|
| 深色模式 | ✅ 已实现 | AppSettingsStore (DataStore Preferences) |
| 自动连接 | ✅ 已实现 | AppSettingsStore (DataStore Preferences) |
| 通知 | ✅ 已实现 | AppSettingsStore (DataStore Preferences) |
| 端口范围 | ✅ 已实现 | NetworkSettingsStore |
| 发现超时 | ✅ 已实现 | NetworkSettingsStore |
| 连接重试 | ✅ 已实现 | NetworkSettingsStore |
| 屏幕镜像开关 | ✅ 已实现 | DeveloperSettingsStore |
| 远程控制开关 | ✅ 已实现 | DeveloperSettingsStore |
| 文件传输开关 | ✅ 已实现 | DeveloperSettingsStore |

### 4.3 设置持久化架构

```
AppSettingsStore (app_settings)
├── dark_mode: Boolean
├── auto_connect: Boolean  
├── notifications_enabled: Boolean
├── use_dynamic_color: Boolean
├── haptic_feedback: Boolean
├── keep_screen_on: Boolean
└── battery_opt_warning: Boolean

NetworkSettingsStore (network_settings)
├── port_range_start: Int
├── port_range_end: Int
├── discovery_timeout_ms: Long
├── max_reconnect_attempts: Int
├── tls_strict_mode: Boolean
├── handshake_enabled: Boolean
└── encryption_mode: String

DeveloperSettingsStore (developer_settings)
├── enable_screen_mirroring: Boolean
├── enable_remote_control: Boolean
└── enable_file_transfer: Boolean
```

## 5. 使用示例

### 5.1 发送文件到 macOS

```kotlin
val service = CrossPlatformFileTransferService(context)

// 监听传输状态
service.transferStateFlow.collect { state ->
    when (state) {
        is TransferState.Progress -> {
            println("进度: ${state.bytesTransferred}/${state.totalBytes}")
        }
        is TransferState.Completed -> {
            println("传输完成")
        }
        is TransferState.Failed -> {
            println("传输失败: ${state.error}")
        }
    }
}

// 发送文件
service.sendFile(
    fileUri = fileUri,
    remoteAddress = "192.168.1.100",
    remotePort = 8080,
    encryptionKey = sessionKey, // 可选，来自 PQC 握手
    enableCompression = true
)
```

### 5.2 远程控制会话

```kotlin
val service = CrossPlatformRemoteControlService(context)

// 设置 AccessibilityService
service.setAccessibilityService(accessibilityService)
service.setScreenSize(1080, 1920)

// 启动会话
val sessionId = service.startSession(
    remoteAddress = "192.168.1.100",
    remotePort = 5901,
    deviceId = "android-device-id",
    deviceName = "My Android"
).getOrThrow()

// 发送触摸事件到 macOS
service.sendTouchEvent(
    sessionId = sessionId,
    touchId = 0,
    x = 500f,
    y = 800f,
    pressure = 1f,
    eventType = EventType.TOUCH_BEGIN
)
```

## 6. 安全考虑

1. **传输加密**: 所有数据传输使用 AES-256-GCM 加密，密钥来自 PQC/Classic 混合握手
2. **完整性验证**: 使用 SHA-256 校验和和 Merkle 树验证数据完整性
3. **PQC 签名**: 支持 ML-DSA-65 文件签名验证
4. **会话认证**: 基于设备 ID 和会话配置的身份验证

## 7. 已知限制

1. **远程控制方向**: 目前主要支持 macOS → Android 方向的控制
2. **屏幕捕获**: Android 端屏幕镜像需要 MediaProjection 权限
3. **按键注入**: 部分按键无法直接注入，使用全局操作替代
4. **音频**: 远程音频传输尚未实现

## 8. 后续优化

1. 实现 WebRTC 作为可选传输协议
2. 添加屏幕镜像 (Android → macOS) 支持
3. 实现音频流传输
4. 优化大文件传输的内存使用
5. 添加传输队列管理

