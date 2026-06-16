# iOS 27 / macOS 27 (Golden Gate) 适配计划（2026-06-14）

状态：WWDC26 已结束，Apple 已发布 iOS 27 / iPadOS 27 / macOS 27 / Xcode 27 **开发者 beta**；正式版预计 2026 年秋季。当前日期为 2026-06-14，本文只把 Apple 官方已公开的 27 beta 文档、CryptoKit quantum-secure workflows、Foundation Models/Core AI 文档、本机 Xcode 27 SDK 事实和本项目实际架构（远程桌面 + PQC 加密 + WebRTC + Metal 渲染 + Widgets）作为工程依据。

官方事实入口：

- Apple Releases: https://developer.apple.com/news/releases/
- Xcode 27 beta release notes: https://developer.apple.com/documentation/xcode-release-notes/xcode-27-release-notes
- iOS/iPadOS 27 beta release notes: https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes
- macOS 27 beta release notes: https://developer.apple.com/documentation/macos-release-notes/macos-27-release-notes
- CryptoKit quantum-secure workflows: https://developer.apple.com/documentation/cryptokit/enhancing-your-app-s-privacy-and-security-with-quantum-secure-workflows
- CryptoKit HPKE X-Wing ciphersuite: https://developer.apple.com/documentation/cryptokit/hpke/ciphersuite/xwingmlkem768x25519_sha256_aes_gcm_256
- Apple Support TLS quantum-secure readiness: https://support.apple.com/en-us/122756
- Apple Platform Security quantum-secure cryptography: https://support.apple.com/guide/security/quantum-secure-cryptography-apple-devices-secc7c82e533/web
- Apple Platform Security TLS security: https://support.apple.com/guide/security/tls-security-sec100a75d12/web
- Foundation Models: https://developer.apple.com/documentation/foundationmodels
- Core AI: https://developer.apple.com/documentation/coreai
- Apple developer tools / intelligence frameworks WWDC26 newsroom: https://www.apple.com/newsroom/2026/06/apple-aids-app-development-with-new-intelligence-frameworks-and-advanced-tools/
- Platforms State of the Union takeaways: https://developer.apple.com/news/?id=lvart8mq
- WWDC26 What’s new in Xcode 27: https://developer.apple.com/videos/play/wwdc2026/258/
- WWDC26 Device Hub: https://developer.apple.com/videos/play/wwdc2026/260/
- WWDC26 Trust Insights: https://developer.apple.com/videos/play/wwdc2026/379/
- WWDC26 App Attest: https://developer.apple.com/videos/play/wwdc2026/201/
- WWDC26 agentic feature security: https://developer.apple.com/videos/play/wwdc2026/347/
- WWDC26 SwiftUI updates: https://developer.apple.com/videos/play/wwdc2026/269/
- Liquid Glass technology overview: https://developer.apple.com/documentation/technologyoverviews/liquid-glass
- Adopting Liquid Glass: https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass

## 基线约束（不变）

