# SkyBridge Compass Pro


SkyBridge Compass Pro 是一个以 **跨平台协议内核（SkyBridgeCore）** 为中心的 P2P 连接/安全栈，并提供 macOS 应用形态与论文复现实验流水线（IEEE/TDSC）。

> **平台说明（给审稿人）**：本仓库的 SwiftPM 构建入口是 **macOS**（`Package.swift` 声明 `platforms: [.iOS(.v17), .macOS(.v14)]`）；
> **iOS 客户端**是独立的 Xcode 工程，位于本仓库 `SkyBridge Compass iOS/` 子目录（详见下表）。
> 核心协议层同时包含若干 **iOS 专用代码路径**（使用 `#if os(iOS)` / `@available(iOS …)` 保护），用于保证 iOS 客户端与 macOS 互通时的行为一致性与可移植性。

## Platform Map（macOS vs iOS 一眼分清）

| 组件 | 平台 | 入口/目录 | 说明 |
|---|---|---|---|
| Protocol contracts / wire core | macOS / iOS | `Sources/SkyBridgeProtocolCore/` | 两端通过同一 Swift product 消费已迁移的协议契约与共享安全实现；仍含待拆出的 Apple 文件 I/O 接缝，不能据此宣称 Android/Linux 可直接构建 |
| Runtime + Crypto + Bench core | macOS（主入口）/ iOS（部分共享路径） | `Sources/SkyBridgeCore/` | 握手/会话运行时、PQC provider、远控、统计与 CSV artifacts；Apple 平台集成仍留在此层 |
| Shared SwiftUI views | macOS（构建）/ iOS（可移植代码） | `Sources/SkyBridgeUI/` | 共享 UI 组件；平台差异用 `#if os(...)` 保护 |
| macOS app | macOS | `Sources/SkyBridgeCompassApp/` | macOS App 入口（SwiftUI + 菜单/窗口等） |
| iOS app | iOS | `SkyBridge Compass iOS/` | iOS 客户端 Xcode 工程（`SkyBridgeCompass-iOS.xcodeproj`，iOS 17+）；已迁移切片直接依赖 `SkyBridgeProtocolCore`，未迁移的平行协议文件仍受 parity 闸门约束 |
| Tests / Paper benches | macOS（host） | `Tests/` | 论文评测、SBP2 sensitivity、fault-injection 等，输出 `Artifacts/*.csv` |
| Paper sources + PDFs | n/a | `Docs/` | 主论文与 Supplementary 源码、生成表格与最终 PDF/DOCX |

**如何定位 iOS-only 代码：**
- 搜索 `#if os(iOS)` 或 `@available(iOS`（例如：文件系统路径、权限/系统能力差异）。
- 例：`Sources/SkyBridgeCore/P2P/TrafficPaddingStats.swift` 在 iOS 写入 Documents，在 macOS 写入 Application Support。

## 环境要求

- macOS 14+
- Apple Silicon（arm64）Mac（当前 vendored XCFramework 仅提供 arm64 slice，Intel x86_64 暂不支持）
- Xcode 26.5+（正式发布/CI 基线）；Xcode 27 beta 仅用于手动 OS 27 兼容验证
- Swift 6.3+（由 Xcode 版本提供）

## macOS 手动 RDP 当前边界

macOS 手动 RDP 入口使用内置 FreeRDP 3.30 core-only 运行时和软件 GDI 渲染。当前只允许证书链受 macOS 系统信任且与输入主机名匹配的端点；需要手动信任的未知、自签名或已变更证书会失败。本版本没有 TOFU、指纹登记或连接时忽略证书的通道。FreeRDP/OpenSSL 的构建期信任目录和用户 `known_hosts` 不参与该决策。

这是受限实现边界，不是“任意 Windows RDP 已发布可用”的验收证明。发布前还必须使用真实 Windows 端点验证生产证书链与主机名、NLA/凭据失败、首帧、鼠标/键盘输入、正常断开与重连。剪贴板、驱动器、音频、RemoteApp 和显示控制通道在当前 core-only 运行时中均未开放。

## Apple PQC（iOS 26+/macOS 26+）在分发包中自动启用

本项目的 Apple CryptoKit PQC（ML-KEM / ML-DSA / X-Wing）代码路径需要在**编译期**启用 `HAS_APPLE_PQC_SDK`。
为避免在旧 SDK 下误开导致编译失败，我们使用环境变量开关：

- `SKYBRIDGE_ENABLE_APPLE_PQC_SDK=1`：启用编译条件（用于 Apple PQC 符号探测通过的 SDK 26+ 构建）

