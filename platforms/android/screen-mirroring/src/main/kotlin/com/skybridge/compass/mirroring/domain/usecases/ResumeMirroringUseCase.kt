package com.skybridge.compass.mirroring.domain.usecases

import com.skybridge.compass.mirroring.domain.repositories.ScreenMirroringRepository

/**
 * 恢复镜像用例
 */
class ResumeMirroringUseCase(
    private val repository: ScreenMirroringRepository
) {
    suspend operator fun invoke(sessionId: String): Result<Unit> {
        return repository.resumeMirroring(sessionId)
    }
}