- 部署目标保持 **macOS 14+ / iOS 17+** 不动；iOS 17 / A12 仍是 app-start 兼容下限，pre-2020 A12/A12X 设备只允许在具体能力层标记 legacy-limited，不能被 OS27 或 Apple PQC 工作误改成启动阻断。任何新引入的 OS 27-only API 必须按 feature capability 走 `#available(macOS 27, iOS 27, *)` 守卫，不得用 deployment target 提升来“获得”API。既有 26-era 设计 API（例如 `glassEffect`）继续只允许通过兼容 wrapper 使用，并与未来 27-only guard 并存（沿用 `FEATURE_DESIGN_v2.md` 的渐进增强工厂模式）。
- **Release 不得使用 beta SDK 构建**：正式分发继续使用 Xcode 26.5 稳定工具链，直至 Xcode 27 正式版发布并重验 notarization 链、update manifest 签名、`liboqs.xcframework` 与 WebRTC binary 兼容性。
- Xcode 27 beta 必须与稳定 Xcode 并存安装；安装/连接设备状态先用 `Scripts/run_os27_beta_compatibility.sh --diagnose-environment` 做只读诊断（不运行 build/test/PQC probe，输出 `compatibility=not_validated`）。该诊断同时记录 Xcode 27 beta bundle 结构、Info.plist、关键文件 mtime、Apple codesign 元数据、签名 verify、Gatekeeper assessment 状态、quarantine/provenance xattr 状态，以及 bundle metadata build 与 `xcodebuild -version` build 的一致性。若 Apple beta 包出现 mtime 或 build metadata 异常，处理边界是记录 `metadata_mismatch`/相关状态并继续用签名、SDK、runtime gate 判断能否做 beta 兼容验证；不得重签名、改 Info.plist、改 mtime 或移除 provenance 来制造“正常”。这些都只是环境 metadata，不能作为 SDK runtime、PQC 可用性或 release eligibility 证明。`Scripts/run_os27_beta_compatibility.sh --verify-source-contracts` 可跑 source-contract preflight（输出 `coverage=source_contracts_only`，仍不是 runtime 兼容证明），但该模式仍会运行三平台 Apple PQC SDK 符号探测，因此当前 Xcode/SDK 必须具备 CryptoKit PQC 符号；它不是“无 SDK”的纯静态检查。完整验证必须通过 `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer SKYBRIDGE_OS27_RUN_IOS_DEVICE_TESTS=1 Scripts/run_os27_beta_compatibility.sh` 手动执行；该 lane 不 notarize、不发布、不写 `macos-stable.json`。未跑 iPadOS 27 真机 PQC runtime 时只能显式使用 `SKYBRIDGE_OS27_ALLOW_PARTIAL_WITHOUT_DEVICE=1` 做 partial 诊断，且返回 `compatibility=partial_not_validated` 非零状态，不能作为完整兼容结论。
- Apple CryptoKit PQC 仍按 iOS/macOS 26+ API 处理；OS 27 的首要任务是验证 ML-KEM / ML-DSA / X-Wing 行为、Secure Enclave PQC 能力和 WebRTC/Metal/SwiftUI 回归，而不是创建 27-only 协议分支。
- WWDC26 官方资料中没有可直接用于本项目的量子通信、QKD 或量子网络 app API；当前可采用的“量子”相关工程落点仍是 CryptoKit quantum-secure cryptography、HPKE X-Wing 和本项目自己的 negotiated suite/runtime proof。任何“量子通信”产品文案都不得替代 PQC 证明链。
- WWDC26 的 Foundation Models、Core AI、Private Cloud Compute 或任何 Apple Intelligence 能力不得进入握手、密钥生成/存储、签名验签、PQC suite selection、WebRTC media hot path 或 release gate。它们只能先落在诊断摘要、离线质量分析、非阻塞 UX 辅助路径，并且必须保留现有规则/本地确定性实现作为默认路径。

## 2026-06-14 Apple 官方 PQC/TLS 事实刷新

- OS 26+ 的 `URLSession` / `Network` TLS 1.3 路径会在 `ClientHello` 中广告 `X25519MLKEM768` hybrid quantum-secure key exchange，但这只是 transport capability advertisement；只有服务器在 TLS 握手中选择该 group 时，才有 negotiated TLS proof。最低人工验证命令是 `nscurl --tls-diagnostics https://<server>`，并检查输出包含 `Negotiated TLS key exchange group (name): X25519MLKEM768`。
- 该 TLS 事实不改变 SkyBridge 应用层 PQC 证明链：`network-tls-pqc-v1` 仍是 transport diagnostic only，报告必须继续保留 `proof_scope=transport_sdk_public_api_surface_only`、`server_support_required=true`、`session_negotiated=false`、`affects_crypto_suite_selection=false`、`release_eligible=false`。TLS hybrid KEX 不得进入 `CryptoSuite`、provider selection、握手 transcript、用户可见“已量子安全连接”文案或 release gate。
- Apple Platform Security 明确把 developer cryptographic APIs 落在 CryptoKit ML-KEM 768/1024、ML-DSA-65/87 以及 well-analyzed protocol 责任上；因此本项目仍只接受 `symbol_probe` + ApplePQC/AppleXWing runtime self-test + negotiated suite/trust material proof，不接受 OS 版本、SDK 版本、硬件型号、TLS advertisement 或 Xcode GUI 状态作为应用层 PQC 会话证明。
- WWDC26 的 Foundation Models / Core AI / Private Cloud Compute、App Intents schema / View Annotations / AppIntentsTesting、Xcode 27 Device Hub / coding agents 是可研究的新能力，但在当前 release 边界内只允许进入 advisory、测试辅助或人工诊断流程。它们不得读取密钥、连接码、raw logs、网络拓扑、文件名或 handshake transcript，也不得直接触发连接、文件传输、远程桌面、信任变更、密钥迁移或 release eligibility。
- macOS 27 beta 当前观察到的侧边栏材质/黑色矩形异常按平台 beta rendering artifact 处理，不作为产品设计回退依据。应用代码必须保留 `NavigationSplitView` + `GlassSidebar` 基线、保留蓝底图标和顶部栏 trailing-aligned 控件，不得叠加第二层自定义圆角玻璃层来掩盖系统 beta bug；后续只通过截图、Feedback Assistant、OS 更新复测和 source-contract 记录状态。