`Scripts/build_dmg.sh`、`Scripts/package_app.sh`、`Scripts/build_with_widgets.sh` 与 `run_app.sh` 会通过
`Scripts/apple_pqc_sdk_probe.sh` 对项目实际使用的 CryptoKit PQC 符号做 typecheck；
只有符号探测通过时才设置该变量。Xcode 27 beta 验证请使用
`Scripts/run_os27_beta_compatibility.sh`，该 lane 会分别验证 macOS、iPhoneOS、iPhoneSimulator SDK 的 PQC 符号。
OS27 beta 报告使用 `cryptokit-pqc-os27-v1` 标记 WWDC26 后的 CryptoKit / macOS Secure Enclave PQC 探测范围；
stable release manifest 仍固定接受 Xcode 26.5 发布基线的 `cryptokit-pqc-v1`。该 lane 不做 notarization、不发布更新 manifest。
Release/打包入口在符号探测失败时会 fail closed；发布 DMG/package 不接受
`SKYBRIDGE_ALLOW_RELEASE_WITHOUT_APPLE_PQC_SDK=1` 旁路。旧 `Scripts/build_with_widgets.sh`
只允许历史本地诊断，不作为发布或验收入口。

安装 Xcode 27 beta 或连接 iPadOS 27 beta 真机后，可先运行只读诊断：

```bash
Scripts/run_os27_beta_compatibility.sh --diagnose-environment
```

该模式只汇总 Xcode/SDK/iPadOS 27 beta iPad 前置条件，输出会标记
`full_validation=false` 与 `compatibility=not_validated`；它不运行 PQC 符号探测、build、test 或真机 runtime 验证，
也不输出设备名、UDID、序列号等硬件标识。缺 Xcode 27、SDK 27 或 iPadOS 27 beta iPad 时会返回非零状态，不能作为兼容通过结论。
若诊断显示 Xcode 27 beta 存在且 `xcodebuild -version` 可用，但 `xcrun`/SDK/device probes 返回 exit 69，
说明 Xcode license/first-launch 尚未完成；需要在本机 Terminal 中执行
`sudo DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -license` 并按提示确认后再重跑诊断。

source-contract preflight 用于验证 OS27 相关脚本、配置、release gate 与 Apple PQC 源码契约没有漂移；它不需要 iPadOS 27 真机，但仍会运行三平台 Apple PQC SDK 符号探测，因此本机当前选中的 Xcode/SDK 必须已经具备这些 CryptoKit PQC 符号：

```bash
Scripts/run_os27_beta_compatibility.sh --verify-source-contracts
```

该模式会输出 `coverage=source_contracts_only` 与 `compatibility=not_validated`；它不是 iPadOS 27 runtime 兼容证明。
机器可读报告里的 `full_validation` 只有在完整 lane 通过后才会为 `true`；`full_validation_attempted=true` 但
`full_validation_passed=false` 表示曾尝试完整 lane，但仍处于失败或 partial 状态。
OS27 兼容报告当前 schema 为 `schema_version=2`；交接或发布前不得引用旧 `/tmp` 报告文字，必须用
`Scripts/check_os27_compatibility_report.py --require-full-validation <report.json>` 结构化复核当前 JSON。
SwiftPM 与 xcodebuild clean-log gate 默认受 `SKYBRIDGE_OS27_BUILD_GATE_TIMEOUT_SECONDS=1800` 保护；
beta toolchain 卡住会写失败报告并保持 `compatibility=not_validated`，不能被解释为通过或 partial 成功。

连接 iPadOS 27 beta 真机后，安装 Xcode 27 beta 后必须显式启用物理设备验证，完整通过才会输出
`[os27-beta-compat] passed`：

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  SKYBRIDGE_OS27_RUN_IOS_DEVICE_TESTS=1 \
  Scripts/run_os27_beta_compatibility.sh
