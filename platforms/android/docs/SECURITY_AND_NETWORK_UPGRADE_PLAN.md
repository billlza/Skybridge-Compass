# Android 安全与网络升级设计文档

版本：v0.2  日期：2025-10-27  范围：远程控制、文件传输与用户认证

## 目标
- 统一端到端加密到 AEAD（AES/GCM/NoPadding），提供完整性与抗篡改。
- 引入握手与密钥协商（Noise XX / 简化 ECDH），实现认证、会话密钥与轮换。
- 强制 TLS 与证书固定（WebSocket/HTTP），其余通道采用自定义握手与 AEAD。
- 使用 Android Keystore 管理密钥，避免明文或可导出密钥。
- 增强可靠性（统一重试、UDP 可靠性、WebRTC STUN/TURN），完善性能监控与测试。
- 与 Supabase 账户系统对接，实现与 macOS 等效的登录认证体验（跨端账号复用）。

## 现状概述
- 远控：现有 AES/CBC/PKCS5Padding，缺少认证与握手；消息在各协议分散处理。
- 文件传输：`FileEncryptionService` 为占位，未加密；网络层仅 GZIP 与校验和。
- 网络客户端：Ktor/OkHttp 未配置严格 TLS、证书固定；密钥未用 Keystore。
- 可靠性、性能与测试体系不足（缺少 UDP 可靠性、端到端监控与安全回归）。
- 账户系统：已接入 Supabase URL/Anon Key（BuildConfig），登录流程与 UI 待完善。

## 总体方案
- 安全层：统一“握手 + 会话密钥 + AEAD”的通道抽象，适配 TCP/UDP/WebSocket/WebRTC。
- TLS 层：HTTP/WS 强制 TLS，启用证书固定与严格 ConnectionSpec。
- 存储层：Android Keystore 存储会话密钥（可轮换），DataStore 管理配置项。
- 可靠性：统一重试与回退策略；为 UDP 引入轻量 RUDP（seq/ack/窗口/重传）。
- 账户层：Supabase Auth（Email/Password 起步，扩展到 OAuth/TOTP/Passwordless）。

## 加密与握手设计
- 算法：`AES/GCM/NoPadding`，密钥 256 位，`nonce` 12 字节随机，`tag` 16 字节。
- 消息格式（示例）：`[version:1][flags:1][sessionId:4][seq:4][timestamp:8][nonce:12][ciphertext+tag:N]`。
- 握手（推荐）：Noise `XX` 模式或简化 ECDH：
  1) ClientHello：临时公钥 + 支持套件 + 会话意图；
  2) ServerHello：临时公钥 + 证书/Pin 确认 + cookie；
  3) 双方派生共享密钥（ECDH），HKDF 导出会话 AEAD 密钥；
  4) 用 AEAD 保护握手完成消息，进入数据通道；
  5) 周期轮换密钥（基于计数/时长）。

## Android Keystore 集成（示例）
```kotlin
// 生成密钥
val keyGen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
val spec = KeyGenParameterSpec.Builder("skybridge_rc_session",
    KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
  .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
  .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
  .setKeySize(256)
  .build()
keyGen.init(spec)
keyGen.generateKey()

// 加密
val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
val secret = (ks.getEntry("skybridge_rc_session", null) as KeyStore.SecretKeyEntry).secretKey
val cipher = Cipher.getInstance("AES/GCM/NoPadding")
val iv = ByteArray(12).also { SecureRandom().nextBytes(it) }
cipher.init(Cipher.ENCRYPT_MODE, secret, GCMParameterSpec(128, iv))
val ct = cipher.doFinal(plaintext) // 包含 tag
val out = ByteBuffer.allocate(1 + 12 + ct.size).put(0x01).put(iv).put(ct).array()

// 解密
cipher.init(Cipher.DECRYPT_MODE, secret, GCMParameterSpec(128, iv))
val pt = cipher.doFinal(ct)
```

