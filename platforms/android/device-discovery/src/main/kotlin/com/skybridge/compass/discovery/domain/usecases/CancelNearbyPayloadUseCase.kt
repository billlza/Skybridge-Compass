package com.skybridge.compass.discovery.domain.usecases

import com.skybridge.compass.discovery.domain.repositories.DeviceDiscoveryRepository
import javax.inject.Inject

class CancelNearbyPayloadUseCase @Inject constructor(
    private val repository: DeviceDiscoveryRepository
) {
    /**
     * 取消指定 payload 的传输。
     */
    suspend operator fun invoke(payloadId: Long): Boolean {
        return repository.cancelNearbyPayload(payloadId)
    }
}