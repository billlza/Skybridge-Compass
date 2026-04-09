package com.skybridge.compass.screenmirroring.negotiation

import com.skybridge.compass.core.utils.Logger
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

/**
 * 设备能力描述
 */
@Serializable
data class DeviceCapabilities(
    val deviceId: String,
    val deviceName: String,
    val platform: String, // "android", "macos", "ios", "windows"
    
    // 支持的分辨率
    val supportedResolutions: List<Resolution>,
    val maxResolution: Resolution,
    val nativeResolution: Resolution,
    
    // 支持的帧率
    val supportedFrameRates: List<Int>,
    val maxFrameRate: Int,
    
    // 支持的编码格式
    val supportedCodecs: List<String>, // "h264", "h265", "vp8", "vp9", "jpeg"
    val preferredCodec: String,
    
    // 硬件能力
    val hasHardwareEncoder: Boolean,
    val hasHardwareDecoder: Boolean,
    
    // 比特率范围
    val minBitrate: Int,
    val maxBitrate: Int,
    val recommendedBitrate: Int
) {
    fun toJson(): String = Json.encodeToString(this)
    
    companion object {
        fun fromJson(json: String): DeviceCapabilities = Json.decodeFromString(json)
    }
}

/**
 * 分辨率
 */
@Serializable
data class Resolution(
    val width: Int,
    val height: Int
) {
    val pixels: Int get() = width * height
    
    fun isWithin(other: Resolution): Boolean {
        return width <= other.width && height <= other.height
    }
    
    companion object {
        val HD = Resolution(1280, 720)
        val FHD = Resolution(1920, 1080)
        val QHD = Resolution(2560, 1440)
        val UHD = Resolution(3840, 2160)
    }
}

/**
 * 协商后的参数
 */
@Serializable
data class NegotiatedParameters(
    val resolution: Resolution,
    val frameRate: Int,
    val codec: String,
    val bitrate: Int,
    val useHardwareEncoder: Boolean,
    val useHardwareDecoder: Boolean
) {
    fun toJson(): String = Json.encodeToString(this)
    
    companion object {
        fun fromJson(json: String): NegotiatedParameters = Json.decodeFromString(json)
    }
}

/**
 * 参数协商器
 * 负责在两个设备之间协商最佳的屏幕镜像参数
 */
class ParameterNegotiator {
    
    companion object {
        private const val TAG = "ParameterNegotiator"
    }
    
    /**
     * 协商参数
     * 
     * @param localCapabilities 本地设备能力
     * @param remoteCapabilities 远程设备能力
     * @return 协商后的参数
     */
    fun negotiate(
        localCapabilities: DeviceCapabilities,
        remoteCapabilities: DeviceCapabilities
    ): NegotiatedParameters {
        Logger.screenMirroring("开始参数协商")
        Logger.screenMirroring("本地设备: ${localCapabilities.deviceName}")
        Logger.screenMirroring("远程设备: ${remoteCapabilities.deviceName}")
        
        // 1. 协商分辨率
        val resolution = negotiateResolution(localCapabilities, remoteCapabilities)
        Logger.screenMirroring("协商分辨率: ${resolution.width}x${resolution.height}")
        
        // 2. 协商帧率
        val frameRate = negotiateFrameRate(localCapabilities, remoteCapabilities)
        Logger.screenMirroring("协商帧率: ${frameRate}fps")
        
        // 3. 协商编码格式
        val codec = negotiateCodec(localCapabilities, remoteCapabilities)
        Logger.screenMirroring("协商编码格式: $codec")
        
        // 4. 协商比特率
        val bitrate = negotiateBitrate(localCapabilities, remoteCapabilities, resolution, frameRate)
        Logger.screenMirroring("协商比特率: ${bitrate / 1000}kbps")
        
        // 5. 确定是否使用硬件编解码
        val useHardwareEncoder = localCapabilities.hasHardwareEncoder && codec != "jpeg"
        val useHardwareDecoder = remoteCapabilities.hasHardwareDecoder && codec != "jpeg"
        
        return NegotiatedParameters(
            resolution = resolution,
            frameRate = frameRate,
            codec = codec,
            bitrate = bitrate,
            useHardwareEncoder = useHardwareEncoder,
            useHardwareDecoder = useHardwareDecoder
        )
    }
    
    /**
     * 协商分辨率
     * 选择两个设备都支持的最高分辨率
     */
    private fun negotiateResolution(
        local: DeviceCapabilities,
        remote: DeviceCapabilities
    ): Resolution {
        // 找到两个设备都支持的分辨率
        val commonResolutions = local.supportedResolutions.filter { localRes ->
            remote.supportedResolutions.any { remoteRes ->
                localRes.width == remoteRes.width && localRes.height == remoteRes.height
            }
        }
        
        if (commonResolutions.isNotEmpty()) {
            // 选择最高的公共分辨率
            return commonResolutions.maxByOrNull { it.pixels } ?: Resolution.HD
        }
        
        // 如果没有公共分辨率，选择两者最大分辨率中较小的那个
        val maxLocal = local.maxResolution
        val maxRemote = remote.maxResolution
        
        return if (maxLocal.pixels <= maxRemote.pixels) {
            maxLocal
        } else {
            maxRemote
        }
    }
    
