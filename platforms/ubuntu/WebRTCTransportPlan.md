## WebRTC / Cross-Network 传输对齐（macOS/iOS 只读调研结论 + Linux 落地计划）

### 1. 只读调研结论：macOS/iOS 已经“打通”了吗？
结论：**已打通**。

- **WebRTC 仅作为传输层**：负责 ICE/TURN + DataChannel 可达性。
- **DataChannel 上复用 P2P 握手**：双方把 DataChannel 当作一条 **length-framed byte stream**：
  - 4-byte big-endian length
  - payload bytes
- **握手后应用层加密**：握手成功拿到 `SessionKeys` 后，DataChannel payload 走 **AES-GCM**（再叠加 traffic padding / handshake padding）。
- **同一条通道承载多类业务**：握手帧 + pairing identity 交换 + 文件传输 wire + 远控输入/屏幕数据等，均复用“frame →（可选解密）→ decode”模式。

关键只读入口（macOS）：
- `Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift`
  - `startWebRTCInboundHandshakeAndControlLoop(...)`
  - `consumeInboundHandshakeOrControlChannelWebRTC(...)`
- `Sources/SkyBridgeCore/RemoteConnection/WebRTC/WebRTCSession.swift`
- `Sources/SkyBridgeCore/RemoteConnection/WebRTC/WebRTCSignalingEnvelope.swift`

关键只读入口（iOS）：
- `SkyBridgeCompassiOS/Sources/Managers/CrossNetworkWebRTCManager.swift`
  - `startHandshakeOverWebRTC(...)`（iOS 作为 initiator）
  - `receiveLoop(...)`（统一处理握手帧/业务帧）

### 2. Linux 侧对齐目标（不复制、不修改 Apple 代码）
Linux 侧要对齐的是 **“分层与 wire 行为”**，而不是具体实现代码：

- **传输层**：QUIC（LAN）与 WebRTC（跨网）都应该产出同一种抽象：`Frame = length-prefix + payload`
- **握手层**：复用现有 Rust `HandshakeDriver`（已做 deterministic wire 对齐）
- **安全层**：握手完成后，业务帧用 `SessionKeys` 做 AES-GCM（并可选 padding）
- **业务层**：文件传输 / 远程桌面 / pairing identity 等，都跑在“解密后的业务 payload”上

### 3. 本仓库已落地的第一步（接口/工具）
为了对齐 macOS/iOS 的 framing（以及与我们现有 QUIC framing 一致），新增了：
- `skybridge-core/src/p2p/framing.rs`
  - `encode_frame(...)`
  - `FrameDecoder`（支持 DataChannel 那种 chunked 输入：一次 push 可能拆/并多个 frame）

同时新增了一个“跨网通道状态机”，用于在任意传输层上复用握手与应用层加密：
- `skybridge-core/src/p2p/cross_network.rs`
  - `CrossNetworkChannel`：握手前处理 raw handshake frame；握手后 AES-GCM 解密/加密业务 frame
  - `CrossNetworkInbound`：输出事件（出站帧 / 业务明文 / 握手已建立）

### 4. 最小可用 WebRTC DataChannel 实现路径（Ubuntu 侧）
#### 4.1 依赖选型（推荐顺序）
1) **libdatachannel + Rust bindings**（最贴近 “DataChannel byte pipe”，实现成本低）
2) `webrtc`（Rust 版 pion 移植）——纯 Rust，但工程量更大、依赖面更广
3) GStreamer WebRTC —— 适合“媒体栈”，但对我们这种 DataChannel 控制/文件更重

#### 4.2 信令复用策略
macOS/iOS 的信令 envelope 很明确：`WebRTCSignalingEnvelope { sessionId, from, to?, type, payload }`。
Linux 侧可以直接实现同构 JSON（字段名/含义保持一致），走：
- WebSocket signaling（同 sessionId room）
- offer/answer/iceCandidate/join/leave

**注意**：这里是“协议兼容”，不是拷贝代码；Linux 用自己的实现即可。

#### 4.3 与现有 QUIC 共存
建议把“连接类型”升级为：
- **LAN**：保持当前 QUIC（`quinn`) 作为默认
- **CrossNetwork**：新增 WebRTC DataChannel transport（同样喂给 handshake + app crypto）

选择策略：
- 发现到 LAN 地址可达（或延迟低）→ 优先 QUIC
- 否则 → WebRTC

#### 4.4 最小闭环步骤（MVP）
1) DataChannel ready 后，按 macOS/iOS 的 framing 发送/接收 raw handshake 帧（MessageA/B/Finished/Error）
2) handshake established 后：
   - `SessionKeys` 绑定到该 WebRTC session
   - 业务 payload AES-GCM 加密后再 frame 发送
3) 先接通 2 类业务即可：
   - pairing identity exchange（用于 device_id/kem keys 的互认）
   - CrossNetworkFileTransferWire（JSON-codable + chunk/ack）


