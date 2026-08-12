package com.skybridge.compass.discovery.data.datasources

import com.skybridge.compass.discovery.data.codec.BonjourTxtRecordCodec
import io.kotest.assertions.throwables.shouldNotThrowAny
import io.kotest.assertions.throwables.shouldThrow
import io.kotest.core.spec.style.FunSpec
import io.kotest.matchers.maps.shouldContainKey
import io.kotest.matchers.maps.shouldNotContainKey
import io.kotest.matchers.shouldBe

/**
 * Verifies that the advertised TXT record carries non-empty capability and crypto-suite fields when
 * present and that the assembled key/value map is routed through [BonjourTxtRecordCodec] for the
 * RFC 6763 length budget (255 B per pair, 1300 B per record) — covering task 7.3 / R3.2.
 */
class BonjourAdvertisementTxtRecordTest : FunSpec({

    val validFingerprint = "a".repeat(64)

    fun advertisement(
        capabilities: String? = null,
        cryptoSuites: String? = null,
        name: String = "Pixel",
        model: String? = "Pixel 9"
    ): BonjourAdvertiserDataSource.Advertisement =
        BonjourAdvertiserDataSource.Advertisement(
            deviceId = "device-1234",
            pubKeyFP = validFingerprint,
            uniqueId = "device-1234",
            name = name,
            capabilities = capabilities,
            cryptoSuites = cryptoSuites,
            model = model
        )

    test("capabilities and cryptoSuites are written non-empty when present") {
        val fields = BonjourAdvertisementTxtRecord.buildFields(
            advertisement = advertisement(
                capabilities = "file_transfer,file,classic_resume",
                cryptoSuites = "0001,0101"
            ),
            normalizedPubKeyFingerprint = validFingerprint
        )

        fields.shouldContainKey("capabilities")
        fields.shouldContainKey("cryptoSuites")
        fields["capabilities"]!!.decodeToString() shouldBe "file_transfer,file,classic_resume"
        fields["cryptoSuites"]!!.decodeToString() shouldBe "0001,0101"
    }

    test("blank capability and crypto-suite values are omitted rather than written empty") {
        val fields = BonjourAdvertisementTxtRecord.buildFields(
            advertisement = advertisement(capabilities = null, cryptoSuites = "   "),
            normalizedPubKeyFingerprint = validFingerprint
        )

        fields.shouldNotContainKey("capabilities")
        fields.shouldNotContainKey("cryptoSuites")
    }

    test("required identity keys and hs_soa flag are always assembled") {
        val fields = BonjourAdvertisementTxtRecord.buildFields(
            advertisement = advertisement(),
            normalizedPubKeyFingerprint = validFingerprint
        )

        fields.shouldContainKey("deviceId")
        fields.shouldContainKey("pubKeyFP")
        fields.shouldContainKey("uniqueId")
        fields.shouldContainKey("hs_soa")
    }

    test("a well-formed advertisement is within the codec length budget") {
        shouldNotThrowAny {
            BonjourAdvertisementTxtRecord.validateBudget(
                advertisement = advertisement(
                    capabilities = "file_transfer,file,classic_resume",
                    cryptoSuites = "0011,0001,0101,1001"
                ),
                normalizedPubKeyFingerprint = validFingerprint
            )
        }
    }

    test("a single oversized pair is rejected before registration") {
        val error = shouldThrow<BonjourAdvertisingException> {
            BonjourAdvertisementTxtRecord.validateBudget(
                advertisement = advertisement(capabilities = "x".repeat(300)),
                normalizedPubKeyFingerprint = validFingerprint
            )
        }
        error.message!!.contains("per-pair") shouldBe true
    }

    test("an oversized whole record is rejected before registration") {
        // Each name pair stays under the 255 B per-pair limit but the aggregate exceeds 1300 B.
        val error = shouldThrow<BonjourAdvertisingException> {
            BonjourAdvertisementTxtRecord.validateBudget(
                advertisement = advertisement(
                    capabilities = "c".repeat(240),
                    cryptoSuites = "s".repeat(240),
                    name = "n".repeat(240),
                    model = "m".repeat(240)
                ).copy(
                    version = "v".repeat(240),
                    osVersion = "o".repeat(240)
                ),
                normalizedPubKeyFingerprint = validFingerprint
            )
        }
        error.message!!.contains("record") shouldBe true
    }

    test("assembled fields encode losslessly through the codec round trip") {
        val fields = BonjourAdvertisementTxtRecord.buildFields(
            advertisement = advertisement(
                capabilities = "file_transfer,file",
                cryptoSuites = "0001,0101"
            ),
            normalizedPubKeyFingerprint = validFingerprint
        )

        val decoded = BonjourTxtRecordCodec.decode(BonjourTxtRecordCodec.encode(fields))

        decoded.keys shouldBe fields.keys
        decoded["capabilities"]!!.decodeToString() shouldBe "file_transfer,file"
        decoded["cryptoSuites"]!!.decodeToString() shouldBe "0001,0101"
    }
})
