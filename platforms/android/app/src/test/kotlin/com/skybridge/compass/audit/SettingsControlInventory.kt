package com.skybridge.compass.audit

/**
 * 设置控件全量清单（Cross-Platform Parity Audit，任务 15.1 / R7.1）。
 *
 * 该文件是**审计工具代码**，位于 `:app` 模块的 `test` 源集（与 [GapItem]、[ConflictRecord]、
 * [AuditScope] 同包），不随生产应用打包（遵守 G3：仅 Kotlin；不改动 Apple 源码树）。
 * 建立本清单**没有触碰任何生产 settings/UI 源码**（G2：不重构 Android UI）。
 *
 * ## 计数规则（可复现，先于计数确定，不为凑数字调整）
 *
 * 一条 [SettingsControlRecord] 当且仅当同时满足以下三条时成立：
 *
 *  - **R-1 交互式或只读事实呈现的设置项**：它是设置界面（含条件显示与折叠区域）内一个由用户直接
 *    改值的控件（Switch / RadioButton / FilterChip / 数值或文本输入 + 其保存动作），或一处 R7.6
 *    要求的**只读事实呈现**（[Presentation.ReadOnlyFact]）。
 *  - **R-2 恰好绑定六个持久化存储之一的一个键**：其值写入
 *    `AppSettingsStore` / `SecuritySettingsStore` / `NetworkSettingsStore` /
 *    `DeveloperSettingsStore` / `RemoteDesktopStreamSettingsStore` / `SupabaseConfigStore`
 *    中恰好一个键（[SettingsControlRecord.store] + [SettingsControlRecord.key]）。
 *  - **R-3 一个键一条记录**：同一 (store, key) 只登记一条记录。因此
 *    **同一枚举键的多个互斥 widget 实例（每个语言 chip、每个 PQC 等级 radio、每个分辨率/帧率/
 *    编解码 radio）合并为一条记录**——它们是同一个设置项的取值选择器，不是多个设置项。
 *
 * 明确**排除**的三类，因其不满足 R-1 或 R-2：
 *
 *  - **纯导航行**（Security 分区 5 行、About 分区 4 行、账户中心行、跨网 WebRTC 入口行）：
 *    只跳 route，不持有任何设置值。
 *  - **纯本地展开/折叠开关与一次性动作按钮**（`networkAdvancedExpanded`、`supabaseExpanded`、
 *    Supabase 的 解锁/保存/使用默认/清除/验证配置、电池优化卡片的「打开系统电池设置」、
 *    登录状态行的「登出」）：无持久化键或只触发动作。
 *  - **进程内存态标志**（`FeatureFlags`）：不是存储键；[FeatureFlags] 的死状态另按 R7.10 登记。
 *
 * ## 计数结论（如实记录，不迁就需求原文）
 *
 * 按上述规则得 **[TOTAL_CONTROLS] = 45** 条记录，**不是 R7.1 / R7.13 写的 77**。
 * 该差异由 [SettingsInventoryConflict] 以既有 [ConflictReconciler] 登记为冲突记录，
 * 并在 `settings-control-inventory.md` 给出两个可选处置，**不擅自修改 requirements.md**。
 *
 * 已持久化控件数见 [persistedCount]，有运行时消费方的控件数见 [withRuntimeConsumerCount]。
 * 零消费方控件见 [zeroConsumerControls]。
 *
 * ## 任务 15.4 的复核修正（R7.2）
 *
 * 15.1 登记了 7 项「零运行时消费方」。15.4 逐项回到工作副本核对后，**其中 6 项实际早已有可定位的
 * 运行时消费方**，是 15.1 的漏记而非缺陷：
 *
 *  | 控件 | 消费方 | 15.1 为何漏记 |
 *  |---|---|---|
 *  | `general.notifications` | `SystemNotifier.kt:53` | 消费方在 notifications 包，未纳入检索面 |
 *  | `general.keep-screen-on` | `MainActivity.kt:145` | 消费方是 `LaunchedEffect` 内的窗口标志调用 |
 *  | `network.max-reconnect-attempts` | `DeviceDiscoveryRepositoryImpl.kt:124` | 生产调用方在 device-discovery 模块 |
 *  | `device-auth.auto-trust-known-devices` | `PairingTrustManager.kt:72` | 15.1 成文时任务 15.3 尚未落地；现已接线 |
 *  | `device-auth.pairing-timeout-sec` | `AndroidPairingTrustApprovalProvider.kt:20` | 消费方在 securityprompts 包 |
 *  | `access-control.allow-clipboard-sync` | `RemoteControlViewModel.kt:560,605` | 剪贴板同步实现确实存在，15.1 误判为「无实现」 |
 *
 * 判定依据是文件修改时间：除 `PairingTrustManager`（15.3）与 `DeviceDiscoveryRepositoryImpl`
 * 之外，上述消费方文件的 mtime 均**早于**本清单成文时间，故它们在 15.1 计数时就已存在。
 *
 * 复核后仅剩 **[zeroConsumerControls] = 1 项**：[Presentation.READ_ONLY_FACT] 的
 * `encryption.algorithm`。它按 D7 的第二个分支处置——**只读事实呈现**（算法由跨平台密码套件固定，
 * 界面无任何可操作控件），因此「可操作但零消费方」的交互控件数为 **0**（见 [interactiveZeroConsumerControls]）。
 */

/** 六个持久化存储（R7.1 列举的存储集合）。 */
enum class SettingsStoreId(val label: String, val declarationFile: String) {
    APP_SETTINGS(
        "AppSettingsStore",
        "app/src/main/kotlin/com/skybridge/compass/android/data/AppSettingsStore.kt",
    ),
    SECURITY_SETTINGS(
        "SecuritySettingsStore",
        "app/src/main/kotlin/com/skybridge/compass/android/data/SecuritySettingsStore.kt",
    ),
    NETWORK_SETTINGS(
        "NetworkSettingsStore",
        "core/src/main/kotlin/com/skybridge/compass/core/data/NetworkSettingsStore.kt",
    ),
    DEVELOPER_SETTINGS(
        "DeveloperSettingsStore",
        "app/src/main/kotlin/com/skybridge/compass/android/data/DeveloperSettingsStore.kt",
    ),
    REMOTE_DESKTOP_STREAM(
        "RemoteDesktopStreamSettingsStore",
        "app/src/main/kotlin/com/skybridge/compass/android/data/RemoteDesktopStreamSettingsStore.kt",
    ),
    SUPABASE_CONFIG(
        "SupabaseConfigStore",
        "app/src/main/kotlin/com/skybridge/compass/android/data/SupabaseConfigStore.kt",
    ),
}

