# Android 设备发现技术规划（2026）

## 2026-07-05 当前结论

本文件早期版本把 Wi-Fi Aware、Nearby、BLE、UDP 与 Bonjour/mDNS 都写成近似同级的发现主线。这个判断对 Android-to-Android 能力探索仍有价值，但不应作为 Android 与 macOS/iOS 互通的主路径。

当前 SkyBridge Android 的 Apple 互通最佳实践是：

- 跨 macOS/iOS 基线：Android NSD/Bonjour 发现 + WebRTC DataChannel 连接 + SkyBridge app-layer P2P/Q-Periapt 握手。
- Android-to-Android 增强：Wi-Fi Aware/NAN 与 Nearby Connections 可以作为后续增强，但它们不直接替代 Apple 互通路径。
- Android 16+/API 36+ 局域网发现必须纳入 Local Network Permission 运行时权限模型，不能只假设 `INTERNET` 权限足够。
- Bonjour TXT 中的 `deviceId` / `pubKeyFP` 只能视为 advertised identity hints；信任必须来自已钉扎配置或 app-layer 加密握手，不得把 TXT 元数据命名为 verified identity。
- 不引入 Android Rust core。Android 保持 Kotlin-first，并复用现有 `device-discovery`、`core`、`remote-control`、`shared` 模块边界。

2026 官方资料核对：

- Android Gradle Plugin 9.3 支持 API level 37，当前 AGP 9.3.0-rc01 + Gradle 9.6.1 lane 仍是本 repo 已验证组合。
- Android Local Network Protection 将本地网络访问纳入新的运行时权限模型，直接影响 mDNS/NSD、局域网 remote control 与 smoke 验收。
- KSP 继续是 Kotlin-first annotation processing 路径；本项目继续避免 kapt/Java-first 新路径扩散。

## 验收边界

- 模拟器验收：可证明 Android API 36+ runtime、APK/instrumentation、loopback/compat signaling、WebRTC/Q-Periapt app-layer 行为。
- 真机验收：只有连接到真实 Android 16+ 设备后才能证明 OEM 网络栈、Wi-Fi 多播、权限弹窗、功耗与真实 LAN 稳定性。
- iOS/macOS 验收：必须分别报告 Android->iOS、iOS->Android、Android->macOS、macOS->Android 的 peer direction；不能把某一个方向的 success 泛化成“Apple interop 全部完成”。

## 背景与目标

- 目标：为 Android 端实现先进、可持续、跨平台互通的设备发现能力，同时兼顾近场、局域网与点对点连接的多种场景。
- 现状：项目已具备 Bonjour/mDNS、蓝牙、部分 UDP 能力。考虑到 Apple 在近期推进更现代的网络 API，且 Android 阵营在近邻网络上持续演进，我们计划升级技术栈，避免对可能过时的接口的单一依赖。

## 厂商发布与趋势

- Apple（WWDC）
  - Network.framework 的 `NWBrowser`/`NWListener` 提供了更现代的 Bonjour（DNS‑SD/mDNS）浏览与发布 API，替代传统的 `NSNetService`/`NSNetServiceBrowser`（参考：Advances in Networking, Part 2，WWDC 2019，https://developer.apple.com/videos/play/wwdc2019/713/）。
  - Apple 设备的近距直连普遍依赖 AWDL 与 MultipeerConnectivity；但 AWDL 非公开跨平台协议，无法直接与 Android Wi‑Fi Direct/NAN 互通（参考：Apple Wireless Direct Link 概述，https://theapplewiki.com/wiki/Apple_Wireless_Direct_Link；OWL 项目，https://owlink.org/wiki/）。
  - 结论：在 Apple 生态内部，Network.framework + MC 更先进；跨平台互通需通过通用协议（如 mDNS、BLE、UDP、多播）与上层连接（如 WebRTC/TCP）。

