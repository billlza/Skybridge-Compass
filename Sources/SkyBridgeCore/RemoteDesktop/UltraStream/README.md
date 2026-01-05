# UltraStream v1 - 高性能远程桌面传输协议

## 概述

UltraStream 是专为 macOS 26.0+ 设计的高性能远程桌面传输协议，结合了：

- **Metal 4** 硬件加速渲染
- **CryptoKit PQC** 后量子加密（HPKE X-Wing ML-KEM-768）
- **Network QUIC** 低延迟传输
- **VideoToolbox** HEVC/H.264 硬件编码

## 系统要求

- **macOS 26.0+** (Tahoe) - 2025-09-15 正式发布，原生支持 CryptoKit PQC
- Apple Silicon 推荐（最佳性能）

## 核心特性

### 1. 高性能编码
- 支持 HEVC (H.265) 和 H.264
- 硬件加速编码（VideoToolbox）
- 可配置帧率（15-240 FPS）
- 可配置码率上限
- 智能关键帧间隔

### 2. 后量子加密
- 使用 HPKE X-Wing (ML-KEM-768 + X25519)
- 帧级 AES-GCM 加密
- 端到端安全传输

### 3. 低延迟传输
- QUIC 协议优先
- 自动分片重组
- 支持大帧传输（MTU 可配置）

### 4. 完整集成
- 依赖现有的 `RemoteFrameRenderer`
- 依赖现有的 `RemoteTextureFeed`
- 依赖现有的 `ScreenCaptureKitStreamer`

## 文件位置

```
Sources/SkyBridgeCore/RemoteDesktop/UltraStream/
└── UltraStream.swift  (主实现文件)
```

## 使用示例

### 发送端（屏幕共享）

```swift
import SkyBridgeCore

// 1. 生成会话密钥（通过 HPKE）
let (sessionKey, encapsulatedKey) = try UltraStreamKeyAgreement.createClientContext(
    serverPublicKeyData: serverPublicKey
)

// 2. 创建发送器
let sender = UltraStreamSender(
    host: "192.168.1.100",
    port: 8888,
    symmetricKey: sessionKey,
    config: UltraStreamConfig(
        targetFPS: 60,
        maxResolution: CGSize(width: 3840, height: 2160),
        codec: .hevc,
        keyFrameInterval: 60
    )
)

// 3. 启动
try await sender.start()

// 4. 停止
sender.stop()
```

### 接收端（远程查看）

```swift
import SkyBridgeCore

// 1. 恢复会话密钥（服务端）
let sessionKey = try UltraStreamKeyAgreement.createServerContext(
    serverPrivateKey: privateKey,
    encapsulatedKey: clientEncapsulatedKey,
    seedCiphertext: clientSeedCiphertext
)

// 2. 创建接收器
let receiver = UltraStreamReceiver(
    connection: nwConnection,
    symmetricKey: sessionKey,
    renderer: RemoteFrameRenderer(),
    textureFeed: RemoteTextureFeed()
)

// 3. 启动
receiver.start()

// 4. 停止
receiver.stop()
```

## 协议格式

### 帧头结构（28 字节）

```
字节  0-3  : Magic 'USTR' (0x55535452)
字节  4    : Version (当前为 1)
字节  5    : Flags (handshake/keyFrame/fecEnabled)
字节  6    : Codec (1=H264, 2=HEVC)
字节  7    : Reserved
字节  8-11 : Frame ID
字节 12-15 : Timestamp (毫秒)
字节 16-17 : Width
字节 18-19 : Height
字节 20-21 : Chunk Index
字节 22-23 : Chunk Count
字节 24-27 : Payload Length
```

### 数据流程

1. **编码**：ScreenCaptureKit → VideoToolbox → H.264/HEVC
2. **加密**：AES-GCM (使用 HPKE 协商的对称密钥)
3. **分片**：按 MTU 大小分片
4. **传输**：QUIC/UDP 发送
5. **重组**：接收端重组分片
6. **解密**：AES-GCM 解密
7. **解码**：VideoToolbox 解码 → Metal 渲染

## 性能优化建议

1. **局域网环境**：
   - 使用 HEVC 编码
   - 帧率设置为 60 FPS
   - MTU 设置为 1400

2. **高分辨率（4K+）**：
   - 降低帧率至 30-45 FPS
   - 增加码率上限
   - 使用 HEVC 编码

3. **低延迟场景**：
   - 缩短关键帧间隔（10-30 帧）
   - 使用 H.264 Baseline Profile
   - 降低 MTU 至 1200

## 安全注意事项

1. **密钥管理**：
   - 服务端私钥应存储在 Keychain 中
   - 公钥可以通过 Supabase 或受信密钥系统分发
   - 会话密钥应定期轮换

2. **网络传输**：
   - 建议在 VPN 或受信网络中使用
   - 可以结合 TLS 进行双重加密

3. **身份验证**：
   - 结合 `TrustedKeysBootstrap` 进行设备身份验证
   - 使用 `RemoteDesktopManager.getTrustedKeys()` 验证对端

## 集成到 RemoteDesktopManager

UltraStream 可以作为 `RemoteDesktopManager` 的一个可选协议：

```swift
// 在 RemoteDesktopManager 中添加
@available(macOS 26.0, *)
public func connectWithUltraStream(
    host: String,
    port: UInt16,
    serverPublicKey: Data
) async throws {
    // 1. HPKE 密钥协商
    let (sessionKey, encKey) = try UltraStreamKeyAgreement.createClientContext(
        serverPublicKeyData: serverPublicKey
    )
    
    // 2. 创建 UltraStream 发送器
    let sender = UltraStreamSender(
        host: host,
        port: port,
        symmetricKey: sessionKey
    )
    
    // 3. 启动并管理生命周期
    try await sender.start()
    // ... 保存到会话管理
}
```

## 故障排查

### 编译错误
- 确保 macOS 部署目标为 26.0+
- 检查 CryptoKit 是否支持 HPKE X-Wing

### 运行时错误
- 检查网络连接状态
- 验证 HPKE 密钥协商是否成功
- 确认 VideoToolbox 编码器可用

### 性能问题
- 降低帧率或分辨率
- 检查网络带宽
- 使用 HEVC 编码（更高效）

## 未来改进

- [ ] 支持前向纠错 (FEC)
- [ ] 自适应码率控制
- [ ] 多路复用支持
- [ ] 音频传输集成
- [ ] 输入事件传输

## 许可证

与 SkyBridge Compass Pro 主项目相同。

