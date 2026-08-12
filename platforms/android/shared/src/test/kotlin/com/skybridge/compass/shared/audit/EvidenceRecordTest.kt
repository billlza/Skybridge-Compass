package com.skybridge.compass.shared.audit

import java.time.Instant
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * EvidenceRecord 采集/标注规则单元测试（任务 5.3，_Requirements: 10.3、10.4、10.5、10.6_）。
 *
 * 使用 JUnit 4 断言（经 vintage 引擎在 `shared` 的 `useJUnitPlatform()` 下执行，
 * 与 [AuditReportWriterTest] 一致），位于 test 源集，不随生产应用打包。
 */
class EvidenceRecordTest {

    private fun realDevice(platform: String, os: String, api: Int) = EndpointDescriptor(
        platform = platform,
        osVersion = Collected.Value(os),
        apiLevel = Collected.Value(api),
    )

    // region 完整真机记录

    @Test
    fun fullRealDeviceRecordIsValidWithNoFlags() {
        val record = EvidenceRecord.create(
            id = "E-001",
            gapItemIds = listOf("G-001"),
            completedAtUtc = Collected.Value(Instant.parse("2026-07-30T15:17:11Z")),
            initiator = realDevice("Android", "16", 36),
            responder = realDevice("macOS", "26.0", 26),
            transport = Collected.Value(TransportKind.WEBRTC_P2P),
            negotiatedSuite = Collected.Value("PQC-KYBER768-AES256GCM"),
            turnRelayed = Collected.Value(false),
            deviceClass = DeviceClass.REAL_DEVICE,
        )

        assertEquals(EvidenceValidation.Valid, record.validate())
        assertFalse(record.hasUncollectedField())
        assertTrue("完整真机记录不应带任何标注", record.flags.isEmpty())
    }

    // endregion

    // region R10.4 不可采集字段 ⇒ INCOMPLETE

    @Test
    fun recordWithUncollectableFieldIsFlaggedIncompleteWithReason() {
        val notCollected = Collected.NotCollected("TURN 中继状态在本次抓包中不可判定")
        val record = EvidenceRecord.create(
            id = "E-002",
            gapItemIds = listOf("G-002"),
            completedAtUtc = Collected.Value(Instant.parse("2026-07-30T15:20:00Z")),
            initiator = realDevice("Android", "16", 36),
            responder = realDevice("iOS", "26.0", 26),
            transport = Collected.Value(TransportKind.WEBRTC_TURN),
            negotiatedSuite = Collected.Value("PQC-KYBER768-AES256GCM"),
            turnRelayed = notCollected,
            deviceClass = DeviceClass.REAL_DEVICE,
        )

        assertTrue(record.hasUncollectedField())
        assertTrue("未采集字段必带 INCOMPLETE", EvidenceFlag.INCOMPLETE in record.flags)
        assertEquals(EvidenceValidation.Valid, record.validate())
        // 原因被保留，未留空、未填推测值。
        assertEquals(notCollected, record.turnRelayed)
    }

    @Test
    fun notCollectedReasonMustNotBeBlank() {
        var threw = false
        try {
            Collected.NotCollected("   ")
        } catch (e: IllegalArgumentException) {
            threw = true
        }
        assertTrue("空白原因必须被拒绝（禁止留空）", threw)
    }

    @Test
    fun manuallyBuiltIncompleteRecordWithoutFlagFailsValidation() {
        // 绕过工厂，手工构造：有未采集字段却不带 INCOMPLETE ⇒ 校验失败。
        val record = EvidenceRecord(
            id = "E-003",
            gapItemIds = emptyList(),
            completedAtUtc = Collected.NotCollected("时钟未同步，完成时刻不可采集"),
            initiator = realDevice("Android", "16", 36),
            responder = realDevice("macOS", "26.0", 26),
            transport = Collected.Value(TransportKind.LAN_TCP),
            negotiatedSuite = Collected.Value("suite"),
            turnRelayed = Collected.Value(false),
            deviceClass = DeviceClass.REAL_DEVICE,
            flags = emptySet(),
        )

        val result = record.validate()
        assertTrue(result is EvidenceValidation.Invalid)
        result as EvidenceValidation.Invalid
        assertTrue(result.violations.any { it.contains("INCOMPLETE") })
    }

