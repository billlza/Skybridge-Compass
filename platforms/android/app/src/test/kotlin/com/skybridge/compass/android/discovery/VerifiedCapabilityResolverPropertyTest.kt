package com.skybridge.compass.android.discovery

import com.skybridge.compass.android.data.SecuritySettings
import com.skybridge.compass.discovery.domain.entities.DeviceCapability
import io.kotest.core.spec.style.FunSpec
import io.kotest.matchers.shouldBe
import io.kotest.property.Arb
import io.kotest.property.arbitrary.bind
import io.kotest.property.arbitrary.boolean
import io.kotest.property.arbitrary.list
import io.kotest.property.arbitrary.long
import io.kotest.property.checkAll

/**
 * **Feature: cross-platform-parity-audit, Property 11: 已验证能力集合与运行时前置条件逐项等价**
 *
 * **Validates: Requirements 3.3**
 *
 * 任务 7.14 的属性测试。与 [VerifiedCapabilityResolverTest] / [AndroidLocalNodeBootstrapPolicyTest]
 * 的示例测试**互补**：示例测试固定五个已知用例（单项满足、缺权限、服务未就绪、恰好满足的子集、
 * 空状态），本文件在随机生成的"能力 × (权限, 服务就绪)"前置条件空间上验证 R3.3 的两个半部：
 *
 * 1. **逐项等价（当且仅当）**：对任意前置条件快照，`verifiedCapabilities` 中含某能力
 *    **等价于**该能力的前置条件（权限已授予 ∧ 服务已就绪）在广播时刻成立。等价是双向的：
 *    既无遗漏（满足者必在集合内），也无越界（集合内者必满足）。
 * 2. **至少一项成立时非空**：当至少一项能力的前置条件成立时，结果不得为空集合。
 *
 * **文件位置说明**：被测的 [DefaultVerifiedCapabilityResolver] / [CapabilityRuntimeState] /
 * [AndroidLocalNodeBootstrapPolicy] 是 `:app` 模块的 `internal` 声明（能力就绪判定依赖 app 侧的
 * 权限与无障碍运行时状态，故按设计不在 `:device-discovery` 中）。`internal` 不跨模块可见，因此本
 * 属性测试与它已有的示例测试同置于 `:app` 的 test 源集，而非 `device-discovery/src/test`——这是
 * 唯一能真正驱动生产实现的位置。其余九个属性均位于 `device-discovery/src/test`。
 *
 * 为避免空真通过，每个测试统计其真正走到的分支并在 `checkAll` 后断言计数均大于 0。
 */
