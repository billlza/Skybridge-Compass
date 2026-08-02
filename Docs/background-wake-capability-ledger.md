# 后台与唤醒能力台账

记录「声明了但没有实现」的后台/唤醒能力,以及每一项要变成真能力所缺的前置条件。

目的:防止假能力再次以注释、entitlement 或未接线的类的形式留在仓库里。任何被移除的占位都必须在此留痕,任何新增的后台模式声明都必须先在此登记其接收端。

判定原则:**`UIBackgroundModes` 与 entitlement 是能力声明,不是能力**。声明必须晚于接收端实现,不能早于。

---

## 已移除的占位

### `Sources/SkyBridgeCore/Widget/WidgetPushService.swift`（2026-07 移除）

- **声称**:文件头注释写「通过 APNS 触发 Widget 刷新」,并附带一段 `content-available: 1` 的 payload 示例。
- **实际**:`registerForWidgetPush()` 只向 `UNUserNotificationCenter` 注册了一个**本地** `UNNotificationCategory`,然后把 `isRegistered = true` 自我声明为成功;与 APNs 没有任何关系。`handlePushNotification(userInfo:)` 有完整解析逻辑但**全仓库零调用方**。`requestBackgroundRefreshCapability()` 只打了一行日志。
- **移除依据**:`WidgetPushService` 与 `WidgetKindConstants` 在 `Sources/`、`Tests/`、`SkyBridge Compass iOS/`、`Docs/` 中均无任何引用。属于死代码 + 误导性文档。
- **要变成真能力所缺的前置**(全部缺失):
  1. iOS/macOS 侧 `registerForRemoteNotifications()` 与 `application(_:didReceiveRemoteNotification:fetchCompletionHandler:)` 接收端。
  2. iOS Info.plist `UIBackgroundModes` 包含 `remote-notification`。
  3. 服务端推送发送能力:`Server/skybridge-signaling/server.js` 目前**没有任何 APNs/FCM 端点,也没有 device token 存储**。
  4. Widget kind 常量需与真实 widget 对齐(macOS `Sources/SkyBridgeCompassWidgets/CompassWidget.swift` 的 `DeviceStatusWidget` / `SystemMonitorWidget` / `FileTransferWidget`;iOS `SkyBridge Compass iOS/Widgets/SkyBridgeWidget.swift` 的 `SkyBridgeWidget` 未被该常量覆盖)。
- 需要时按上述前置重建,不要恢复旧文件。

---

### `SkyBridge Compass iOS/.../Core/Background/BackgroundTaskManager.swift`（2026-07 移除）

- **声称**:「支持后台刷新、后台传输、推送唤醒」,定义了 `deviceDiscoveryRefresh` / `messageSync` / `fileTransfer` / `connectionKeepAlive` / `dataCleanup` 五种 `BGTask`。
- **实际**:`registerBackgroundTasks()` / `registerTask(_:)` 在 iOS App 内零调用方,且 Info.plist 与 `project.yml` 均未声明 `BGTaskSchedulerPermittedIdentifiers` —— 用未声明的 identifier 调用 `BGTaskScheduler.register` 会抛 `NSInternalInconsistencyException`,**一旦接线就会崩在启动路径上**。
- **移除依据**:两个任务类型在设计上不可实现(`BGAppRefreshTask` 是机会性调度,延迟分钟级到小时级,既不能保活连接也不能让本机在挂起状态保持可被发现);其余三个没有真实的可延迟工作定义。为了「用上 BGTaskScheduler」而接线其中任何一个都是另一种形态的假能力。
- **重建条件**:出现真实的可延迟后台工作(有明确输入、输出与失败语义)时,先声明 `BGTaskSchedulerPermittedIdentifiers`,再注册,再接线。顺序不得颠倒。
- 同时从 `SkyBridgeCompass-iOS.xcodeproj/project.pbxproj` 移除了 4 处该文件的引用(该工程文件由 xcodegen 从 `project.yml` 生成,但已提交,故做等价的最小手工移除)。

---

## 已实现的真实能力

### macOS CloudKit 静默推送唤醒（2026-07 完成,端到端）

| 组件 | 位置 |
|---|---|
| 订阅(发送侧) | `CloudKitService.subscribeToZoneChanges()` 的 `CKRecordZoneSubscription` + `shouldSendContentAvailable = true`(既有) |
| 订阅 id 所有权 | `CloudKitService.deviceChangesSubscriptionID`,与订阅创建绑定注册 |
| 路由 | `Sources/SkyBridgeCore/Services/RemoteNotificationRouter.swift` |
| 接收端 | `Sources/SkyBridgeCompassApp/Core/RemoteNotificationAppDelegate.swift`(`@NSApplicationDelegateAdaptor`) |

设计约束:

