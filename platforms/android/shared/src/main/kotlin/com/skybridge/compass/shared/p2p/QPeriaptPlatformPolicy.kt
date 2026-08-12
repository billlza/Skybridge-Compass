package com.skybridge.compass.shared.p2p

import com.skybridge.compass.shared.platform.AndroidPlatformMetadata

/**
 * Fail-closed platform admission for the experimental Q-Periapt suite.
 *
 * Q-Periapt is self-developed and not yet part of the production suite set. Keep its platform
 * boundary explicit so a valid-looking key from an unsupported or ambiguous peer cannot make the
 * handshake select the beta suite.
 */
object QPeriaptPlatformPolicy {
    const val AUTH_PROFILE: String = "q-periapt-beta"

    private const val MIN_ANDROID_RELEASE_MAJOR = 16
    private const val MIN_ANDROID_API = 36
    private const val MIN_APPLE_MAJOR = 26

    fun androidPlatformVersion(release: String?, sdkInt: Int): String {
        return AndroidPlatformMetadata.versionString(release = release, sdkInt = sdkInt)
    }

    fun androidHandshakePlatformVersion(release: String?, sdkInt: Int): String {
        return androidPlatformVersion(release = release, sdkInt = sdkInt)
    }

    fun requireLocalAndroidSupported(platformVersion: String) {
        require(isLocalAndroidSupported(platformVersion)) {
            "Q-Periapt requires local Android 16+ / API 36+, actual=$platformVersion"
        }
    }

    fun isLocalAndroidSupported(platformVersion: String): Boolean {
        val parsed = parse(platformVersion, platformHint = null, allowBareAndroidVersion = false)
        return parsed is PlatformVersion.Android && parsed.isSupported
    }

    fun isHandshakePeerEligible(capabilities: P2PCryptoCapabilities): Boolean =
        capabilities.pqcAvailable &&
            capabilities.supportedKEM.any {
                canonicalCapabilityToken(it) == canonicalCapabilityToken(P2PQPeriaptKem.KEM_CAPABILITY_NAME) ||
                    canonicalCapabilityToken(it) == canonicalCapabilityToken(P2PHandshakeWire.PROVIDER_TYPE_QPERIAPT)
            } &&
            capabilities.supportedSignature.any {
                canonicalCapabilityToken(it) == canonicalCapabilityToken("ml-dsa-65")
            } &&
            capabilities.supportedAuthProfiles.any {
                canonicalCapabilityToken(it) == canonicalCapabilityToken(AUTH_PROFILE)
            } &&
            capabilities.providerTypeRaw == P2PHandshakeWire.PROVIDER_TYPE_QPERIAPT &&
            isExplicitPeerPlatformSupported(capabilities.platformVersion)

    fun requireHandshakePeerEligible(capabilities: P2PCryptoCapabilities, peerRole: String) {
        require(isHandshakePeerEligible(capabilities)) {
            "Q-Periapt $peerRole platform unsupported or ambiguous: platformVersion=${capabilities.platformVersion}, authProfiles=${capabilities.supportedAuthProfiles}"
        }
    }

    fun isAppPeerEligible(platform: String?, osVersion: String?): Boolean {
        val combined = listOfNotNull(
            platform?.trim()?.takeIf { it.isNotEmpty() },
            osVersion?.trim()?.takeIf { it.isNotEmpty() }
        ).joinToString(" ")
        return isExplicitPeerPlatformSupported(combined)
    }

    fun requireAppPeerEligible(platform: String?, osVersion: String?) {
        require(isAppPeerEligible(platform, osVersion)) {
            "Q-Periapt peer key requires macOS 26+, iOS 26+, or Android 16+ / API 36+; platform=${platform.orEmpty()}, osVersion=${osVersion.orEmpty()}"
        }
    }

    private fun isExplicitPeerPlatformSupported(value: String): Boolean =
        when (val parsed = parse(value, platformHint = null, allowBareAndroidVersion = false)) {
            is PlatformVersion.Android -> parsed.isSupported
            is PlatformVersion.Apple -> parsed.isSupported
            PlatformVersion.Unsupported -> false
        }

    private fun canonicalCapabilityToken(value: String): String =
        value.trim().lowercase().filter { it in 'a'..'z' || it in '0'..'9' }

    private fun parse(
        value: String,
        platformHint: String?,
        allowBareAndroidVersion: Boolean
    ): PlatformVersion {
        val normalized = value.trim()
        if (normalized.isEmpty()) return PlatformVersion.Unsupported
        val lower = listOfNotNull(platformHint, normalized)
            .joinToString(" ")
            .lowercase()

        val isAndroid = lower.contains("android") || lower.contains("api ")
        if (isAndroid) {
            val api = Regex("""\bapi\s*(\d{1,3})\b""")
                .find(lower)
                ?.groupValues
                ?.getOrNull(1)
                ?.toIntOrNull()
            val release = androidReleaseMajor(lower)
            return PlatformVersion.Android(
                releaseMajor = release,
                api = api
            )
        }

        val isMac = lower.contains("macos") || lower.contains("mac os")
        if (isMac) {
            return PlatformVersion.Apple(name = "macOS", major = firstMajor(normalized))
        }

        val isIos = Regex("""\bios\b""").containsMatchIn(lower)
        if (isIos) {
            return PlatformVersion.Apple(name = "iOS", major = firstMajor(normalized))
        }

        if (allowBareAndroidVersion) {
            return PlatformVersion.Android(releaseMajor = firstMajor(normalized), api = null)
        }

        return PlatformVersion.Unsupported
    }

    private fun firstMajor(value: String): Int? =
        Regex("""\d{1,3}""").find(value)?.value?.toIntOrNull()

    private fun androidReleaseMajor(lower: String): Int? =
        Regex("""\bandroid\s+(\d{1,3})\b""")
            .find(lower)
            ?.groupValues
            ?.getOrNull(1)
            ?.toIntOrNull()

    private sealed interface PlatformVersion {
        data class Android(val releaseMajor: Int?, val api: Int?) : PlatformVersion {
            val isSupported: Boolean
                get() = (releaseMajor != null && releaseMajor >= MIN_ANDROID_RELEASE_MAJOR) &&
                    (api != null && api >= MIN_ANDROID_API)
        }

        data class Apple(val name: String, val major: Int?) : PlatformVersion {
            val isSupported: Boolean
                get() = major != null && major >= MIN_APPLE_MAJOR
        }

        data object Unsupported : PlatformVersion
    }
}
