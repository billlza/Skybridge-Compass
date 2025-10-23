package com.yunqiao.sinan.manager

import java.util.Locale
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

enum class BridgeDevicePlatform {
    ANDROID,
    IOS,
    IPADOS,
    MAC,
    WINDOWS,
    LINUX,
    CHROME_OS,
    UNKNOWN
}

data class BridgeCompatibilityProfile(
    val platform: BridgeDevicePlatform,
    val supportedTransports: Set<BridgeTransportHint>,
    val supportsNearField: Boolean,
    val supportsCloudRelay: Boolean,
    val supportsUniversalBridge: Boolean,
    val remark: String
)

class CrossPlatformCompatibilityManager {

    private val matrix = buildMatrix()
    private val _profiles = MutableStateFlow(matrix)
    val profiles: StateFlow<Map<BridgeDevicePlatform, BridgeCompatibilityProfile>> = _profiles.asStateFlow()

    fun resolvePlatform(deviceName: String?, model: String?): BridgeDevicePlatform {
        val normalized = normalizedCandidate(deviceName, model) ?: return BridgeDevicePlatform.UNKNOWN
        if (isHarmonyCandidate(normalized)) {
            return BridgeDevicePlatform.UNKNOWN
        }
        return when {
            normalized.contains("ipad") -> BridgeDevicePlatform.IPADOS
            normalized.contains("iphone") || normalized.contains("ios") -> BridgeDevicePlatform.IOS
            normalized.contains("mac") || normalized.contains("imac") || normalized.contains("macbook") -> BridgeDevicePlatform.MAC
            normalized.contains("windows") || normalized.contains("win32") || normalized.contains("win64") -> BridgeDevicePlatform.WINDOWS
            normalized.contains("linux") || normalized.contains("ubuntu") || normalized.contains("debian") || normalized.contains("arch") -> BridgeDevicePlatform.LINUX
            normalized.contains("chrome") || normalized.contains("chromebook") -> BridgeDevicePlatform.CHROME_OS
            normalized.contains("android") || normalized.contains("pixel") || normalized.contains("galaxy") -> BridgeDevicePlatform.ANDROID
            else -> BridgeDevicePlatform.UNKNOWN
        }
    }

    fun shouldExclude(deviceName: String?, model: String?): Boolean {
        val normalized = normalizedCandidate(deviceName, model) ?: return false
        return isHarmonyCandidate(normalized)
    }

    fun isSupported(platform: BridgeDevicePlatform): Boolean {
        return platform != BridgeDevicePlatform.UNKNOWN
    }

    fun transportsFor(platform: BridgeDevicePlatform): Set<BridgeTransportHint> {
        return matrix[platform]?.supportedTransports ?: emptySet()
    }

    fun remarkFor(platform: BridgeDevicePlatform): String {
        return matrix[platform]?.remark ?: ""
    }

    private fun normalizedCandidate(deviceName: String?, model: String?): String? {
        return sequenceOf(deviceName, model)
            .filterNotNull()
            .map { it.trim() }
            .firstOrNull { it.isNotEmpty() }
            ?.lowercase(Locale.US)
    }

    private fun isHarmonyCandidate(normalized: String): Boolean {
        return normalized.contains("harmony") || normalized.contains("hongmeng")
    }

    private fun buildMatrix(): Map<BridgeDevicePlatform, BridgeCompatibilityProfile> {
        val universal = setOf(
            BridgeTransportHint.WifiDirect,
            BridgeTransportHint.Lan,
            BridgeTransportHint.Cloud,
            BridgeTransportHint.Bluetooth,
            BridgeTransportHint.Nfc,
            BridgeTransportHint.AirPlay,
            BridgeTransportHint.UltraWideband
        )
        val universalBridge = universal + BridgeTransportHint.UniversalBridge
        return mapOf(
            BridgeDevicePlatform.ANDROID to BridgeCompatibilityProfile(
                platform = BridgeDevicePlatform.ANDROID,
                supportedTransports = universalBridge,
                supportsNearField = true,
                supportsCloudRelay = true,
                supportsUniversalBridge = true,
                remark = "安卓端全协议互联"
            ),
            BridgeDevicePlatform.IOS to BridgeCompatibilityProfile(
                platform = BridgeDevicePlatform.IOS,
                supportedTransports = setOf(
                    BridgeTransportHint.Bluetooth,
                    BridgeTransportHint.Nfc,
                    BridgeTransportHint.AirPlay,
                    BridgeTransportHint.UniversalBridge
                ),
                supportsNearField = true,
                supportsCloudRelay = true,
                supportsUniversalBridge = true,
                remark = "iPhone 硬件级投屏"
            ),
            BridgeDevicePlatform.IPADOS to BridgeCompatibilityProfile(
                platform = BridgeDevicePlatform.IPADOS,
                supportedTransports = setOf(
                    BridgeTransportHint.WifiDirect,
                    BridgeTransportHint.AirPlay,
                    BridgeTransportHint.UniversalBridge
                ),
                supportsNearField = true,
                supportsCloudRelay = true,
                supportsUniversalBridge = true,
                remark = "iPad 多屏协作"
            ),
            BridgeDevicePlatform.MAC to BridgeCompatibilityProfile(
                platform = BridgeDevicePlatform.MAC,
                supportedTransports = setOf(
                    BridgeTransportHint.Lan,
                    BridgeTransportHint.Cloud,
                    BridgeTransportHint.AirPlay,
                    BridgeTransportHint.UniversalBridge
                ),
                supportsNearField = true,
                supportsCloudRelay = true,
                supportsUniversalBridge = true,
                remark = "macOS 桥接"
            ),
            BridgeDevicePlatform.WINDOWS to BridgeCompatibilityProfile(
                platform = BridgeDevicePlatform.WINDOWS,
                supportedTransports = setOf(
                    BridgeTransportHint.Lan,
                    BridgeTransportHint.Cloud,
                    BridgeTransportHint.WifiDirect,
                    BridgeTransportHint.UniversalBridge
                ),
                supportsNearField = true,
                supportsCloudRelay = true,
                supportsUniversalBridge = true,
                remark = "Windows 互传"
            ),
            BridgeDevicePlatform.LINUX to BridgeCompatibilityProfile(
                platform = BridgeDevicePlatform.LINUX,
                supportedTransports = setOf(
                    BridgeTransportHint.Lan,
                    BridgeTransportHint.Cloud,
                    BridgeTransportHint.Bluetooth,
                    BridgeTransportHint.UniversalBridge
                ),
                supportsNearField = true,
                supportsCloudRelay = true,
                supportsUniversalBridge = true,
                remark = "Linux 全面适配"
            ),
            BridgeDevicePlatform.CHROME_OS to BridgeCompatibilityProfile(
                platform = BridgeDevicePlatform.CHROME_OS,
                supportedTransports = setOf(
                    BridgeTransportHint.WifiDirect,
                    BridgeTransportHint.Cloud,
                    BridgeTransportHint.UniversalBridge
                ),
                supportsNearField = true,
                supportsCloudRelay = true,
                supportsUniversalBridge = true,
                remark = "ChromeOS 快速接力"
            )
        )
    }
}

