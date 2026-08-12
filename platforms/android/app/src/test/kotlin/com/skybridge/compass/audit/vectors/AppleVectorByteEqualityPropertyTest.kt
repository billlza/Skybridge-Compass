package com.skybridge.compass.audit.vectors

import io.kotest.common.ExperimentalKotest
import io.kotest.core.spec.style.FunSpec
import io.kotest.matchers.shouldBe
import io.kotest.property.Arb
import io.kotest.property.PropTestConfig
import io.kotest.property.arbitrary.arbitrary
import io.kotest.property.checkAll

/** Apple production-codec corpus compatibility through exact Android shipping codecs. */
@OptIn(ExperimentalKotest::class)
class AppleVectorByteEqualityPropertyTest : FunSpec({
    val loader = CompatibilityVectorLoader.fromWorkspace()

    test("all 23 Apple vectors project to captured typed fields and re-encode byte-exactly") {
        val vectors = loader.loadAll()
        val failures = mutableListOf<String>()
        val comparedBySurface = linkedMapOf<CodecSurface, Int>()

        vectors.forEach { vector ->
            val evaluation = try {
                AppleVectorCodecRegistry.evaluate(vector)
            } catch (error: Exception) {
                failures += "${vector.relativePath}: shipping codec rejected Apple bytes (${error::class.java.simpleName})"
                return@forEach
            }

            if (evaluation.projectedFields != vector.expectedFields) {
                failures += "${vector.relativePath}: typed field projection differs from captured expectedFields"
            }
            CompatibilityVectorLoader.describeByteMismatch(
                expected = vector.rawBytes,
                actual = evaluation.reEncodedBytes,
                context = vector.relativePath,
            )?.let(failures::add)
            comparedBySurface[vector.surface] = comparedBySurface.getOrDefault(vector.surface, 0) + 1
        }

        if (failures.isNotEmpty()) {
            throw AssertionError(
                "Apple canonical wire compatibility failed:\n" +
                    failures.joinToString("\n") { " - $it" },
            )
        }
        vectors.size shouldBe 23
        comparedBySurface shouldBe mapOf(
            CodecSurface.F1_FILE_TRANSFER to 8,
            CodecSurface.F2_P2P_HANDSHAKE to 5,
            CodecSurface.F3_HPKE_SEALED_BOX to 5,
            CodecSurface.F4_BONJOUR_TXT to 5,
        )
    }

    test("F1 result is canonical wire compatibility evidence and uses the shipping codec") {
        val f1 = loader.requireAppleVectors(CodecSurface.F1_FILE_TRANSFER)
        f1.size shouldBe 8
        f1.forEach { vector ->
            val evaluation = AppleVectorCodecRegistry.evaluate(vector)
            evaluation.projectedFields shouldBe vector.expectedFields
            evaluation.reEncodedBytes.contentEquals(vector.rawBytes) shouldBe true
        }
        // Stateful request/response admission parity is intentionally not claimed by this test.
        FileTransferMessageCodecAdapter.delegatesTo.contains("CrossNetworkFileTransferWireCodec") shouldBe true
    }

    test("F3 registry fixes handshake and application parse modes by typed message") {
        mapOf(
            "handshake-v1" to true,
            "handshake-v2" to true,
            "application-v1" to false,
            "application-v2" to false,
            "v2-empty-nonce-tag" to false,
        ).forEach { (messageType, expectedMode) ->
            AppleVectorCodecRegistry.hpkeHandshakeMode(messageType) shouldBe expectedMode
        }
    }

    test("byte mismatch helper reports the first differing offset") {
        val seed = System.getenv("F5_COMPARATOR_PBT_SEED")?.toLongOrNull()
            ?: java.util.Random().nextLong()
        val pairArb: Arb<Triple<ByteArray, ByteArray, Int?>> = arbitrary { randomSource ->
            val size = randomSource.random.nextInt(0, 256)
            val expected = ByteArray(size).also { randomSource.random.nextBytes(it) }
            when (randomSource.random.nextInt(3)) {
                0 -> Triple(expected, expected.copyOf(), null)
                1 -> if (size == 0) {
                    Triple(expected, expected.copyOf(), null)
                } else {
                    val offset = randomSource.random.nextInt(size)
                    val actual = expected.copyOf()
                    actual[offset] = (actual[offset].toInt() xor 0xff).toByte()
                    Triple(expected, actual, offset)
                }
                else -> {
                    val shorterSize = randomSource.random.nextInt(0, size + 1)
                    val actual = expected.copyOf(shorterSize)
                    Triple(expected, actual, if (shorterSize == size) null else shorterSize)
                }
            }
        }
        checkAll(PropTestConfig(seed = seed, iterations = 500), pairArb) {
                (expected, actual, expectedOffset) ->
            CompatibilityVectorLoader.firstUnequalByteOffset(expected, actual) shouldBe expectedOffset
        }
    }
})