    /**
     * 协商帧率
     * 选择两个设备都支持的最高帧率
     */
    private fun negotiateFrameRate(
        local: DeviceCapabilities,
        remote: DeviceCapabilities
    ): Int {
        val commonFrameRates = local.supportedFrameRates.filter { 
            remote.supportedFrameRates.contains(it) 
        }
        
        if (commonFrameRates.isNotEmpty()) {
            return commonFrameRates.maxOrNull() ?: 30
        }
        
        // 选择两者最大帧率中较小的那个
        return minOf(local.maxFrameRate, remote.maxFrameRate)
    }
    
    /**
     * 协商编码格式
     * 优先选择硬件支持的格式
     */
    private fun negotiateCodec(
        local: DeviceCapabilities,
        remote: DeviceCapabilities
    ): String {
        // 优先级：h265 > h264 > vp9 > vp8 > jpeg
        val codecPriority = listOf("h265", "h264", "vp9", "vp8", "jpeg")
        
        val commonCodecs = local.supportedCodecs.filter { 
            remote.supportedCodecs.contains(it) 
        }
        
        if (commonCodecs.isEmpty()) {
            // 如果没有公共编码格式，使用 JPEG 作为后备
            return "jpeg"
        }
        
        // 按优先级选择
        for (codec in codecPriority) {
            if (commonCodecs.contains(codec)) {
                return codec
            }
        }
        
        return commonCodecs.first()
    }
    
    /**
     * 协商比特率
     * 根据分辨率和帧率计算合适的比特率
     */
    private fun negotiateBitrate(
        local: DeviceCapabilities,
        remote: DeviceCapabilities,
        resolution: Resolution,
        frameRate: Int
    ): Int {
        // 基于分辨率和帧率计算推荐比特率
        val pixelsPerSecond = resolution.pixels.toLong() * frameRate
        
        // 每像素约 0.1-0.2 比特（压缩后）
        val calculatedBitrate = (pixelsPerSecond * 0.15).toInt()
        
        // 限制在两个设备支持的范围内
        val minBitrate = maxOf(local.minBitrate, remote.minBitrate)
        val maxBitrate = minOf(local.maxBitrate, remote.maxBitrate)
        
        return calculatedBitrate.coerceIn(minBitrate, maxBitrate)
    }
    
    /**
     * 创建 Android 设备的默认能力描述
     */
    fun createAndroidCapabilities(
        deviceId: String,
        deviceName: String,
        screenWidth: Int,
        screenHeight: Int,
        hasHardwareEncoder: Boolean
    ): DeviceCapabilities {
        val nativeResolution = Resolution(screenWidth, screenHeight)
        
        val supportedResolutions = mutableListOf<Resolution>()
        
        // 添加常见分辨率（不超过原生分辨率）
        if (Resolution.UHD.isWithin(nativeResolution)) supportedResolutions.add(Resolution.UHD)
        if (Resolution.QHD.isWithin(nativeResolution)) supportedResolutions.add(Resolution.QHD)
        if (Resolution.FHD.isWithin(nativeResolution)) supportedResolutions.add(Resolution.FHD)
        if (Resolution.HD.isWithin(nativeResolution)) supportedResolutions.add(Resolution.HD)
        supportedResolutions.add(nativeResolution)
        
        val supportedCodecs = mutableListOf("jpeg") // JPEG 总是支持
        if (hasHardwareEncoder) {
            supportedCodecs.add(0, "h264")
            // 检查 H.265 支持
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.LOLLIPOP) {
                supportedCodecs.add(1, "h265")
            }
        }
        
        return DeviceCapabilities(
            deviceId = deviceId,
            deviceName = deviceName,
            platform = "android",
            supportedResolutions = supportedResolutions.distinct(),
            maxResolution = nativeResolution,
            nativeResolution = nativeResolution,
            supportedFrameRates = listOf(15, 24, 30, 60),
            maxFrameRate = 60,
            supportedCodecs = supportedCodecs,
            preferredCodec = if (hasHardwareEncoder) "h264" else "jpeg",
            hasHardwareEncoder = hasHardwareEncoder,
            hasHardwareDecoder = true, // Android 通常支持硬件解码
            minBitrate = 500_000,      // 500 kbps
            maxBitrate = 20_000_000,   // 20 Mbps
            recommendedBitrate = 4_000_000 // 4 Mbps
        )
    }
}