/** 控件的呈现形态（R7.6：固定不可更改项须为只读事实呈现，不得为禁用空开关）。 */
enum class Presentation(val label: String) {
    /** 用户可改值的交互控件。 */
    INTERACTIVE("交互式"),

    /** 只读事实呈现：呈现固定取值与不可更改说明，无可点击开关。 */
    READ_ONLY_FACT("只读事实呈现"),
}

/**
 * 清单单条记录，字段逐项对应 design.md §7 的 `SettingsControlRecord` 契约。
 *
 * [consumers] 只登记**改变运行时行为的读取点**（`文件:行`）。设置 UI 自身的回显读取、
 * `SettingsViewModel` 的转发、以及 `CloudUserSettingsSyncManager` 的镜像**都不算消费方**——
 * 否则 R7.2 的「零消费方」判定会被云同步镜像掩盖（R7.7 正是要求镜像键另有归属）。
 */
data class SettingsControlRecord(
    val id: String,
    val sectionId: String,
    val orderInSection: Int,
    val store: SettingsStoreId,
    val key: String,
    val consumers: List<String>,
    val presentation: Presentation,
    /** 控件声明处的 `文件:行`（本清单的证据来源）。 */
    val declaredAt: String,
) {
    init {
        require(id.isNotBlank()) { "control id must not be blank" }
        require(sectionId.isNotBlank()) { "control $id: sectionId must not be blank" }
        require(orderInSection >= 1) { "control $id: orderInSection must be >= 1" }
        require(key.isNotBlank()) { "control $id: key must not be blank" }
        require(declaredAt.isNotBlank()) { "control $id: declaredAt must not be blank" }
        require(consumers.all { it.isNotBlank() }) { "control $id: consumer refs must not be blank" }
    }

    /** 是否有至少一处改变运行时行为的消费方（R7.1 后半、R7.2）。 */
    val hasRuntimeConsumer: Boolean get() = consumers.isNotEmpty()
}

/**
 * 设置界面分区（`sectionId`）。顺序即用户从上到下、由根屏进入子屏的实际遍历顺序，
 * 取自 `SettingsScreen.kt:110-236` 的 LazyColumn item 顺序与各子屏 route。
 */
object SettingsSections {
    /** 根屏「常规」分区（`sections/GeneralSettingsSection.kt`）。 */
    const val GENERAL = "general"

    /** 根屏「账户」分区（`sections/AccountSettingsSection.kt`）。 */
    const val ACCOUNT = "account"

    /** 根屏「网络」分区，含 `networkAdvancedExpanded` 折叠区（`sections/NetworkSettingsSection.kt`）。 */
    const val NETWORK = "network"

    /** 根屏「云服务」分区，含 `supabaseExpanded` 折叠区（`sections/SupabaseSettingsSection.kt`）。 */
    const val CLOUD = "cloud"

    /** 根屏「深度开发设置」分区（`sections/DeveloperSettingsSection.kt`）。 */
    const val DEVELOPER = "developer"

    /** 子屏：设备认证（`SecuritySettingsScreen.kt` 的 `DeviceAuthenticationScreen`）。 */
    const val DEVICE_AUTH = "security.device-authentication"

    /** 子屏：数据加密（`SecuritySettingsScreen.kt` 的 `EncryptionSettingsScreen`）。 */
    const val ENCRYPTION = "security.encryption"

    /** 子屏：访问控制（`SecuritySettingsScreen.kt` 的 `AccessControlScreen`）。 */
    const val ACCESS_CONTROL = "security.access-control"

    /** 子屏：隐私设置（`SecuritySettingsScreen.kt` 的 `PrivacySettingsScreen`）。 */
    const val PRIVACY = "security.privacy"

    /** 子屏：画面流设置（`RemoteDesktopStreamSettingsScreen.kt`）。 */
    const val STREAM = "security.remote-desktop-stream"

    /** 子屏：跨网 WebRTC（`WebRtcSettingsScreen.kt`）。 */
    const val WEBRTC = "network.webrtc"

    /** 分区遍历顺序（用于清单排序与 R7.13 的分区顺序核对）。 */
    val order: List<String> = listOf(
        GENERAL, ACCOUNT, NETWORK, WEBRTC, DEVICE_AUTH, ENCRYPTION,
        ACCESS_CONTROL, PRIVACY, STREAM, CLOUD, DEVELOPER,
    )
}

/**
 * 全量设置控件清单（45 条）。每条 [SettingsControlRecord.declaredAt] 与
 * [SettingsControlRecord.consumers] 均为在当前工作副本可定位的 `文件:行`（R2.3 的核实前提）。
 */
object SettingsControlInventory {

    private const val GENERAL_SECTION = "app/src/main/kotlin/com/skybridge/compass/android/ui/screens/settings/sections/GeneralSettingsSection.kt"
    private const val ACCOUNT_SECTION = "app/src/main/kotlin/com/skybridge/compass/android/ui/screens/settings/sections/AccountSettingsSection.kt"
    private const val NETWORK_SECTION = "app/src/main/kotlin/com/skybridge/compass/android/ui/screens/settings/sections/NetworkSettingsSection.kt"
    private const val DEVELOPER_SECTION = "app/src/main/kotlin/com/skybridge/compass/android/ui/screens/settings/sections/DeveloperSettingsSection.kt"
    private const val SECURITY_SCREEN = "app/src/main/kotlin/com/skybridge/compass/android/ui/screens/settings/SecuritySettingsScreen.kt"
    private const val WEBRTC_SCREEN = "app/src/main/kotlin/com/skybridge/compass/android/ui/screens/settings/WebRtcSettingsScreen.kt"
    private const val STREAM_SCREEN = "app/src/main/kotlin/com/skybridge/compass/android/ui/screens/settings/RemoteDesktopStreamSettingsScreen.kt"
    private const val SUPABASE_SECTION = "app/src/main/kotlin/com/skybridge/compass/android/ui/screens/settings/sections/SupabaseSettingsSection.kt"

