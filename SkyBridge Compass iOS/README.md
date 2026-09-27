# SkyBridge Compass iOS：唯一阅读入口

日常启动、架构导航和历史教训集中于本页；[BUILD.md](BUILD.md) 负责构建、签名、测试与发布流程，[FEATURE_PARITY.md](FEATURE_PARITY.md) 负责能力差异，[RiskAuditChecklist.md](RiskAuditChecklist.md) 保留风险检查。重复的 Quickstart、项目总结、文件清单和完成快照已合并。

## 工程与验证入口

打开本目录的 `SkyBridgeCompass-iOS.xcodeproj`，选择 `SkyBridgeCompass-iOS` scheme。按实际可用设备选择 destination，不照抄旧文档固定的模拟器名称/OS。使用现有签名身份与配置，不为了启动而修改 bundle 身份。

XCTest target 为 `SkyBridgeCompassiOSTests`。XCUITest bundle/scheme 是否启用，以当前工程和实际执行结果为准；旧报告的 UI smoke 不能证明现有 scheme 已运行这些测试。`swift build/test` 只证明其覆盖的 package 路径，不替代完整 App、签名包或真机验收。

共享边界以 [CoreLayering](../Docs/CoreLayering.md)、[ADR-0001](../Docs/ADR-0001-SkyBridge-Core-Transport-Matrix.md) 和 [ADR-0003](../Docs/ADR-0003-Native-Runtimes-and-Operator-Contract.md) 为准。当前工程已消费根包产品（如 `OQSRAII`、`SkyBridgeWebRTCRuntime`）；“完全自包含、不要引用根包”是旧描述。不要恢复平行 vendor/local package 或用软链接复制核心。

| 位置 | 阅读用途 |
|---|---|
| `SkyBridgeCompassiOS/Sources/App`、`Views`、`Managers`、`ViewModels` | App 生命周期、页面和业务状态；以现存目录为准 |
| `SkyBridgeCompassiOS/Sources/Core` 与根包 `Sources` | 平台特有代码和共享边界，不能按同名文件推定重复 |
| `Widgets`、`SkyBridgeCompassiOSTests` | 扩展与测试 |
| 根目录 `Config/native-dependencies.lock.json` | native 依赖与版本来源 |
| 根目录 `Sources/Vendor/liboqs.xcframework` | 唯一 liboqs 产物，由仓库配方/provenance 验证 |

## 协议、配置和故障判断

- Apple PQC 需要 symbol probe、显式 compile gate、runtime self-test、所需信任/KEM 材料及实际协商结果；SDK 大版本、文件名或 provider 类型存在都不够。Info.plist 权限描述不能打开编译期 PQC。严格策略失败应显式报告，不能为连通而放宽身份/套件校验。
- PQC 只在 runtime-negotiated suite 已证明时声明。核对信任材料与协商 suite 是连接验收的一部分；发布说明中的安全结论也应在 runtime-negotiated suite 与信任/KEM 材料证明后声明。
- Identity pinning 使用 `IdentityPublicKeys.authoritativeProtocolFingerprint()` 的规范化协议身份；不能把裸公钥、wire blob 的任意 SHA-256 当作同一个指纹。
- `missingPeerKEMPublicKey` 要核对既有配对/信任同步和选中对端，不先生成替代身份。源码对齐、连接建立、双向文件完整性和真实远程输入分别验收。
- WebRTC 是传输，PQC/应用授权依然按应用协议验证。TURN 返回的 URI/授权策略和签名 QR 的处理以当前实现为准；旧静态 fallback 环境变量不能视为默认操作建议。
- 客户端配置只使用适合公开客户端的后端 URL/标识；服务端密钥不进入客户端包、客户端 Keychain 或日志。后端配置缺失与配对/网络权限失败应分开诊断。
- Bonjour/local-network 权限、同网段可达性和运行中的真实 device roster 需分别观察；优先使用可用的直接 USB 进行设备操作，不能用 Wi-Fi 成功冒充 USB 成功。

## 已提取的旧工程教训

- 旧说明曾把创建符号链接、`open Package.swift` 和完整 iOS App 构建混在一起。应以真实 `.xcodeproj`、scheme、target 和依赖图为准；SwiftPM library 通过不能证明 App 通过。
- 2026-01-16 的构建记录提到 ambiguous `.shared`、重复 `SkyBridgeLogger`、`#Preview` 返回/环境对象、引号问题。保留这些故障线索；按实际符号和编译器诊断修复，不把不同类型同名静态成员一概当根因，也不机械批量改成 `.instance`。
- 目录迁移会使硬编码 Desktop 路径失效。检查实际路径和包 target，不恢复旧软链接布局，不靠清空全部 DerivedData 或重建身份来“修复”。
- 旧文档同时宣称全部 PQC、跨端和测试完成，又把真实 liboqs 和测试列为未来任务。那些勾选、百分比和生产就绪措辞均撤出现行说明；保留的设计目标不算实测。
- 本地网络/Bonjour 权限、真机发现、Widget entitlement、前后台行为与双向文件/远程输入需要分别观察。模拟器 smoke 和文件存在不能替代设备验收。

## 历史验收的保留范围

2026-03-14 的原记录报告主 scheme simulator build/test、35 项 XCTest、最小 XCUITest smoke 和 identity pinning 对齐通过。本次未重跑这些检查；该数字不作为当前源码测试数、真机/发布验收或全功能完成证明。旧 scheme/test-plan 误指向问题及最小 smoke 的覆盖限制保留于此。

PQC-only 是否可建联、CloudKit、剪贴板、Widget、跨网/断点续传等能力要按当前代码路径与对应证据判断，不从旧表格复活已失效的完成主张。签名包设备验收、App Store 导出、实际上传和正式发布各有独立结果，按 [BUILD.md](BUILD.md) 与 [发布事务](../Docs/ops/ios-app-store-release-transaction.md) 执行。

合并前原文及其身份见 [合并映射](</Users/bill/document-audits/20260926-235911-consolidation/deletion-map.json>) 与 [单一恢复包](</Users/bill/document-audits/20260926-235911-consolidation/before-documents.tar.gz>)。本次只整理文档，没有修改产品代码、工程配置、身份或测试。许可与主 macOS 项目相同，原许可证保留。
