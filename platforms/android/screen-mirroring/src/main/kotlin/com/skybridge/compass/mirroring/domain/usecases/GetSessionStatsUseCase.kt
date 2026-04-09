package com.skybridge.compass.mirroring.domain.usecases

import com.skybridge.compass.mirroring.domain.repositories.ScreenMirroringRepository

/**
 * 获取会话统计用例
 */
class GetSessionStatsUseCase(
    private val repository: ScreenMirroringRepository
) {
    suspend operator fun invoke(sessionId: String): Map<String, Any>? {
        return repository.getSessionStats(sessionId)
    }
}