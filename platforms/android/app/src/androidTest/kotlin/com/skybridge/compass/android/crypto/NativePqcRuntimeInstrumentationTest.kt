package com.skybridge.compass.android.crypto

import android.os.Build
import android.os.Bundle
import android.os.Process
import android.system.Os
import android.system.OsConstants
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.skybridge.compass.shared.crypto.CryptoTier
import com.skybridge.compass.shared.crypto.KeyUsage
import com.skybridge.compass.shared.crypto.models.CryptoSuite
import com.skybridge.compass.shared.crypto.models.KeyPair
import com.skybridge.compass.shared.crypto.providers.AndroidPQCCryptoProvider
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.util.Locale

/**
 * Minimal device-runtime proof for the tracked liboqs -> JNI -> shipping-provider path.
 *
 * The host gate supplies an exact runtime profile. This test independently
 * verifies it inside the app process that loaded `libskybridge_pqc.so`, executes
 * both required algorithms through [AndroidPQCCryptoProvider], and emits only
 * fixed, non-secret result fields.
 */
@RunWith(AndroidJUnit4::class)
class NativePqcRuntimeInstrumentationTest {

    @Test
    fun appNativeProviderCompletesRequiredPqcOperations() = runBlocking {
        val expectation = RuntimeExpectation.fromInstrumentationArguments()
        val actualAbi = currentProcessAbi()
        val actualPageSize = Os.sysconf(OsConstants._SC_PAGESIZE)

        assertTrue("The native PQC gate requires a 64-bit process", Process.is64Bit())
        assertTrue(
            "Runtime API does not match the selected physical-gate profile",
            Build.VERSION.SDK_INT == expectation.apiLevel,
        )
        assertTrue(
            "Runtime page size does not match the selected physical-gate profile",
            actualPageSize == expectation.pageSizeBytes.toLong(),
        )
        assertTrue(
            "Runtime ABI does not match the selected physical-gate profile",
            actualAbi == expectation.abi && Build.SUPPORTED_ABIS.firstOrNull() == expectation.abi,
        )
        if (expectation.profile == SAMSUNG_API36_4K_PROFILE) {
            assertTrue(
                "The API 36 / 4K profile requires a physical Samsung runtime",
                Build.MANUFACTURER.equals("samsung", ignoreCase = true),
            )
        }

        assertTrue(
            "The tracked liboqs JNI provider did not load both required algorithms",
            AndroidPQCCryptoProvider.isAvailable(),
        )
        val provider = AndroidPQCCryptoProvider(CryptoSuite.ML_KEM_768_ML_DSA_65)
        assertTrue("Unexpected native PQC provider", provider.providerName == EXPECTED_PROVIDER)
        assertTrue("Unexpected native PQC tier", provider.tier == CryptoTier.LIBOQS_PQC)

        var kemKeyPair: KeyPair? = null
        var signingKeyPair: KeyPair? = null
        var ciphertext: ByteArray? = null
        var encapsulatedSecret: ByteArray? = null
        var decapsulatedSecret: ByteArray? = null
        var message: ByteArray? = null
        var alteredMessage: ByteArray? = null
        var signature: ByteArray? = null
        var alteredSignature: ByteArray? = null
        var kemSecretMatched = false
        var signatureVerified = false
        var alteredMessageRejected = false
        var alteredSignatureRejected = false
        var cleanupComplete = false

        try {
            val generatedKemKeyPair = provider.generateKeyPair(KeyUsage.KEY_EXCHANGE)
            kemKeyPair = generatedKemKeyPair
            val (generatedCiphertext, generatedEncapsulatedSecret) =
                provider.encapsulate(generatedKemKeyPair.publicKey.bytes)
            ciphertext = generatedCiphertext
            encapsulatedSecret = generatedEncapsulatedSecret
            val generatedDecapsulatedSecret = provider.decapsulate(
                ciphertext = generatedCiphertext,
                secretKey = generatedKemKeyPair.privateKey.bytes,
            )
            decapsulatedSecret = generatedDecapsulatedSecret
            kemSecretMatched = generatedEncapsulatedSecret.contentEquals(generatedDecapsulatedSecret)
            assertTrue("ML-KEM-768 encapsulation and decapsulation secrets differ", kemSecretMatched)

            val generatedSigningKeyPair = provider.generateKeyPair(KeyUsage.SIGNING)
            signingKeyPair = generatedSigningKeyPair
            val signingMessage =
                "SkyBridge native PQC physical runtime gate v1".toByteArray(Charsets.UTF_8)
            message = signingMessage
            val generatedSignature = provider.sign(
                signingMessage,
                generatedSigningKeyPair.privateKey.bytes,
            )
            signature = generatedSignature
            signatureVerified = provider.verify(
                signingMessage,
                generatedSignature,
                generatedSigningKeyPair.publicKey.bytes,
            )
            assertTrue("ML-DSA-65 positive verification failed", signatureVerified)

            val changedMessage = signingMessage.copyOf().also { bytes ->
                bytes[bytes.lastIndex] = (bytes.last().toInt() xor 0x01).toByte()
            }
            alteredMessage = changedMessage
            alteredMessageRejected = !provider.verify(
                changedMessage,
                generatedSignature,
                generatedSigningKeyPair.publicKey.bytes,
            )
            assertTrue("ML-DSA-65 accepted an altered message", alteredMessageRejected)

            val changedSignature = generatedSignature.copyOf().also { bytes ->
                bytes[bytes.lastIndex] = (bytes.last().toInt() xor 0x01).toByte()
            }
            alteredSignature = changedSignature
            alteredSignatureRejected = !provider.verify(
                signingMessage,
                changedSignature,
                generatedSigningKeyPair.publicKey.bytes,
            )
            assertTrue("ML-DSA-65 accepted an altered signature", alteredSignatureRejected)
        } finally {
            kemKeyPair?.clear()
            signingKeyPair?.clear()
            ciphertext?.fill(0)
            encapsulatedSecret?.fill(0)
            decapsulatedSecret?.fill(0)
            message?.fill(0)
            alteredMessage?.fill(0)
            signature?.fill(0)
            alteredSignature?.fill(0)
            cleanupComplete = listOfNotNull(
                kemKeyPair?.publicKey?.bytes,
                kemKeyPair?.privateKey?.bytes,
                signingKeyPair?.publicKey?.bytes,
                signingKeyPair?.privateKey?.bytes,
                ciphertext,
                encapsulatedSecret,
                decapsulatedSecret,
                message,
                alteredMessage,
                signature,
                alteredSignature,
            ).all { bytes -> bytes.all { it == 0.toByte() } }
        }

        assertTrue("PQC runtime test did not clear all retained byte buffers", cleanupComplete)
        val resultMarker = buildString {
            append(MARKER_PREFIX)
            append(" schema=1")
            append(" profile=").append(expectation.profile)
            append(" provider=").append(EXPECTED_PROVIDER)
            append(" api=").append(expectation.apiLevel)
            append(" abi=").append(actualAbi)
            append(" page_size=").append(actualPageSize)
            append(" native_load=true")
            append(" mlkem_keygen=true")
            append(" mlkem_encaps=true")
            append(" mlkem_decaps=true")
            append(" mlkem_secret_match=").append(kemSecretMatched)
            append(" mldsa_keygen=true")
            append(" mldsa_sign=true")
            append(" mldsa_verify=").append(signatureVerified)
            append(" mldsa_negative_message=").append(alteredMessageRejected)
            append(" mldsa_negative_signature=").append(alteredSignatureRejected)
            append(" cleanup=").append(cleanupComplete)
        }
        InstrumentationRegistry.getInstrumentation().sendStatus(
            RESULT_STATUS_CODE,
            Bundle().apply { putString(RESULT_STATUS_STREAM_KEY, resultMarker) },
        )
    }