    // endregion

    // region R10.5 模拟器证据 ⇒ EMULATOR + 两项真机覆盖结论

    @Test
    fun emulatorRecordCarriesEmulatorFlagAndTwoPhysicalConclusions() {
        val coverage = EmulatorCoverage(
            localNetworkDiscoveryCovered = false,
            hardwareCodecCovered = false,
            uncoveredBehaviorNotes = "模拟器无法验证真机 mDNS 组播与硬件 H.264/HEVC 编解码器",
        )
        val record = EvidenceRecord.create(
            id = "E-004",
            gapItemIds = listOf("G-004"),
            completedAtUtc = Collected.Value(Instant.parse("2026-07-30T16:00:00Z")),
            initiator = realDevice("Android", "16", 36),
            responder = realDevice("macOS", "26.0", 26),
            transport = Collected.Value(TransportKind.WEBRTC_P2P),
            negotiatedSuite = Collected.Value("PQC-KYBER768-AES256GCM"),
            turnRelayed = Collected.Value(false),
            deviceClass = DeviceClass.EMULATOR,
            emulatorCoverage = coverage,
        )

        assertTrue("模拟器证据必带 EMULATOR", EvidenceFlag.EMULATOR in record.flags)
        // 两项必需结论均被记录（无论覆盖与否，都要有明确结论）。
        assertEquals(false, record.emulatorCoverage?.localNetworkDiscoveryCovered)
        assertEquals(false, record.emulatorCoverage?.hardwareCodecCovered)
        assertEquals(EvidenceValidation.Valid, record.validate())
    }

    @Test
    fun emulatorRecordWithoutCoverageIsRejectedByFactory() {
        var threw = false
        try {
            EvidenceRecord.create(
                id = "E-005",
                gapItemIds = emptyList(),
                completedAtUtc = Collected.Value(Instant.now()),
                initiator = realDevice("Android", "16", 36),
                responder = realDevice("macOS", "26.0", 26),
                transport = Collected.Value(TransportKind.LAN_TCP),
                negotiatedSuite = Collected.Value("suite"),
                turnRelayed = Collected.Value(false),
                deviceClass = DeviceClass.EMULATOR,
                emulatorCoverage = null,
            )
        } catch (e: IllegalArgumentException) {
            threw = true
        }
        assertTrue("模拟器证据缺覆盖结论必须被拒绝", threw)
    }

    // endregion

    // region R10.6 本地兼容信令 ⇒ CONNECTIVITY_ONLY

    @Test
    fun connectivityOnlyFlagSetForLocalCompatSignaling() {
        val record = EvidenceRecord.create(
            id = "E-006",
            gapItemIds = listOf("G-006"),
            completedAtUtc = Collected.Value(Instant.parse("2026-07-30T17:00:00Z")),
            initiator = realDevice("Android", "16", 36),
            responder = realDevice("macOS", "26.0", 26),
            transport = Collected.Value(TransportKind.WEBRTC_P2P),
            negotiatedSuite = Collected.Value("PQC-KYBER768-AES256GCM"),
            turnRelayed = Collected.Value(false),
            deviceClass = DeviceClass.REAL_DEVICE,
            connectivityOnly = ConnectivityOnlyNote(),
        )

        assertTrue(
            "本地兼容信令证据必带 CONNECTIVITY_ONLY",
            EvidenceFlag.CONNECTIVITY_ONLY in record.flags,
        )
        assertEquals(EvidenceValidation.Valid, record.validate())
        assertTrue(record.connectivityOnly!!.note.isNotBlank())
    }