## 2026-06-13 本机 Xcode 27 beta 证据

- `/Users/bill/Desktop/Xcode_27_beta.xip` 保留 Apple developer 下载来源和 provenance xattr；`pkgutil --check-signature` 显示 Apple Software 签名，`xip --expand` 可在临时目录成功展开。XIP TOC 和展开后的 bundle 存在 Apple beta 包元数据异常：部分 `FinderCreateTime` 为 1900/1970，少量文件 mtime 为 1970-01-01。该异常不能靠重签名、改 Info.plist、改 mtime、移除 provenance 或重新打包来“修复”；处理边界是记录并继续依赖 Apple 签名、SDK symbol probe 和 runtime gate。
- `/Applications/Xcode-beta.app` 已并存安装；`codesign --verify --deep --strict --verbose=4` 通过，`xcodebuild -version` 为 `Xcode 27.0 / Build version 27A5194q`，Swift 为 `6.4`，`macosx`、`iphoneos`、`iphonesimulator` SDK 均为 `27.0`。当前本机 `spctl --status` 为 assessments disabled，因此 `spctl` 不能作为强 Gatekeeper 通过证明。
- `Scripts/run_os27_beta_compatibility.sh --diagnose-environment` 记录到 beta metadata mismatch：bundle `Info.plist` build 为 `27A5194o`，`xcodebuild` build 为 `27A5194q`。这是当前 Apple beta 包元数据异常；处理方式是保留并报告 `metadata_mismatch`，不得改 `Info.plist`、mtime、签名、quarantine 或 provenance 来制造一致。
- `Scripts/apple_pqc_sdk_probe.sh` 在 Xcode 27 beta 下三平台 `symbol_probe` 通过：`macosx`/`iphoneos`/`iphonesimulator` 均能 typecheck CryptoKit ML-KEM、ML-DSA、HPKE X-Wing；macOS probe 额外包含 Secure Enclave PQC symbols。OS27 beta 报告使用 `cryptokit-pqc-os27-v1` 标记这组 WWDC26 后的 SDK 探测范围；稳定 release manifest 仍只接受 Xcode 26.5 baseline 的 `cryptokit-pqc-v1`。该结论只证明 SDK 符号和编译 gate，不证明 iPadOS 27 runtime 或 release eligibility。
- 本轮先通过 `Scripts/run_os27_beta_compatibility.sh --verify-source-contracts` 完成 source-contract lane：三平台 CryptoKit PQC symbol probe 通过，OS27 filtered source-contract tests 通过，控制台输出固定为 `source_contracts=verified full_validation=false compatibility=not_validated release_eligible=false`，机器报告固定为 `schema_version=2 mode=source-contracts status=source_contracts_verified full_validation=false compatibility=not_validated release_eligible=false coverage=source_contracts_only gates.source_contracts=passed`。source-contract-only 报告不得单独描述为 full validation。SwiftPM/xcodebuild clean-log gate 现在受 `SKYBRIDGE_OS27_BUILD_GATE_TIMEOUT_SECONDS=1800` 默认超时保护；beta toolchain 卡住会写失败报告并保持 `compatibility=not_validated`，不能被解释为通过。默认路径 `Artifacts/os27/compatibility-report.json` 是最新一次 lane 的可变产物；审计时必须直接读取 JSON 字段并用 `Scripts/check_os27_compatibility_report.py --require-source-contracts` 或 `--require-full-validation` 显式复核，不能把本文档中的历史示例当成当前 artifact 状态。
- `Network.framework` SDK 27 的 `.tbd` 中可见 `SwiftTLSOptions.KeyExchangeGroup.x25519MLKEM768` 符号痕迹，但本仓库显式 `SwiftTLSOptions.KeyExchangeGroup.x25519MLKEM768` 配置探针当前不能作为 source-level proof；这不否定 OS 26+ `URLSession` / `Network` 默认 `ClientHello` 广告能力。因此它只作为 `network-tls-pqc-v1` transport-only 诊断探针记录，报告范围固定为 `proof_scope=transport_sdk_public_api_surface_only server_support_required=true session_negotiated=false affects_session_status=false affects_crypto_suite_selection=false release_eligible=false`；即便后续公开 API probe 通过，也不能进入 `CryptoSuite`、provider selection、握手 transcript、release gate 或用户可见“已量子安全连接”文案。当前项目继续把 quantum-secure 会话证明收敛在 CryptoKit provider、HPKE X-Wing runtime self-test 和 OS27 report，不新增 OS27-only wire suite。

