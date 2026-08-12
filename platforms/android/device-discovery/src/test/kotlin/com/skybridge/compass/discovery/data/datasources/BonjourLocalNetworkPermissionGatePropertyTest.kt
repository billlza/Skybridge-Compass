package com.skybridge.compass.discovery.data.datasources

import android.content.Context
import android.content.pm.PackageManager
import io.kotest.assertions.throwables.shouldNotThrowAny
import io.kotest.assertions.throwables.shouldThrow
import io.kotest.core.spec.style.FunSpec
import io.kotest.matchers.shouldBe
import io.kotest.property.Arb
import io.kotest.property.arbitrary.boolean
import io.kotest.property.arbitrary.int
import io.kotest.property.arbitrary.of
import io.kotest.property.checkAll
import io.mockk.every
import io.mockk.mockk

/**
 * **Feature: cross-platform-parity-audit, Property 13: 本地网络权限门槛函数**
 *
 * **Validates: Requirements 3.7**
 *
 * 任务 7.16 的属性测试。与 [BonjourLocalNetworkPolicyTest] 的示例测试**互补**：示例测试固定
 * 三个 API 级别（35/36/37）上的返回值，本文件在整个 API 级别取值域上验证 R3.7 的门槛函数属性：
 *
 * 1. **门槛值恰为 37**：[BonjourLocalNetworkPermissionPolicy.isLocalNetworkPermissionRequired]
 *    是关于 `sdkInt` 的**单调阶跃**函数，跃变点恰好在 37 —— 即 `sdkInt >= 37 ⇔ true`。
 *    API 36 不得请求尚未存在的 API-37 权限；其可选兼容限制由
 *    `NEARBY_WIFI_DEVICES` 通道独立处理。
 * 2. **两函数一致**：[BonjourLocalNetworkPermissionPolicy.requiredPermission] 返回非 null
 *    当且仅当 `isLocalNetworkPermissionRequired` 为 true，且非 null 时恒为 `ACCESS_LOCAL_NETWORK`。
 * 3. **门槛与授予状态的合成**：[BonjourLocalNetworkPermissionPolicy.isGranted] 在权限不被要求时
 *    恒为 true（旧平台无此权限概念）；在被要求时**当且仅当**系统返回
 *    [PackageManager.PERMISSION_GRANTED] 时为 true。
 *
 * **属性定义域**：`sdkInt` 取 1..60（覆盖门槛两侧足够宽的范围，含 minSdk 36 与 API 37）。
 * `Context` 用 mockk 替身注入 `checkSelfPermission` 的返回码——被测的是门槛判定逻辑，
 * 而非 Android 框架的权限存储实现。
 *
 * 为避免空真通过，每个测试统计其真正走到的分支并在 `checkAll` 后断言计数均大于 0。
 */