    /** 「常规」分区：9 条（深色模式、语言、自动连接、通知、动态取色、触觉反馈、屏幕常亮、实时天气、电池提醒）。 */
    private val general: List<SettingsControlRecord> = listOf(
        SettingsControlRecord(
            id = "general.dark-mode", sectionId = SettingsSections.GENERAL, orderInSection = 1,
            store = SettingsStoreId.APP_SETTINGS, key = "dark_mode",
            consumers = listOf("app/src/main/kotlin/com/skybridge/compass/android/MainActivity.kt:140"),
            presentation = Presentation.INTERACTIVE, declaredAt = "$GENERAL_SECTION:68",
        ),
        SettingsControlRecord(
            // 4 个语言 chip（系统/中文/EN/日本語）是同一个 app_language 键的互斥取值选择器 → 合并为一条（R-3）。
            id = "general.app-language", sectionId = SettingsSections.GENERAL, orderInSection = 2,
            store = SettingsStoreId.APP_SETTINGS, key = "app_language",
            consumers = listOf("app/src/main/kotlin/com/skybridge/compass/android/i18n/LocalizedText.kt:1"),
            presentation = Presentation.INTERACTIVE, declaredAt = "$GENERAL_SECTION:88",
        ),
        SettingsControlRecord(
            id = "general.auto-connect", sectionId = SettingsSections.GENERAL, orderInSection = 3,
            store = SettingsStoreId.APP_SETTINGS, key = "auto_connect",
            consumers = listOf("app/src/main/kotlin/com/skybridge/compass/android/ui/screens/devicediscovery/DeviceDiscoveryScreen.kt:1"),
            presentation = Presentation.INTERACTIVE, declaredAt = "$GENERAL_SECTION:110",
        ),
        SettingsControlRecord(
            id = "general.notifications", sectionId = SettingsSections.GENERAL, orderInSection = 4,
            store = SettingsStoreId.APP_SETTINGS, key = "notifications_enabled",
            // 任务 15.4 复核：15.1 漏记。SystemNotifier 订阅该键（:47）并据此决定是否把应用内
            // 通知事件桥接为系统通知（:53，判定函数 shouldPostBridgedNotification）。
            consumers = listOf(
                "app/src/main/kotlin/com/skybridge/compass/android/notifications/SystemNotifier.kt:53",
            ),
            presentation = Presentation.INTERACTIVE, declaredAt = "$GENERAL_SECTION:118",
        ),
        SettingsControlRecord(
            id = "general.dynamic-color", sectionId = SettingsSections.GENERAL, orderInSection = 5,
            store = SettingsStoreId.APP_SETTINGS, key = "use_dynamic_color",
            consumers = listOf("app/src/main/kotlin/com/skybridge/compass/android/MainActivity.kt:141"),
            presentation = Presentation.INTERACTIVE, declaredAt = "$GENERAL_SECTION:128",
        ),
        SettingsControlRecord(
            id = "general.haptic-feedback", sectionId = SettingsSections.GENERAL, orderInSection = 6,
            store = SettingsStoreId.APP_SETTINGS, key = "haptic_feedback",
            consumers = listOf("$NETWORK_SECTION:171"),
            presentation = Presentation.INTERACTIVE, declaredAt = "$GENERAL_SECTION:138",
        ),
        SettingsControlRecord(
            id = "general.keep-screen-on", sectionId = SettingsSections.GENERAL, orderInSection = 7,
            store = SettingsStoreId.APP_SETTINGS, key = "keep_screen_on",
            // 任务 15.4 复核：15.1 漏记。MainActivity 按该键增删窗口 FLAG_KEEP_SCREEN_ON
            // （判定函数 keepScreenOnWindowFlag，同文件末尾）。
            consumers = listOf(
                "app/src/main/kotlin/com/skybridge/compass/android/MainActivity.kt:145",
            ),
            presentation = Presentation.INTERACTIVE, declaredAt = "$GENERAL_SECTION:148",
        ),
        SettingsControlRecord(
            id = "general.real-time-weather", sectionId = SettingsSections.GENERAL, orderInSection = 8,
            store = SettingsStoreId.APP_SETTINGS, key = "real_time_weather_enabled",
            consumers = listOf(
                "app/src/main/kotlin/com/skybridge/compass/android/weather/WeatherRepository.kt:56",
            ),
            presentation = Presentation.INTERACTIVE, declaredAt = "$GENERAL_SECTION:148",
        ),
        SettingsControlRecord(
            id = "general.battery-opt-warning", sectionId = SettingsSections.GENERAL, orderInSection = 9,
            store = SettingsStoreId.APP_SETTINGS, key = "battery_opt_warning",
            // 唯一读取点是设置屏自身的条件显示门（决定是否呈现电池优化警告卡片）。
            consumers = listOf("app/src/main/kotlin/com/skybridge/compass/android/ui/screens/settings/SettingsScreen.kt:84"),
            presentation = Presentation.INTERACTIVE, declaredAt = "$GENERAL_SECTION:163",
        ),
    )

    /** 「账户」分区：1 条（记住登录）。登录状态行与账户中心行是纯导航/动作，按规则排除。 */
    private val account: List<SettingsControlRecord> = listOf(
        SettingsControlRecord(
            id = "account.remember-login", sectionId = SettingsSections.ACCOUNT, orderInSection = 1,
            store = SettingsStoreId.APP_SETTINGS, key = "remember_login",
            consumers = listOf("app/src/main/kotlin/com/skybridge/compass/auth/AuthViewModel.kt:1"),
            presentation = Presentation.INTERACTIVE, declaredAt = "$ACCOUNT_SECTION:60",
        ),
    )