- Google（Android）
  - Wi‑Fi Aware（NAN）：Android 8.0+ 原生近邻网络（API level 26），支持设备发现与直连，无需 AP/互联网（参考：AOSP Wi‑Fi Aware，https://source.android.com/docs/core/connect/wifi-aware；开发者文档，https://developer.android.com/develop/connectivity/wifi/wifi-aware）。
  - Nearby Connections 2.0：Play Services 提供离线、高带宽、低延迟的近邻直连 API，内部组合 Wi‑Fi/BT/BTLE（参考：Google for Developers，https://developers.google.com/nearby/connections/overview；Android Dev Blog，https://android-developers.googleblog.com/2017/07/announcing-nearby-connections-20-fully.html）。
  - 结论：Android 阵营在近邻发现/直连方面有两套成熟方案（NAN 与 Nearby），应优先采用，并与跨平台的 mDNS/UDP/BLE 组合互补。

## 跨平台发现技术候选（含现有技术）

- Bonjour/mDNS（DNS‑SD）
  - 优点：跨平台通用、生态成熟；与 Apple/iOS/macOS 完全互通。
  - 风险：Android NSD 在部分机型/ROM 解析稳定性一般；Apple 正推 Network.framework 现代 API，传统 API 可能逐步弱化。
  - 用途：作为通用发现层与 TXT 元数据分发；非单一依赖。

- UDP 广播/组播
  - 优点：实现简单、覆盖广，适合快速广播公告（announce）。
  - 风险：Android 接收端需 `CHANGE_WIFI_MULTICAST_STATE` + `WifiManager.MulticastLock`；设备兼容性差异较大；需控时使用以降低耗电（参考：StackOverflow 讨论，MulticastLock 权限与耗电）。
  - 用途：作为轻量补充与兜底通道，承载短 JSON announce。

- BLE 广播/扫描
  - 优点：近距离、低功耗；无需加入同一 Wi‑Fi；可承载精简 ID/能力掩码。
  - 风险：扫描过滤在不同机型上兼容性差异；UWB/超声等更高级手段不统一。
  - 用途：近场发现与唤醒，连接协商由上层完成。

- Android Wi‑Fi Aware（NAN）
  - 优点：原生近邻、低延迟；支持发布/订阅与数据通道；不依赖 AP。
  - 风险：硬件/ROM 支持率需评估；与 Apple AWDL 不互通。
  - 用途：Android‑to‑Android 的高阶近邻能力；作为高级模式。

- Nearby Connections 2.0（Android）
  - 优点：统一抽象，自动选择最佳通道（Wi‑Fi/BT/BTLE），加密且高带宽、低时延。
  - 风险：依赖 Play Services；与 iOS/macOS 不直接互通。
  - 用途：Android 端强韧近邻直连；跨平台通过 BLE/mDNS/UDP 发现，再用 WebRTC/TCP 完成互联。

## 技术选型与架构

- 发现层：多协议并行，统一聚合
  - 首选：`Wi‑Fi Aware（NAN）`（Android‑to‑Android）与 `Nearby Connections`（Android‑to‑Android）。
  - 跨平台基线：`BLE 广播/扫描` + `UDP 广播/组播` + `Bonjour/mDNS（DNS‑SD）`。
  - 策略：按权限/硬件能力动态启用；Flow 合并去重（按 `deviceId`/`endpoint`）。

- 连接层：统一握手与加密通道
  - 首选：`WebRTC（ICE/STUN/TURN，mDNS Host Candidates）`，在同网/跨网均可用。
  - 备选：`TCP（直连或 Proxy）`；Android‑to‑Android 可用 `Nearby` 的字节/文件通道。

