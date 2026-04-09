package com.skybridge.compass.mirroring.domain.usecases

import com.skybridge.compass.mirroring.domain.repositories.ScreenMirroringRepository

/**
 * 优化网络设置用例
 */
class OptimizeNetworkSettingsUseCase(
    private val repository: ScreenMirroringRepository
) {
    suspend operator fun invoke(sessionId: String): Result<Unit> {
        return repository.optimizeNetworkSettings(sessionId)
    }
}