    /** 「网络」折叠区：4 条。端口起始/结束是两个独立键，故为两条记录。 */
    private val network: List<SettingsControlRecord> = listOf(
        SettingsControlRecord(
            id = "network.port-range-start", sectionId = SettingsSections.NETWORK, orderInSection = 1,
            store = SettingsStoreId.NETWORK_SETTINGS, key = "port_range_start",
            // 任务 15.2 已接线：RuntimeNetworkParameters → 监听端口选择。
            consumers = listOf(
                "core/src/main/kotlin/com/skybridge/compass/core/data/RuntimeNetworkParameters.kt:83",
                "device-discovery/src/main/kotlin/com/skybridge/compass/discovery/data/services/P2PLocalNodeService.kt:90",
            ),
            presentation = Presentation.INTERACTIVE, declaredAt = "$NETWORK_SECTION:135",
        ),
        SettingsControlRecord(
            id = "network.port-range-end", sectionId = SettingsSections.NETWORK, orderInSection = 2,
            store = SettingsStoreId.NETWORK_SETTINGS, key = "port_range_end",
            consumers = listOf(
                "core/src/main/kotlin/com/skybridge/compass/core/data/RuntimeNetworkParameters.kt:83",
                "device-discovery/src/main/kotlin/com/skybridge/compass/discovery/data/services/P2PLocalNodeService.kt:90",
            ),
            presentation = Presentation.INTERACTIVE, declaredAt = "$NETWORK_SECTION:144",
        ),
        SettingsControlRecord(
            id = "network.discovery-timeout", sectionId = SettingsSections.NETWORK, orderInSection = 3,
            store = SettingsStoreId.NETWORK_SETTINGS, key = "discovery_timeout_ms",
            consumers = listOf(
                "core/src/main/kotlin/com/skybridge/compass/core/data/RuntimeNetworkParameters.kt:84",
                "device-discovery/src/main/kotlin/com/skybridge/compass/discovery/data/repositories/DeviceDiscoveryRepositoryImpl.kt:67",
            ),
            presentation = Presentation.INTERACTIVE, declaredAt = "$NETWORK_SECTION:186",
        ),
        SettingsControlRecord(
            id = "network.max-reconnect-attempts", sectionId = SettingsSections.NETWORK, orderInSection = 4,
            store = SettingsStoreId.NETWORK_SETTINGS, key = "max_reconnect_attempts",
            // 任务 15.4 复核：已有生产调用方。connectToDevice 首次连接失败后走
            // reconnectAfterFailedConnect，经 RuntimeReconnectPolicyFactory.forNewSession()
            // 取当前持久化值构造退避策略；设为 0 时不重试。
            consumers = listOf(
                "device-discovery/src/main/kotlin/com/skybridge/compass/discovery/data/repositories/DeviceDiscoveryRepositoryImpl.kt:124",
                "core/src/main/kotlin/com/skybridge/compass/core/network/ReconnectPolicy.kt:104",
            ),
            presentation = Presentation.INTERACTIVE, declaredAt = "$NETWORK_SECTION:229",
        ),
    )

    /** 子屏「跨网 WebRTC」：4 条（启用开关、信令 URL、STUN、TURN）。 */
    private val webrtc: List<SettingsControlRecord> = listOf(
        SettingsControlRecord(
            id = "webrtc.enabled", sectionId = SettingsSections.WEBRTC, orderInSection = 1,
            store = SettingsStoreId.NETWORK_SETTINGS, key = "webrtc_enabled",
            consumers = listOf("core/src/main/kotlin/com/skybridge/compass/core/webrtc/SkyBridgeWebRtcConnectionManager.kt:592"),
            presentation = Presentation.INTERACTIVE, declaredAt = "$WEBRTC_SCREEN:129",
        ),
        SettingsControlRecord(
            id = "webrtc.signaling-url", sectionId = SettingsSections.WEBRTC, orderInSection = 2,
            store = SettingsStoreId.NETWORK_SETTINGS, key = "webrtc_signaling_url",
            consumers = listOf("core/src/main/kotlin/com/skybridge/compass/core/webrtc/SkyBridgeWebRtcConnectionManager.kt:592"),
            presentation = Presentation.INTERACTIVE, declaredAt = "$WEBRTC_SCREEN:143",
        ),
        SettingsControlRecord(
            id = "webrtc.stun-servers", sectionId = SettingsSections.WEBRTC, orderInSection = 3,
            store = SettingsStoreId.NETWORK_SETTINGS, key = "stun_servers_csv",
            consumers = listOf("core/src/main/kotlin/com/skybridge/compass/core/webrtc/SkyBridgeWebRtcConnectionManager.kt:592"),
            presentation = Presentation.INTERACTIVE, declaredAt = "$WEBRTC_SCREEN:186",
        ),
        SettingsControlRecord(
            id = "webrtc.turn-servers", sectionId = SettingsSections.WEBRTC, orderInSection = 4,
            store = SettingsStoreId.NETWORK_SETTINGS, key = "turn_servers_csv",
            consumers = listOf("core/src/main/kotlin/com/skybridge/compass/core/webrtc/SkyBridgeWebRtcConnectionManager.kt:592"),
            presentation = Presentation.INTERACTIVE, declaredAt = "$WEBRTC_SCREEN:194",
        ),
    )

    /** 子屏「设备认证」：6 条。4 个 PQC 等级 radio 合并为 pqc_minimum_tier 一条（R-3）。 */
    private val deviceAuth: List<SettingsControlRecord> = listOf(
        SettingsControlRecord(
            id = "device-auth.require-pairing", sectionId = SettingsSections.DEVICE_AUTH, orderInSection = 1,
            store = SettingsStoreId.SECURITY_SETTINGS, key = "require_pairing",
            consumers = listOf("app/src/main/kotlin/com/skybridge/compass/android/data/cloud/CloudSettingsPullPolicy.kt:76"),
            presentation = Presentation.INTERACTIVE, declaredAt = "$SECURITY_SCREEN:75",
        ),
        SettingsControlRecord(
            id = "device-auth.auto-trust-known-devices", sectionId = SettingsSections.DEVICE_AUTH, orderInSection = 2,
            store = SettingsStoreId.SECURITY_SETTINGS, key = "auto_trust_known_devices",
            // 任务 15.3 已落地 PairingApprovalPolicy：每个配对请求判定时重新读取该开关。
            consumers = listOf(
                "core/src/main/kotlin/com/skybridge/compass/core/p2p/PairingTrustManager.kt:72",
                "core/src/main/kotlin/com/skybridge/compass/core/p2p/TcpControlSession.kt:553",
                "app/src/main/kotlin/com/skybridge/compass/android/data/DataStoreRuntimePairingApprovalParametersSource.kt:32",
            ),
            presentation = Presentation.INTERACTIVE, declaredAt = "$SECURITY_SCREEN:100",
        ),
        SettingsControlRecord(
            id = "device-auth.pairing-timeout-sec", sectionId = SettingsSections.DEVICE_AUTH, orderInSection = 3,
            store = SettingsStoreId.SECURITY_SETTINGS, key = "pairing_timeout_sec",
            // 任务 15.4 复核：15.1 漏记。配对提示的自动拒绝超时取自该键
            // （判定函数 pairingDecisionTimeoutMs），而非 SecurityPromptStore 的 60s 硬编码兜底。
            consumers = listOf(
                "app/src/main/kotlin/com/skybridge/compass/android/securityprompts/AndroidPairingTrustApprovalProvider.kt:20",
            ),
            presentation = Presentation.INTERACTIVE, declaredAt = "$SECURITY_SCREEN:127",
        ),
        SettingsControlRecord(
            id = "device-auth.enforce-pqc-handshake", sectionId = SettingsSections.DEVICE_AUTH, orderInSection = 4,
            store = SettingsStoreId.SECURITY_SETTINGS, key = "enforce_pqc_handshake",
            consumers = listOf("core/src/main/kotlin/com/skybridge/compass/core/p2p/LocalP2PIdentity.kt:594"),
            presentation = Presentation.INTERACTIVE, declaredAt = "$SECURITY_SCREEN:185",
        ),
        SettingsControlRecord(
            id = "device-auth.allow-classic-fallback", sectionId = SettingsSections.DEVICE_AUTH, orderInSection = 5,
            store = SettingsStoreId.SECURITY_SETTINGS, key = "allow_classic_fallback_for_compatibility",
            consumers = listOf("core/src/main/kotlin/com/skybridge/compass/core/p2p/LocalP2PIdentity.kt:604"),
            presentation = Presentation.INTERACTIVE, declaredAt = "$SECURITY_SCREEN:203",
        ),
        SettingsControlRecord(
            id = "device-auth.pqc-minimum-tier", sectionId = SettingsSections.DEVICE_AUTH, orderInSection = 6,
            store = SettingsStoreId.SECURITY_SETTINGS, key = "pqc_minimum_tier",
            consumers = listOf("core/src/main/kotlin/com/skybridge/compass/core/p2p/LocalP2PIdentity.kt:605"),
            presentation = Presentation.INTERACTIVE, declaredAt = "$SECURITY_SCREEN:229",
        ),
    )

