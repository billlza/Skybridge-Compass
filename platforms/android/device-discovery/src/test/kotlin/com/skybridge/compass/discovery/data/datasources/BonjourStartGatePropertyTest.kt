package com.skybridge.compass.discovery.data.datasources

import android.content.Context
import android.content.pm.PackageManager
import io.kotest.core.spec.style.FunSpec
import io.kotest.matchers.shouldBe
import io.kotest.property.Arb
import io.kotest.property.arbitrary.boolean
import io.kotest.property.arbitrary.element
import io.kotest.property.arbitrary.int
import io.kotest.property.arbitrary.list
import io.kotest.property.arbitrary.map
import io.kotest.property.arbitrary.set
import io.kotest.property.checkAll
import io.mockk.every
import io.mockk.mockk

/**
 * **Feature: cross-platform-parity-audit, Property 14: 权限全部授予前不启动广播与浏览**
 *
 * **Validates: Requirements 3.8**
 *
 * 任务 7.17 的属性测试。与 [BonjourLocalNetworkPolicyTest] 的示例测试**互补**：示例测试固定
 * 几个传输组合与 API 级别，本文件在随机生成的"所需权限授予向量 × 活跃传输集合 × API 级别"
 * 空间上验证 R3.8 的核心命题：
 *
 * **仅在全部所需权限的授权结果均为"已授予"之后，广播与浏览才被启动**；只要有任一所需权限
 * 未授予，两条路径都不得进入注册步骤。
 *
 * 本测试驱动生产的**真实门禁函数**，并复刻 `BonjourAdvertiserDataSource.startAdvertising` 与
 * `BonjourDiscoveryDataSource.startDiscovery` 中门禁的**实际调用顺序**：
 * - 广播路径：先 [BonjourLocalNetworkPolicy.requireAdvertisingNetwork]（需活跃本地网络传输），
 *   再 [BonjourLocalNetworkPermissionPolicy.requireLocalNetworkPermission]（需权限已授予）；
 * - 浏览路径：仅 [BonjourLocalNetworkPermissionPolicy.requireLocalNetworkPermission]。
 *
 * `reachedRegistration` 标志只在门禁全部通过后才被置位，因此"未授予即未启动"是被**观测**出来的，
 * 而不是假设出来的。
 *
 * **属性定义域**：R3.8 还含"1 秒内发起权限请求"的时限要求与 UI 呈现要求；时限属运行时行为、
 * 权限请求发起点在 `:app` 的 `PermissionManager` / `DeviceDiscoveryScreen`（`arePermissionsGranted`
 * 对所需权限集合取合取），均不在本单元测试可判定的范围内，故本属性只覆盖"授予完成前不启动"
 * 这一可判定的核心断言。授予向量刻意包含多个权限位（含与本地网络无关的位），以验证门禁结果
 * **只**取决于真正被要求的那个权限，不被无关权限的授予/拒绝干扰。
 *
 * 为避免空真通过，每个测试统计其真正走到的分支并在 `checkAll` 后断言计数均大于 0。
 */