- 元数据（跨协议统一）
  - 字段：`id`、`name`、`type`、`capabilities[]`、`endpoint`（ip/port 或 ble/nan）、`preferredConnect`（webrtc|tcp|ble）、`version`、`extra{}`。
  - Bonjour TXT：`name`、`type`、`cap`、`proto`、`id`、`os_version`、`battery`。
  - UDP JSON 示例：`{"op":"announce","id":"mac-xyz","name":"SkyBridge Mac","type":"macos","cap":["screen_sharing","file_transfer"],"endpoint":{"ip":"192.168.1.5","port":4975},"proto":"webrtc","ver":1}`。
  - BLE Service Data：`ver|cap_mask|type|id_hash|flags`（压缩编码，≤ 24 字节）。

## Android 端实现清单（面向现有代码结构）

- 协议枚举统一
  - 在 `discovery.domain.entities.DiscoveryProtocol` 统一：`BONJOUR`、`UDP_BROADCAST`、`BLUETOOTH_LE`、`WIFI_AWARE`、`NEARBY_CONNECTIONS`。
  - 清理重复定义，避免多模块枚举不一致。

- 新增数据源
  - `UdpBroadcastDiscoveryDataSource`：监听组播/广播端口，解析 announce JSON，输出 `Flow<List<DiscoveredDevice>>`。
  - `BleDiscoveryDataSource`：按 Service UUID 扫描，解析 Service/Manufacturer Data，输出 `Flow<List<DiscoveredDevice>>`。
  - `WifiAwareDiscoveryDataSource`：基于 `WifiAwareManager` 发布/订阅服务名，收敛发现事件为统一实体。
  - 保留/增强 `BonjourDiscoveryDataSource`：兼容 TXT 解析与错误重试。

- 聚合与仓库
  - 扩展 `UnifiedDeviceDiscoveryService`：并发收集三/五路 Flow，按 `deviceId`/`endpoint` 去重；打分排序（信号强度/最近见到）。
  - `DeviceDiscoveryRepository`：提供统一设备列表、刷新/停止操作；`StartDeviceDiscoveryUseCase` 支持协议集合与默认策略。

- 依赖注入（Hilt）
  - 在 `DeviceDiscoveryModule` 中 `@Provides` 新数据源与 `UnifiedDeviceDiscoveryService`；引入 `MulticastLockManager` 管理锁生命周期。

- 权限与 Manifest
  - BLE：`BLUETOOTH_SCAN`（Android 12+）、`ACCESS_FINE_LOCATION`（旧版扫描）、`BLUETOOTH`。
  - UDP：`INTERNET`、`ACCESS_NETWORK_STATE`、`CHANGE_WIFI_MULTICAST_STATE`（临时持锁）。
  - NAN：`ACCESS_WIFI_STATE`、`CHANGE_WIFI_STATE`、`ACCESS_FINE_LOCATION`（具体以官方文档为准）。
  - Nearby：依赖 Play Services，按官方权限清单与运行时请求（参考：https://developers.google.com/nearby/connections/android/get-started）。

- UI 与交互（Jetpack Compose）
  - 协议开关：`Bonjour / UDP / BLE / Wi‑Fi Aware / Nearby` 过滤器；动态可用性显示。
  - 设备卡片：名称/类型/能力标签/来源徽标/信号强度/最近见到；`Connect` 主操作。
  - 状态与空态：“正在通过 X/Y/Z 发现设备”、权限缺失提示与引导；渐进动画。

## 风险与缓解

- 兼容性：BLE 过滤在部分机型不稳定 → 空过滤 + 业务侧二次过滤；限制扫描频率与时长。
- 能耗：UDP 组播需 `MulticastLock` → 仅前台/限定时间启用，完毕立即释放。
- 覆盖率：NAN/Nearby 非所有设备可用 → 动态探测能力，自动回退到 BLE/UDP/mDNS。
- 安全与隐私：统一使用短 ID + 上层握手（WebRTC/TLS）；本地信息最小化。

## 里程碑与验收

- M1（两周）：协议枚举统一；UDP/BLE 数据源骨架；聚合服务；权限与 DI。
- M2（两周）：NAN/Nearby 集成；稳定性与去重策略；联调脚本（macOS Bonjour 发布/UDP 脚本）。
- M3（两周）：UI 改版；能耗评估；异常与容错；Beta 验收与文档完善。

