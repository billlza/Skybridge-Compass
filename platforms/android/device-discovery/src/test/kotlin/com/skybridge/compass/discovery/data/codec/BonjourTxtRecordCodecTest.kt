package com.skybridge.compass.discovery.data.codec

import io.kotest.assertions.throwables.shouldThrow
import io.kotest.core.spec.style.FunSpec
import io.kotest.matchers.shouldBe
import io.kotest.matchers.types.shouldBeInstanceOf

class BonjourTxtRecordCodecTest : FunSpec({

    fun Map<String, ByteArray>.assertRoundTrips() {
        val decoded = BonjourTxtRecordCodec.decode(BonjourTxtRecordCodec.encode(this))
        decoded.keys shouldBe this.keys
        this.forEach { (key, value) ->
            decoded[key]?.toList() shouldBe value.toList()
        }
    }

    test("encode then decode round-trips a simple field set") {
        mapOf(
            "deviceId" to "abc-123".toByteArray(Charsets.UTF_8),
            "platform" to "android".toByteArray(Charsets.UTF_8),
            "cap" to "file_transfer,remote_control".toByteArray(Charsets.UTF_8)
        ).assertRoundTrips()
    }

    test("round-trip preserves empty values") {
        mapOf(
            "flag" to ByteArray(0),
            "name" to "compass".toByteArray(Charsets.UTF_8)
        ).assertRoundTrips()
    }

    test("round-trip preserves arbitrary binary value bytes") {
        val binary = ByteArray(200) { (it * 7 % 256).toByte() }
        mapOf("blob" to binary).assertRoundTrips()
    }

    test("encoding is order-independent producing identical bytes") {
        val a = linkedMapOf(
            "suites" to "x25519".toByteArray(Charsets.UTF_8),
            "cap" to "file".toByteArray(Charsets.UTF_8),
            "deviceId" to "id".toByteArray(Charsets.UTF_8)
        )
        val b = linkedMapOf(
            "deviceId" to "id".toByteArray(Charsets.UTF_8),
            "cap" to "file".toByteArray(Charsets.UTF_8),
            "suites" to "x25519".toByteArray(Charsets.UTF_8)
        )
        BonjourTxtRecordCodec.encode(a).toList() shouldBe BonjourTxtRecordCodec.encode(b).toList()
    }

    test("canonical ordering compares raw keys before the equals separator") {
        val encoded = BonjourTxtRecordCodec.encode(
            linkedMapOf(
                "a!" to "v".toByteArray(Charsets.UTF_8),
                "a" to "v".toByteArray(Charsets.UTF_8),
            )
        )
        val expected =
            byteArrayOf(3) + "a=v".toByteArray(Charsets.ISO_8859_1) +
                byteArrayOf(4) + "a!=v".toByteArray(Charsets.ISO_8859_1)

        encoded.toList() shouldBe expected.toList()
    }

    test("canonical version 2 advertisement bytes remain unchanged") {
        val fields = mapOf(
            "version" to "2".toByteArray(Charsets.UTF_8),
            "deviceId" to "mac-reference-0001".toByteArray(Charsets.UTF_8),
            "pubKeyFP" to
                "2123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
                    .toByteArray(Charsets.UTF_8),
            "platform" to "macos".toByteArray(Charsets.UTF_8),
            "hs_soa" to "1".toByteArray(Charsets.UTF_8),
        )
        val expected =
            byteArrayOf(27) + "deviceId=mac-reference-0001".toByteArray(Charsets.UTF_8) +
                byteArrayOf(8) + "hs_soa=1".toByteArray(Charsets.UTF_8) +
                byteArrayOf(14) + "platform=macos".toByteArray(Charsets.UTF_8) +
                byteArrayOf(73) +
                "pubKeyFP=2123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
                    .toByteArray(Charsets.UTF_8) +
                byteArrayOf(9) + "version=2".toByteArray(Charsets.UTF_8)

        BonjourTxtRecordCodec.encode(fields).toList() shouldBe expected.toList()
    }

    test("encoded output uses one length byte per pair") {
        val encoded = BonjourTxtRecordCodec.encode(mapOf("ab" to "cd".toByteArray(Charsets.UTF_8)))
        // pair payload "ab=cd" is 5 bytes, prefixed by a single length byte
        encoded.size shouldBe 6
        (encoded[0].toInt() and 0xFF) shouldBe 5
    }

    test("empty field set encodes to empty record and decodes back to empty map") {
        val encoded = BonjourTxtRecordCodec.encode(emptyMap())
        encoded.size shouldBe 0
        BonjourTxtRecordCodec.decode(encoded) shouldBe emptyMap()
    }

    test("validate returns Valid for a within-limits field set") {
        val validation = BonjourTxtRecordCodec.validate(
            mapOf("k" to "v".toByteArray(Charsets.UTF_8))
        )
        validation shouldBe BonjourTxtRecordCodec.TxtValidation.Valid
    }

    test("validate discriminates a single pair exceeding 255 bytes") {
        // key(1) + '='(1) + value = must exceed 255 -> value of 254 bytes gives pair size 256
        val oversizedValue = ByteArray(254) { 'a'.code.toByte() }
        val validation = BonjourTxtRecordCodec.validate(mapOf("k" to oversizedValue))

        val pairTooLarge = validation.shouldBeInstanceOf<BonjourTxtRecordCodec.TxtValidation.PairTooLarge>()
        pairTooLarge.key shouldBe "k"
        pairTooLarge.encodedPairBytes shouldBe 256
    }

    test("validate discriminates the whole record exceeding 1300 bytes") {
        // Each pair: key(3) + '='(1) + value(246) = 250 bytes payload, + 1 length byte = 251 on wire.
        // Six such pairs = 1506 bytes > 1300, while every single pair (250) stays under 255.
        val value = ByteArray(246) { 'b'.code.toByte() }
        val fields = (0 until 6).associate { index -> "k0$index" to value }

        val validation = BonjourTxtRecordCodec.validate(fields)

        val recordTooLarge = validation.shouldBeInstanceOf<BonjourTxtRecordCodec.TxtValidation.RecordTooLarge>()
        recordTooLarge.encodedRecordBytes shouldBe fields.entries.sumOf { (k, v) ->
            1 + k.toByteArray(Charsets.ISO_8859_1).size + 1 + v.size
        }
    }

    test("single-pair violation is reported ahead of a record violation") {
        val oversizedPair = ByteArray(300) { 'c'.code.toByte() }
        val filler = ByteArray(246) { 'd'.code.toByte() }
        val fields = buildMap {
            put("big", oversizedPair)
            (0 until 6).forEach { put("k0$it", filler) }
        }

        BonjourTxtRecordCodec.validate(fields)
            .shouldBeInstanceOf<BonjourTxtRecordCodec.TxtValidation.PairTooLarge>()
    }

    test("encode rejects an oversized pair with a length violation") {
        val oversizedValue = ByteArray(300) { 'e'.code.toByte() }
        shouldThrow<IllegalArgumentException> {
            BonjourTxtRecordCodec.encode(mapOf("k" to oversizedValue))
        }
    }

    test("encode rejects a key containing an equals sign") {
        shouldThrow<IllegalArgumentException> {
            BonjourTxtRecordCodec.encode(mapOf("a=b" to ByteArray(0)))
        }
    }

    test("encode rejects an empty key") {
        shouldThrow<IllegalArgumentException> {
            BonjourTxtRecordCodec.encode(mapOf("" to "v".toByteArray(Charsets.UTF_8)))
        }
    }

    test("decode treats a pair without '=' as a key with empty value") {
        // Manually build a record: length byte 3 + "abc"
        val record = byteArrayOf(3, 'a'.code.toByte(), 'b'.code.toByte(), 'c'.code.toByte())
        val decoded = BonjourTxtRecordCodec.decode(record)
        decoded.keys shouldBe setOf("abc")
        decoded["abc"]?.toList() shouldBe emptyList()
    }

    test("decode rejects a truncated record") {
        // length byte claims 5 bytes but only 2 follow
        val record = byteArrayOf(5, 'a'.code.toByte(), 'b'.code.toByte())
        shouldThrow<IllegalArgumentException> {
            BonjourTxtRecordCodec.decode(record)
        }
    }
})
