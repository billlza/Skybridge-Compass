# SkyBridge Compass Pro


SkyBridge Compass Pro 是一个以 **跨平台协议内核（SkyBridgeCore）** 为中心的 P2P 连接/安全栈，并提供 macOS 应用形态与论文复现实验流水线（IEEE/TDSC）。

> **平台说明（给审稿人）**：本仓库当前的构建入口是 **macOS**（SwiftPM `platforms: [.macOS(.v14)]`）。
> 同时，核心协议层包含若干 **iOS 专用代码路径**（使用 `#if os(iOS)` / `@available(iOS …)` 保护），用于保证 iOS 客户端与 macOS 互通时的行为一致性与可移植性。

## Platform Map（macOS vs iOS 一眼分清）

| 组件 | 平台 | 入口/目录 | 说明 |
|---|---|---|---|
| Protocol + Crypto + Bench core | macOS / iOS（代码路径） | `Sources/SkyBridgeCore/` | 协议实现（握手/会话/策略）、PQC/降级可审计、SBP1/SBP2 padding、统计与 CSV artifacts |
| Shared SwiftUI views | macOS（构建）/ iOS（可移植代码） | `Sources/SkyBridgeUI/` | 共享 UI 组件；平台差异用 `#if os(...)` 保护 |
| macOS app | macOS | `Sources/SkyBridgeCompassApp/` | macOS App 入口（SwiftUI + 菜单/窗口等） |
| Tests / Paper benches | macOS（host） | `Tests/` | 论文评测、SBP2 sensitivity、fault-injection 等，输出 `Artifacts/*.csv` |
| Paper sources + PDFs | n/a | `Docs/` | 主论文与 Supplementary 源码、生成表格与最终 PDF/DOCX |

**如何定位 iOS-only 代码：**
- 搜索 `#if os(iOS)` 或 `@available(iOS`（例如：文件系统路径、权限/系统能力差异）。
- 例：`Sources/SkyBridgeCore/P2P/TrafficPaddingStats.swift` 在 iOS 写入 Documents，在 macOS 写入 Application Support。

## 环境要求

- macOS 14+
- Xcode 15+
- Swift 6.2+（由 Xcode 版本提供）

## Apple PQC（iOS 26+/macOS 26+）在分发包中自动启用

本项目的 Apple CryptoKit PQC（ML-KEM / ML-DSA / X-Wing）代码路径需要在**编译期**启用 `HAS_APPLE_PQC_SDK`。
为避免在旧 SDK 下误开导致编译失败，我们使用环境变量开关：

- `SKYBRIDGE_ENABLE_APPLE_PQC_SDK=1`：启用编译条件（用于 Xcode/SDK 26+ 的 Release/分发）

`Scripts/build_with_widgets.sh` 与 `run_app.sh` 会自动检测 macOS SDK 版本（>=26）并设置该变量。

## 跨网连接（WebRTC + TURN，面向“普通用户零配置”路线）

本项目的跨网连接方向是 **WebRTC DataChannel + ICE**（优先直连，失败自动走 TURN 中继），避免让用户安装 VPN 或导入配置文件。

- **实现入口**：`Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift`（已开始落地 offer/answer/ICE 信令与 DataChannel 传输层）
- **信令地址**：`Sources/SkyBridgeCore/Config/ServerConfig.swift` 中的 `SkyBridgeServerConfig.signalingWebSocketURL`
- **TURN/STUN**：同上 `SkyBridgeServerConfig.stunURL / turnURL / turnUsername / turnPassword`

### 服务器端口（EC2 安全组建议）

- **信令 WebSocket**：`8443/tcp`（`wss://<host>:8443/ws`）
- **STUN**：`3478/udp`（可选补 `3478/tcp`）
- **TURN (TLS)**：`5349/tcp`（推荐）
- **TURN relay 端口段**：`49152–65535/udp`

> 生产环境建议使用 **短期 TURN 凭据**（例如 coturn 的 REST API / shared secret），避免在客户端硬编码用户名密码。

## 构建与运行（macOS）

