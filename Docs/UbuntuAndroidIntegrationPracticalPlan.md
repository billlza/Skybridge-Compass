# Ubuntu / Android 接入落地方案（面向现有 SkyBridge 架构）

## 目标

在**不破坏当前 macOS ↔ iOS 已验证连通性**的前提下，把桌面上的两个独立工程逐步接入现有 SkyBridge 体系：

- Ubuntu 工程：`/Users/bill/Desktop/SkyBridge Compass Ubuntu`
- Android 工程：`/Users/bill/Desktop/SkyBridge Compass - Android`

核心原则：

1. **不改现有信令 payload 协议**
2. **不改现有 DataChannel framing 语义**
3. **不引入平台特有捷径导致协议分叉**
4. **先打通文件传输 / 首帧 / 状态展示，再追求高级能力**

---

## 当前现实判断

### 1. Apple 主线已经是“正确基线”

当前已跑通并验证的能力是：

- WebRTC 只做 **ICE/TURN + DataChannel 可达性**
- DataChannel 上继续复用 **P2P 握手协议**
- 握手成功后，业务消息继续走 **会话密钥 + AES-GCM**
- 文件传输、远程桌面、pairing identity exchange 都复用同一条 framed byte stream

因此，Ubuntu / Android **最稳的接入方式**不是另起炉灶，而是：

- **接同一套 signaling envelope**
- **接同一套 framed DataChannel**
- **接同一套 handshake / rekey / pairing identity exchange**
- **接同一套 file-transfer wire / remote wire**

### 2. Ubuntu 已经比 Android 更接近可落地

Ubuntu 工程并不是空壳，已经存在：

- `skybridge-core/src/webrtc/cross_network_manager.rs`
- `skybridge-core/src/webrtc/signaling_ws.rs`
- `skybridge-core/src/webrtc/session.rs`
- `skybridge-core/src/webrtc/file_transfer_wire.rs`
- `skybridge-core/src/webrtc/remote_wire.rs`

这意味着 Ubuntu 方向更像是**协议对齐 + 实机验收**问题，而不是从零起步。

### 3. Android 工程模块完整，但主传输仍偏“自定义”

Android 工程已经有：

- `:device-discovery`
- `:file-transfer`
- `:screen-mirroring`
- `:remote-control`
- `:shared`

但从源码看，Android 现在仍然更偏：

- WebSocket / 自定义网络层
- MediaProjection / MediaCodec 自己的流媒体链路

而不是已经全面切到与 Apple 完全一致的：

- WebRTC signaling envelope
- WebRTC DataChannel framing
- handshake-over-DataChannel

所以 Android 的工作量会明显大于 Ubuntu。

---

## 统一接入红线

后续 Ubuntu / Android 接入时，必须保持以下不变：

### 信令层

- 继续使用同一套 `sessionId / from / to / type / payload / sentAt`
- 不新增平台私有 envelope 字段作为核心依赖
- 保持和当前 signaling server 完全兼容

### 传输层

- WebRTC DataChannel 使用同一个 label（现有 Apple 路线）
- 同一条 DataChannel 继续承载：
  - handshake frame
  - pairing identity exchange
  - file transfer wire
  - remote desktop wire

### framing

- 继续使用 **4-byte big-endian length prefix**
- 不新增 Android-only / Linux-only framing

### 密码学

- PQC 主线仍以：
  - `ML-KEM-768`
  - `ML-DSA-65`
  为核心
- Classic fallback 仍维持：
  - `X25519`
  - `Ed25519`

### 状态语义

- “connected” 必须与 `readiness == handshakeComplete` 对齐
- 不能只因为 DataChannel open 就在 UI 上显示已连接

---

## 先做什么最稳

建议顺序：

1. **Ubuntu 文件传输跨网打通**
2. **Ubuntu 远程桌面（先 Ubuntu 作为客户端 / 观察端）**
3. **Android 文件传输跨网打通**
4. **Android 远程桌面（先 Android 作为观察端）**
5. **再考虑 Ubuntu 作为被控桌面、Android 作为被控设备**

原因：

- 文件传输比远程桌面简单，最适合先验证协议对齐
- 远程桌面的“作为目标端”在 Linux / Android 上都更复杂
- 尤其：
  - Linux Wayland 输入注入难
  - Android 远控输入注入涉及 Accessibility / 特权 / 系统限制

---

## Ubuntu 落地方案

## U1. 第一阶段：Ubuntu ↔ macOS 文件传输跨网打通

直接利用 Ubuntu 现有 `webrtc/` 模块，对齐现有 Apple 语义：

- signaling：
  - 继续使用当前 server
  - 采用当前分支已补好的 sticky/session-shard 路由方案（内存模式下按 code 前缀回到所属实例）
  - 后续切到 `SIGNALING_STATE_BACKEND=redis` 时，仍保持同一套 `sessionId / from / to / type / payload`，Ubuntu / Android 不需要改 envelope
  - WebSocket 连接加上 `?shard=<sessionId>`
- DataChannel：
  - 二进制模式
  - 4-byte big-endian framing
- handshake：
  - 严格复用当前 P2P handshake transcript 语义
- file transfer：
  - 对齐现有 `CrossNetworkFileTransferMessage`
  - 先做 metadata / chunk / ack / completeAck 全链路

验收标准：

1. Ubuntu 作为发送端，macOS 收到并落盘
2. macOS 作为发送端，Ubuntu 收到并落盘
3. 通知 / 历史 / active transfer 三套 UI 状态都正确

## U2. 第二阶段：Ubuntu ↔ macOS 远程桌面打通

建议**先做 Ubuntu 作为客户端 / 查看端**：

