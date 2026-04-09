package com.skybridge.compass.mirroring.domain.usecases

import com.skybridge.compass.mirroring.domain.repositories.ScreenMirroringRepository

/**
 * 停止镜像用例
 */
class StopMirroringUseCase(
    private val repository: ScreenMirroringRepository
) {
    suspend operator fun invoke(sessionId: String): Result<Unit> {
        return repository.stopMirroring(sessionId)
    }
}