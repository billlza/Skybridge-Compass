package com.skybridge.compass.discovery.data.datasources

import com.skybridge.compass.discovery.data.codec.BonjourTxtRecordCodec
import com.skybridge.compass.discovery.data.services.P2PLocalNodeAdvertisementPolicy
import com.skybridge.compass.discovery.domain.entities.DeviceCapability
import io.kotest.assertions.throwables.shouldNotThrowAny
import io.kotest.assertions.throwables.shouldThrow
import io.kotest.core.spec.style.FunSpec
import io.kotest.matchers.shouldBe
import io.kotest.property.Arb
import io.kotest.property.arbitrary.bind
import io.kotest.property.arbitrary.element
import io.kotest.property.arbitrary.int
import io.kotest.property.arbitrary.set
import io.kotest.property.checkAll

/**
 * **Feature: cross-platform-parity-audit, Property 10: 能力与套件 TXT 字段非空且满足长度上限**
 *
 * **Validates: Requirements 3.2**
 *
 * 任务 7.13 的属性测试。与 [BonjourAdvertisementTxtRecordTest] 的示例测试**互补**：示例测试固定
 * 几个已知用例（写出非空 capabilities/cryptoSuites、空白值被省略、单对超限、整条记录超限），
 * 本文件在随机生成的能力集合 × 套件 CSV × 各字段长度空间上验证 R3.2 的两个半部：
 *
 * 1. **非空**：只要本机存在已验证能力，[P2PLocalNodeAdvertisementPolicy.capabilityTxt] 必须产出
 *    非空 CSV；只要本地身份报告了可协商套件，[P2PLocalNodeAdvertisementPolicy.cryptoSuitesTxt]
 *    必须产出非空 CSV；两者写入 TXT 后对应键（`capabilities` / `cryptoSuites`）存在且值非空。
 * 2. **长度上限**：整条 TXT 记录经 [BonjourAdvertisementTxtRecord.validateBudget] 校验，单条键值对
 *    ≤ [BonjourTxtRecordCodec.MAX_PAIR_BYTES]（255 B）、整条记录 ≤
 *    [BonjourTxtRecordCodec.MAX_RECORD_BYTES]（1300 B）；越限必须在注册前抛出而非静默截断。
 *
 * **属性定义域**：R3.2 约束的是"每次广播注册"写出的 TXT。真实注册需要 `NsdManager`，无法在 JVM
 * 单测中驱动；因此本测试驱动注册路径上游的两个真实生产函数——能力/套件 CSV 的生成
 * （`P2PLocalNodeAdvertisementPolicy`，由 `P2PLocalNodeService.start` 调用）与 TXT 组装+预算校验
 * （`BonjourAdvertisementTxtRecord`，由 `BonjourAdvertiserDataSource.buildServiceInfo` 调用）。
 * 空集合能力（→ 省略该键而非写空值）是生产的既定语义，属本属性定义域内的合法输出。
 *
 * 为避免空真通过，每个测试统计其真正走到的分支并在 `checkAll` 后断言计数均大于 0。
 */
