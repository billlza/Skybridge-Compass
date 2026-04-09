package com.skybridge.compass.mirroring.domain.usecases

import com.skybridge.compass.mirroring.domain.repositories.ScreenMirroringRepository

/**
 * 切换音频用例
 */
class ToggleAudioUseCase(
    private val repository: ScreenMirroringRepository
) {
    suspend operator fun invoke(sessionId: String, enabled: Boolean): Result<Unit> {
        return repository.toggleAudio(sessionId, enabled)
    }
}