## TLS 与证书固定（OkHttp/Ktor）
```kotlin
// OkHttp 证书固定 + 受限 TLS
val pinner = CertificatePinner.Builder()
  .add("your.host", "sha256/BASE64_PIN")
  .build()
val client = OkHttpClient.Builder()
  .connectionSpecs(listOf(ConnectionSpec.RESTRICTED_TLS))
  .certificatePinner(pinner)
  .build()

// Ktor Android 引擎默认支持 TLS；启用 expectSuccess、严格主机校验
val ktorClient = HttpClient(Android) {
  expectSuccess = true
  install(WebSockets)
  install(ContentNegotiation) { /* ... */ }
}
```

## 文件传输加密落地
- 在 `FileTransferModule.provideFileEncryptionService()` 实现 AES-GCM（Keystore）。
- `FileTransferService` 中按分块进行加密：每块携带独立 `nonce` 与 `tag`。
- 发送顺序：`压缩`（可选）→ `加密` → `封包`；接收顺序：`解包` → `解密` → `解压`。
- 校验：保留 `SHA-256` 进行整文件校验，与远端校验和比对。

## 可靠性与网络弹性
- 统一重试策略：指数退避（基础 Xms，乘以 2，最大 Yms）+ 随机抖动。
- UDP(RUDP) 增强：包序号、ACK/NACK、滑动窗口、快速重传、超时估计与乱序缓冲。
- WebRTC：补全 STUN/TURN（可通过 `NetworkSettingsStore` 配置），提升跨 NAT 成功率。

## 输入与触觉反馈
- 使用 `VibrationEffect.createPredefined(...)` 与自定义 `Amplitude`，不同手势对应不同模式。
- 基于 `ConnectionQuality` 动态调整事件采样/合并与压缩强度。

## 性能与监控
- 指标：端到端延迟、抖动、吞吐、丢包率、CPU/内存、错误率。
- 工具：Macrobenchmark + Instrumentation；结构化日志与追踪（OpenTelemetry/Sentry）。

## 测试与质量保障
- 安全：握手互通性、AEAD 完整性、密钥轮换、重放/篡改检测。
- 协议：多协议路径一致性、断点续传与恢复、重试回退。
- 性能：压力测试与稳定性回归（长时间运行）。

## 落地路线图
- 0–7 天：文件传输 AES-GCM + Keystore；WS/HTTP 强制 TLS + 证书固定；远控改为 AES-GCM。
- 8–14 天：统一握手与会话密钥协商；统一重试；UDP 可靠性增强；WebRTC 配置 STUN/TURN。
- 15–21 天：性能基准与压力测试；触觉反馈策略完善与自适应。
- 22–30 天：安全一致性测试、篡改/重放、断点续传；结构化日志与端到端追踪。

## 改动清单与接口变更
- `remote-control`：
  - `RemoteControlNetworkServiceImpl.kt`：替换 AES/CBC → AES/GCM；统一消息头与 AEAD；集成握手。
  - `RemoteControlService.kt`：会话新增 `auth/handshake/encryptionMode` 标志与状态管理。
- `file-transfer`：
  - `FileTransferModule.kt`：真实 `FileEncryptionService`（AES-GCM + Keystore）。
  - `FileTransferService.kt`：分块加密封装与解包；校验流更新。
  - `FileTransferNetworkServiceImpl.kt`：消息封包/解包与校验；保留压缩但建议 Brotli/Zstd 对比评估。
- `network`：
  - `NetworkManager.kt` / `NetworkClientImpl.kt`：启用严格 TLS、证书固定；主机名校验。
- `shared`：
  - `NetworkSettingsStore.kt`：新增 `stun_servers`、`turn_servers`、`certificate_pins`、`tls_strict_mode`、`handshake_enabled`、`encryption_mode`。

## 风险与兼容
- 旧会话与新消息头兼容需版本协商；
- 性能影响需通过压缩策略与批处理优化；
- Keystore 在部分设备上的行为差异需回归验证。

## 验收标准
- 加密：所有数据通道消息具备 AEAD 保护（随机 nonce、有效 tag）。
- 握手：完成认证与会话密钥生成，支持轮换与失败回退。
- TLS：HTTP/WS 强制 TLS；证书固定与受限 TLS 生效。
- 可靠性：UDP 丢包场景下稳定；重试与回退策略一致化。
- 测试：安全、协议、性能三类测试通过；长时间运行稳定。

