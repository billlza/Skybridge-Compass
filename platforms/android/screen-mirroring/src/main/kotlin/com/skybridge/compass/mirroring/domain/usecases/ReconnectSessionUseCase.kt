package com.skybridge.compass.mirroring.domain.usecases

import com.skybridge.compass.mirroring.domain.repositories.ScreenMirroringRepository

/**
 * 重连会话用例
 */
class ReconnectSessionUseCase(
    private val repository: ScreenMirroringRepository
) {
    suspend operator fun invoke(sessionId: String): Result<Unit> {
        return repository.reconnectSession(sessionId)
    }
}