- **fail-closed 识别**:只有 payload 指名的 subscription id 属于本进程**实际维护**的订阅时才允许触发刷新。任何持有 device token 的发送方都能投递任意负载,所以外部订阅 id、缺失 id、非 CloudKit 负载全部返回 `noData` 且不执行任何工作。
- **outcome 必须真实**:`refreshDevicesReportingChange()` 比较刷新前后的 `devices` 再决定 `newData` / `noData`。恒报 `newData` 会被系统收紧后台唤醒配额,恒报 `noData` 会让唤醒信道失效。
- **订阅已存在也要声明所有权**:CloudKit 对重复订阅 id 返回 `serverRejectedRequest`,此时订阅在服务端已存在,若不声明所有权,本进程会把自己的推送当外部订阅丢弃。
- **注册失败不静默降级**:`didFailToRegisterForRemoteNotificationsWithError` 记 error 级 —— 没有 token 就意味着唤醒信道静默消失、退回轮询,这正是不能无声通过的退化。
- `NSApplicationDelegate` 只承载远程通知一件事,不承接其他生命周期工作。

### iOS 侧为何未做（外部阻塞,需决策）

两个独立阻塞,任一未解都不应在 iOS 声明 `remote-notification` 后台模式:

1. **模块边界**:`SkyBridge Compass iOS/project.yml` 的 `dependencies` 只包含 `WebRTC`、`SkyBridgeQPeriaptRuntime`、`OQSRAII`、`SkyBridgeRealtimeMedia`、`SkyBridgeCameraKit` —— **不依赖 `SkyBridgeCore`**,因此 `RemoteNotificationRouter` 与 `CloudKitService` 在 iOS 上都不可用。要么让 iOS 依赖 SkyBridgeCore,要么复制一套路由(后者违反「禁止形成第二套实现」)。
2. **CloudKit 订阅**:iOS 的 `CloudKitSyncManager` 把 `SBTrustedDevice` 记录放在 private **默认 zone**。默认 zone 不能建 `CKRecordZoneSubscription`,`CKDatabaseSubscription` 也只覆盖自定义 zone。可选路径:
   - 迁移 iOS 信任记录到自定义 zone(与 macOS 的 `SkyBridgeDeviceZone` 一致)—— 属于持久化布局迁移,需要迁移方案与回滚策略;
   - 改用 `CKQuerySubscription` —— 需要在 CloudKit Dashboard 为 `SBTrustedDevice` 增加 queryable index,属于仓库外操作,无法在此验证。

在这两项解决之前,iOS 不添加接收端(否则是不可达代码),也不声明后台模式。

---

## 未解决的风险登记

### iOS `aps-environment` entitlement 已开但无实现

`SkyBridge Compass iOS/SkyBridgeCompass-iOSDebug.entitlements` 与 `SkyBridgeCompass-iOSRelease.entitlements` 均声明了 `aps-environment`,iOS 代码侧零使用(原因见上「iOS 侧为何未做」)。属于超出实际能力的权限声明。解决那两个阻塞时一并处理:补齐实现,或移除声明。

---

## 唤醒能力现状矩阵

| 平台 | 作为被唤醒方 | 现状 |
|---|---|---|
| macOS | CloudKit 静默推送 | **已完成端到端**(2026-07),见上。 |
| macOS | Bonjour Sleep Proxy / Wake on Demand | **已适配可适配的部分**(2026-07)。`MacWakeOnDemandReadiness` 探测链路上的 `_sleep-proxy._udp`;`LocalPeerServiceCoordinator` 在 `didWakeNotification` 后延迟 3s 复核本地监听器。**仍不可验证**:「唤醒以供网络访问」系统设置无公开 API 可读,报告为 `undetermined`,需要用户自行确认。 |
| macOS | Wake-on-LAN(有线) | 未实现。服务端也未保存对端 MAC/子网。 |
| iOS | CoreBluetooth 状态保存与恢复 | 未实现。用户从 App 切换器上划杀掉后系统通常不再恢复,产品文案不得承诺"永远可唤醒"。 |
| iOS | 静默推送 | 未实现,阻塞于「模块边界」与「CloudKit 默认 zone 无法订阅」两项决策(见上)。 |
| Windows / Linux / Android | 任意 | **无端点实现**,当前只能被发现和分类。为其设计唤醒需先有原生端点。 |

## 相关的反退化机制

`Sources/SkyBridgeCore/Diagnostics/ConnectionRouteAttribution.swift` 负责让「实际走了哪条路径」可见,防止中继因为永远可用而吸收全部流量。

所有权划分(单一所有者,不得重复记录):
- LAN 栈路由由 `ConnectionPresenceService.markConnected` 按 **peerId** 记录。
- WebRTC 路由由 `CrossNetworkConnectionManager` 的会话级 ICE 探测按 **sessionID** 记录(5s 间隔,无会话时自动退出)。`ConnectionTransportRoute(_ routeSource:)` 对 `.webrtc` 返回 `nil` 即为此约束的强制点。

唤醒信道落地后应在此记录 wake channel 维度;在对应子系统存在之前不要添加恒为 `unknown` 的字段。

冒烟断言:设置 `SKYBRIDGE_SMOKE_EXPECT_DIRECT_ROUTE=1` 后,观测到中继会输出 `route-attribution-violation` 状态行,供局域网场景断言「绝不能走中继」。这是既有 `SKYBRIDGE_SMOKE_FORCE_RELAY_ICE` 的对偶,缺了它直连路径的回归无法被发现。