### 2026-06-13 追加本机验证结果

- 当前本机 `/Applications/Xcode-beta.app` 可直接由 `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -version` 调用，结果为 `Xcode 27.0 / Build version 27A5194q`；`xcrun swift --version` 为 Apple Swift 6.4，target `arm64-apple-macosx27.0.0`。
- `xcrun simctl list runtimes` 已显示 `iOS 27.0 (24A5355p)` runtime；`simctl list devices 'iOS 27.0'` 已显示 iPhone 17 / 17 Pro / 17e / iPhone Air / M5 iPad Pro / M4 iPad Air 等 simulator。
- `codesign --verify --deep --strict --verbose=2 /Applications/Xcode-beta.app` 通过，说明当前 bundle 签名链在本机可验证；这不改变 beta SDK 不可 release 的边界。
- 本次 source-contract lane 命令为 `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer SKYBRIDGE_OS27_COMPAT_REPORT_PATH=/tmp/skybridge-os27-wording-source-contract.json Scripts/run_os27_beta_compatibility.sh --verify-source-contracts`，结果为 `source_contracts=verified full_validation=false compatibility=not_validated release_eligible=false`，81 个 OS27 source-contract tests 0 失败；机器报告中 `apple_quantum_secure_runtime_proof.status=not_run`。该结果只证明源码/脚本 guardrail，不证明真机 runtime 兼容。
- 旧 `/tmp` full-validation JSON 只作为历史定位材料，不再作为当前兼容证明：旧报告可能缺少 `schema_version=2`、`full_validation_attempted`、`full_validation_passed` 或 OS27 专用 `cryptokit-pqc-os27-v1` 字段。当前真机完整证明必须重新运行 full lane，并紧接着执行 `python3 Scripts/check_os27_compatibility_report.py --require-full-validation Artifacts/os27/full-validation-report.json`；只有 checker 通过的当前 JSON/log 对才能作为 OS27 full-validation 证据。
- 本次 iOS 27 simulator targeted test 命令为 `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild test -project 'SkyBridge Compass iOS/SkyBridgeCompass-iOS.xcodeproj' -scheme SkyBridgeCompassiOSTests -destination 'platform=iOS Simulator,name=iPhone 17,OS=27.0' CODE_SIGNING_ALLOWED=NO -only-testing:SkyBridgeCompassiOSTests/KEMTrustStoreTests/testSignedRefreshKEMLookupRequiresSignedSourceAndPinnedProtocolFingerprint`，结果 1 test 0 失败。输出中出现 `IOSurfaceClientSetSurfaceNotify` 与 PointerUI XPC simulator 系统日志；不作为项目编译 warning，但后续 clean-log lane 应继续分离系统日志噪声与项目 warning。

## WWDC26 技术采用矩阵（2026-06-13 审核）

