package com.skybridge.compass.shared.crypto

import android.os.Build
import com.skybridge.compass.shared.crypto.models.CryptoSuite
import com.skybridge.compass.shared.crypto.providers.ClassicCryptoProvider

/**
 * Factory for creating CryptoProvider instances based on suite and platform capabilities.
 * 
 * Provider selection priority:
 * 1. AndroidPQCCryptoProvider (liboqs) - for PQC suites when available
 * 2. BouncyCastlePQCProvider - for PQC suites when liboqs unavailable
 * 3. ClassicCryptoProvider - for classic suites or as fallback
 * 
 * This factory ensures the most capable provider is selected for each suite
 * while gracefully falling back when preferred providers are unavailable.
 */
object CryptoProviderFactory {

    /**
     * Crypto policy eras (per project requirements):
     * - Android 13 (API 33, ~2022): Classic only
     * - Android 14–15 (API 34–35, ~2023–2024): liboqs PQC (ML-KEM) preferred
     * - Android 16–17 (API 36–37, ~2025–2026): X-Wing (hybrid) + PQC preferred
     */
    private enum class CryptoEra {
        ClassicOnly,
        LiboqsPreferred,
        XWingPreferred
    }

    private fun currentEra(): CryptoEra {
        val sdk = try {
            Build.VERSION.SDK_INT
        } catch (_: Throwable) {
            // Unit tests or non-Android runtime: keep existing "prefer PQC/hybrid" behavior.
            return CryptoEra.XWingPreferred
        }

        return when (sdk) {
            in 0..33 -> CryptoEra.ClassicOnly
            in 34..35 -> CryptoEra.LiboqsPreferred
            else -> CryptoEra.XWingPreferred
        }
    }

    private fun isSuiteAllowedByEra(suite: CryptoSuite, era: CryptoEra): Boolean {
        return when (era) {
            CryptoEra.ClassicOnly -> !suite.isPQC
            CryptoEra.LiboqsPreferred -> suite != CryptoSuite.X_WING_ML_DSA
            CryptoEra.XWingPreferred -> true
        }
    }
    
    /**
     * Creates a CryptoProvider for the specified suite.
     * 
     * Selection logic:
     * - For PQC suites (isPQC = true):
     *   1. Try AndroidPQCCryptoProvider if available
     *   2. Try BouncyCastlePQCProvider if available
     *   3. Throw CryptoProviderUnavailableException if no PQC provider available
     * - For classic suites (isPQC = false):
     *   1. Use ClassicCryptoProvider
     * 
     * @param suite The CryptoSuite to create a provider for
     * @return A CryptoProvider capable of handling the suite
     * @throws CryptoProviderUnavailableException if no suitable provider is available
     */
    fun createProvider(suite: CryptoSuite): CryptoProvider {
        val era = currentEra()
        if (!isSuiteAllowedByEra(suite, era)) {
            throw CryptoProviderUnavailableException(
                provider = "Policy",
                message = "Suite not allowed by platform policy: ${suite.rawValue} (era=$era)"
            )
        }

        return when {
            suite.isPQC && isAndroidPQCProviderAvailable() -> {
                createAndroidPQCProvider(suite)
            }
            suite.isPQC && isBouncyCastlePQCProviderAvailable() -> {
                createBouncyCastlePQCProvider(suite)
            }
            suite.isPQC -> {
                throw CryptoProviderUnavailableException(
                    provider = "PQC",
                    message = "No PQC provider available for suite: ${suite.rawValue}"
                )
            }
            else -> {
                ClassicCryptoProvider(suite)
            }
        }
    }
    
    /**
     * Returns a list of all CryptoSuites supported on this platform.
     * 
     * The list is ordered by preference (highest security first):
     * 1. ML-KEM-768 + ML-DSA-65 (if PQC available)
     * 2. X-Wing + ML-DSA (if PQC available)
     * 3. X25519 + Ed25519
     * 4. P-256 + ECDSA
     * 
     * @return List of supported CryptoSuites in priority order
     */
    fun getSupportedSuites(): List<CryptoSuite> {
        val suites = mutableListOf<CryptoSuite>()

        val era = currentEra()

        // Add PQC suites if allowed and any PQC provider is available.
        if (isPQCAvailable()) {
            when (era) {
                CryptoEra.ClassicOnly -> Unit
                CryptoEra.LiboqsPreferred -> {
                    suites.add(CryptoSuite.ML_KEM_768_ML_DSA_65)
                }
                CryptoEra.XWingPreferred -> {
                    // Prefer hybrid suite first on 2025–2026 devices.
                    suites.add(CryptoSuite.X_WING_ML_DSA)
                    suites.add(CryptoSuite.ML_KEM_768_ML_DSA_65)
                }
            }
        }
        
        // Classic suites are always available
        suites.add(CryptoSuite.X25519_ED25519)
        suites.add(CryptoSuite.P256_ECDSA)
        
        return suites
    }
    
