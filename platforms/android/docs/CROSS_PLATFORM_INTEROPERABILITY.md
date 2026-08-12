# SkyBridge Compass - Android 跨平台互操作性设计文档

## 概述

本文档记录 Android 端与 macOS/iOS 的 current-path 互操作边界，并明确哪些内容仍只是 legacy/lab 协议或未完成证明。任何“兼容”声明都必须以 `docs/REAL_DEVICE_INTEROP_RUNBOOK.md` 中的真机 artifact 为准。

当前可作为 Android <-> Apple 互操作主路径的内容：

- Bonjour / NSD 发现真实 Apple peer，并记录 device id 与 fingerprint。
- WebRTC code-based session 使用 SBWC application envelope，PQC 默认开启。
- Q-Periapt 验证必须精确断言 `Q_PERIAPT_CONTEXT_BOUND` / `0x0011`，不能用 X-Wing 或 ML-KEM 成功替代。
- WebRTC 文件传输使用 `WebRtcFileTransferController` 与 `CrossNetworkFileTransferMessage`，验收必须包含 bytes、chunk ACK、complete ACK 和 SHA-256 receipt。
- LAN remote smoke 当前只证明 secure session 与 screen frame received；mouse、keyboard、text、clipboard 需要额外手工或 UI automation artifact。

Windows 互操作不是本文档的已完成项。Android <-> Windows 必须另有 Windows native DNS-SD、live file-transfer、live remote-desktop evidence；否则只能称为 proof gap。

## 1. 文件传输 current path

### 1.1 WebRTC / SBWC 文件传输

发布路径使用 WebRTC data channel 上的 SBWC application envelope 承载 `CrossNetworkFileTransferMessage`，而不是旧的裸 `SBFT` LAN binary framing。

关键实现文件：

- `file-transfer/src/main/kotlin/com/skybridge/compass/filetransfer/webrtc/WebRtcFileTransferController.kt`
- `file-transfer/src/main/kotlin/com/skybridge/compass/filetransfer/webrtc/CrossNetworkFileTransferValidator.kt`
- `shared` 模块中的 `CrossNetworkFileTransferMessage` / `CrossNetworkFileTransferOp`

验收要求：

- metadata、chunk、complete、error 都必须通过 validator。
- 发送端和接收端 evidence 必须包含非零 transferred bytes、chunk ACK、complete ACK、最终 SHA-256 receipt、session id 和 peer digest。
- 失败必须暴露为明确阶段和错误原因，不能把失败包装成空结果或“已完成”。

### 1.2 Legacy / lab SBFT

旧的 `SBFT` / `CrossPlatformFileTransferProtocol.kt` / `CrossPlatformFileTransferService.kt` 只能作为历史协议或实验路径阅读。它们不能单独支撑当前发布版“与 macOS/iOS 完全兼容”的声明，也不能替代 WebRTC/SBWC 文件传输 artifact。

## 2. 远程控制 current path

### 2.1 Android as viewer/client

Android public app release 是 macOS/iOS peer 的 remote-desktop viewer/control client。Android 端发送远端输入事件并解码安全屏幕帧；发布包不得暴露 Android-as-host 行为。

关键实现文件：

- `app/src/debug/kotlin/com/skybridge/compass/android/debug/DebugLanInteropSmokeActivity.kt`
- `core` 模块中的 `MacRemoteControlClient`
- `core` 模块中的 remote-control secure envelope / trusted-session policy

### 2.2 证明边界

| 能力 | 当前证明状态 | 验收要求 |
|------|-------------|---------|
| Bonjour / `_skybridge-remote._tcp` 发现 | Android <-> macOS LAN smoke 可证明 | artifact 记录 expected device id 与 fingerprint |
| 安全会话与屏幕帧 | 自动 smoke 可证明 `secure_frame_received` | `android-status.log` 记录 secure state，summary 记录 frame success |
| mouse / keyboard / text / clipboard | 自动 smoke 尚不能证明 | 必须有手工或 UI automation artifact 记录输入动作与 host-side effect |
| Android 作为 host | 发布路径不支持 | packaging audit 必须证明 host service / MediaProjection / Accessibility 入口未打包 |
| Windows remote desktop | 未完成证明 | 需要 Windows artifact 记录 frame、input path、notice lifecycle、disconnect truth |

### 2.3 Legacy / lab SBRC

旧的 `SBRC` / `CrossPlatformRemoteControlProtocol.kt` / `CrossPlatformRemoteControlService.kt` 只能作为协议历史或实验路径。当前发布版 remote desktop 验收以 secure envelope、trusted session policy、screen-frame artifact 和 input-closure artifact 为准。

## 3. Android Release 方向

