# SkyBridge 文档入口

当前用户要求、源码/配置、接受的契约和绑定当前候选的验证回执优先。设计目标、历史审查和发布记录分别保留，不把旧的 current/ready/completed 当作今天的状态。

| 主题 | 现行入口 |
| --- | --- |
| 传输和核心边界 | [ADR-0001](ADR-0001-SkyBridge-Core-Transport-Matrix.md)、[Core layering](CoreLayering.md) |
| 原生运行时和操作入口 | [ADR-0003](ADR-0003-Native-Runtimes-and-Operator-Contract.md)、[CLI scope](cli-scope-v1.md) |
| 本地授权、远控和会话 | [ADR-0002](ADR-0002-Remote-Control-Authority-and-Sessions.md)、[入站契约](inbound-route-contract.md) |
| 账号设备登记、在线和移除 | [共同生命周期](account-device-lifecycle.md) |
| 文件授权与接收证明 | [文件契约](cli-file-approval-contract.md)、[路由真值](file-transfer-route-source.md) |
| 信令、认证和部署 | [生命周期](signaling-lifecycle-contract.md)、[认证操作](ops/auth-email-and-sms-production.md)、[服务端部署](../Server/skybridge-signaling/deploy/README.md) |
| Apple 平台和真机 | [OS 27 Runbook](os27-cutover-and-real-device-runbook.md)、[iOS 入口](<../SkyBridge Compass iOS/README.md>) |
| 发布与产品证据 | [macOS 打包](ops/macos-release-packaging-runbook.md)、[iOS 发布事务](ops/ios-app-store-release-transaction.md)、[产品证据](ops/apple-formal-product-evidence.md) |

## 合并的跨平台接入约束

旧 Ubuntu/Android 接入计划已由上述运行时与协议契约替代。保留它的有效要求：共享信令/消息、身份、授权、生命周期、完整性和错误语义；各平台通过自己的原生适配器实现。Android 使用现有 Kotlin/JNI 边界，不再根据旧提案复制 Apple app 或增加另一套 Android runtime。

文件接收、首帧、实际输入、断开恢复和用户可见状态仍需分别验证。历史“Apple 已打通”不证明新候选或其他平台通过；Windows 当前没有真机验收，Linux 主机编译不证明原生 Linux 运行。未完成事项继续由现行验收清单和真实结果管理。

## 历史材料

`CrossPlatformDiscoveryDesign.md` 与 OS 27 June plan 仍被源码契约测试读取，保留作为历史输入。纸稿、旧 KDF/算法材料、审查失败、原始测试数据、许可和冻结源身份保留。更新论文或实验结论需要独立证据，不通过清理文档改写历史结果。
