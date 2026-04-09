package com.skybridge.compass.mirroring.domain.usecases

import com.skybridge.compass.mirroring.domain.entities.VideoQuality
import com.skybridge.compass.mirroring.domain.repositories.ScreenMirroringRepository

/**
 * 更新镜像质量用例
 */
class UpdateMirroringQualityUseCase(
    private val repository: ScreenMirroringRepository
) {
    suspend operator fun invoke(sessionId: String, quality: VideoQuality): Result<Unit> {
        return repository.updateQuality(sessionId, quality)
    }
}