# Android WebRTC Signaling Alignment Plan

## 当前判断

Android 工程当前还没有接到与 macOS / iOS / Ubuntu 一致的跨网主线：

- 还没有稳定的 `sessionId / from / to / type / payload / sentAt` signaling envelope
- 还没有统一的 WebRTC DataChannel framed byte stream
- 还没有把 P2P handshake 复用到 DataChannel 上
- 当前 `MirroringNetworkService` 里的 WebRTC 仍偏占位实现，不适合直接硬补协议

因此，Android 这阶段**先不要围绕旧 WebSocket/自定义传输做增量修修补补**，而是按现有 Apple / Ubuntu 已验证链路做对齐。

## 必须对齐的主线

### 1. Signaling

统一到：

- `sessionId`
- `from`
- `to?`
- `type`
- `payload`
- `sentAt`

消息类型保持与 Apple 一致：

- `join`
- `offer`
- `answer`
- `iceCandidate`
- `leave`

WebSocket URL 连接时带：

- `?shard=<sessionId>`

这样可以直接兼容当前：

- memory + sticky/session-shard
- 以及后续 `SIGNALING_STATE_BACKEND=redis`

### 2. WebRTC 传输

WebRTC 只负责：

- ICE / TURN
- DataChannel 可达性

不要在 Android 上单独设计另一套媒体/控制协议。

### 3. DataChannel framing

统一使用：

- `4-byte big-endian length prefix`
- payload 原样送入上层

不要引入 Android-only framing。

### 4. Handshake

DataChannel ready 后：

- 复用现有 P2P handshake transcript
- 复用现有 session key 派生
- 复用现有 rekey / pairing identity exchange

### 5. 应用消息

握手完成后，同一条 framed stream 继续承载：

- file transfer wire
- remote desktop wire
- pairing identity exchange
- heartbeat / control

## Android 代码落点

建议新增一层明确的 `cross-network` / `webrtc-transport` 适配层，职责只做：

1. signaling envelope
2. PeerConnection / DataChannel
3. framed byte stream
4. handshake driver 桥接

然后让现有：

- `file-transfer`
- `screen-mirroring`
- `remote-control`

继续复用 UI、repository、状态管理，不要在业务层重复造协议。

## 推荐实施顺序

1. Android ↔ macOS 文件传输跨网打通
2. Android ↔ iOS 文件传输跨网打通
3. Android 作为远程桌面观察端
4. 再考虑 Android 作为被控目标端

## 本轮和服务端的关系

服务端已演进到：

- `memory` 默认
- `redis` 可开关
- sticky/session-shard 继续保留

所以 Android 接入时：

- **不需要改 signaling payload**
- **不需要感知 Redis 细节**
- 只需要保证 `WebSocket + shard=sessionId` 与 envelope 对齐

## 暂不建议做的事

- 不要继续扩展旧的自定义 WebSocket 媒体协议
- 不要在 Android 侧单独定义另一套 answer / ICE / room model
- 不要先做“远程桌面目标端”再补文件传输
