# iOS 27 / macOS 27 (Golden Gate) 适配计划（2026-06-10）

状态：WWDC26（2026-06-08）已发布 iOS 27 / iPadOS 27 / macOS 27 / Xcode 27 **开发者 beta**；正式版预计 2026 年秋季。
本文档基于 WWDC26 与 Google I/O 2026 公开信息，结合本项目实际架构（远程桌面 + PQC 加密 + WebRTC + Metal 渲染 + Widgets）给出适配决策。

## 基线约束（不变）

- 部署目标保持 **macOS 14+ / iOS 17+** 不动；任何 OS 27 API 必须走 `#available(macOS 27, iOS 27, *)` 守卫，与现有 26 守卫并存（沿用 `FEATURE_DESIGN_v2.md` 的渐进增强工厂模式）。
- **Release 不得使用 beta SDK 构建**：正式分发继续使用 Xcode 26.4+ 工具链，直至 Xcode 27 正式版发布并重验 notarization 链与 `liboqs.xcframework` 兼容性。

## 适配决策（按优先级）

| # | 事项 | 时机 | 适用模块 | 决策依据 |
|---|------|------|----------|----------|
| 1 | **OS 27 beta 回归验证**：Apple PQC 路径（`HAS_APPLE_PQC_SDK`、ML-KEM/ML-DSA/X-Wing）、WebRTC 连通、ScreenCaptureKit/Metal 渲染、Liquid Glass 视觉 | **现在做**（纯验证，零代码） | QuantumSecure、RemoteDesktop、SkyBridgeUI、iOS 全链路 | 提前发现 27 上的行为回归；可复用 `skybridge smoke suite` 与 `Scripts/run_local_webrtc_smoke.sh`。CryptoKit PQC 行为变化风险最高，需重点验证签名/验签与 26 的互操作 |
| 2 | **SwiftUI state initialization / layout 渲染提速** | 自动获得（beta 上量化对比） | SkyBridgeUI、SkyBridgeCompassApp、iOS Views | Apple 声明无需改代码即生效；用 `MacUIBaselineCapture` / `SkyBridgeVisualParity` 做前后帧率与视觉基线对比，layout 行为变化由 #1 兜底 |
| 3 | **Liquid Glass 更新**（统一窗口圆角、edge-to-edge sidebar、彩色侧边栏图标、用户可调透明度滑块） | **秋季正式版后做** | `Sources/SkyBridgeCompassApp/Views/LiquidGlassUserArea.swift`、iOS `Utilities/LiquidGlass.swift` | 项目已有 glass 抽象层，接入成本低-中；需 Xcode 27 正式版 SDK |
| 4 | **App Intents schema 化 + View Annotations + AppIntentsTesting** | **秋季正式版后做** | `Sources/SkyBridgeCore/IntentBridge.swift`、`SkyBridgeCompassWidgets/WidgetIntents.swift`、iOS LiveActivities | "连接到 X 设备 / 开始远程会话 / 发送文件" 获得 Siri AI 系统级入口，对远程控制类 App 是真实差异化能力；AppIntentsTesting 可补当前 intents 零测试现状。注意 Siri AI 初期在欧盟 iPhone/iPad 与中国大陆不可用，不得让核心流程依赖它 |
| 5 | **Foundation Models framework（多模态、Language Model protocol）** | 正式版后做 PoC，**仅限非核心诊断路径** | `SkyBridgeCore/ML`（异常检测）、连接失败诊断摘要 | `FEATURE_DESIGN_v2.md` 已规划 "ML 异常检测 → Foundation Models"。部署目标 17/14 意味着必须维护规则引擎双路径；**禁止进入握手/加密/媒体热路径** |
| 6 | **Xcode 27 / Device Hub** | 工具链正式版后切换；Device Hub 可先用于 beta 真机冒烟 | 工程/CI | Apple Silicon only 无影响（仓库已是 arm64-only）；切换前重验 notarization 与 vendored xcframework |
| 7 | **Core AI framework（自定义模型本地加载/特化）** | **不做** | — | 无自定义大模型需求；唯一未来场景是 UltraStream 超分/帧预测（`RemoteDesktop/UltraStream/`），届时再评估 |
| 8 | **Spatial Preview / reorderable containers** | **不做** | — | 无 visionOS target；收益不抵 27-only 分支维护成本 |

## Google I/O 2026 参考结论

I/O 2026 的主线是 agentic 开发（Gemini 3.5 Flash、Antigravity 2.0、Managed Agents、AI Studio 原生 Android 支持）。对本项目的影响：

- **Android 客户端路线**（`Docs/UbuntuAndroidIntegrationPracticalPlan.md`）：Android Studio 的 Migration Agent 与开源 Android Skills（Jetpack Compose 迁移等）可降低未来 Android 端实现成本；前提仍是先完成两端协议防漂移/`SkyBridgeProtocolCore` 复用（见 `CoreLayering.md`），否则 Android 端会成为第三份手工复制的协议实现。
- **WebMCP / Modern Web Guidance**：与本项目无直接交集，不采纳。
- **Managed Agents / Gemini API**：服务端无 AI 推理需求，不引入（符合依赖管理原则：不为小问题引入重量级依赖）。

## 与本次安全/质量修复的关系

2026-06-10 同步完成的修复（详见 git 历史）：

- 两端 `PQCSignatureProvider` 验签回退收紧为"仅运行性异常才回退 liboqs"，消除双实现并集验签面——该语义在 OS 27 上验证 CryptoKit PQC 行为时必须保持（#1 验证项）。
- iOS/macOS `WebRTCSession` 对未知 DataChannel label 的 fail-closed 语义已两端对齐；未来若新增通道 label，必须同步升级两端并提供版本协商，否则旧端会主动断开。
