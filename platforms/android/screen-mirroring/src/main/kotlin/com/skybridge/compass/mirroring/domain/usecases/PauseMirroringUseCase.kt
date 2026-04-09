package com.skybridge.compass.mirroring.domain.usecases

import com.skybridge.compass.mirroring.domain.repositories.ScreenMirroringRepository

/**
 * 暂停镜像用例
 */
class PauseMirroringUseCase(
    private val repository: ScreenMirroringRepository
) {
    suspend operator fun invoke(sessionId: String): Result<Unit> {
        return repository.pauseMirroring(sessionId)
    }
}