```

若只做无真机的本地诊断，必须显式设置 `SKYBRIDGE_OS27_ALLOW_PARTIAL_WITHOUT_DEVICE=1`；
该模式只代表 SDK/build 静态路径通过，不代表 iPadOS 27 PQC runtime 通过，并会以非零状态返回 `compatibility=partial_not_validated`。

当前 Xcode 26.5 可运行 iPadOS 27 定向测试，但会输出 `Error locating DeviceSupport directory`；
clean-log gate 会把这类工具链错误判为失败，不能用它替代 Xcode 27 beta 验证。

发布、打包、更新 manifest 仍固定使用 stable release toolchain：`Scripts/verify_xcode_toolchain.sh` 默认执行 `stable-release` policy，要求 Xcode 26.5 / build 17F42 / macOS SDK 26.5，并拒绝 beta 命名的 Xcode developer directory。Xcode 27 beta 只能用于 OS27 手动兼容验证。

## 握手信任钉扎契约（跨平台接入前必读）

`HandshakeTrustProvider.trustedFingerprint(for:)` 返回的必须是**规范化协议身份指纹**，不能是任意 `SHA256(publicKey)`。

- 指纹输入为：`protocol signing algorithm tag + raw protocol public key bytes`
- 输出格式为：**64 字符小写十六进制**
- 本仓库的权威实现位于 `IdentityPublicKeys.authoritativeProtocolFingerprint()`
- `MessageA` 与 `MessageB` 的验签后 pinning 都以解码后的 `IdentityPublicKeys` 为准，不再接受“裸公钥 Data”与“wire blob Data”混用

这条契约是后续 **macOS / iOS / Ubuntu / Android** 对齐时的硬要求；新平台接入如果沿用旧的裸公钥哈希，会在首次信任同步或 pinning 校验时产生系统性误报。

## Nebula 配置最佳实践

Nebula 原生客户端现统一使用以下配置键：

- `NEBULA_BASE_URL`
- `NEBULA_CLIENT_ID`
- `NEBULA_CLIENT_SECRET`（可选，仅兼容旧后端）

读取优先级：

- Keychain
- 环境变量
- `Info.plist`
- `NebulaConfig.plist`（可选）

推荐做法：

- 在客户端把 `NEBULA_BASE_URL` 和 `NEBULA_CLIENT_ID` 作为常规配置。
- 不要把长期 `NEBULA_CLIENT_SECRET` 固化进仓库或 App 包；仅在本地调试或旧后端过渡期通过环境变量/Keychain 注入。
- 真实 Nebula 后端应迁移为 OAuth 2.1 public client + PKCE；本仓库提供迁移说明 [Docs/Nebula-Public-Client-PKCE-Migration.md](Docs/Nebula-Public-Client-PKCE-Migration.md) 与参考服务 [Server/nebula-auth-reference/README.md](Server/nebula-auth-reference/README.md)。

## 跨网连接（WebRTC + TURN，面向“普通用户零配置”路线）

本项目的跨网连接方向是 **WebRTC DataChannel + ICE**（优先直连，失败自动走 TURN 中继），避免让用户安装 VPN 或导入配置文件。

- **实现入口**：`Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift`（当前主路径已使用服务端签发短期 token 的 offer/answer/ICE 信令与 DataChannel 传输层）
- **信令地址**：`Sources/SkyBridgeCore/Config/ServerConfig.swift` 中的 `SkyBridgeServerConfig.signalingWebSocketURL`
- **TURN/STUN**：同上 `SkyBridgeServerConfig.stunURL / turnURLs`（默认 `turns:5349` 优先，`turn:3478` 兜底）

当前 WebRTC 信令主路径：

- **连接码模式**：发起端先调用 `/api/webrtc/register-code` 获取服务端签发的短期连接码（默认 8 位）和 `initiatorToken`；输入端调用 `/api/webrtc/lookup/:code` 获取 `responderToken`。
- **二维码模式**：发起端先调用 `/api/webrtc/register-session` 获取服务端签发的 `sessionId` 与短期 `signalingToken`，再把它封装进二维码 payload。
- **WebSocket 鉴权**：新客户端连接 `/ws?shard=<sessionId>` 时通过 `X-SkyBridge-Session-Id` 与 `X-SkyBridge-Session` 握手 header 绑定短期 session token；`shard` 仅作为路由/粘性提示。服务端仍保留 legacy query token 兼容旧客户端，但 header 与 query token 同时出现会 fail closed。

### 服务器端口（EC2 安全组建议）

- **信令 WebSocket**：`8443/tcp`（`wss://<host>:8443/ws`）
- **STUN**：`3478/udp`（可选补 `3478/tcp`）
- **TURN (TLS)**：`5349/tcp`（推荐）
- **TURN relay 端口段**：`49152–65535/udp`

> 生产环境默认强制 **短期 TURN 凭据**（`mode=shared_secret_hmac`）。
> 除非手动开启 `TURN_ALLOW_STATIC_FALLBACK=true`，否则服务端不会回退静态长期凭据。
> 客户端默认也会 **fail-closed** 到 STUN-only；只有显式设置 `SKYBRIDGE_ALLOW_STATIC_TURN_FALLBACK=true` 才允许本地静态 TURN 应急回滚。

