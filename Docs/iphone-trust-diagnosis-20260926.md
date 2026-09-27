# iPhone CLI 连接：信任读取修复与剩余冲突

日期：2026-09-26。此文记录开发候选包的观察，不是发布或传输验收报告。

## 前一候选包的结论

用户报告没有重装 iPhone 上的 SkyBridge、重置身份或重新配对。现有证据不能
把连接失败归因于用户改动。Mac 已记住当前 iPhone 协议指纹的“始终允许”；
本次失败发生在该授权与对端签名验证之后、本地持久信任提交之前。

已修复一个真实的 Keychain 读取缺陷，但修复后实机连接仍失败。旧指纹的生成
和写入来源尚未确定；未将“镜像陈旧”“密钥轮换”“测试污染”中的任何一种
假设写成已证实的根因。

## 已修复的原生边界

`TrustSyncService.loadAllFromKeychain` 原先对 generic-password 项同时使用
`kSecReturnData` 与 `kSecMatchLimitAll`，失败后又把 `errSecParam=-50` 当成空结果。
Apple 明确要求对此类数据先取引用，再按具体条目读取。

- 原生失败复现：唯一测试 service 中成功插入两条公开测试数据，旧读取器返回零条。
- 修复：分别枚举 file Keychain / Data Protection Keychain 的属性和 persistent ref，
  复用 `LegacySecItemLocation.applyPersistentReferenceMatch` 读取每条确定的记录。
  读取后核对 service、account、access group 和数据类型，保留跨后端和同步副本
  交给原有签名及撤销合并规则处理。
- 错误语义：只有枚举的 `errSecItemNotFound` 表示没有匹配项。非法查询或单项
  读取失败仍明确失败；不再把它们变成“空但可用”。原有明确的镜像使用规则保留。
- 原生复验：两条数据逐项匹配；临时数据按唯一 service/account/backend 清理成功。
  注入非法查询时抛错且 `isLocalStoreAvailable=false`。

生产修改在 `Sources/SkyBridgeCore/P2P/TrustSyncService.swift`；回归资产在
`Tests/SkyBridgeCoreTests/TrustRecordKeychainReadTests.swift`。
`P2PTrustSyncTests.swift` 中检查旧字符串 `items = a + b` 的断言已由原生完整性
回归替代，签名、撤销、身份冲突等行为断言保留。