| 技术 | 当前处置 | 可用落点 | 禁止落点 / 原因 |
|------|----------|----------|-----------------|
| CryptoKit quantum-secure workflows / HPKE X-Wing | **继续采用并优先验证** | `Scripts/apple_pqc_sdk_probe.sh`、`CryptoProviderFactory`、ApplePQC/X-Wing runtime self-test、update manifest provenance | 不创建 OS27-only suite，不用 SDK major/version 推断能力；只接受 symbol probe + runtime proof |
| Network.framework TLS hybrid KEX (`x25519MLKEM768`) | **只做 transport-only 诊断** | `Scripts/apple_pqc_sdk_probe.sh` 的独立 Network TLS PQC 探针、OS27 report `network_tls_pqc_symbol_probe_details`；报告必须保留 `proof_scope=transport_sdk_public_api_surface_only`、`server_support_required=true`、`session_negotiated=false`、`affects_session_status=false` | 本仓库显式 `SwiftTLSOptions` 配置探针不能替代服务端 negotiated TLS proof；即使 probe 通过也不得进入应用层 PQC、`CryptoSuite`、provider selection、release eligibility 或“端到端已 PQC”文案 |
| Xcode 27 beta / Swift 6.4 / SDK 27 | **只做兼容验证** | `Scripts/run_os27_beta_compatibility.sh`、source-contract、manual device lane | 不进入 release DMG/package/readiness/publish manifest；不切换 stable release baseline |
| Device Hub / Organizer workflow 更新 (`device-hub-diagnostics`) | **手动验证辅助** | 设备连接诊断、物理 iPadOS 27 PQC runtime proof 记录 | 不替代 `xcodebuild` clean-log gate，不把 GUI 连接状态、`devicectl` 可见状态或 Simulator 状态当 runtime proof、Mac-iPad live interop proof 或 release gate |
| Foundation Models framework | **正式版后 PoC，当前只记录边界** | `AnomalyDetectionService` 的非阻塞解释、连接失败摘要、用户可见诊断文本草稿 | 禁止参与认证、鉴权、密钥决策、降级决策、自动阻断；不能把模型输出当安全事实 |
| Private Cloud Compute / Apple Intelligence 服务路径 | **不作为默认依赖** | 未来若做 opt-in 诊断上传，必须先有隐私清单、用户同意和脱敏 contract | 禁止发送密钥、连接码、设备标识、网络拓扑、文件名、日志原文或 handshake transcript |
| Core AI framework | **暂不采用** | 未来 UltraStream 超分/帧预测 PoC，且必须在 renderer capability 层隔离 | 不进入 `SkyBridgeCore` 协议层或 PQC provider；不新增大模型运行时依赖 |
| App Intents pending-confirmation bridge (`app-intents-pending-confirmation`) / OS27 schema / AppIntentsTesting | **Siri connect 入口只做待确认请求；Widget intents 只做导航/刷新；OS27 正式版后再 schema 化** | 当前 macOS Siri connect AppIntent 只唤醒 app、写入 pending request、要求应用内确认后连接；当前 Widget AppIntents 只能 post navigation/refresh notification 或 reload timelines；后续再评估连接设备、发送文件、开始远程会话、Widget/Live Activity 控制面 | Intent 不得直接调用连接、信任、PQC、Keychain、文件传输引擎、远程桌面引擎、release gate；不让 Siri/AI 可用性决定核心流程；欧盟/中国大陆可用性差异必须有普通 UI 路径 |
| Liquid Glass / SwiftUI 27 visual updates | **正式版后做视觉渐进增强** | 已有 glass 抽象、sidebar/window chrome、用户透明度设置 | 不改变 macOS 14/iOS 17 的首屏可用性，不引入 27-only view 作为默认入口 |
| Xcode 27 Device Hub / coding agents / MCP / ACP plug-ins | **采用为人工辅助工具，不进入 release gate** | 设备/Simulator 复现、Xcode 内联 issue triage、Figma/GitHub 辅助工作流 | 不替代 shell 可复现命令、source-contract、clean-log、真机 runtime proof |
| Trust Insights | **先做安全研究，不进核心决策** | 未来可作为远程控制/文件传输的 social-engineering 风险提示候选 | 不能作为连接准入、阻断、降级、密钥或认证事实；只能 advisory，且必须尊重隐私边界 |
| App Attest（含 macOS 27 支持和 iOS 27 新 signals） | **值得做 server-backed PoC** | Supabase/API 请求完整性、付费/敏感操作、防篡改信号；server 验证 attestation/assertion | 不在客户端本地自证；不能阻塞核心 P2P 离线功能；必须有 key rotation、backoff、fraud metric 风险评估 |
| Agentic feature threat modeling | **立即作为 AI/Apple Intelligence 约束** | App Intents / Foundation Models PoC 前的 threat model、user confirmation、secure prompt/context redaction | 禁止让模型读取密钥/连接码/raw logs/topology；禁止未确认的副作用动作 |

### 采用前必须满足的契约