1. 用 Xcode 打开 `Package.swift`
2. 选择 `SkyBridgeCompassApp` 作为运行目标
3. 直接运行

命令行测试：

```bash
swift test
```

## 论文与 PDF 源码位置

- 主论文 LaTeX：`Docs/IEEE_Paper_SkyBridge_Compass_patched.tex`
- Supplementary LaTeX（投稿版本）：`Docs/TDSC-2026-01-0318_supplementary.tex`
- 一键编译脚本：`./compile_paper.sh`（会自动生成 figures + 编译主论文和 Supplementary）

## 可复现实验（Artifact 复核）

论文中标注的 artifact 信息如下（供 reviewer/编辑核对）：

- URL：`https://github.com/billlza/Skybridge-Compass`
- Submission truth tag：`tdsc-2026-01-0318-ios-sim-fix-20260211`
- Commit：`b16fe9386ff047d17ba9a518b2c331f64493971e`（short=`b16fe9386ff0`）

Source archive checksums（immutability 辅助证据）：

- `b16fe9386ff0.zip`：`SHA256=460813da9ade5b79b333c94a1b76e14e6b522f630be1a6f0decb9845def3f258`
- `b16fe9386ff0.tar.gz`：`SHA256=443b8ac90ffe42f757d65f1d79cd3d183b7d7ce502dd8bcd31cdb0161016f380`

对外呈现的唯一投稿基准 tag：`tdsc-2026-01-0318-ios-sim-fix-20260211`（README 与论文一致）

最小复核流程（需要本机已安装 Xcode/Swift 与 TeXLive；PQC SDK 仅在 macOS 26+ 可用）：

```bash
git clone https://github.com/billlza/Skybridge-Compass
cd Skybridge-Compass
git checkout tdsc-2026-01-0318-ios-sim-fix-20260211

git rev-parse HEAD
git describe --tags --always

# 复现论文 PDF（主论文 + Supplementary）
bash ./compile_paper.sh

# 运行论文评测与生成 CSV/图表
bash Scripts/run_paper_eval.sh
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

关于 cross-NAT / 入站限制（重要）：

- **IPv4 端口转发前提**：路由器 WAN 必须拿到**可入站的公网 IPv4**。如果 WAN 显示 `0.0.0.0`、或 WAN 是 `192.168.x.x / 10.x / 100.64–127.x`，通常意味着双层 NAT / CGNAT / DS-Lite，**外网无法直达**，会表现为 client 全部 `timeout`（`connect_ms` 为空）。
- **优先推荐 IPv6 直连**：若你的宽带和蜂窝网络都支持 IPv6，可使用 Mac 的公网 IPv6（`2400:`/`2409:` 开头）作为 server endpoint。注意：多数路由器需要在 **IPv6 防火墙**中放行入站 TCP `44444` 到 Mac 的 IPv6 地址。
- **备选（无需改上级路由）**：使用 overlay/relay（例如 Tailscale）建立可达路径，并在论文/label 中如实标注 **“via overlay/relay”**（用于跨网络条件评估）。

输出文件：

- `Artifacts/realnet_stun_samples_<timestamp>_<label>.csv`
- `Artifacts/realnet_stun_summary_<timestamp>_<label>.csv`

预期输出（关键点）：

- `git rev-parse HEAD` 应为 `b16fe9386ff047d17ba9a518b2c331f64493971e`
- `git describe --tags --always` 应输出 `tdsc-2026-01-0318-ios-sim-fix-20260211`（或等价形式）
- 生成的 PDF（对外分发版本）：`TDSC-2026-01-0318_IEEE_Paper_SkyBridge_Compass_patched.pdf` 与 `Docs/TDSC-2026-01-0318_supplementary.pdf`
- CSV 输出目录：`Artifacts/`

## Release 校验

当前目录下 DMG 构建产物（本地）：

- `dist/SkyBridgeCompassPro-1.0.2.dmg`：`SHA256=312a4ca61142afd8b6cf6e6f2d0993a40c51e3cc0ef7ecc12608e07a76c001de`

## 说明

仓库不包含构建产物与敏感配置（密钥、证书、运行时凭据等），相关内容已加入忽略规则。