### 信令服务部署（推荐生产流程）

仓库已内置可复用部署资产（systemd + Nginx + 原子发布 + 回滚）：

- 部署文档：`Server/skybridge-signaling/deploy/README.md`
- 环境模板：`Server/skybridge-signaling/production.env.example`
- 一键部署：`Server/skybridge-signaling/deploy/scripts/deploy_remote.sh`
- 一键回滚：`Server/skybridge-signaling/deploy/scripts/rollback_remote.sh`
- 本地烟雾测试：`Server/skybridge-signaling/deploy/scripts/smoke_local.sh`
- 认证邮件 / 短信生产化 runbook：`Docs/ops/auth-email-and-sms-production.md`

最小上线命令：

```bash
bash Server/skybridge-signaling/deploy/scripts/deploy_remote.sh \
  --host <server-ip-or-dns> \
  --user <ssh-user>
```

该流程会强制校验 `/api/turn/credentials` 路由语义，避免“代码已修复但线上仍旧 404”的配置漂移问题。

上线前建议额外执行 TURN/TLS 回归脚本：

```bash
TURN_CLIENT_API_KEY=<deployment-specific value from production.env> \
bash Scripts/check_turn_tls_regression.sh https://api.nebula-technologies.net
```

脚本会检查：
- `/health` 与 `/api/turn/credentials` 可达性
- 返回模式是否为短期凭据（默认拒绝 static fallback）
- 返回的 URI 是否包含 `turns:...:5349`
- `5349/TLS` 握手、`/ws` 升级（101）和 STUN UDP 探测

## 构建与运行（macOS）

1. 用 Xcode 打开 `Package.swift`
2. 选择 `SkyBridgeCompassApp` 作为运行目标
3. 直接运行

正式 macOS 发布包不要手工拼装；按
[`Docs/ops/macos-release-packaging-runbook.md`](Docs/ops/macos-release-packaging-runbook.md)
执行打包、公证、WebRTC payload、TCC plist 与图标资源校验。

命令行测试：

```bash
swift test
```

## SkyBridge CLI / Agent Workspace

SkyBridge CLI/agent 的 headless Rust 工作区位于 `rust/`，用于承载正式的 operator surface。原生/headless 命令不依赖 GUI 侧状态；`skybridge crossnet ...` 则是明确依赖运行中 Mac App 的独立控制面。用户可见产品名是 SkyBridge CLI；稳定命令名仍是 `skybridge`。

常用命令：

```bash
cargo test --manifest-path rust/Cargo.toml
cargo run --manifest-path rust/Cargo.toml -p skybridge -- version
```

当前已落地的可运行命令：

- `skybridge login`
- `skybridge logout`
- `skybridge agent run`
- `skybridge device status`
- `skybridge device enroll --invite-token <token>`
- `skybridge device approve <pending-device-id> --pending-fingerprint <fp>`
- `skybridge device discover --nearby --scan [--show-addresses]`
- `skybridge code create`
- `skybridge connect <code> [--timeout-seconds <seconds>]`
- `skybridge session ls`
- `skybridge session inspect <id>`
- `skybridge disconnect <id>`
- `skybridge file send <path> --to <peer> --session-id <id> [--detach]`
- `skybridge file history`
- `skybridge crossnet preflight`
- `skybridge crossnet status`
- `skybridge crossnet settings`
- `skybridge crossnet settings set <id> <value>`
- `skybridge doctor`
- `skybridge doctor webrtc-media --artifact-dir <dir> --latest`
- `skybridge smoke local-p2p`
- `skybridge smoke local-webrtc`
- `skybridge smoke real-device --real-device-id <udid>`
- `skybridge smoke fault-detection`
- `skybridge smoke suite --profile <quick|full|local-p2p|local-webrtc|real-device|release|all>`
- `skybridge logs tail`
- `skybridge metrics`
- `skybridge version`

原生连接与文件传输不依赖 Desktop App，但要求同一 `--state-dir` 下有一个
健康、持锁的 `skybridge agent run`。`connect` 只在身份绑定的协议握手完成后
返回成功，并报告实际协商套件；文件发送默认等待接收端 SHA-256 receipt。
原生连接与文件发送在取得跨平台真机 artifact 前均标记为
`pending_live_proof`。PQC 路径还要求主协议身份与握手身份一致并具备明确的对端
KEM 公钥；没有 control-plane→bridge 签名绑定的独立 bridge 身份不能作为发布
路径。主动扫描默认不输出 IP，只有显式 `--show-addresses` 才显示短期、未认证的
mDNS 地址。

