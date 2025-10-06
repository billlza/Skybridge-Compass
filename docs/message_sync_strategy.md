# 云桥司南跨端消息同步方案建议

## 设计目标
- **跨平台一致性**：保证 Android 与 iOS 端登录同一账户的设备能以等效能力收发消息。
- **低时延直连**：两台设备靠近时优先走局域或近场链路，降低 RTT，满足实时互动需求。
- **安全可靠**：全链路加密、端到端身份校验与断线重连保障。
- **离线容错**：网络受限时仍能保留消息并在恢复后同步，避免数据丢失。

## 协议与传输层建议
### 1. 近场直连（优先级最高）
- **发现机制**：复用现有 `BridgeConnectionCoordinator` 的近场发现模块，结合 BLE Advertising + Wi‑Fi Aware/Bonjour mDNS 发布服务，实现跨平台发现。
- **链路建立**：
  - 首选 **WebRTC DataChannel (SCTP over DTLS)** 搭配 **ICE**，在局域网或热点环境下实现点对点低延迟通道；
  - 保留 **QUIC P2P** 备用通道，兼容不支持 WebRTC 的未来扩展设备。
- **安全性**：沿用登录态的 Nubula ID + 会话令牌进行 DTLS/SRTP 指纹校验，确保同一账户的双端互信。

### 2. 云端中继与同步
- **信令层**：基于 **MQTT over QUIC** 的全双工通道，Topic 结构建议为：
  - `accounts/{nubulaId}/devices/{deviceId}`：设备在线状态与能力汇报；
  - `accounts/{nubulaId}/messages/{threadId}`：消息队列与回执；
  - `presence/{region}/{nubulaId}`：跨区域状态广播，方便近场发现失败时回落。
- **消息存储**：采用多副本的 **Event Sourcing**（时间序列日志），消息体以 **Protocol Buffers** 序列化，便于增量同步与版本演进。
- **推送唤醒**：在 iOS 端结合 **APNs VoIP Push**，Android 端结合 **FCM 高优先级通知**，拉起后再走 MQTT/QUIC 长连接。

### 3. 同步流程
1. 设备成功登录后向 MQTT/QUIC 信令服务注册在线状态，携带当前支持的近场能力（Wi‑Fi Direct、UWB、BLE、NFC 等）。
2. 若检测到同账号另一台在线设备且在近场范围，则发起 WebRTC/QUIC P2P 建链，消息走 DataChannel；
3. 若近场失败或跨区域，则落到云中继：消息写入事件日志，并通过 MQTT 推送到目标设备；
4. 设备收到消息后本地落盘（Room/Realm 数据库），返回回执并更新已读游标；
5. 断线期间的离线消息在重新上线时通过 `syncToken` 批量拉取。

## 消息格式与能力扩展
- **基础字段**：`messageId`、`threadId`、`senderDeviceId`、`timestamp`, `ttl`, `payloadType`。
- **扩展负载**：支持文本、指令、媒体（照片/视频/音频/GIF/文档）、设备控制信令；通过 `oneof`/多态编码减少解析开销。
- **端到端加密**：可接入 **双棘轮 (Double Ratchet)** + X3DH 预密钥机制，保证云端仅存密文。

## 同步冲突与状态
- 利用 **Lamport Clock** 或 **Vector Clock** 解决多设备同时编辑导致的顺序冲突；
- 重要状态（例如远程桌面权限升级）走幂等指令事件，消费端按版本号比对应用。

## 运维与监控建议
- 指标采集：信令 RTT、P2P成功率、MQTT主题滞留量、消息端到端时延；
- 异常恢复：提供灰度限流、离线缓存上限、失败重试指数回退策略；
- 客户端日志：统一格式（JSON Lines），便于上传诊断。

## 下一步实施顺序
1. 在 `BridgeConnectionCoordinator` 中实现 MQTT/QUIC 客户端与 Topic 订阅，打通基础在线状态同步。
2. 增强 Device Discovery 模块支持 BLE + Wi‑Fi Aware 的跨平台发现能力。
3. 为消息模块引入事件日志存储与离线补拉 API。
4. 接入端到端加密与多媒体消息编解码（复用现有文件传输格式表）。
5. 编写集成测试：模拟双端并发、离线重连、弱网切换等场景验证可靠性。

通过以上组合，可以在近场场景提供媲美本地的低延迟体验，在远场借助云中继保持可靠同步，同时确保数据安全与多媒体扩展能力。