- 原因：macOS 端已有 ScreenCaptureKit 与输入接收路径
- Ubuntu 侧只需要：
  - 接收 screen frames
  - 渲染
  - 回传输入事件

这样风险最低。

### Ubuntu 作为被控桌面（第二优先级）

Ubuntu 作为“远程桌面目标端”复杂度更高，建议拆成两条：

- **X11**：优先实现
  - 屏幕抓取：`XGetImage` / MIT-SHM
  - 输入注入：`XTest`
- **Wayland**：后做
  - 屏幕抓取：PipeWire + xdg-desktop-portal
  - 输入注入：不能假设与 X11 一样，需要 portal / compositor 支持

结论：

- **Ubuntu 目标端先 X11，后 Wayland**
- **Ubuntu 观察端先做，最稳**

## U3. Ubuntu PQC 建议

Ubuntu 当前 Rust workspace 已接：

- `pqcrypto-*`
- `webrtc` feature

建议：

- 继续以 `ML-KEM-768` / `ML-DSA-65` 为主
- 优先做**与 Apple wire / suite 命名完全一致**
- 不要为了“Rust 原生更优雅”重新设计 suite/wire 编码

---

## Android 落地方案

## A1. 第一阶段：Android ↔ macOS 文件传输跨网打通

Android 当前已经有完整模块化结构，但主网络层还没完全对齐 Apple 的 WebRTC/DataChannel 主线。

建议做法：

- 新建一层明确的 **Cross-Network Transport Adapter**
  - 位置可放在 `:core` 或新增 `:cross-network`
- 该层职责只做：
  - signaling envelope
  - WebRTC PeerConnection / DataChannel
  - framed byte stream
- 文件传输模块继续复用现有 UI / repository / history 逻辑

也就是说：

- **替换传输层，不重写文件传输业务层**

## A2. Android WebRTC 选择建议

建议使用**官方 libwebrtc Android AAR / M 系列预编译包**，而不是自己拼 Ktor WebSocket + 自定义 P2P 流。

目标：

- SDP / ICE / DataChannel 行为尽量和 Apple 端一致
- 降低跨平台行为漂移

结论：

- Android 上不要把“现有 WebSocket 传输”继续演化成跨网主线
- 应改成真正的 WebRTC DataChannel 主线

## A3. Android PQC 建议

Android 工程里已经有：

- `Android_PQC_Implementation.md`
- `shared/scripts/build_liboqs_android.sh`

这说明 Android 项目已经为 PQC 做过准备。

**建议主路线：liboqs via JNI**

原因：

1. 与当前 Apple / Ubuntu 的 PQC 语义更接近
2. 方便保持 `ML-KEM-768` / `ML-DSA-65` 线上的一致性
3. 比“纯 Java 自己再来一套”更不容易出现 wire / key 编码漂移

**不建议**一开始就完全依赖 Android 侧自有的另一套 PQC 抽象。

可以保留：

- Android Keystore：设备身份/包裹 classic key
- liboqs JNI：PQC KEM / PQC signature 主执行路径

## A4. Android 远程桌面建议

### Android 作为查看端 / 控制端

这是应该优先做的方向：

- 接收来自 macOS / Ubuntu 的屏幕帧
- 本地渲染
- 发送输入事件

因为：

- 不涉及 Android 目标端权限地狱
- 可以快速进入“真可用”

### Android 作为被控端

这是更后面的能力：

- 屏幕抓取：`MediaProjection`
- 持续运行：前台服务
- 输入注入：
  - 无障碍服务
  - 或 adb / 企业设备特权

结论：

- **Android 作为目标端不要放在第一阶段**
- 否则会把权限、前台服务、电量、OEM 兼容性一次性引爆

---

## signaling / 部署建议（与 Redis 演进兼容）

当前仓库已经补好一个低风险路线：

- HTTP：
  - `/api/lookup/:code`
  - `/api/answer/:code`
  - `/api/ice/:sessionId`
  走 path hash
- WS：
  - `/ws?shard=<sessionId>`
  走 query hash

这套方案的意义：

1. **现在就能支撑多实例，不改协议**
2. **未来 Redis 化时不推倒重来**

后续 Ubuntu / Android 只要照着现有 Apple 一样带 `?shard=<sessionId>` 即可。

---

## 最推荐的实施顺序

### Phase A（最小风险）

1. Ubuntu ↔ macOS：跨网文件传输
2. Ubuntu ↔ macOS：远程桌面（Ubuntu 作为查看端）
3. Android ↔ macOS：跨网文件传输

### Phase B（中风险）

4. Android ↔ macOS：远程桌面（Android 作为查看端）
5. Ubuntu ↔ iOS：文件传输互通
6. Android ↔ iOS：文件传输互通

### Phase C（高风险 / 体验增强）

7. Ubuntu 作为被控桌面（先 X11，后 Wayland）
8. Android 作为被控设备（MediaProjection + Accessibility）
9. signaling 状态外置到 Redis

---

## 我对可行性的最终判断

### Ubuntu

**高可行**

原因：

- 已有 Rust workspace
- 已有 webrtc / remote / p2p / transfer 结构
- 已经比 Android 更接近当前 Apple 主线

### Android

**可行，但必须控制范围**

原因：

- 模块很多，说明 UI/应用层基础不错
- 但跨网主线还没完全统一到 WebRTC/DataChannel
- 如果一上来就追 Android 作为被控端，极容易拖垮节奏

---

## 一句话建议

- **Ubuntu：现在就可以按“文件传输优先、远程桌面查看端第二”推进**
- **Android：先把跨网文件传输对齐到 WebRTC/DataChannel，再做远程桌面查看端**
- **两边都不要先碰“平台作为被控目标端”的 hardest path**