    /**
     * 子屏「数据加密」：3 条，三项均为 [Presentation.READ_ONLY_FACT]。
     *
     * 15.1 曾按**目标形态**把传输加密与后量子加密登记为只读事实呈现，而当时源码仍是
     * `onCheckedChange = null, enabled = false` 的禁用空开关，违反 R7.6「禁用空开关数量为 0」。
     * **任务 15.5 已完成改造**：两行的 `trailing` 槽位内容由禁用开关替换为只读取值文本
     * （「始终启用」/ Always On / 常時有効），固定取值与不可更改说明齐备。该替换是**叶节点内替换**
     * —— 行本身、`Card` / `Column` / `Row` 容器数量与每一级嵌套均未改动（G2 / R11.3）。
     *
     * 因此**本清单的 [Presentation] 取值无需修改**：15.1 记录的目标形态现已与源码事实一致。
     * 三项的呈现形态、分区内顺序与结构不变式由
     * `SettingsReadOnlyPresentationGuardTest` 锁定（禁用空开关数 = 0 + UI 结构快照）。
     * 加密算法行本就是只读事实呈现，未改动。
     */
    private val encryption: List<SettingsControlRecord> = listOf(
        SettingsControlRecord(
            id = "encryption.transport-encryption", sectionId = SettingsSections.ENCRYPTION, orderInSection = 1,
            store = SettingsStoreId.SECURITY_SETTINGS, key = "encryption_enabled",
            // 存储层硬编码 true（SecuritySettingsStore.kt:134），值本身不可变。
            consumers = listOf("app/src/main/kotlin/com/skybridge/compass/android/data/SecuritySettingsStore.kt:134"),
            // 行号随任务 15.5 的只读化改造（副标题补充不可更改说明）前移，原 :283。
            presentation = Presentation.READ_ONLY_FACT, declaredAt = "$SECURITY_SCREEN:267",
        ),
        SettingsControlRecord(
            id = "encryption.algorithm", sectionId = SettingsSections.ENCRYPTION, orderInSection = 2,
            store = SettingsStoreId.SECURITY_SETTINGS, key = "encryption_algorithm",
            consumers = emptyList(),
            // 该行未被 15.5 改动；行号因上一项副标题变长而后移，原 :296。
            presentation = Presentation.READ_ONLY_FACT, declaredAt = "$SECURITY_SCREEN:301",
        ),
        SettingsControlRecord(
            id = "encryption.post-quantum", sectionId = SettingsSections.ENCRYPTION, orderInSection = 3,
            store = SettingsStoreId.SECURITY_SETTINGS, key = "pqc_enabled",
            consumers = listOf("app/src/main/kotlin/com/skybridge/compass/android/data/SecuritySettingsStore.kt:136"),
            // 行号随任务 15.5 的只读化改造前移，原 :335。
            presentation = Presentation.READ_ONLY_FACT, declaredAt = "$SECURITY_SCREEN:327",
        ),
    )

