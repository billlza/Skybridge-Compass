package com.yunqiao.sinan.manager

import android.os.Build
import kotlin.math.coerceAtMost
import kotlin.math.max
import kotlin.math.roundToInt

internal object Android16PlatformBoost {
    private const val ANDROID_16_SDK = 36

    val isAndroid16 = Build.VERSION.SDK_INT >= ANDROID_16_SDK

    fun tuneConfig(base: RemoteDesktopConfig): RemoteDesktopConfig {
        if (!isAndroid16) return base
        val tunedFps = max(base.targetFps, (base.targetFps * 1.3f).roundToInt().coerceAtMost(96))
        val tunedBitrate = max(base.targetBitrate, (base.targetBitrate * 1.4f).roundToInt())
        val tunedQuality = (base.compressionQuality + 6).coerceAtMost(98)
        return base.copy(
            targetFps = tunedFps,
            targetBitrate = tunedBitrate,
            compressionQuality = tunedQuality,
            enableHardwareAcceleration = true,
            adaptiveBitrate = true
        )
    }

    fun boostedFrameMultiplier(quality: BridgeLinkQuality, baseMultiplier: Float): Float {
        if (!isAndroid16) return baseMultiplier
        return when {
            quality.supportsLossless && quality.throughputMbps >= 480f -> max(baseMultiplier, 1.85f)
            quality.isDirect && quality.throughputMbps >= 320f -> max(baseMultiplier, 1.55f)
            quality.throughputMbps >= 220f -> max(baseMultiplier, 1.25f)
            else -> baseMultiplier
        }
    }

    fun elevatedBitrate(currentBitrate: Int, quality: BridgeLinkQuality): Int {
        if (!isAndroid16) return currentBitrate
        if (!quality.supportsLossless) return currentBitrate
        val floor = (quality.throughputMbps * 1_100_000f).toInt()
        return max(currentBitrate, floor)
    }
}