- Apple 平台能力采用边界同时记录在 `SkyBridgeApplePlatformFeatureRegistry`：`cryptokit-pqc-v1` 是稳定 release baseline proof，`cryptokit-pqc-os27-v1` 是 OS27 beta compatibility evidence，`network-tls-pqc-v1` 是 transport diagnostic only，`device-hub-diagnostics` 是人工设备诊断 only，`liquid-glass-wrapper` 只能走兼容包装器，`foundation-models-advisory` / `core-ai-advisory` 只能走脱敏 advisory DTO，`app-intents-pending-confirmation` 只能唤醒 app、写待确认请求或触发 Widget 导航/刷新。
- 新增 Apple 27 API 只能通过隔离 adapter 或 feature module 暴露给现有业务层；调用点必须有 `#available` 和测试覆盖。
- Liquid Glass / OS27 设计 API 只能进入明确的兼容包装器；业务视图只能调用 `SkyBridgeUI` 或 iOS `Utilities/LiquidGlass.swift` 暴露的渐进增强入口。新增 OS27-only 设计符号前必须先有 SDK symbol probe、显式 compile condition、`#available` 运行时分支、老系统 fallback 和 source-contract 更新；裸 `#available(...27...)` 不是稳定 Xcode 26.5 发布链可接受的证明。
- 任何 AI/模型输出必须标记为 advisory，现阶段只能通过 `AIAdvisoryInputDTO` / `AIAdvisoryOutputDTO` 这样的脱敏 DTO 边界；输入只能包含分类事实、脱敏上下文和既有确定性 policy/anomaly snapshot，不能驱动安全决策、连接准入、自动降级或密钥迁移。
- 任何网络/云 AI 路径默认关闭；启用前必须有隐私文案、脱敏器、日志审计和单测，并禁止日志原文、连接码、设备标识、文件名、handshake transcript、token/challenge 进入模型上下文。
- OS27 source-contract 只证明源码/脚本 guardrail，没有 runtime 结论；完整兼容仍以 Xcode 27 + iPadOS 27 真机 PQC runtime lane 为准。
- Release baseline 切换到 Xcode 27 正式版前，必须重新跑 notarization、update manifest、vendored xcframework、SwiftPM clean-log、iOS/macOS 真机互通矩阵。

## PQC adoption matrix（PQC 采用与 release eligibility）

| 能力 | 当前用途 | 最低证明 | release eligibility |
|------|----------|----------|---------------------|
| Apple CryptoKit ML-KEM / ML-DSA | 26+ Apple PQC provider、签名/验签、runtime self-test | `HAS_APPLE_PQC_SDK` 只能由 `symbol_probe` 打开；release 前还需要 iOS/macOS runtime proof 与 clean-log gate | 稳定 Xcode 26.5 当前可进入 release；Xcode 27 beta lane `release_eligible=false` |
| CryptoKit HPKE X-Wing | AppleXWing 会话密钥封装、跨端互通验证 | `symbol_probe` + X-Wing seal/open runtime proof；不得按 SDK major 推断可用 | 稳定 SDK 通过 runtime proof 后可进入 release；OS27 source-contract 本身 `release_eligible=false` |
| liboqs / OQSRAII | 旧系统和 Apple PQC 不可用时的显式兼容 provider | vendored xcframework hash、Mach-O minos、签名/验签和封装/解封测试 | 作为兼容路径可 release；不得伪装成 Apple PQC 或 strictPQC 证明 |
| Classic X25519 / Ed25519 | 仅限非 strictPQC legacy compatibility | 必须由策略明确允许，日志/manifest 不得宣称 PQC | 可作为非 PQC 兼容 release 路径；strictPQC 场景 `release_eligible=false` |
| Foundation Models / Core AI / Private Cloud Compute | 非阻塞诊断解释、离线质量分析候选 | `AIAdvisoryInputDTO` / `AIAdvisoryOutputDTO` 脱敏 DTO、advisory 标记、隐私清单、脱敏 contract、adapter 和测试齐备 | 安全路径、密钥路径、握手路径、PQC suite selection、release gate 永远 `release_eligible=false` |
| Xcode 27 beta / SDK 27 | 兼容性验证、API/source-contract 探测 | Xcode 27 + macOS/iPhoneOS/iPhoneSimulator SDK 27 + `symbol_probe` + iPadOS 27 runtime proof | beta 构建不得发布；稳定 release baseline 仍是 Xcode 26.5，直到 Xcode 27 final 完整重验 |

## 适配决策（按优先级）