class BonjourStartGatePropertyTest : FunSpec({

    /** 发现界面可能一并请求的权限集合（见 :app 的 PermissionManager.Feature.DEVICE_DISCOVERY）。 */
    val discoveryPermissions = listOf(
        android.Manifest.permission.ACCESS_LOCAL_NETWORK,
        android.Manifest.permission.BLUETOOTH_SCAN,
        android.Manifest.permission.BLUETOOTH_ADVERTISE,
        android.Manifest.permission.BLUETOOTH_CONNECT,
        android.Manifest.permission.NEARBY_WIFI_DEVICES
    )

    /**
     * 按授予向量作答的 Context 替身：未在 [grantedPermissions] 中的权限返回 DENIED。
     * 这让"部分授予"成为可生成的一等状态，而不是只能测试全授予/全拒绝两端。
     */
    fun contextWith(grantedPermissions: Set<String>): Context = mockk<Context>().also { context ->
        every { context.checkSelfPermission(any()) } answers {
            val requested = firstArg<String>()
            if (requested in grantedPermissions) {
                PackageManager.PERMISSION_GRANTED
            } else {
                PackageManager.PERMISSION_DENIED
            }
        }
    }

    /** 广播路径的门禁序列，与生产 startAdvertising 的顺序一致。返回是否真正到达注册步骤。 */
    fun advertiseStartReachedRegistration(
        context: Context,
        sdkInt: Int,
        transports: Set<BonjourAdvertisingTransport>
    ): Boolean {
        var reachedRegistration = false
        try {
            BonjourLocalNetworkPolicy.requireAdvertisingNetwork(transports)
            BonjourLocalNetworkPermissionPolicy.requireLocalNetworkPermission(context, sdkInt)
            // 生产实现在此处才构造 NsdServiceInfo 并调用 registrar.register(...)。
            reachedRegistration = true
        } catch (_: BonjourAdvertisingException) {
            // 无可用本地网络传输：不启动。
        } catch (_: BonjourLocalNetworkPermissionException) {
            // 权限未授予：不启动。
        }
        return reachedRegistration
    }

    /** 浏览路径的门禁，与生产 startDiscovery 的 callbackFlow 首行一致。 */
    fun browseStartReachedRegistration(context: Context, sdkInt: Int): Boolean {
        var reachedRegistration = false
        try {
            BonjourLocalNetworkPermissionPolicy.requireLocalNetworkPermission(context, sdkInt)
            // 生产实现在此处才 acquireMulticastLock 并 nsdManager.discoverServices(...)。
            reachedRegistration = true
        } catch (_: BonjourLocalNetworkPermissionException) {
            // 权限未授予：不启动。
        }
        return reachedRegistration
    }

    val transportArb: Arb<Set<BonjourAdvertisingTransport>> =
        Arb.set(Arb.element(*BonjourAdvertisingTransport.entries.toTypedArray()), 0..4)

    val grantedSetArb: Arb<Set<String>> =
        Arb.list(
            Arb.boolean(),
            discoveryPermissions.size..discoveryPermissions.size,
        ).map { grants ->
            discoveryPermissions.zip(grants)
                .filter { (_, granted) -> granted }
                .map { (permission, _) -> permission }
                .toSet()
        }

    test("Property 14: 本地网络权限未授予时，广播与浏览都不进入注册步骤") {
        var localNetworkGranted = 0
        var localNetworkDenied = 0
        var partialGrantWithoutLocalNetwork = 0
        var allGranted = 0
        var supportedTransport = 0
        var unsupportedTransport = 0

        checkAll(1_000, grantedSetArb, transportArb, Arb.int(30..45)) { granted, transports, sdkInt ->
            val context = contextWith(granted)

            val permissionRequired =
                BonjourLocalNetworkPermissionPolicy.isLocalNetworkPermissionRequired(sdkInt)
            val localNetworkOk = !permissionRequired ||
                android.Manifest.permission.ACCESS_LOCAL_NETWORK in granted
            val transportOk = transports.any {
                it == BonjourAdvertisingTransport.WIFI ||
                    it == BonjourAdvertisingTransport.ETHERNET ||
                    it == BonjourAdvertisingTransport.LOCAL_NETWORK
            }

            val browseStarted = browseStartReachedRegistration(context, sdkInt)
            val advertiseStarted = advertiseStartReachedRegistration(context, sdkInt, transports)

            // 核心属性（浏览）：当且仅当所需本地网络权限已满足时才启动。
            browseStarted shouldBe localNetworkOk

            // 核心属性（广播）：需要"本地网络权限已满足 ∧ 有可用本地网络传输"两者同时成立。
            advertiseStarted shouldBe (localNetworkOk && transportOk)

            // R3.8 的关键蕴含：权限未满足 ⇒ 两条路径都没启动。
            if (!localNetworkOk) {
                browseStarted shouldBe false
                advertiseStarted shouldBe false
            }

            // 无关权限（蓝牙/邻近 Wi-Fi）的授予状态不得影响本地网络门禁结果。
            val onlyLocalNetworkGranted = setOf(android.Manifest.permission.ACCESS_LOCAL_NETWORK)
            if (localNetworkOk && permissionRequired) {
                browseStartReachedRegistration(contextWith(onlyLocalNetworkGranted), sdkInt) shouldBe true
            }

            if (localNetworkOk) localNetworkGranted++ else localNetworkDenied++
            if (granted.isNotEmpty() &&
                android.Manifest.permission.ACCESS_LOCAL_NETWORK !in granted
            ) {
                partialGrantWithoutLocalNetwork++
            }
            if (granted.size == discoveryPermissions.size) allGranted++
            if (transportOk) supportedTransport++ else unsupportedTransport++
        }

        println(
            "[Property 14 门禁] localNetworkGranted=$localNetworkGranted " +
                "localNetworkDenied=$localNetworkDenied " +
                "partialGrantWithoutLocalNetwork=$partialGrantWithoutLocalNetwork " +
                "allGranted=$allGranted supportedTransport=$supportedTransport " +
                "unsupportedTransport=$unsupportedTransport"
        )

        // 非空真保证：授予/拒绝、部分授予、全授予与两类传输状态都被真正生成到。
        (localNetworkGranted > 0) shouldBe true
        (localNetworkDenied > 0) shouldBe true
        (partialGrantWithoutLocalNetwork > 0) shouldBe true
        (allGranted > 0) shouldBe true
        (supportedTransport > 0) shouldBe true
        (unsupportedTransport > 0) shouldBe true
    }

    test("Property 14: 权限从拒绝转为全部授予后，同一路径才开始允许启动（单调放行）") {
        var deniedThenGranted = 0

        checkAll(300, transportArb, Arb.int(37..45)) { transports, sdkInt ->
            val deniedContext = contextWith(emptySet())
            val grantedContext = contextWith(discoveryPermissions.toSet())

            // 授予前：两条路径都不启动（API >= 37 该权限必被要求）。
            browseStartReachedRegistration(deniedContext, sdkInt) shouldBe false
            advertiseStartReachedRegistration(deniedContext, sdkInt, transports) shouldBe false

            // 全部授予后：浏览必启动；广播还额外要求可用传输（网络条件独立于权限）。
            browseStartReachedRegistration(grantedContext, sdkInt) shouldBe true
            val transportOk = transports.any {
                it == BonjourAdvertisingTransport.WIFI ||
                    it == BonjourAdvertisingTransport.ETHERNET ||
                    it == BonjourAdvertisingTransport.LOCAL_NETWORK
            }
            advertiseStartReachedRegistration(grantedContext, sdkInt, transports) shouldBe transportOk

            deniedThenGranted++
        }

        println("[Property 14 单调放行] deniedThenGranted=$deniedThenGranted")

        (deniedThenGranted > 0) shouldBe true
    }

    test("Property 14: 仅 Android 模拟器 NAT 传输不足以放行广播（不得据此认为已可被 Apple 发现）") {
        var emulatorOnlyBlocked = 0

        checkAll(200, Arb.boolean(), Arb.boolean()) { isEmulator, hasLocalInterface ->
            val grantedContext = contextWith(discoveryPermissions.toSet())
            val transports = BonjourLocalNetworkPolicy.emulatorAdvertisingTransports(
                isAndroidEmulator = isEmulator,
                hasCellularActiveNetwork = true,
                hasEmulatorLocalInterface = hasLocalInterface
            )

            // 即使权限全部授予，模拟器 NAT（或空集）都不构成可用于 Bonjour 的本地网络传输。
            advertiseStartReachedRegistration(grantedContext, 36, transports) shouldBe false
            // 浏览不依赖传输判定，权限已授予即可启动。
            browseStartReachedRegistration(grantedContext, 36) shouldBe true
            emulatorOnlyBlocked++
        }

        println("[Property 14 模拟器 NAT] emulatorOnlyBlocked=$emulatorOnlyBlocked")

        (emulatorOnlyBlocked > 0) shouldBe true
    }
})