class BonjourLocalNetworkPermissionGatePropertyTest : FunSpec({

    /** R3.7 规定的门槛：该权限在 Android 平台上实际生效的最低 API 级别。 */
    val expectedThreshold = 37

    fun contextGranting(resultCode: Int): Context = mockk<Context>().also { context ->
        every { context.checkSelfPermission(any()) } returns resultCode
    }

    test("Property 13: 门槛函数是以 37 为跃变点的单调阶跃函数") {
        var belowThreshold = 0
        var atThreshold = 0
        var aboveThreshold = 0

        checkAll(500, Arb.int(1..60)) { sdkInt ->
            val required = BonjourLocalNetworkPermissionPolicy.isLocalNetworkPermissionRequired(sdkInt)

            // 核心属性：required ⇔ sdkInt >= 37。
            required shouldBe (sdkInt >= expectedThreshold)

            // 单调性：门槛函数一旦为 true，更高的 API 级别必须仍为 true。
            if (required) {
                BonjourLocalNetworkPermissionPolicy
                    .isLocalNetworkPermissionRequired(sdkInt + 1) shouldBe true
            } else {
                // 未达门槛时，更低的 API 级别也必须为 false。
                BonjourLocalNetworkPermissionPolicy
                    .isLocalNetworkPermissionRequired((sdkInt - 1).coerceAtLeast(1)) shouldBe false
            }

            // requiredPermission 与门槛函数严格一致。
            val permission = BonjourLocalNetworkPermissionPolicy.requiredPermission(sdkInt)
            (permission != null) shouldBe required
            if (required) {
                permission shouldBe android.Manifest.permission.ACCESS_LOCAL_NETWORK
            }

            when {
                sdkInt < expectedThreshold -> belowThreshold++
                sdkInt == expectedThreshold -> atThreshold++
                else -> aboveThreshold++
            }
        }

        // 边界值显式断言，避免仅依赖随机生成器命中门槛。
        BonjourLocalNetworkPermissionPolicy
            .isLocalNetworkPermissionRequired(expectedThreshold - 1) shouldBe false
        BonjourLocalNetworkPermissionPolicy
            .isLocalNetworkPermissionRequired(expectedThreshold) shouldBe true

        println(
            "[Property 13 门槛] belowThreshold=$belowThreshold atThreshold=$atThreshold " +
                "aboveThreshold=$aboveThreshold"
        )

        // 非空真保证：门槛两侧与门槛点本身都被真正生成到。
        (belowThreshold > 0) shouldBe true
        (aboveThreshold > 0) shouldBe true
    }

    test("Property 13: isGranted 在权限不被要求时恒真，被要求时当且仅当系统返回 GRANTED") {
        var requiredAndGranted = 0
        var requiredAndDenied = 0
        var notRequired = 0

        // 结果码含 GRANTED(0)、DENIED(-1) 与其它非 GRANTED 值（防御框架返回未知码）。
        val resultCodeArb = Arb.of(
            PackageManager.PERMISSION_GRANTED,
            PackageManager.PERMISSION_DENIED,
            1,
            -2,
            Int.MIN_VALUE
        )

        checkAll(500, Arb.int(1..60), resultCodeArb) { sdkInt, resultCode ->
            val context = contextGranting(resultCode)
            val required = BonjourLocalNetworkPermissionPolicy.isLocalNetworkPermissionRequired(sdkInt)
            val granted = BonjourLocalNetworkPermissionPolicy.isGranted(context, sdkInt)

            if (!required) {
                notRequired++
                // 旧平台无此权限概念：门槛未达时恒视为已授予，且不查询系统。
                granted shouldBe true
            } else if (resultCode == PackageManager.PERMISSION_GRANTED) {
                requiredAndGranted++
                granted shouldBe true
            } else {
                requiredAndDenied++
                // 任何非 GRANTED 的返回码都不得被当作已授予。
                granted shouldBe false
            }

            // requireLocalNetworkPermission 与 isGranted 严格同构：仅在未授予时抛出。
            if (granted) {
                shouldNotThrowAny {
                    BonjourLocalNetworkPermissionPolicy.requireLocalNetworkPermission(context, sdkInt)
                }
            } else {
                shouldThrow<BonjourLocalNetworkPermissionException> {
                    BonjourLocalNetworkPermissionPolicy.requireLocalNetworkPermission(context, sdkInt)
                }
            }
        }

        println(
            "[Property 13 isGranted] notRequired=$notRequired " +
                "requiredAndGranted=$requiredAndGranted requiredAndDenied=$requiredAndDenied"
        )

        // 非空真保证：三条分支（不要求 / 要求且授予 / 要求但拒绝）都被真正生成到。
        (notRequired > 0) shouldBe true
        (requiredAndGranted > 0) shouldBe true
        (requiredAndDenied > 0) shouldBe true
    }

    test("Property 13: 门槛判定只取决于 sdkInt，与授予状态无关（两维度正交）") {
        var grantedPaths = 0
        var deniedPaths = 0

        checkAll(300, Arb.int(1..60), Arb.boolean()) { sdkInt, grant ->
            val resultCode = if (grant) {
                PackageManager.PERMISSION_GRANTED
            } else {
                PackageManager.PERMISSION_DENIED
            }
            val context = contextGranting(resultCode)

            // 门槛函数与 requiredPermission 不得因授予状态而改变。
            val required = BonjourLocalNetworkPermissionPolicy.isLocalNetworkPermissionRequired(sdkInt)
            required shouldBe (sdkInt >= expectedThreshold)
            BonjourLocalNetworkPermissionPolicy.requiredPermission(sdkInt) shouldBe
                android.Manifest.permission.ACCESS_LOCAL_NETWORK.takeIf { required }

            // isGranted 恰为"不要求 ∨ 已授予"。
            BonjourLocalNetworkPermissionPolicy.isGranted(context, sdkInt) shouldBe (!required || grant)

            if (grant) grantedPaths++ else deniedPaths++
        }

        println("[Property 13 正交] grantedPaths=$grantedPaths deniedPaths=$deniedPaths")

        (grantedPaths > 0) shouldBe true
        (deniedPaths > 0) shouldBe true
    }
})