---

## 实施进度追踪（当前仓库）
- [x] `NetworkSettingsStore` 已包含：`stun_servers`、`turn_servers`、`certificate_pins`、`tls_strict_mode`、`handshake_enabled`、`encryption_mode`。
- [x] BuildConfig 已注入 `SUPABASE_URL` 与 `SUPABASE_ANON_KEY`（客户端仅使用 Anon Key）。
- [ ] 文件传输：`FileEncryptionService` 替换为 AES-GCM（Keystore），分块加密与解包。
- [ ] 远控：AES/CBC → AES/GCM，统一消息头与 AEAD；会话握手与密钥轮换。
- [ ] TLS：OkHttp/Ktor 启用证书固定与受限 TLS；主机名严格校验。
- [ ] 可靠性：UDP(RUDP) 增强与统一重试；WebRTC STUN/TURN 配置落地。
- [ ] 监控与测试：安全/协议/性能测试与长时间稳定性跑批。

## 下一步计划（本迭代）
- 优先完成文件传输 AES-GCM 与 Keystore 集成，闭环端到端加密路径。
- 在远控网络层引入握手与统一消息头；替换 AES/GCM。
- 接入证书固定并统一 TLS 配置；提供配置与回退策略。
- 为 UDP 路径加 RUDP 组件；补齐 STUN/TURN 管理界面与默认值。
- 加入仪表与回归测试（Macrobenchmark + Instrumentation）。

---

## 用户系统与登录认证（macOS 等效）

### 设计目标
- 复用已创建 Supabase 账户，Android 端无需二次创建。
- 与 macOS 体验一致：登录后持久会话、启动即自动恢复、显式登出与多设备支持。
- 安全：避免在客户端使用 `service_role`；全部 API 通过 Anon Key + RLS 控制。

### 流程概述
- 启动：读取 Supabase 会话状态；未登录则进入登录界面；已登录直接进入 `Dashboard`。
- 登录：Email/Password（首版）；后续扩展 Magic Link、OAuth（Apple/Google）、TOTP 2FA。
- 会话：监听 `sessionStatus` 变更；切换 UI 与权限范围；支持登出与清理缓存。

### 关键接口（Supabase）
- `supabase.auth.sessionStatus: Flow<SessionStatus>`（监听会话状态）。
- `supabase.auth.signInWith(Email) { email = ..., password = ... }`（登录）。
- `supabase.auth.signOut()`（登出）。

### UI 与导航
- 新增 `LoginScreen`（Material3）：邮箱、密码、登录按钮、错误提示与加载态。
- 在 `MainActivity` 使用会话状态进行 UI 门禁：未登录显示 `LoginScreen`；登录后显示导航框架。
- 在 `Settings` 中提供“账户”分区：显示登录状态与“登出”按钮。

### 已落地项（仓库）
- [x] BuildConfig 注入 Supabase URL/Anon Key。
- [x] 新增 `AuthRepository` + `AuthViewModel`（会话监听、登录、登出）。
- [x] 新增 `LoginScreen`（Compose）。
- [x] `MainActivity` 加入登录门禁（未登录显示登录页）。
- [x] `Settings` 页面增加账户状态与登出按钮。
- [ ] 扩展 OAuth（Apple/Google）与 Magic Link；TOTP 2FA。
- [ ] 认证相关的 UI 测试与端到端流测试。

### 安全注意事项
- 仅在客户端使用 `Anon Key`；`service_role` 只在服务端/CI 环境。
- 为敏感表启用 RLS 与策略；所有请求在服务端再校验权限（如远控指令）。
- 会话存储与网络通道的密钥应分离；避免将业务会话与通道密钥混用。

---

> 备注：本节进度将随实现同步更新；为避免与网络安全升级互相阻塞，登录认证和 AEAD 握手将并行推进，但两者的密钥材料保持隔离并通过最小权限策略进行控制。