一手资料：[Apple SecItemCopyMatching](https://developer.apple.com/documentation/security/secitemcopymatching(_:_:))；
[Apple DTS 的 SecItem 陷阱说明](https://developer.apple.com/forums/thread/724013)。

## 前一候选包的实机证据

Mac 候选包为 `mac-candidate-r1/SkyBridge Compass Pro.app`，版本 1.0.2，
构建号 `20260926164053`，可执行文件 SHA-256：
`c1405b7056e9d55c2e7be6e0fa86fd4402e6440a83df3ef6ca1a5bab83a87e74`。
其签名、共享 Keychain entitlement、profile 和资源检查通过，复用了已有登录。
没有覆盖 `/Applications` 中的产品，没有公证或发布。

本次链路按可达源码与日志核对如下：

1. CLI preflight 成功，发现 USB 连接的 iPhone。
2. PIB-1 候选签名验证成功，发送签名 confirm。
3. 源码在验证 final ACK 的交易字段和对端签名后，才调用
   `recordAuthenticatedRemoteAuthority`。本次日志到达该调用的身份冲突分支。
4. 本地记录提交拒绝：两条 active、非 tombstone 的直接身份关联发生冲突；
   一条没有同算法 pin，另一条有一个不同的同算法 pin。
5. CLI 返回 `nearby_trust_preflight_failed`，没有已认证会话，没有成功传输回执。

当前 iPhone 声明的稳定 ID 是 `31BB9D78-11F6-4843-91EE-0A0C4C003632`，
ML-DSA-65 公共指纹为
`bd42abfb163778e22cafa23c3f449f4ba1c144255817b6cba2d8904d9a4b9140`。
Bonjour 是发现信息，不能单独证明身份；上面的签名链路是独立证据。

只读检查发现，Mac 的 PairingTrust policy 同时保存了绑定上述完整 ID、算法、
指纹的 `PIB-1-peer` 与 `PIB-1-requester` 的 `alwaysAllow`。整个 policy 文件
SHA-256 为 `eefc506ba9fc23dfd37a8e8520b982dcb0c8d4b44f6609766f35d4522e9c7b54`。
文件时间不是某一条授权的创建时间；这只能证明当前保存着这两项决定。

五月的 protected mirror 中，iPhone 相关旧记录包括未绑定指纹的 Bonjour 别名，
以及指向不同 ML-DSA-65 指纹的记录。另一个设备记录也持有该旧指纹；没有原始
协议公钥，不能据此证明跨设备共用密钥或当前密钥发生轮换。当前候选包的原生
UI 也展示 iPhone 的 Bonjour 配对记录为“待验证 / 公钥指纹未绑定”。

两条 Keychain 添加记录的本机签名验证被拒绝。现有加载规则允许逐条跳过无法
由本机管理密钥验证的同步添加记录，同时保留撤销的拒绝语义。这些日志没有给出
记录签署者的来源证明，不能直接称为数据损坏。

## 恢复的边界与下一步

现有代码刻意区分“允许与当前公钥交互”和“允许替换旧协议身份”。
`authenticatedRemoteAuthorityResolution` 与 `protocolIdentityBindingsV2` 拒绝
有冲突的直接身份关联和同算法不同指纹，即便 pinSource 为 PIB-1 operator approval。
测试明确覆盖该拒绝。删除此检查会改变身份替换策略，不能作为普通重连修复。

现有“修复 P2P 信任”只清理 KEM 缓存；它不会解决这里的持久身份冲突。
“彻底忘记设备”也不是保留原有关系的恢复事务。本次均未调用。

可评审的恢复范围仅限上述 iPhone，目标为已有授权的完整当前指纹。实施前需要：

1. 从签名应用的真实存储路径取得待处理记录、版本、签名验证结果及摘要；保护
   可回查的原始记录。镜像与 UI 不能代替完整的存储快照。
2. 在新的、有期限的 PIB-1 交易中重新验证当前完整公钥、稳定 ID 和 final ACK，
   并核对精确绑定的既有授权。若指纹变化，不沿用此恢复范围。
3. 只处理该设备的精确冲突关联，不依赖名称或远端别名扩展对象。任何有效撤销、
   无法区分的跨设备关联或 iPad 影响都应中止，不以重试或清缓存绕过。
4. 将恢复做成可检查的显式事务：提交时重新检查存储版本与候选身份，记录旧关系
   如何退出当前认证集合，保留崩溃恢复及旧版本重新加载时的拒绝语义。完成前
   不把普通 `connect-nearby` 改成自动替换身份。
5. 取得针对持久信任关系变更的明确授权后才落盘。落盘后再以新会话验证连接、
   真实文件收据、字节数/哈希和终端进度，不能以本地记录写入作为传输验收。

在前一检查点，以上恢复事务尚未实现或执行。它不能反过来证明旧记录当初为什么被写入；历史
来源仍需保留为独立问题。用户 AGENTS 第 8 条要求变更安全策略前获得明确授权，
本次只读排障和 Keychain 查询修复没有授权覆盖已有信任身份。

## 验证与保留资产

证据目录：`Artifacts/cli-040-identity-diagnosis-20260926/`。

| 证据 | 结果 |
| --- | --- |
| `keychain-regression-red.log` | 旧实现两项测试产生三处失败：读不到两条原生记录，非法查询未抛错且错误标记可用 |
| `keychain-regression-green-r1.log` | 43 项相关测试通过，包括原生读取和失败边界 |
| `trust-security-regressions.log` | 39 项信任及 Keychain 作用域测试通过 |
| `candidate-identity.json` / `source-identity-r2.json` | 当前构建、签名和选定源码摘要 |
| `preflight-r2.json` / `nearby-r1.json` | 正确候选包恢复登录并发现 iPhone |
| `connect-iphone-r1.txt` / `trust-runtime-r1.log` | 当前实机连接仍被本地身份冲突拒绝 |
| `pairing-policy-readonly-summary.json` | 当前完整指纹已有持久允许决定；文件未修改 |
| `mirror-advertisement-comparison.json` | 历史镜像的关联形态，非当前完整存储快照 |

SwiftPM 日志保留既有 duplicate-rpath 与 `.build/debug` 链接警告；本次未通过
忽略检查来接受新增编译问题。Device Hub 与 iPhone Mirroring 保持关闭；iPhone
应用没有重装，iPad 没有重新接线或重置信任。


## USB 开发检查点：真实 Keychain 记录与恢复预览

用户随后明确允许针对当前 iPhone 的恢复，并要求 USB 可独立承载相同的
PQC 握手；USB 与局域网并存时 USB 优先。旧检查点的“未授权/未实现”不再
代表当前实现状态，旧记录的历史来源仍未确定。

签名 Mac 候选 `20260926174611` 的 `crossnet trust preview` 读取实际 Data
Protection Keychain，发现当前 iPhone 的正确 `bd42…9140` ML-DSA-65 pin 已在
版本 8 记录中存在，且本机签名验证成功。两个直接匹配该 iPhone 的旧镜像
记录也通过本机签名验证：未绑定协议指纹的 Bonjour 行，以及大写规范 ID
行中的旧 `1b59…8b17b` 指纹。因此恢复实现保留现有 Keychain 权威，不旋转密钥。

新增恢复路径将原始镜像字节归档，提交前再次比对完整快照摘要，随后通过
原有 authority resolver 绑定新验证到的同一公钥。结果明确区分全部完成、
别名已退出但绑定未确认、尚未应用、归档后镜像变化；均不宣称已有加密会话。

进一步只读核对发现 Bonjour 行还包含另一个稳定 ID `41D461A8-3E0E-4506-B498-674B43F1871C`，
镜像内另有该 ID 的两条记录。仅有相同设备名称不能证明它属于当前手机。
恢复计划因此会检查跨设备关联，在范围未核实前拒绝退休该共享别名。iPad
记录 `29094B83-3D32-4027-9B70-B1C924CB7CEF` 仍保留，未执行任何信任写入。

USB 原生枚举和 9527 端口连接成功，但旧 iPhone 程序收到流后立即关闭。
Mac 日志为 `FramedReaderError.peerClosed`；iOS 对应源码无条件拒绝 loopback
入站。修复将该入口接回原有容量、期限、签名和握手验证，并显式拒绝签名
请求者冒用本机 ID/公钥。1.0.2（14）候选已构建、签名且前后源码摘要相同；
本检查点仍等待原位安装许可，不能把源码分析冒充真机 red/green 完成。

新增证据集中在 `Artifacts/cli-040-usb-recovery-20260926/`，包括
`trust-preview-r1.json`、`usb-connect-foreground-r2.json`、
`usb-foreground-protocol-r2.log` 和 `ios-candidate-identity-r1.json`。

## 已执行的精确恢复及后续阻塞

用户批准原位更新后，iPhone 已安装 1.0.2（14），应用容器和协议身份保持不变。
物理 USB 不再在 PIB 前 EOF：已验证对端签名和 final ACK。这提供了旧版拒绝
loopback、修复版进入正常协议处理的真机对照。

用户随后确认共享别名的精确范围。恢复事务
`37D946EE-ECC5-4D01-AEB2-8C5FAF3DE323` 已执行成功，只退休两条已审核镜像行。
独立读回确认历史 `41D4…871C`、iPad 以及其他所有镜像行和未知字段逐项保留；
Keychain 中现有 `bd42…9140` 权威与 pairing policy 摘要不变。不可覆盖归档、
原生返回、独立读回分别记录在恢复目录中。前文“等待许可/未写入”描述的是
历史检查点，不应再次请求或执行这次恢复。

下一次连接通过身份绑定后，在 SKR-1 返回
`missing_requested_pqc_kem`。Mac 的 Q-Periapt-only 请求与 iPhone 当前 X-Wing
偏好没有对应 KEM。设备偏好读取和原生 USB 按钮返回支持这一因果链；这不是
新的信任冲突，也不能通过重新配对解决。当前未修改密码套件，等待明确选择。
CLI 0.4.0-dev.4 已实现封闭错误码 `peer_pqc_suite_unavailable`，保留严格 PQC
和拒绝跨传输重试的语义。完整连接、接收回执与进度仍未完成实机验收。