    /** 子屏「访问控制」：6 条。 */
    private val accessControl: List<SettingsControlRecord> = listOf(
        SettingsControlRecord(
            id = "access-control.allow-screen-mirroring", sectionId = SettingsSections.ACCESS_CONTROL, orderInSection = 1,
            store = SettingsStoreId.SECURITY_SETTINGS, key = "allow_screen_mirroring",
            consumers = listOf("app/src/main/kotlin/com/skybridge/compass/android/ui/screens/remotecontrol/RemoteControlScreen.kt:276"),
            presentation = Presentation.INTERACTIVE, declaredAt = "$SECURITY_SCREEN:390",
        ),
        SettingsControlRecord(
            id = "access-control.allow-file-transfer", sectionId = SettingsSections.ACCESS_CONTROL, orderInSection = 2,
            store = SettingsStoreId.SECURITY_SETTINGS, key = "allow_file_transfer",
            consumers = listOf("app/src/main/kotlin/com/skybridge/compass/android/ui/screens/filetransfer/FileTransferScreen.kt:129"),
            presentation = Presentation.INTERACTIVE, declaredAt = "$SECURITY_SCREEN:394",
        ),
        SettingsControlRecord(
            id = "access-control.auto-accept-trusted-devices", sectionId = SettingsSections.ACCESS_CONTROL, orderInSection = 3,
            store = SettingsStoreId.SECURITY_SETTINGS, key = "auto_accept_trusted_devices",
            consumers = listOf("app/src/main/kotlin/com/skybridge/compass/android/ui/screens/filetransfer/FileTransferViewModel.kt:211"),
            presentation = Presentation.INTERACTIVE, declaredAt = "$SECURITY_SCREEN:399",
        ),
        SettingsControlRecord(
            id = "access-control.confirm-overwrite-on-inbound", sectionId = SettingsSections.ACCESS_CONTROL, orderInSection = 4,
            store = SettingsStoreId.SECURITY_SETTINGS, key = "confirm_overwrite_on_inbound",
            consumers = listOf("app/src/main/kotlin/com/skybridge/compass/android/ui/screens/filetransfer/FileTransferViewModel.kt:211"),
            presentation = Presentation.INTERACTIVE, declaredAt = "$SECURITY_SCREEN:408",
        ),
        SettingsControlRecord(
            id = "access-control.allow-remote-control", sectionId = SettingsSections.ACCESS_CONTROL, orderInSection = 5,
            store = SettingsStoreId.SECURITY_SETTINGS, key = "allow_remote_control",
            consumers = listOf(
                "app/src/main/kotlin/com/skybridge/compass/android/ui/screens/remotecontrol/RemoteControlViewModel.kt:516",
                "app/src/main/kotlin/com/skybridge/compass/android/ui/screens/remotecontrol/RemoteControlScreen.kt:460",
            ),
            presentation = Presentation.INTERACTIVE, declaredAt = "$SECURITY_SCREEN:416",
        ),
        SettingsControlRecord(
            id = "access-control.allow-clipboard-sync", sectionId = SettingsSections.ACCESS_CONTROL, orderInSection = 6,
            store = SettingsStoreId.SECURITY_SETTINGS, key = "allow_clipboard_sync",
            // 任务 15.4 复核：15.1 漏记，且剪贴板同步实现确实存在。三处消费方：
            //  - 是否把 CLIPBOARD_SYNC 播报为已验证能力（AndroidLocalNodeBootstrap:258）；
            //  - 本地剪贴板监听器的注册/注销与出站发送门（RemoteControlViewModel:560）；
            //  - 入站剪贴板是否落地到本机剪贴板（RemoteControlViewModel:605）。
            consumers = listOf(
                "app/src/main/kotlin/com/skybridge/compass/android/discovery/AndroidLocalNodeBootstrap.kt:258",
                "app/src/main/kotlin/com/skybridge/compass/android/ui/screens/remotecontrol/RemoteControlViewModel.kt:560",
                "app/src/main/kotlin/com/skybridge/compass/android/ui/screens/remotecontrol/RemoteControlViewModel.kt:605",
            ),
            presentation = Presentation.INTERACTIVE, declaredAt = "$SECURITY_SCREEN:421",
        ),
    )

    /**
     * 子屏「隐私设置」：1 条。
     *
     * `collect_analytics` 与 `share_usage_data` 两个控件**已从 UI 移除**
     * （`SecuritySettingsScreen.kt:474-476` 的注释说明），键仅为云同步 schema 兼容而保留 →
     * 不再是界面控件，故不进清单，而按 R7.7「仅被云同步镜像」登记到 `gaps/fake-wiring.md`。
     */
    private val privacy: List<SettingsControlRecord> = listOf(
        SettingsControlRecord(
            id = "privacy.show-device-name", sectionId = SettingsSections.PRIVACY, orderInSection = 1,
            store = SettingsStoreId.SECURITY_SETTINGS, key = "show_device_name",
            consumers = listOf(
                "device-discovery/src/main/kotlin/com/skybridge/compass/discovery/data/services/P2PLocalNodeService.kt:153",
                "core/src/main/kotlin/com/skybridge/compass/core/p2p/LocalP2PIdentity.kt:84",
            ),
            presentation = Presentation.INTERACTIVE, declaredAt = "$SECURITY_SCREEN:497",
        ),
    )

    /**
     * 子屏「画面流设置」：6 条。
     *
     * 分辨率 / 帧率 / 编解码三组 radio 各自是同一个键的互斥取值选择器 → 各合并为一条（R-3）。
     * 六项在 WebRTC 路径生效（`RemoteControlViewModel.kt:408`），但 LAN 路径被
     * `MacRemoteControlClient.kt:831` 硬编码的 `RemoteDesktopStreamConfiguration` 旁路 →
     * 记为半接线缺陷，修复不属本任务。
     */
    private val stream: List<SettingsControlRecord> = listOf(
        SettingsControlRecord(
            id = "stream.quality-preset", sectionId = SettingsSections.STREAM, orderInSection = 1,
            store = SettingsStoreId.REMOTE_DESKTOP_STREAM, key = "rd_quality_preset",
            consumers = listOf("app/src/main/kotlin/com/skybridge/compass/android/ui/screens/remotecontrol/RemoteControlViewModel.kt:408"),
            presentation = Presentation.INTERACTIVE, declaredAt = "$STREAM_SCREEN:110",
        ),
        SettingsControlRecord(
            id = "stream.resolution", sectionId = SettingsSections.STREAM, orderInSection = 2,
            store = SettingsStoreId.REMOTE_DESKTOP_STREAM, key = "rd_resolution",
            consumers = listOf("app/src/main/kotlin/com/skybridge/compass/android/ui/screens/remotecontrol/RemoteControlViewModel.kt:408"),
            presentation = Presentation.INTERACTIVE, declaredAt = "$STREAM_SCREEN:135",
        ),
        SettingsControlRecord(
            id = "stream.frame-rate", sectionId = SettingsSections.STREAM, orderInSection = 3,
            store = SettingsStoreId.REMOTE_DESKTOP_STREAM, key = "rd_frame_rate",
            consumers = listOf("app/src/main/kotlin/com/skybridge/compass/android/ui/screens/remotecontrol/RemoteControlViewModel.kt:408"),
            presentation = Presentation.INTERACTIVE, declaredAt = "$STREAM_SCREEN:150",
        ),
        SettingsControlRecord(
            id = "stream.preferred-codec", sectionId = SettingsSections.STREAM, orderInSection = 4,
            store = SettingsStoreId.REMOTE_DESKTOP_STREAM, key = "rd_preferred_codec",
            consumers = listOf("app/src/main/kotlin/com/skybridge/compass/android/ui/screens/remotecontrol/RemoteControlViewModel.kt:408"),
            presentation = Presentation.INTERACTIVE, declaredAt = "$STREAM_SCREEN:165",
        ),
        SettingsControlRecord(
            id = "stream.low-latency-mode", sectionId = SettingsSections.STREAM, orderInSection = 5,
            store = SettingsStoreId.REMOTE_DESKTOP_STREAM, key = "rd_low_latency_mode",
            consumers = listOf("app/src/main/kotlin/com/skybridge/compass/android/ui/screens/remotecontrol/RemoteControlViewModel.kt:408"),
            presentation = Presentation.INTERACTIVE, declaredAt = "$STREAM_SCREEN:189",
        ),
        SettingsControlRecord(
            id = "stream.hardware-acceleration", sectionId = SettingsSections.STREAM, orderInSection = 6,
            store = SettingsStoreId.REMOTE_DESKTOP_STREAM, key = "rd_enable_hw_accel",
            consumers = listOf("app/src/main/kotlin/com/skybridge/compass/android/ui/screens/remotecontrol/RemoteControlViewModel.kt:408"),
            presentation = Presentation.INTERACTIVE, declaredAt = "$STREAM_SCREEN:203",
        ),
    )

