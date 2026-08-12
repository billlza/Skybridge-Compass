package com.skybridge.compass.shared.crypto

import org.bouncycastle.jce.provider.BouncyCastleProvider
import java.security.GeneralSecurityException
import java.security.InvalidKeyException
import java.security.KeyFactory
import java.security.Provider
import java.security.ProviderException
import java.security.Security
import java.security.Signature
import java.security.SignatureException
import java.security.spec.InvalidKeySpecException
import java.security.spec.X509EncodedKeySpec

/**
 * Verifies raw Ed25519 protocol identities with software JCA providers only.
 *
 * Protocol identity keys are the 32-byte RFC 8032 encoding used by CryptoKit. JCA consumes the
 * equivalent RFC 8410 SubjectPublicKeyInfo wrapper. AndroidKeyStore is deliberately excluded from
 * both key decoding and signature verification: remote public keys are not keystore-backed keys,
 * and silently selecting that provider makes verification device/provider-order dependent.
 */
object Ed25519SoftwareVerifier {
    private const val RAW_PUBLIC_KEY_BYTES: Int = 32
    private const val SIGNATURE_BYTES: Int = 64

    sealed class Failure(message: String, cause: Throwable? = null) : GeneralSecurityException(message, cause) {
        class InvalidInputLength(
            val field: String,
            val expectedBytes: Int,
            val actualBytes: Int
        ) : Failure("Ed25519 $field must be $expectedBytes bytes (was $actualBytes)")

        class SoftwareProviderUnavailable(val service: String) :
            Failure("No non-AndroidKeyStore Ed25519 provider is available for $service")

        class InvalidPublicKey(cause: Throwable) :
            Failure("Ed25519 public key could not be decoded", cause)

        class ProviderOperationFailed(cause: Throwable) :
            Failure("Every non-AndroidKeyStore Ed25519 provider rejected verification setup", cause)
    }

    /**
     * @return `false` only when a well-formed signature does not authenticate [message].
     * @throws Failure for malformed input or unavailable/broken provider infrastructure.
     */
    fun verify(message: ByteArray, signature: ByteArray, rawPublicKey: ByteArray): Boolean =
        verifyWithCatalog(message, signature, rawPublicKey, SystemProviderCatalog)

    internal fun verifyWithCatalog(
        message: ByteArray,
        signature: ByteArray,
        rawPublicKey: ByteArray,
        providerCatalog: ProviderCatalog
    ): Boolean {
        validateLength("public key", RAW_PUBLIC_KEY_BYTES, rawPublicKey.size)
        validateLength("signature", SIGNATURE_BYTES, signature.size)

        val keyFactories = engines(
            providers = softwareProviders(providerCatalog.providersFor(KEY_FACTORY_FILTER)),
            service = KEY_FACTORY_FILTER,
            create = { provider -> KeyFactory.getInstance(ALGORITHM, provider) }
        )
        val publicKeySpec = X509EncodedKeySpec(
            Ed25519PublicKeyEncoding.toRfc8410SubjectPublicKeyInfo(rawPublicKey)
        )
        var lastKeyFailure: Throwable? = null
        val publicKeys = keyFactories.mapNotNull { keyFactory ->
            try {
                keyFactory.generatePublic(publicKeySpec)
            } catch (failure: InvalidKeySpecException) {
                lastKeyFailure = failure
                null
            } catch (failure: ProviderException) {
                lastKeyFailure = failure
                null
            }
        }
        if (publicKeys.isEmpty()) {
            throw Failure.InvalidPublicKey(
                lastKeyFailure ?: InvalidKeySpecException("No Ed25519 KeyFactory accepted the RFC 8410 key")
            )
        }

        val signatures = engines(
            providers = softwareProviders(providerCatalog.providersFor(SIGNATURE_FILTER)),
            service = SIGNATURE_FILTER,
            create = { provider -> Signature.getInstance(ALGORITHM, provider) }
        )
        var lastSetupFailure: Throwable? = null
        signatures.forEach { verifier ->
            publicKeys.forEach { publicKey ->
                try {
                    verifier.initVerify(publicKey)
                    verifier.update(message)
                    return try {
                        verifier.verify(signature)
                    } catch (_: SignatureException) {
                        false
                    }
                } catch (failure: InvalidKeyException) {
                    lastSetupFailure = failure
                } catch (failure: SignatureException) {
                    lastSetupFailure = failure
                } catch (failure: ProviderException) {
                    lastSetupFailure = failure
                }
            }
        }
        throw Failure.ProviderOperationFailed(
            lastSetupFailure ?: ProviderException("No Ed25519 Signature provider accepted a decoded public key")
        )
    }

    private fun validateLength(field: String, expected: Int, actual: Int) {
        if (actual != expected) {
            throw Failure.InvalidInputLength(field, expected, actual)
        }
    }

    private fun softwareProviders(providers: List<Provider>): List<Provider> =
        providers
            .filterNot(::isAndroidKeyStore)
            .distinctBy { provider -> provider.name to provider::class.java.name }

    private fun <T> engines(
        providers: List<Provider>,
        service: String,
        create: (Provider) -> T
    ): List<T> {
        val engines = providers.mapNotNull { provider ->
            try {
                create(provider)
            } catch (_: GeneralSecurityException) {
                null
            } catch (_: ProviderException) {
                null
            }
        }
        if (engines.isEmpty()) {
            throw Failure.SoftwareProviderUnavailable(service)
        }
        return engines
    }

    private fun isAndroidKeyStore(provider: Provider): Boolean =
        provider.name.contains(ANDROID_KEYSTORE_PROVIDER_TOKEN, ignoreCase = true)

    internal fun interface ProviderCatalog {
        fun providersFor(filter: String): List<Provider>
    }

    private object SystemProviderCatalog : ProviderCatalog {
        private val bundledBouncyCastle: Provider? by lazy {
            constructOptionalBundledProvider(::BouncyCastleProvider)
        }

        override fun providersFor(filter: String): List<Provider> = buildList {
            // Keep verification independent from device provider registration order. The bundled
            // provider is a known software implementation and is therefore always attempted first.
            bundledBouncyCastle?.let(::add)
            PREFERRED_INSTALLED_PROVIDERS.forEach { name ->
                Security.getProvider(name)?.let(::add)
            }
            Security.getProviders(filter).orEmpty()
                .sortedBy { provider -> provider.name }
                .forEach(::add)
        }
    }

    internal fun constructOptionalBundledProvider(factory: () -> Provider): Provider? = try {
        factory()
    } catch (_: RuntimeException) {
        null
    } catch (_: LinkageError) {
        null
    }

    private const val ALGORITHM = "Ed25519"
    private const val KEY_FACTORY_FILTER = "KeyFactory.Ed25519"
    private const val SIGNATURE_FILTER = "Signature.Ed25519"
    private const val ANDROID_KEYSTORE_PROVIDER_TOKEN = "AndroidKeyStore"
    private val PREFERRED_INSTALLED_PROVIDERS = listOf("Conscrypt", "AndroidOpenSSL", "BC")
}
