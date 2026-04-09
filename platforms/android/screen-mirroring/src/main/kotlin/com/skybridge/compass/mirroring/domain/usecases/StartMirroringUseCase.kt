package com.skybridge.compass.mirroring.domain.usecases

import com.skybridge.compass.mirroring.domain.entities.MirroringSession
import com.skybridge.compass.mirroring.domain.entities.MirroringType
import com.skybridge.compass.mirroring.domain.entities.VideoQuality
import com.skybridge.compass.mirroring.domain.repositories.ScreenMirroringRepository

/**
 * 开始镜像用例
 */
class StartMirroringUseCase(
    private val repository: ScreenMirroringRepository
) {
    suspend operator fun invoke(
        deviceId: String,
        mirroringType: MirroringType = MirroringType.SCREEN_AUDIO,
        quality: VideoQuality = VideoQuality.AUTO,
        audioEnabled: Boolean = true
    ): Result<MirroringSession> {
        return try {
            // 检查设备连接状态
            val connectionQuality = repository.testConnectionQuality(deviceId)
            val networkSpeed = connectionQuality.bandwidth

            // 根据网络状况推荐质量设置
            val recommendedQuality = if (quality == VideoQuality.AUTO) {
                repository.getRecommendedQuality(deviceId, networkSpeed)
            } else {
                quality
            }

            // 开始镜像
            repository.startMirroring(
                deviceId = deviceId,
                mirroringType = mirroringType,
                quality = recommendedQuality,
                audioEnabled = audioEnabled
            )
        } catch (e: Exception) {
            Result.failure(e)
        }
    }
}