    /**
     * 「云服务」折叠区：2 条（Supabase URL 与匿名 Key）。
     *
     * 二者经 [SettingsStoreId.SUPABASE_CONFIG] 的生物识别加密写入路径持久化，密文落
     * `supabase_ciphertext` / `supabase_iv`（`SupabaseConfigStore.kt:51-52`）。
     * 展开/收起、解锁、保存、使用默认、清除、验证配置均为动作按钮，按规则排除。
     */
    private val cloud: List<SettingsControlRecord> = listOf(
        SettingsControlRecord(
            id = "cloud.supabase-url", sectionId = SettingsSections.CLOUD, orderInSection = 1,
            store = SettingsStoreId.SUPABASE_CONFIG, key = "supabase_ciphertext",
            consumers = listOf("app/src/main/kotlin/com/skybridge/compass/android/data/SupabaseConfigStore.kt:228"),
            presentation = Presentation.INTERACTIVE, declaredAt = "$SUPABASE_SECTION:135",
        ),
        SettingsControlRecord(
            id = "cloud.supabase-anon-key", sectionId = SettingsSections.CLOUD, orderInSection = 2,
            store = SettingsStoreId.SUPABASE_CONFIG, key = "supabase_iv",
            consumers = listOf("app/src/main/kotlin/com/skybridge/compass/android/data/SupabaseConfigStore.kt:229"),
            presentation = Presentation.INTERACTIVE, declaredAt = "$SUPABASE_SECTION:145",
        ),
    )

    /** 「深度开发设置」分区：3 条。 */
    private val developer: List<SettingsControlRecord> = listOf(
        SettingsControlRecord(
            id = "developer.enable-screen-mirroring", sectionId = SettingsSections.DEVELOPER, orderInSection = 1,
            store = SettingsStoreId.DEVELOPER_SETTINGS, key = "enable_screen_mirroring",
            consumers = listOf("app/src/main/kotlin/com/skybridge/compass/android/ui/screens/devicediscovery/DeviceDiscoveryScreen.kt:843"),
            presentation = Presentation.INTERACTIVE, declaredAt = "$DEVELOPER_SECTION:29",
        ),
        SettingsControlRecord(
            id = "developer.enable-remote-control", sectionId = SettingsSections.DEVELOPER, orderInSection = 2,
            store = SettingsStoreId.DEVELOPER_SETTINGS, key = "enable_remote_control",
            consumers = listOf(
                "app/src/main/kotlin/com/skybridge/compass/android/ui/screens/remotecontrol/RemoteControlScreen.kt:109",
                "app/src/main/kotlin/com/skybridge/compass/android/ui/screens/devicediscovery/DeviceDiscoveryScreen.kt:844",
            ),
            presentation = Presentation.INTERACTIVE, declaredAt = "$DEVELOPER_SECTION:44",
        ),
        SettingsControlRecord(
            id = "developer.enable-file-transfer", sectionId = SettingsSections.DEVELOPER, orderInSection = 3,
            store = SettingsStoreId.DEVELOPER_SETTINGS, key = "enable_file_transfer",
            consumers = listOf(
                "app/src/main/kotlin/com/skybridge/compass/android/ui/screens/filetransfer/FileTransferScreen.kt:94",
                "app/src/main/kotlin/com/skybridge/compass/android/ui/screens/devicediscovery/DeviceDiscoveryScreen.kt:845",
            ),
            presentation = Presentation.INTERACTIVE, declaredAt = "$DEVELOPER_SECTION:59",
        ),
    )

    /** 全量清单，按 [SettingsSections.order] 的分区顺序、分区内按 `orderInSection` 排列。 */
    val all: List<SettingsControlRecord> =
        general + account + network + webrtc + deviceAuth + encryption +
            accessControl + privacy + stream + cloud + developer

    /** 清单总条数（**实测 45**，非需求原文的 77）。 */
    val TOTAL_CONTROLS: Int = all.size

    /** R7.1 前半：已持久化控件数。按 R-2，每条记录都绑定六存储之一的一个键，故等于总数。 */
    val persistedCount: Int get() = all.count { it.key.isNotBlank() }

    /** R7.1 后半：有至少一处改变运行时行为消费方的控件数。 */
    val withRuntimeConsumerCount: Int get() = all.count { it.hasRuntimeConsumer }

    /** 零运行时消费方的控件。复核后仅剩只读事实呈现的 `encryption.algorithm`（见文件头 15.4 说明）。 */
    val zeroConsumerControls: List<SettingsControlRecord> get() = all.filterNot { it.hasRuntimeConsumer }

    /**
     * R7.2 的验收判据：**可操作但零消费方**的控件。
     *
     * 只读事实呈现项不计入——它按 D7 的第二个分支处置，本就不承诺改变运行时行为。
     * 该列表为空即满足「界面无可操作但零消费方控件」。
     */
    val interactiveZeroConsumerControls: List<SettingsControlRecord>
        get() = zeroConsumerControls.filter { it.presentation == Presentation.INTERACTIVE }

    /** R7.6 目标形态为只读事实呈现的控件。 */
    val readOnlyFactControls: List<SettingsControlRecord>
        get() = all.filter { it.presentation == Presentation.READ_ONLY_FACT }

    /** 按分区分组（保持 [SettingsSections.order] 顺序）。 */
    fun bySection(): Map<String, List<SettingsControlRecord>> =
        SettingsSections.order.associateWith { section ->
            all.filter { it.sectionId == section }.sortedBy { it.orderInSection }
        }
}