Rust CLI 的 control-plane / signaling origin 默认只接受 `https://` / `wss://`。
本机明文开发必须显式设置
`SKYBRIDGE_ALLOW_INSECURE_LOOPBACK_TRANSPORT=true`，或在 doctor 的显式
`--base-url` 上同时传入 `--allow-insecure-loopback`；该例外仍只接受严格 loopback，
不会放宽到局域网地址。原生 WebSocket 使用
`X-SkyBridge-Session-Id` / `X-SkyBridge-Session` 握手 header，session token
不会进入 `?st=`，也没有 query-token fallback。

CLI 的公开 tag 发布目前也保持 fail-closed：四平台 bundle 可以构建和校验，但在
macOS 签名/公证与 Windows publisher signature 证明进入工作流并被验证之前，
GitHub、npm 与 Homebrew 发布任务不会执行。

首发边界与 contract 文档：

- `Docs/cli-scope-v1.md`
- `Docs/signaling-lifecycle-contract.md`
- `Docs/inbound-route-contract.md`
- `Docs/file-transfer-route-source.md`
- `Docs/cli-install-release.md`
- `Docs/failure-matrix-and-recovery.md`

分发骨架：

- `rust/packaging/homebrew/`
- `rust/packaging/npm/skybridge-cli/`
- `rust/scripts/render_homebrew_formula.sh`
- `rust/scripts/build_release_artifact.sh`
- `rust/scripts/assemble_release_assets.sh`
- `rust/scripts/prepare_npm_package.py`
- `rust/scripts/publish_homebrew_formula.sh`
- `.github/workflows/skybridge-cli-packaging.yml`
- `.github/workflows/skybridge-cli-release.yml`

Mac App 的“检查更新”使用 GitHub Releases 上的 `macos-stable.json`
manifest。Manifest 必须带 Ed25519 签名，并由 App 内置的
`SKYBRIDGE_UPDATE_MANIFEST_ED25519_PUBLIC_KEYS` 公钥验证；未签名或不受信任的
manifest 会 fail closed，不会把 HTTPS 托管内容直接当作可信版本元数据。
发布和密钥轮换流程见 `Docs/ops/macos-update-management.md`。

## 论文与 PDF 源码位置

- 主论文 LaTeX：`Docs/TDSC-2026-01-0318_IEEE_Paper_SkyBridge_Compass_patched.tex`
- Supplementary LaTeX：`Docs/TDSC-2026-01-0318_supplementary.tex`
- 一键编译脚本：`./compile_paper.sh`（会自动生成 figures + 编译主论文和 Supplementary）

## 可复现实验（Artifact 复核）

论文中标注的 artifact 信息如下（供 reviewer/编辑核对）：

- URL：`https://github.com/billlza/Skybridge-Compass`
- Git ref：`6576e954a5bb`
- Commit：`6576e954a5bb7b9c42a367ba43f086d383e5f495`（short=`6576e954a5bb`）

Source archive checksums（immutability 辅助证据）：

- `6576e954a5bb.zip`：`SHA256=8b56831681518171af8466910bd8893a8831293626241f7a416b2522afe4ef42`
- `6576e954a5bb.tar.gz`：`SHA256=fe6088e46a9da6103ad6d1d58aebb6543cbb1a0c5370232b53a6e24687fa3b33`

说明：
- 本仓库仍在持续演进；如需形成新的投稿/归档快照，请在最终提交前重新刷新 `artifact` pin 与归档校验和。
- 当前工作分支已经升级到 `Swift 6.3 / Xcode 26.5` 稳定工具链，并会继续吸收实现级优化；这些变更默认视为 **post-artifact engineering evolution**，不会自动改写主论文当前冻结的定量结论。
- 只有在重新生成 `Artifacts/*.csv`、刷新 `Docs/tables/` / `Docs/supp_tables/`、并重编主论文与 Supplementary PDF 之后，才应更新论文中的数字、artifact pin 和归档校验和。

### 当前分支与论文快照的 PQC 边界

- 当前论文冻结基线仍以 `ML-KEM-768` / `ML-DSA-65` / `X-Wing` 为主，并对应 `2026-01-23` 的 artifact 快照。
- Apple 平台原生 PQC 能力集合可能比论文基线更宽；当前分支可以继续吸收实现、调度、并发和工程层优化，但**不应**在未重跑实验前把论文主基线直接切换到新的算法档位或新的性能数字。
- 如果后续决定把论文主线演进到新的 Apple-native PQC 档位或新的 benchmark 结果，建议作为一次明确的 `artifact refresh` 处理，而不是把它混进现有冻结快照。