| # | 事项 | 时机 | 适用模块 | 决策依据 |
|---|------|------|----------|----------|
| 1 | **OS 27 beta 回归验证**：Apple PQC 路径（`HAS_APPLE_PQC_SDK`、ML-KEM/ML-DSA/X-Wing）、WebRTC 连通、ScreenCaptureKit/Metal 渲染、Liquid Glass 视觉 | **现在做**（验证与 gate 加固，不改协议语义） | QuantumSecure、RemoteDesktop、SkyBridgeUI、iOS 全链路 | 提前发现 27 上的行为回归；使用 `Scripts/run_os27_beta_compatibility.sh`、`skybridge smoke suite` 与 `Scripts/run_local_webrtc_smoke.sh`。CryptoKit PQC 行为变化风险最高，需重点验证签名/验签与 26 的互操作 |
| 2 | **SwiftUI state initialization / layout 渲染提速** | 自动获得（beta 上量化对比） | SkyBridgeUI、SkyBridgeCompassApp、iOS Views | Apple 声明无需改代码即生效；用 `MacUIBaselineCapture` / `SkyBridgeVisualParity` 做前后帧率与视觉基线对比，layout 行为变化由 #1 兜底 |
| 3 | **Liquid Glass 更新**（统一窗口圆角、edge-to-edge sidebar、彩色侧边栏图标、用户可调透明度滑块） | **秋季正式版后做** | `Sources/SkyBridgeCompassApp/Views/LiquidGlassUserArea.swift`、iOS `Utilities/LiquidGlass.swift` | 项目已有 glass 抽象层，接入成本低-中；需 Xcode 27 正式版 SDK |
| 4 | **App Intents schema 化 + View Annotations + AppIntentsTesting** | **秋季正式版后做** | `Sources/SkyBridgeCore/IntentBridge.swift`、`SkyBridgeCompassWidgets/WidgetIntents.swift`、iOS LiveActivities | "连接到 X 设备 / 开始远程会话 / 发送文件" 获得 Siri AI 系统级入口，对远程控制类 App 是真实差异化能力；AppIntentsTesting 可补当前 intents 零测试现状。注意 Siri AI 初期在欧盟 iPhone/iPad 与中国大陆不可用，不得让核心流程依赖它 |
| 5 | **Foundation Models framework（多模态、Language Model protocol）** | 正式版后做 PoC，**仅限非核心诊断路径** | `SkyBridgeCore/Security/AnomalyDetectionService.swift` 的解释层、连接失败诊断摘要 | 部署目标 17/14 意味着必须维护规则引擎双路径；模型输出只能 advisory，**禁止进入握手/加密/媒体热路径** |
| 6 | **Xcode 27 / Device Hub** | beta 阶段仅手动验证；工具链正式版后才评估切换 release baseline | 工程/CI | 当前本机已将 Xcode 27 beta 并存安装到 `/Applications/Xcode-beta.app`；`--diagnose-environment` 必须分别记录 first-launch/toolchain/SDK/device/bundle metadata。bundle 签名时间、文件系统 mtime、quarantine 和 Gatekeeper 状态只能定位安装问题，不能证明 SDK、Device Hub runtime 或 PQC 可用；切换 release baseline 前必须重验 notarization、vendored xcframework、Swift warnings-as-errors 和 iOS/macOS 真机互通 |
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

## 2026-06-11 已落地的兼容 guardrail