class BonjourCapabilitySuiteTxtPropertyTest : FunSpec({

    val validFingerprint = "a".repeat(64)

    fun advertisement(
        capabilities: String?,
        cryptoSuites: String?,
        name: String = "Pixel",
        model: String? = "Pixel 9",
        version: String = "1.0.0",
        osVersion: String = "Android 16 (API 36)"
    ): BonjourAdvertiserDataSource.Advertisement =
        BonjourAdvertiserDataSource.Advertisement(
            deviceId = "device-1234",
            pubKeyFP = validFingerprint,
            uniqueId = "device-1234",
            name = name,
            version = version,
            osVersion = osVersion,
            model = model,
            capabilities = capabilities,
            cryptoSuites = cryptoSuites
        )

    val capabilitySetArb: Arb<Set<DeviceCapability>> =
        Arb.set(Arb.element(*DeviceCapability.entries.toTypedArray()), 0..DeviceCapability.entries.size)

    /** 真实身份可能报告的套件 CSV 形态，含空串与纯空白（生产语义：省略该字段）。 */
    val suitesCsvArb: Arb<String> = Arb.element(
        "0101",
        "0001,0101",
        "0011,0001,0101,1001",
        "",
        "   ",
        "0101,0201,0301,0401,0501,0601,0701,0801"
    )

    test("Property 10 (非空): 非空能力集合与非空套件 CSV 必产出非空 TXT 值并写入对应键") {
        var nonEmptyCaps = 0
        var emptyCaps = 0
        var nonBlankSuites = 0
        var blankSuites = 0

        checkAll(500, capabilitySetArb, suitesCsvArb) { capabilities, rawSuitesCsv ->
            val capabilityTxt = P2PLocalNodeAdvertisementPolicy.capabilityTxt(capabilities)
            val suitesTxt = P2PLocalNodeAdvertisementPolicy.cryptoSuitesTxt(rawSuitesCsv)

            val fields = BonjourAdvertisementTxtRecord.buildFields(
                advertisement = advertisement(capabilities = capabilityTxt, cryptoSuites = suitesTxt),
                normalizedPubKeyFingerprint = validFingerprint
            )

            if (capabilities.isNotEmpty()) {
                nonEmptyCaps++
                // 核心属性（能力半部）：有已验证能力时必须写出非空 capabilities 值。
                (capabilityTxt != null) shouldBe true
                capabilityTxt!!.isNotBlank() shouldBe true
                fields.containsKey("capabilities") shouldBe true
                fields.getValue("capabilities").isNotEmpty() shouldBe true
                // 值确实是 Apple 兼容 token CSV，且不含空 token。
                capabilityTxt.split(",").all { it.isNotBlank() } shouldBe true
            } else {
                emptyCaps++
                // 生产既定语义：无已验证能力时省略该键，而不是写入空值（空值会被 Apple 误读为"无能力声明"以外的形态）。
                capabilityTxt shouldBe null
                fields.containsKey("capabilities") shouldBe false
            }

            if (rawSuitesCsv.isNotBlank()) {
                nonBlankSuites++
                // 核心属性（套件半部）：身份报告了可协商套件时必须写出非空 cryptoSuites 值。
                (suitesTxt != null) shouldBe true
                suitesTxt!!.isNotBlank() shouldBe true
                fields.containsKey("cryptoSuites") shouldBe true
                fields.getValue("cryptoSuites").isNotEmpty() shouldBe true
            } else {
                blankSuites++
                suitesTxt shouldBe null
                fields.containsKey("cryptoSuites") shouldBe false
            }

            // 身份键在任何组合下都必须存在且非空（能力/套件的取值不得影响身份字段）。
            fields.containsKey("deviceId") shouldBe true
            fields.containsKey("pubKeyFP") shouldBe true
            fields.containsKey("uniqueId") shouldBe true
            fields.getValue("pubKeyFP").decodeToString() shouldBe validFingerprint
        }

        println(
            "[Property 10 非空] nonEmptyCaps=$nonEmptyCaps emptyCaps=$emptyCaps " +
                "nonBlankSuites=$nonBlankSuites blankSuites=$blankSuites"
        )

        // 非空真保证：能力/套件的空与非空四种组合都被真正生成到。
        (nonEmptyCaps > 0) shouldBe true
        (emptyCaps > 0) shouldBe true
        (nonBlankSuites > 0) shouldBe true
        (blankSuites > 0) shouldBe true
    }

    test("Property 10 (长度上限): 真实能力/套件组合恒在预算内，且编码后满足 255B/1300B 双上限") {
        var withinBudget = 0
        var maxCapabilitySet = 0

        checkAll(500, capabilitySetArb, suitesCsvArb) { capabilities, rawSuitesCsv ->
            val advertisement = advertisement(
                capabilities = P2PLocalNodeAdvertisementPolicy.capabilityTxt(capabilities),
                cryptoSuites = P2PLocalNodeAdvertisementPolicy.cryptoSuitesTxt(rawSuitesCsv)
            )

            // 真实取值域下预算校验必须通过（不得因全能力集合而越限）。
            shouldNotThrowAny {
                BonjourAdvertisementTxtRecord.validateBudget(advertisement, validFingerprint)
            }

            val fields = BonjourAdvertisementTxtRecord.buildFields(advertisement, validFingerprint)
            BonjourTxtRecordCodec.validate(fields) shouldBe BonjourTxtRecordCodec.TxtValidation.Valid

            // 用编码后的真实字节交叉核对两个上限，而不是只信 validate 的返回值。
            val encoded = BonjourTxtRecordCodec.encode(fields)
            (encoded.size <= BonjourTxtRecordCodec.MAX_RECORD_BYTES) shouldBe true
            fields.forEach { (key, value) ->
                val pairBytes = key.toByteArray(Charsets.ISO_8859_1).size + 1 + value.size
                (pairBytes <= BonjourTxtRecordCodec.MAX_PAIR_BYTES) shouldBe true
            }

            withinBudget++
            if (capabilities.size == DeviceCapability.entries.size) maxCapabilitySet++
        }

        println(
            "[Property 10 预算内] withinBudget=$withinBudget maxCapabilitySet=$maxCapabilitySet"
        )

        (withinBudget > 0) shouldBe true
        // 非空真保证：连"全部能力都已验证"这一最长 CSV 也被生成到并验证过。
        (maxCapabilitySet > 0) shouldBe true
    }

    test("Property 10 (长度上限): 超出 255B 单对或 1300B 整条记录的取值在注册前被拒绝并可区分") {
        var pairViolations = 0
        var recordViolations = 0

        // `capabilities` / `cryptoSuites` 键各占 12 字节，故值 v 的单对编码长度为 12+1+|v|；
        // 单对越限的阈值是 |v| >= 243（12+1+243 = 256 > 255）。
        val capabilitiesKeyBytes = "capabilities".toByteArray(Charsets.ISO_8859_1).size
        val maxValueBytesForSinglePair = BonjourTxtRecordCodec.MAX_PAIR_BYTES - capabilitiesKeyBytes - 1

        // 单对越限：capabilities 值超过该键允许的最大值长度。
        checkAll(200, Arb.int(maxValueBytesForSinglePair + 1..600)) { oversizeLen ->
            val fields = BonjourAdvertisementTxtRecord.buildFields(
                advertisement = advertisement(capabilities = "c".repeat(oversizeLen), cryptoSuites = "0101"),
                normalizedPubKeyFingerprint = validFingerprint
            )
            // 与生产 codec 的判定交叉核对：这确实是单对越限（而非整条记录越限）。
            val validation = BonjourTxtRecordCodec.validate(fields)
            (validation is BonjourTxtRecordCodec.TxtValidation.PairTooLarge) shouldBe true
            (validation as BonjourTxtRecordCodec.TxtValidation.PairTooLarge).key shouldBe "capabilities"

            val error = shouldThrow<BonjourAdvertisingException> {
                BonjourAdvertisementTxtRecord.validateBudget(
                    advertisement = advertisement(capabilities = "c".repeat(oversizeLen), cryptoSuites = "0101"),
                    normalizedPubKeyFingerprint = validFingerprint
                )
            }
            // 越限必须在注册前失败，且原因可区分为单对超限。
            error.message!!.contains("per-pair") shouldBe true
            pairViolations++
        }

        // 整条记录越限：每个字段都在 255B 之内（|v| <= 242），但聚合后超过 1300B。
        checkAll(
            200,
            Arb.int(200..maxValueBytesForSinglePair),
            Arb.int(200..maxValueBytesForSinglePair)
        ) { capLen, suiteLen ->
            val oversizedRecord = advertisement(
                capabilities = "c".repeat(capLen),
                cryptoSuites = "s".repeat(suiteLen),
                name = "n".repeat(240),
                model = "m".repeat(240),
                version = "v".repeat(240),
                osVersion = "o".repeat(240)
            )
            val fields = BonjourAdvertisementTxtRecord.buildFields(oversizedRecord, validFingerprint)

            // 生成器自检：确实每一对都合法，越限只发生在聚合层面。
            fields.all { (k, v) ->
                k.toByteArray(Charsets.ISO_8859_1).size + 1 + v.size <= BonjourTxtRecordCodec.MAX_PAIR_BYTES
            } shouldBe true
            val validation = BonjourTxtRecordCodec.validate(fields)
            (validation is BonjourTxtRecordCodec.TxtValidation.RecordTooLarge) shouldBe true

            val error = shouldThrow<BonjourAdvertisingException> {
                BonjourAdvertisementTxtRecord.validateBudget(oversizedRecord, validFingerprint)
            }
            error.message!!.contains("record") shouldBe true
            recordViolations++
        }

        println(
            "[Property 10 越限] pairViolations=$pairViolations recordViolations=$recordViolations"
        )

        // 非空真保证：两种越限形态都被真正构造并拒绝。
        (pairViolations > 0) shouldBe true
        (recordViolations > 0) shouldBe true
    }
})