最小复核流程（需要本机已安装 Xcode/Swift 与 TeXLive；PQC SDK 仅在 macOS 26+ 可用）：

```bash
git clone https://github.com/billlza/Skybridge-Compass
cd Skybridge-Compass
git checkout 6576e954a5bb7b9c42a367ba43f086d383e5f495

git rev-parse HEAD
git describe --tags --always

# 复现论文 PDF（主论文 + Supplementary）
bash ./compile_paper.sh

# 运行论文评测与生成 CSV/图表
bash Scripts/run_paper_eval.sh

# 可选：导入 iOS on-device microbench JSON（schema v3）并生成主文表格
RUN_IOS_MICROBENCH_IMPORT=1 bash Scripts/run_paper_eval.sh

# 可选：运行 kernel-level dummynet/netem 对照（需要 sudo）
RUN_KERNEL_EMULATION=1 bash Scripts/run_paper_eval.sh
```

### Artifact 输出定位（Reviewer 常用）
- **CSV**：`Artifacts/*.csv`（由 `Scripts/run_paper_eval.sh` / bench tests 生成）
- **表格（LaTeX）**：`Docs/tables/`、`Docs/supp_tables/`（由 `Scripts/make_tables.py` 生成，带日期一致性锁）
- **图（PDF/PNG）**：`figures/*.pdf`（由 `Scripts/generate_ieee_figures.py` 生成）

多批次（独立进程）性能统计复核（Repeatability / CI）：

```bash
# 推荐：固定 ARTIFACT_DATE，确保所有 CSV 前缀落在同一天，避免 make_tables 混用不同实验日的数据
ARTIFACT_DATE=2026-01-23 SKYBRIDGE_BENCH_BATCHES=5 bash Scripts/run_paper_eval.sh
```

说明：
- Repeatability 表会显示观测到的 batch 数 **B**；只有当 **B ≥ 2** 时才报告跨 batch 的 **95% CI**。
- `SKYBRIDGE_BENCH_BATCHES` 的含义是“重启测试进程的批次数”（独立 batch），不是单次测试内部的 iteration 数。

## 真实网络小规模验证（仅需一台 Mac，可选）

如果你想补充 reviewer 关心的真实 NAT / 异构接入网络 / mobility 的“小规模实测”，但手头只有一台 Mac：

1. 在不同网络下分别运行一次 STUN 探测脚本（例如：家庭 Wi‑Fi、手机热点、不同运营商/不同地点）。
2. 脚本会记录当前网络路径（是否 expensive/constrained）、本地 UDP 端口、STUN 映射端点、RTT 分布与丢包率（超时）。
3. 输出 CSV 到 `Artifacts/`，可直接汇总到 supplementary 表格或作为外部有效性补充材料。

运行示例：

```bash
swift Scripts/run_real_network_probe.swift --label home_wifi --samples 50
# 切换网络后再跑一遍（mobility / 异构网络）
swift Scripts/run_real_network_probe.swift --label phone_hotspot --samples 50
```

可选：端到端 12~kB payload 的 TCP micro-study（需要两台机器/两端进程，一个 server 一个 client）：

```bash
# 机器 A（server）
swift Scripts/run_real_network_e2e.swift server --bind 0.0.0.0:44444

# 机器 B（client），固定 ARTIFACT_DATE 方便生成论文表格
ARTIFACT_DATE=2026-01-23 swift Scripts/run_real_network_e2e.swift client \
  --label home_wifi --connect <server_ip>:44444 --samples 50 --bytes 687 --bytes 12002

# 汇总生成 Supplementary 表（可选）
ARTIFACT_DATE=2026-01-23 python3 Scripts/aggregate_realnet.py
```

注：`run_real_network_e2e.swift` 在传输层使用 `4B length prefix + payload`，其中比较口径统一使用 payload-only 的经典/后量子基准（687B / 12,002B）。

## Kernel-level 网络仿真（dummynet / netem）

跨工具统一 profile 定义在 `Scripts/netem_profiles.json`。常见三档（mild/moderate/severe）在 dummynet 与 netem 都可报告；`reorder` 仅 netem 原生支持，dummynet 行标记为 `n/a`。