- iOS Xcode 工程的 app/test target 只保留空的 `SKYBRIDGE_APPLE_PQC_SDK_CONDITION` 接入口；OS27 lane 必须在 `macosx`、`iphoneos`、`iphonesimulator` 三个平台 Apple PQC symbol probe 全部通过后，才显式传入 `HAS_APPLE_PQC_SDK`，避免按 SDK 大版本推断可用性。
- `Scripts/check_ios_test_configuration.sh` 已把上述 selector 纳入静态校验，后续 project.yml / pbxproj 漂移会直接失败。
- `Scripts/apple_pqc_sdk_probe.sh` 已改为真实 `probe.swift` typecheck，并支持按 SDK 显式探测：macOS / iPhoneOS / iPhoneSimulator 共同验证 ML-KEM-768/1024、ML-DSA-65/87、X-Wing HPKE；macOS 额外验证 Secure Enclave ML-KEM/ML-DSA。符号探测失败不再允许按 SDK major 推断成功。
- `run_app.sh` 与旧 `Scripts/build_with_widgets.sh` 已复用同一 PQC 符号探针，不再仅靠 SDK major 判断是否启用 Apple PQC 编译条件；release DMG/package 入口在 Apple PQC symbol probe 失败时 fail closed，并且不接受 `SKYBRIDGE_ALLOW_RELEASE_WITHOUT_APPLE_PQC_SDK=1` 旁路。
- 新增 `Scripts/run_os27_beta_compatibility.sh` 作为 Xcode 27 beta 手动兼容入口；该脚本要求真实 Xcode 27 + macOS/iPhoneOS/iPhoneSimulator SDK 27 + 三平台 Apple PQC symbol probe 通过后才运行测试/build，并默认要求 iPadOS 27 beta 真机 runtime PQC self-test。
- `Scripts/run_os27_beta_compatibility.sh --diagnose-environment` 提供只读环境诊断：汇总候选 Xcode 27 路径、Xcode beta bundle 结构/签名/时间戳/quarantine/Gatekeeper metadata、bundle build consistency、当前 Xcode/SDK 与已连接 iPadOS 27 beta iPad 数量；工具探测有超时保护，卡住或 license 未接受会报告 `toolchain_invocation_timeout`/失败状态并输出 `compatibility=not_validated`，不会被误判为通过。该模式不 source PQC probe、不设置 `SKYBRIDGE_ENABLE_APPLE_PQC_SDK`、不运行 SwiftPM/xcodebuild/真机测试，不 notarize、不发布、不写 manifest；bundle metadata 输出固定为 `release_eligible=false`，并且不会输出设备名、UDID、序列号、hostname、raw quarantine、raw TeamIdentifier 或 raw CDHash。
- `Scripts/run_os27_beta_compatibility.sh` 所有模式都会写入机器可读兼容报告，默认路径是 `Artifacts/os27/compatibility-report.json`，也可通过 `SKYBRIDGE_OS27_COMPAT_REPORT_PATH` 覆盖。报告字段包括 `mode`、`status`、`compatibility`、`release_eligible=false`、Xcode/Swift/SDK 版本、Xcode beta bundle 签名与 metadata 状态、PQC symbol probe 状态、SwiftPM/iOS build/test gate 状态和 required iPadOS 27 device runtime test 状态。该报告只服务 OS27 beta 兼容审计，不被 `Scripts/generate_macos_update_manifest.swift`、release DMG、notarization 或 `macos-stable.json` 消费。
- `Scripts/run_os27_beta_compatibility.sh --verify-source-contracts` 在 Xcode 27 beta 尚未完全可用时继续验证脚本/源码/配置 guardrail：PQC probe API fixture、OS27 诊断 fixture、Mach-O minos release gate、iOS 配置 gate、release package policy，以及 Apple PQC/update manifest source-contract tests；该模式不运行 OS27 build 或 iPadOS 27 runtime test，输出 `compatibility=not_validated`。SwiftPM 与 xcodebuild clean-log gate 使用 `SKYBRIDGE_OS27_BUILD_GATE_TIMEOUT_SECONDS` 做有界失败，避免 beta toolchain 卡死导致无人能复现的半状态。
- `Scripts/verify_xcode_toolchain.sh` 默认执行 stable-release policy，release DMG/package/readiness/publish manifest 入口均要求 Xcode 26.5 / build 17F42 / macOS SDK 26.5，并拒绝 beta 命名的 Xcode developer directory；Xcode 27 beta 不得进入 stable release 产物或 `macos-stable.json`。
- `SkyBridge Compass iOS/Scripts/test_lane_ios_device.sh` 支持约束物理设备必须为 iPadOS 27 Beta，并验证显式 `SKYBRIDGE_IOS_DEVICE_ID` 也不能绕过 OS/release/device-type 过滤。
- OS27 full validation 默认向真机 lane 传入 `SKYBRIDGE_IOS_DEVICE_REQUIRE_RELEASE_TYPE=Beta`；如果 Apple 后续进入 final release，应新建/重命名 final validation lane，而不是把 beta lane 放宽为空约束。
- iPadOS 27 真机上的 `ApplePQCProviderRuntimeSelfTestTests` 已覆盖 ApplePQC 与 AppleXWing 的 key generation、ML-DSA sign/verify、ML-KEM/X-Wing seal/open。当前 Xcode 26.5 运行该测试会通过，但日志含 `Error locating DeviceSupport directory`；clean-log gate 会阻塞该状态，要求改用 Xcode 27 beta 完成最终 OS27 验证。