class VerifiedCapabilityResolverPropertyTest : FunSpec({

    val resolver = DefaultVerifiedCapabilityResolver

    val allCapabilities = DeviceCapability.entries.toTypedArray()
    require(allCapabilities.size < Long.SIZE_BITS) {
        "Capability power-set generator requires fewer than ${Long.SIZE_BITS} enum entries"
    }
    val allCapabilityMasks = 0L..((1L shl allCapabilities.size) - 1L)

    val preconditionArb: Arb<CapabilityPrecondition> =
        Arb.bind(Arb.boolean(), Arb.boolean()) { permissionGranted, serviceReady ->
            CapabilityPrecondition(permissionGranted = permissionGranted, serviceReady = serviceReady)
        }

    /**
     * 随机前置条件快照。键集合是能力枚举的任意子集（含空集），刻意允许"部分能力缺席"，
     * 因为生产语义规定缺席即视为未满足——这一点必须被属性覆盖而不是假设。
     * 每个在场能力配一个独立生成的前置条件（按枚举序号取用，保证与键集合一一对应）。
     */
    val runtimeStateArb: Arb<CapabilityRuntimeState> = Arb.bind(
        Arb.long(allCapabilityMasks),
        Arb.list(preconditionArb, allCapabilities.size..allCapabilities.size)
    ) { capabilityMask, preconditions ->
        val presentKeys = allCapabilities.filterIndexed { index, _ ->
            capabilityMask and (1L shl index) != 0L
        }
        CapabilityRuntimeState(
            preconditions = presentKeys.associateWith { capability ->
                preconditions[capability.ordinal]
            }
        )
    }

    test("Property 11: 能力属于 verifiedCapabilities 当且仅当其前置条件成立（逐项等价，无遗漏无越界）") {
        var someSatisfied = 0
        var noneSatisfied = 0
        var permissionOnlyBlocked = 0
        var serviceOnlyBlocked = 0
        var bothBlocked = 0
        var absentCapability = 0
        var emptyState = 0

        checkAll(1_000, runtimeStateArb) { state ->
            val resolved = resolver.resolve(state)

            // 核心属性（双向等价）：逐个能力核对，而不是只比较集合大小。
            allCapabilities.forEach { capability ->
                val precondition = state.preconditions[capability]
                val shouldBeAdvertised =
                    precondition != null && precondition.permissionGranted && precondition.serviceReady
                // 当且仅当：含于结果 ⇔ 前置条件成立。
                resolved.contains(capability) shouldBe shouldBeAdvertised
            }

            // 结果不得含任何未在快照中登记的能力（不越界）。
            resolved.all { it in state.preconditions.keys } shouldBe true
            // 结果恰好是满足者的集合。
            resolved shouldBe state.preconditions
                .filterValues { it.permissionGranted && it.serviceReady }
                .keys

            // R3.3 后半句：至少一项前置条件成立时结果非空。
            val satisfiedCount = state.preconditions.count { it.value.isSatisfied }
            if (satisfiedCount > 0) {
                someSatisfied++
                resolved.isNotEmpty() shouldBe true
                resolved.size shouldBe satisfiedCount
            } else {
                noneSatisfied++
                resolved.isEmpty() shouldBe true
            }

            // 分支计数（证明非空真）。
            state.preconditions.values.forEach { p ->
                when {
                    !p.permissionGranted && p.serviceReady -> permissionOnlyBlocked++
                    p.permissionGranted && !p.serviceReady -> serviceOnlyBlocked++
                    !p.permissionGranted && !p.serviceReady -> bothBlocked++
                }
            }
            if (state.preconditions.keys.size < allCapabilities.size) absentCapability++
            if (state.preconditions.isEmpty()) emptyState++
        }

        println(
            "[Property 11 等价] someSatisfied=$someSatisfied noneSatisfied=$noneSatisfied " +
                "permissionOnlyBlocked=$permissionOnlyBlocked " +
                "serviceOnlyBlocked=$serviceOnlyBlocked bothBlocked=$bothBlocked " +
                "absentCapability=$absentCapability emptyState=$emptyState"
        )

        // 非空真保证：满足/不满足、三种阻断成因、能力缺席与空快照都被真正生成到。
        (someSatisfied > 0) shouldBe true
        (noneSatisfied > 0) shouldBe true
        (permissionOnlyBlocked > 0) shouldBe true
        (serviceOnlyBlocked > 0) shouldBe true
        (bothBlocked > 0) shouldBe true
        (absentCapability > 0) shouldBe true
        (emptyState > 0) shouldBe true
    }

    test("Property 11: 由真实设置映射出的前置条件同样逐项等价，且未交付的宿主能力永不出现") {
        var fileTransferAdvertised = 0
        var fileTransferWithheld = 0
        var clipboardAdvertised = 0
        var clipboardWithheld = 0
        var bothAccessTogglesOn = 0

        // 驱动生产映射 AndroidLocalNodeBootstrapPolicy.advertisementSettings（R3.3 的真实入口），
        // 而非在测试内重写映射规则。
        checkAll(
            500,
            Arb.boolean(),
            Arb.boolean(),
            Arb.boolean(),
            Arb.boolean(),
            Arb.boolean()
        ) { allowFileTransfer, allowClipboardSync, allowScreenMirroring, allowRemoteControl, showDeviceName ->
            val settings = SecuritySettings(
                allowFileTransfer = allowFileTransfer,
                allowClipboardSync = allowClipboardSync,
                allowScreenMirroring = allowScreenMirroring,
                allowRemoteControl = allowRemoteControl,
                showDeviceName = showDeviceName
            )

            val advertisementSettings = AndroidLocalNodeBootstrapPolicy.advertisementSettings(settings)
            val state = AndroidLocalNodeBootstrapPolicy.capabilityRuntimeState(settings)
            val resolved = advertisementSettings.verifiedCapabilities

            // 与前置条件快照逐项等价（同一属性，作用在真实设置映射上）。
            allCapabilities.forEach { capability ->
                val precondition = state.preconditions[capability]
                resolved.contains(capability) shouldBe (precondition?.isSatisfied == true)
            }

            // 已交付且服务就绪的能力：当且仅当用户授权时被广播。
            resolved.contains(DeviceCapability.FILE_TRANSFER) shouldBe allowFileTransfer
            resolved.contains(DeviceCapability.CLIPBOARD_SYNC) shouldBe allowClipboardSync

            // 宿主侧未交付（serviceReady = false）的能力：无论开关如何都不得被广播，
            // 否则即为"声明了做不到的能力"，正是 R3.3 要禁止的越界。
            resolved.contains(DeviceCapability.SCREEN_SHARING) shouldBe false
            resolved.contains(DeviceCapability.REMOTE_CONTROL) shouldBe false

            // 至少一项成立时非空。
            if (allowFileTransfer || allowClipboardSync) {
                resolved.isNotEmpty() shouldBe true
            } else {
                resolved.isEmpty() shouldBe true
            }

            // showDeviceName 是隐私开关，不得影响能力集合。
            advertisementSettings.showDeviceName shouldBe showDeviceName

            if (allowFileTransfer) fileTransferAdvertised++ else fileTransferWithheld++
            if (allowClipboardSync) clipboardAdvertised++ else clipboardWithheld++
            if (allowFileTransfer && allowClipboardSync) bothAccessTogglesOn++
        }

        println(
            "[Property 11 真实设置] fileTransferAdvertised=$fileTransferAdvertised " +
                "fileTransferWithheld=$fileTransferWithheld " +
                "clipboardAdvertised=$clipboardAdvertised clipboardWithheld=$clipboardWithheld " +
                "bothAccessTogglesOn=$bothAccessTogglesOn"
        )

        // 非空真保证：两个已交付能力的授予/拒绝分支都被真正生成到。
        (fileTransferAdvertised > 0) shouldBe true
        (fileTransferWithheld > 0) shouldBe true
        (clipboardAdvertised > 0) shouldBe true
        (clipboardWithheld > 0) shouldBe true
        (bothAccessTogglesOn > 0) shouldBe true
    }
})