    private data class RuntimeExpectation(
        val profile: String,
        val apiLevel: Int,
        val pageSizeBytes: Int,
        val abi: String,
    ) {
        companion object {
            fun fromInstrumentationArguments(): RuntimeExpectation {
                val arguments = InstrumentationRegistry.getArguments()
                val profile = arguments.requireString(ARG_PROFILE)
                val apiLevel = arguments.requireString(ARG_EXPECTED_API).toIntOrNull()
                    ?: throw IllegalArgumentException("$ARG_EXPECTED_API must be an integer")
                val pageSize = arguments.requireString(ARG_EXPECTED_PAGE_SIZE).toIntOrNull()
                    ?: throw IllegalArgumentException("$ARG_EXPECTED_PAGE_SIZE must be an integer")
                val abi = arguments.requireString(ARG_EXPECTED_ABI)
                val expectation = RuntimeExpectation(profile, apiLevel, pageSize, abi)
                require(expectation in ALLOWED_EXPECTATIONS) {
                    "Unsupported native PQC physical-gate runtime profile"
                }
                return expectation
            }
        }
    }

    companion object {
        private const val ARG_PROFILE = "skybridgePqcRuntimeProfile"
        private const val ARG_EXPECTED_API = "skybridgeExpectedApi"
        private const val ARG_EXPECTED_PAGE_SIZE = "skybridgeExpectedPageSize"
        private const val ARG_EXPECTED_ABI = "skybridgeExpectedAbi"
        private const val SAMSUNG_API36_4K_PROFILE = "samsung-api36-4k"
        private const val API37_16K_PROFILE = "api37-16k"
        private const val EXPECTED_PROVIDER = "liboqs-android"
        private const val MARKER_PREFIX = "SB-PQC-NATIVE-RUNTIME"
        private const val RESULT_STATUS_CODE = 2
        private const val RESULT_STATUS_STREAM_KEY = "stream"

        private val ALLOWED_EXPECTATIONS = setOf(
            RuntimeExpectation(SAMSUNG_API36_4K_PROFILE, 36, 4_096, "arm64-v8a"),
            RuntimeExpectation(API37_16K_PROFILE, 37, 16_384, "arm64-v8a"),
            RuntimeExpectation(API37_16K_PROFILE, 37, 16_384, "x86_64"),
        )

        private fun currentProcessAbi(): String = when (
            System.getProperty("os.arch")?.lowercase(Locale.US)
        ) {
            "aarch64", "arm64" -> "arm64-v8a"
            "amd64", "x86_64" -> "x86_64"
            else -> throw IllegalStateException("Unsupported 64-bit Android process ABI")
        }
    }
}

private fun android.os.Bundle.requireString(key: String): String = getString(key)
    ?.trim()
    ?.takeIf(String::isNotEmpty)
    ?: throw IllegalArgumentException("Missing instrumentation argument: $key")