```bash
# macOS (dummynet)
ARTIFACT_DATE=2026-01-23 TOOL=dummynet bash Scripts/run_network_emulation_kernel.sh

# Linux (netem)
ARTIFACT_DATE=2026-01-23 TOOL=netem IFACE=eth0 bash Scripts/run_network_emulation_kernel.sh

# 生成 Supplementary 表
ARTIFACT_DATE=2026-01-23 python3 Scripts/aggregate_kernel_emulation.py
```

关于 cross-NAT / 入站限制（重要）：

- **IPv4 端口转发前提**：路由器 WAN 必须拿到**可入站的公网 IPv4**。如果 WAN 显示 `0.0.0.0`、或 WAN 是 `192.168.x.x / 10.x / 100.64–127.x`，通常意味着双层 NAT / CGNAT / DS-Lite，**外网无法直达**，会表现为 client 全部 `timeout`（`connect_ms` 为空）。
- **优先推荐 IPv6 直连**：若你的宽带和蜂窝网络都支持 IPv6，可使用 Mac 的公网 IPv6（`2400:`/`2409:` 开头）作为 server endpoint。注意：多数路由器需要在 **IPv6 防火墙**中放行入站 TCP `44444` 到 Mac 的 IPv6 地址。
- **备选（无需改上级路由）**：使用 overlay/relay（例如 Tailscale）建立可达路径，并在论文/label 中如实标注 **“via overlay/relay”**（用于跨网络条件评估）。

输出文件：

- `Artifacts/realnet_stun_samples_<timestamp>_<label>.csv`
- `Artifacts/realnet_stun_summary_<timestamp>_<label>.csv`

预期输出（关键点）：

- `git rev-parse HEAD` 应为 `6576e954a5bb7b9c42a367ba43f086d383e5f495`
- `git describe --tags --always` 应包含 `6576e954`（等价短 SHA 形式也可）
- 生成的 PDF：`Docs/TDSC-2026-01-0318_IEEE_Paper_SkyBridge_Compass_patched.pdf` 与 `Docs/TDSC-2026-01-0318_supplementary.pdf`
- CSV 输出目录：`Artifacts/`

## Release Packaging

发布 DMG 的推荐路径：

首次在一台新机器上执行本地公证前，先做一次 notary 凭据 bootstrap：

```bash
./Scripts/bootstrap_notarytool_credentials.sh
```

脚本会自动：

- 识别本机 `~/.appstoreconnect/private_keys/AuthKey_*.p8`
- 通过当前 App Store Connect 会话解析 `NOTARYTOOL_ISSUER`
- 校验 `notarytool` 认证
- 写入可复用的 Keychain profile 与本地 env 文件

详细说明见：

- [`Docs/ops/macos-release-packaging-runbook.md`](Docs/ops/macos-release-packaging-runbook.md)
- [`Docs/ops/notary-credential-bootstrap.md`](Docs/ops/notary-credential-bootstrap.md)
- [`Scripts/ensure_notarytool_credentials.sh`](Scripts/ensure_notarytool_credentials.sh)

`bundle exec fastlane release` 现在会在本地候选打包前先自动执行 notary 凭据自检：

- 当前本机凭据已可用：直接继续
- 当前本机凭据缺失：自动调用 `Scripts/bootstrap_notarytool_credentials.sh`
- bootstrap 完成后再次验证，成功才进入本地构建、签名、公证与 package-integrity-only 校验

该 lane 不消费物理证据，也不生成“最终发布就绪”结论。正式发布只允许走受保护的候选构建 → 同一候选物理证据 → 原字节发布工作流。

发布 DMG 还会在 `package_app.sh` 前自动执行 Developer ID provisioning profile 自检：

- 主应用与 Widget Extension 会分别校验 bundle id、Team ID、Developer ID direct distribution、过期时间、当前 Developer ID 证书以及 App Groups entitlement。
- 若本机已安装合格 profile：直接继续。
- 若 profile 缺失或过期：`build_dmg.sh` 会调用 `Scripts/ensure_developer_id_profiles.sh --create`，通过本机 App Store Connect API key 重新生成并安装。
- 若首次配置时 Apple Developer 里还没把具体 App Group 关联到 Bundle ID，先交互式执行一次：

```bash
SKYBRIDGE_ASSOCIATE_DEVELOPER_ID_APP_GROUPS=1 \
./Scripts/ensure_developer_id_profiles.sh --create --associate-app-groups
```

这一步可能触发 Apple 2FA。关联完成后，后续 DMG 打包只需要常规命令；脚本会继续强校验 profile 中是否真的包含 `group.com.skybridge.compass`。