    /**
     * Checks if any PQC provider is available on this platform.
     * 
     * @return true if either AndroidPQCCryptoProvider or BouncyCastlePQCProvider is available
     */
    fun isPQCAvailable(): Boolean {
        val era = currentEra()
        if (era == CryptoEra.ClassicOnly) return false
        return isAndroidPQCProviderAvailable() || isBouncyCastlePQCProviderAvailable()
    }
    
    /**
     * Returns the highest tier available for the given suite.
     * 
     * @param suite The CryptoSuite to check
     * @return The CryptoTier of the best available provider for this suite
     */
    fun getAvailableTier(suite: CryptoSuite): CryptoTier {
        val era = currentEra()
        if (!isSuiteAllowedByEra(suite, era)) return CryptoTier.CLASSIC

        return when {
            suite.isPQC && isAndroidPQCProviderAvailable() -> CryptoTier.LIBOQS_PQC
            suite.isPQC && isBouncyCastlePQCProviderAvailable() -> CryptoTier.BOUNCY_CASTLE_PQC
            !suite.isPQC -> CryptoTier.CLASSIC
            else -> CryptoTier.CLASSIC // Fallback
        }
    }
    
    /**
     * Checks if AndroidPQCCryptoProvider (liboqs) is available.
     * 
     * This checks if the native liboqs library can be loaded.
     */
    private fun isAndroidPQCProviderAvailable(): Boolean {
        return try {
            // Try to check if AndroidPQCCryptoProvider.isAvailable() returns true
            // This will be implemented when AndroidPQCCryptoProvider is created
            AndroidPQCProviderChecker.isAvailable()
        } catch (e: Exception) {
            false
        }
    }
    
    /**
     * Checks if BouncyCastlePQCProvider is available.
     * 
     * This checks if BouncyCastle PQC classes are on the classpath.
     */
    private fun isBouncyCastlePQCProviderAvailable(): Boolean {
        return try {
            // Try to check if BouncyCastlePQCProvider.isAvailable() returns true
            // This will be implemented when BouncyCastlePQCProvider is created
            BouncyCastlePQCProviderChecker.isAvailable()
        } catch (e: Exception) {
            false
        }
    }
    
    /**
     * Creates an AndroidPQCCryptoProvider instance.
     * This is separated to allow for lazy loading of the provider class.
     */
    private fun createAndroidPQCProvider(suite: CryptoSuite): CryptoProvider {
        return AndroidPQCProviderChecker.createProvider(suite)
    }
    
    /**
     * Creates a BouncyCastlePQCProvider instance.
     * This is separated to allow for lazy loading of the provider class.
     */
    private fun createBouncyCastlePQCProvider(suite: CryptoSuite): CryptoProvider {
        return BouncyCastlePQCProviderChecker.createProvider(suite)
    }
}

/**
 * Helper object to check AndroidPQCCryptoProvider availability without
 * directly referencing the class (which may not exist yet).
 */
internal object AndroidPQCProviderChecker {
    private var available: Boolean? = null
    
    fun isAvailable(): Boolean {
        if (available == null) {
            available = try {
                // Check if native library is loadable
                // This will be updated when AndroidPQCCryptoProvider is implemented
                Class.forName("com.skybridge.compass.shared.crypto.providers.AndroidPQCCryptoProvider")
                    .getMethod("isAvailable")
                    .invoke(null) as Boolean
            } catch (e: Exception) {
                false
            }
        }
        return available!!
    }
    
    fun createProvider(suite: CryptoSuite): CryptoProvider {
        val clazz = Class.forName("com.skybridge.compass.shared.crypto.providers.AndroidPQCCryptoProvider")
        val constructor = clazz.getConstructor(CryptoSuite::class.java)
        return constructor.newInstance(suite) as CryptoProvider
    }
}

/**
 * Helper object to check BouncyCastlePQCProvider availability without
 * directly referencing the class (which may not exist yet).
 */
internal object BouncyCastlePQCProviderChecker {
    private var available: Boolean? = null
    
    fun isAvailable(): Boolean {
        if (available == null) {
            available = try {
                // Check if BouncyCastle PQC classes are available
                Class.forName("com.skybridge.compass.shared.crypto.providers.BouncyCastlePQCProvider")
                    .getMethod("isAvailable")
                    .invoke(null) as Boolean
            } catch (e: Exception) {
                false
            }
        }
        return available!!
    }
    
    fun createProvider(suite: CryptoSuite): CryptoProvider {
        val clazz = Class.forName("com.skybridge.compass.shared.crypto.providers.BouncyCastlePQCProvider")
        val constructor = clazz.getConstructor(CryptoSuite::class.java)
        return constructor.newInstance(suite) as CryptoProvider
    }
}