Android public app release is a remote-desktop viewer/control client for macOS/iOS peers. It must
not expose Android-as-host behavior in the shipping APK. In particular, the app manifest must not
declare an Accessibility service, MediaProjection foreground service, overlay permission, camera
permission, or audio-recording permission for remote-control hosting. The legacy Android host
module can remain in source for lab work, but packaging audit must keep it out of the app artifact.

### 3.1 支持的远端操作

| 操作 | API 级别 | 实现方式 |
|------|---------|---------|
| 指针点击/拖动 | 36+ | Android client sends remote-control wire events |
| 文本输入 | 36+ | Android client sends remote text payloads |
| 远端屏幕帧 | 36+ | Android client decodes secure screen frames |
| 最近任务 | 16+ | GLOBAL_ACTION_RECENTS |
| 文本输入 | 21+ | ACTION_SET_TEXT |

## 4. 设置界面占位符修复

### 4.1 已识别的占位符

| 模块 | 文件 | 问题 | 状态 |
|------|------|------|------|
| 文件传输 | FileTransferProtocolManager.kt | 网络发送为占位实现 | 发布路径改为 WebRTC/SBWC `WebRtcFileTransferController` |
| 文件传输 | FileTransferNetworkServiceImpl.kt | 加密/压缩服务为占位 | ✅ 已在协议层实现 |
| 远程控制 | RemoteControlManager.kt | 事件注入为占位 | 发布路径改为 Android viewer/client + secure remote-control envelope |

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

### 5.1 文件传输验收入口

文件传输的发布验收必须走 WebRTC/SBWC 会话，并在 artifact 中记录 bytes、ACK 与 SHA-256 receipt。旧的 `CrossPlatformFileTransferService` 代码片段不再作为 current-path 示例。

可执行入口见 `docs/REAL_DEVICE_INTEROP_RUNBOOK.md`：

- Android <-> Apple WebRTC smoke: `scripts/run_android_apple_webrtc_smoke.sh`
- Signed release APK packaging audit: `scripts/check_android_packaged_placeholders.sh --mode formal --apk <signed-release.apk> --mapping app/build/outputs/mapping/release/mapping.txt --audit-metadata app/build/outputs/release-audit/release/metadata.properties --expected-cert-sha256 "$EXPECTED_ANDROID_SIGNING_CERT_SHA256" --expected-commit "$(git rev-parse HEAD)"` (certificate fingerprint comes from the approved release-key channel, not the inspected APK; canonical Git worktree must be clean)
- Signed release AAB formal audit: `scripts/check_android_release_aab.sh --aab <signed-release.aab> --mapping app/build/outputs/mapping/release/mapping.txt --audit-metadata app/build/outputs/release-audit/release/aab-metadata.properties --bundletool <official-bundletool-all-1.18.3.jar> --expected-upload-cert-sha256 "$EXPECTED_ANDROID_UPLOAD_CERT_SHA256" --expected-commit "$(git rev-parse HEAD)"` (proves only the independently approved upload certificate; Play app-signing/distribution certificate and delivered APK remain a separate Play gate)
- Windows peer: 需要 Windows 侧 live file-transfer evidence，Android 本仓库不能单独证明

### 5.2 远程桌面 client 会话

```kotlin
val client = MacRemoteControlClient(context)
client.connect(
    target = MacRemoteControlClient.ConnectionTarget(
        host = "192.168.1.100",
        port = 5901,
        displayName = "MacBook Pro"
    ),
    enableHandshake = true,
    securityConfig = MacRemoteControlClient.SecurityConfig(
        encryptionRequired = true,
        allowPlaintextFallback = false
    )
)

// Android sends remote input to the macOS/iOS peer; it does not inject input into Android itself.
client.sendMouseMove(x = 500.0, y = 800.0)
```

## 6. 安全考虑

1. **传输加密**: 所有数据传输使用 AES-256-GCM 加密，密钥来自 PQC/Classic 混合握手
2. **完整性验证**: 使用 SHA-256 校验和和 Merkle 树验证数据完整性
3. **PQC 签名**: 支持 ML-DSA-65 文件签名验证
4. **会话认证**: 基于设备 ID 和会话配置的身份验证

## 7. 已知限制

1. **远程控制方向**: public Android app 支持 Android → macOS/iOS 方向，不发布 Android 被控入口
2. **屏幕捕获**: public Android app 不申请 MediaProjection；远端屏幕帧来自 macOS/iOS peer
3. **按键注入**: Android 作为 client 发送远端输入事件，本机不启用 Accessibility 注入
4. **音频**: 远程音频传输尚未实现

## 8. 后续优化

1. 补齐 mouse / keyboard / text / clipboard 的自动化 input-closure artifact
2. 补齐 Android <-> Windows native discovery、live file-transfer、live remote-desktop evidence
3. 实现音频流传输
4. 优化大文件传输的内存使用
5. 添加传输队列管理