```bash
export SKYBRIDGE_RELEASE_BUILD_ID=202608120001 # 替换为下一批准的单调递增数字构建号
SKYBRIDGE_REQUIRE_APPLE_SIGN_IN_MODE=web_session \
SKYBRIDGE_REQUIRE_APP_GROUPS=1 \
SKYBRIDGE_REQUIRE_WIDGET_EXTENSION=1 \
./Scripts/build_dmg.sh \
  --build-id "$SKYBRIDGE_RELEASE_BUILD_ID" \
  --notarize-dmg \
  --require-notarization
```

当前发布约束：

- 发布 DMG 只接受明确 Release provenance 的 `SkyBridgeCompassApp` executable 产物（默认 `swiftpm_release`；在 Xcode Package destination 无歧义时也接受 `xcode_release`），最终 `.app` 由 `package_app.sh` 组装；禁止把 `SkyBridgeCompassMac.app` native app bundle 当作发布 runtime。
- `package_app.sh` 在 `release_dmg` 上下文下会校验构建来源，禁止隐式 fallback。
- `build_dmg.sh` 要求显式正整数 `--build-id`，并验证最终 `.app` 的 `CFBundleVersion` 与该事务完全一致；正式构建不使用时间 fallback。
- `build_dmg.sh --use-existing-app` 也会校验现有 `.app` 的构建来源与稳定 Xcode/SDK metadata，非 Release provenance 或 beta SDK 产物会直接失败。
- 正式发布必须使用 `Developer ID Application` 证书签名；`ad-hoc` 仅适合本地调试，不适合稳定复用 macOS TCC 授权。
- `Developer ID + notarized DMG` 发布链下，Apple 登录固定走 `web_session`（`ASWebAuthenticationSession` + Services ID）；原生 `Sign in with Apple` 仅适用于 Apple 官方支持的分发通道。
- 最终发布要求 `Widget Extension` 与 `App Groups` 全部随签名产物交付。
- 主应用与 Widget Extension 需要分别准备匹配的 macOS Developer ID provisioning profile；`build_dmg.sh` 默认会自检并在可用 API key 下自动创建/刷新。
- 主应用 profile 可通过 `SKYBRIDGE_MACOS_PROVISIONPROFILE_PATH` 指定，Widget Extension profile 可通过 `SKYBRIDGE_WIDGET_PROVISIONPROFILE_PATH` 指定。
- 若要完全跳过 profile 自检，可显式设置 `SKYBRIDGE_ENSURE_DEVELOPER_ID_PROFILES=0`；正式发布不建议这样做。
- 若要执行本地 notarization，需要提供 `notarytool` 凭据（例如 `NOTARYTOOL_KEY` / `NOTARYTOOL_KEY_ID` / `NOTARYTOOL_ISSUER` 或 keychain profile）。
- 发布 readiness 必须提供与精确候选进程绑定的 Mac/iOS shipping-product OSLog artifact。`skybridge check connectivity` 只接受 X-Wing/X-Wing、X-Wing/PQC、PQC/X-Wing 三组双端认证成功，以及 Mac、iOS shipping responder 各一次已验证签名的 Classic offer 严格策略拒绝；外部 case/status 标签、helper、Debug 或 simulator 证据均不能替代产品事件。

推荐的最终校验命令：

```bash
SKYBRIDGE_RELEASE_GATE_REQUIRE_NOTARIZATION=1 \
./Scripts/check_macos_release_readiness.sh \
  --require-notarization \
  --connectivity-artifact-dir "Artifacts/<real-device-connectivity-matrix>" \
  --p2p-remote-artifact-dir "Artifacts/<real-device-p2p-remote-smoke>" \
  --file-transfer-artifact-dir "Artifacts/<real-device-file-transfer-smoke>"
```

该发布门禁会运行 Rust CLI 的 memory/connectivity/performance/coverage 检查；coverage
为 operator check-surface 覆盖率，默认阈值 88%，不是 Rust 行/分支覆盖率。

脚本自检：

```bash
./Scripts/test_check_manual_p2p_remote_artifact.sh
./Scripts/test_package_build_policy.sh
./Scripts/test_signing_entitlements_helpers.sh
```

当前目录下最近一次本地生成的 DMG 构建产物：

- `dist/SkyBridgeCompassPro-1.0.2.dmg`

## 说明

仓库不包含构建产物与敏感配置（密钥、证书、运行时凭据等），相关内容已加入忽略规则。