## 参考资料

- Apple Network.framework（NWBrowser/NWListener）：https://developer.apple.com/videos/play/wwdc2019/713/
- Apple AWDL 概述与研究：https://theapplewiki.com/wiki/Apple_Wireless_Direct_Link ，https://owlink.org/wiki/
- Android Wi‑Fi Aware（NAN）：https://developer.android.com/develop/connectivity/wifi/wifi-aware ，https://source.android.com/docs/core/connect/wifi-aware
- Nearby Connections 2.0：https://developers.google.com/nearby/connections/overview ，https://android-developers.googleblog.com/2017/07/announcing-nearby-connections-20-fully.html
- Android NSD（Bonjour/DNS‑SD）：https://developer.android.com/develop/connectivity/wifi/use-nsd
- MulticastLock 权限与兼容讨论：StackOverflow 相关讨论（示例：https://stackoverflow.com/questions/30648334/

## 更新记录（2025‑10）

- 弃用 API 处理
  - Wi‑Fi Aware：`DiscoverySession.createNetworkSpecifierOpen(peer)` 已弃用，现以 `WifiAwareNetworkSpecifier.Builder(session, peer).build()` 替代（API 29+）。在低版本上保留旧实现并抑制弃用警告，保持双向兼容。
  - Bonjour/NSD：在 API 34+ 使用新签名 `NsdManager.resolveService(serviceInfo, executor, listener)` 与 `NsdServiceInfo.hostAddresses`，在旧版本上回退到 `resolveService(serviceInfo, listener)` 与 `host`。统一封装版本判断，避免运行时崩溃。

- 告警策略（NSD Deprecated）
  - 仅在 Android 34+ 分支的 `resolveService(serviceInfo, executor, listener)` 调用处加局部 `@Suppress("DEPRECATION")`，避免跨分支误抑制。
  - 旧签名 `resolveService(serviceInfo, listener)` 仍以局部 `@Suppress("DEPRECATION")` 处理，确保编译期干净且不影响运行时行为。

- Telemetry 接入
  - 数据源扩展：为 `WiFiDirectDiscoveryDataSource` 与 `NearbyConnectionsDiscoveryDataSource` 注入 `DiscoveryTelemetry`，覆盖事件：发现启动、设备发现、权限缺失、错误/失败。
  - DI 更新：`DeviceDiscoveryModule` 中的两项提供者增加 `DiscoveryTelemetry` 依赖并向构造函数传递，实现与既有 BLE/UDP 数据源一致的统一遥测。

- 构建与验证
  - 已完成 `:device-discovery` 模块编译验证，修复后编译通过；Bonjour 的新 `resolveService` 在当前 SDK 注释中显示为“Deprecated in Java”，但不影响编译与运行，版本分支已确保兼容。

## 状态盘点（2025‑10）

- 已完成
  - 协议枚举统一（`DiscoveryProtocol`）。
  - 新增/保留数据源（UDP、BLE、Wi‑Fi Aware、Bonjour、Nearby）。
  - 仓库与聚合服务（`UnifiedDeviceDiscoveryService`、`DeviceDiscoveryRepository`）。
  - 依赖注入（Hilt 模块齐备，含 `MulticastLockManager` 与 Telemetry 注入）。
  - 弃用 API 修复（Wi‑Fi Aware、NSD）。
  - Telemetry 接入（Wi‑Fi Direct、Nearby）。

- 待办
  - UI 改版与发现状态可视化（Compose 过滤/徽标/空态）。
  - 能耗评估与扫描节流策略（UDP 组播与 BLE）。
  - 异常与容错完善（重试、退避、日志分级）。
  - Beta 验收与跨平台联调脚本（macOS Bonjour 发布/UDP 脚本）。