    @Test
    fun manuallyBuiltConnectivityOnlyFlagWithoutNoteFailsValidation() {
        val record = EvidenceRecord(
            id = "E-007",
            gapItemIds = emptyList(),
            completedAtUtc = Collected.Value(Instant.parse("2026-07-30T17:30:00Z")),
            initiator = realDevice("Android", "16", 36),
            responder = realDevice("macOS", "26.0", 26),
            transport = Collected.Value(TransportKind.WEBRTC_P2P),
            negotiatedSuite = Collected.Value("suite"),
            turnRelayed = Collected.Value(false),
            deviceClass = DeviceClass.REAL_DEVICE,
            flags = setOf(EvidenceFlag.CONNECTIVITY_ONLY),
            connectivityOnly = null,
        )

        val result = record.validate()
        assertTrue(result is EvidenceValidation.Invalid)
        result as EvidenceValidation.Invalid
        assertTrue(result.violations.any { it.contains("CONNECTIVITY_ONLY") })
    }

    // endregion

    // region 组合与精度

    @Test
    fun completedAtUtcIsTruncatedToSecondPrecision() {
        val withMillis = Instant.parse("2026-07-30T18:00:00.123456789Z")
        val record = EvidenceRecord.create(
            id = "E-008",
            gapItemIds = emptyList(),
            completedAtUtc = Collected.Value(withMillis),
            initiator = realDevice("Android", "16", 36),
            responder = realDevice("macOS", "26.0", 26),
            transport = Collected.Value(TransportKind.LAN_TCP),
            negotiatedSuite = Collected.Value("suite"),
            turnRelayed = Collected.Value(true),
            deviceClass = DeviceClass.REAL_DEVICE,
        )

        val ts = record.completedAtUtc as Collected.Value
        assertEquals(Instant.parse("2026-07-30T18:00:00Z"), ts.value)
    }

    @Test
    fun emulatorConnectivityIncompleteFlagsCombine() {
        val coverage = EmulatorCoverage(
            localNetworkDiscoveryCovered = false,
            hardwareCodecCovered = false,
            uncoveredBehaviorNotes = "模拟器 + 本地信令，真机发现与硬件编解码均未覆盖",
        )
        val record = EvidenceRecord.create(
            id = "E-009",
            gapItemIds = listOf("G-009"),
            completedAtUtc = Collected.Value(Instant.parse("2026-07-30T19:00:00Z")),
            initiator = realDevice("Android", "16", 36),
            responder = EndpointDescriptor(
                platform = "macOS",
                osVersion = Collected.NotCollected("对端 OS 版本未在握手中暴露"),
                apiLevel = Collected.NotCollected("对端 API 级别不适用/未采集"),
            ),
            transport = Collected.Value(TransportKind.WEBRTC_TURN),
            negotiatedSuite = Collected.Value("PQC-KYBER768-AES256GCM"),
            turnRelayed = Collected.Value(true),
            deviceClass = DeviceClass.EMULATOR,
            emulatorCoverage = coverage,
            connectivityOnly = ConnectivityOnlyNote(),
        )

        assertEquals(
            setOf(
                EvidenceFlag.EMULATOR,
                EvidenceFlag.CONNECTIVITY_ONLY,
                EvidenceFlag.INCOMPLETE,
            ),
            record.flags,
        )
        assertEquals(EvidenceValidation.Valid, record.validate())
    }

    @Test
    fun blankIdIsRejected() {
        var threw = false
        try {
            EvidenceRecord.create(
                id = "  ",
                gapItemIds = emptyList(),
                completedAtUtc = Collected.Value(Instant.now()),
                initiator = realDevice("Android", "16", 36),
                responder = realDevice("macOS", "26.0", 26),
                transport = Collected.Value(TransportKind.LAN_TCP),
                negotiatedSuite = Collected.Value("suite"),
                turnRelayed = Collected.Value(false),
                deviceClass = DeviceClass.REAL_DEVICE,
            )
        } catch (e: IllegalArgumentException) {
            threw = true
        }
        assertTrue(threw)
    }

    // endregion
}