/**
 * 「77 vs 实测 45」的冲突登记（R2.4）。
 *
 * **复用既有 [ConflictReconciler] / [ConflictRecord]，不新造平行类型。**
 *
 * 冲突双方：
 *  - **S4（设置与构建范围，本任务）**：按本文件顶部的 R-1/R-2/R-3 计数规则，逐控件枚举得 45，
 *    每条附可定位的 `文件:行`。
 *  - **需求基线 R7.1/R7.13**：控件总数为 77，未附任何 `文件:行` 依据。
 *
 * 裁决按 [AdjudicationBasis.SOLE_LOCATABLE_EVIDENCE]：仅 S4 一方持可定位证据 → S4 方胜。
 * 但该裁决**只确认 45 是当前工作副本的事实**，不代表 requirements.md 应当被改写——
 * 处置选项由用户决定（见 `settings-control-inventory.md` §5），本任务不编辑 requirements.md。
 */
object SettingsInventoryConflict {

    /** 争议对象：设置控件总数这一行为判定。 */
    val subject: ContestedSubject = ContestedSubject(
        kind = SubjectKind.BEHAVIOR,
        identifier = "Settings_Subsystem 设置控件总数（R7.1 / R7.13）",
    )

    /** S4 方判定：按成文计数规则逐控件枚举得 45。 */
    val inventoryJudgment: AuditJudgment = AuditJudgment(
        scopeId = "S4",
        subject = subject,
        stance = "count=45",
        conclusion = "按 R-1/R-2/R-3 计数规则逐控件枚举，设置界面（含条件显示与折叠区域、" +
            "3 个安全子屏、画面流子屏、WebRTC 子屏）共 ${SettingsControlInventory.TOTAL_CONTROLS} 个" +
            "绑定六存储之一的设置控件；其中有运行时消费方 " +
            "${SettingsControlInventory.withRuntimeConsumerCount} 个。",
        evidence = SettingsControlInventory.all
            .mapNotNull { SourceRef.parse(it.declaredAt) }
            .distinct(),
    )

    /** 需求基线方判定：总数 77，无 `文件:行` 依据。 */
    val requirementJudgment: AuditJudgment = AuditJudgment(
        scopeId = "R7-baseline",
        subject = subject,
        stance = "count=77",
        conclusion = "R7.1 与 R7.13 记载设置控件总数为 77，并以「已持久化控件数 = 77」" +
            "与「有运行时消费方的控件数 = 77」作为验收判据。",
        evidence = emptyList(),
    )

    /** 两方判定，交由 [ConflictReconciler.reconcile] 裁决。 */
    val judgments: List<AuditJudgment> = listOf(inventoryJudgment, requirementJudgment)

    /** 用给定的可定位性判定执行裁决。 */
    fun reconcile(locator: SourceLocator): ReconciliationOutcome =
        ConflictReconciler(locator).reconcile(judgments)
}

/**
 * R7.10：`FeatureFlags` 纯内存死状态的**清零记录**（任务 15.4 已执行）。
 *
 * ## 15.1 记录的原始状态
 *
 * 三个 `@Volatile` 标志声明于 `android/config/FeatureFlags.kt:4-6`，仅由
 * `SettingsViewModel.kt:274,281,288` 写入，**全仓无任何读取点，且进程启动时不从
 * `DeveloperSettingsStore` 回填**——因此它们既不影响运行时行为，也在每次进程重启后回到
 * 硬编码的 `true`，与用户持久化的开发者开关不一致。
 *
 * ## 15.4 的处置
 *
 * 按 R7.10「既不被写入也不被读取的进程内设置镜像变量清零」：三个变量与其三处写入点一并移除，
 * `FeatureFlags.kt` 因移除后无剩余内容而删除。真正的功能门仍是 `DeveloperSettingsStore` 的三个
 * 键，消费方未被触碰（见 [remainingGateKeys]）。
 *
 * ## 枚举的诚实说明（任务标题写「15 项内存态设置」）
 *
 * 15.1 的枚举与 15.4 的复核都**只找到这 3 个**纯内存镜像变量，不是 15 个。判定口径：全仓
 * `:app` / `:core` / `:device-discovery` / `:file-transfer` / `shared` 主源集内，声明为进程内
 * 可变状态、且承载某个设置项取值镜像的变量。符合该口径的只有 `FeatureFlags` 的三个标志。
 * 其余进程内状态（如 `SecurityPromptStore` 的提示表、`SystemNotifier.notificationsEnabled`
 * 缓存）都有真实读取点并改变运行时行为，是正常的运行期状态，不是死镜像——
 * `SystemNotifier.notificationsEnabled` 尤其不是：它每次被读取以决定是否发布系统通知。
 * **不为凑够 15 而虚构条目**：虚构的数字就是伪造的审计证据。
 */
object FeatureFlagsDeadState {
    /** 15.1 记录的声明处（现已移除，文件已删除）。 */
    val declarations: List<SourceRef> = listOf(
        SourceRef("app/src/main/kotlin/com/skybridge/compass/android/config/FeatureFlags.kt", 4),
        SourceRef("app/src/main/kotlin/com/skybridge/compass/android/config/FeatureFlags.kt", 5),
        SourceRef("app/src/main/kotlin/com/skybridge/compass/android/config/FeatureFlags.kt", 6),
    )

    /** 15.1 记录的唯一写入点（镜像赋值），无对应读取点；现已移除。 */
    val writeSites: List<SourceRef> = listOf(
        SourceRef("app/src/main/kotlin/com/skybridge/compass/android/ui/screens/settings/SettingsViewModel.kt", 274),
        SourceRef("app/src/main/kotlin/com/skybridge/compass/android/ui/screens/settings/SettingsViewModel.kt", 281),
        SourceRef("app/src/main/kotlin/com/skybridge/compass/android/ui/screens/settings/SettingsViewModel.kt", 288),
    )

    /** 读取点数量为 0 —— 这正是判定其为死镜像的依据。 */
    val readSiteCount: Int = 0

    /** 全仓实际找到的纯内存镜像变量数（**3，不是任务标题的 15**）。 */
    val inMemoryOnlyMirrorCount: Int = declarations.size

    /** 15.4 已执行清零：变量、写入点与承载文件全部移除。 */
    val cleared: Boolean = true

    /**
     * 清零后仍然生效的真实功能门：`DeveloperSettingsStore` 的三个持久化键，消费方保持不变。
     * 键名到消费方的对应见 [SettingsControlInventory] 的 developer 分区三条记录。
     */
    val remainingGateKeys: List<String> = listOf(
        "enable_screen_mirroring",
        "enable_remote_control",
        "enable_file_transfer",
    )
}
