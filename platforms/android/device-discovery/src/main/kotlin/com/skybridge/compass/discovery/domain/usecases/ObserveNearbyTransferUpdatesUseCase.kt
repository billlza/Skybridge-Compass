package com.skybridge.compass.discovery.domain.usecases

import com.skybridge.compass.discovery.domain.entities.NearbyTransferUpdate
import com.skybridge.compass.discovery.domain.repositories.DeviceDiscoveryRepository
import kotlinx.coroutines.flow.Flow
import javax.inject.Inject

class ObserveNearbyTransferUpdatesUseCase @Inject constructor(
    private val repository: DeviceDiscoveryRepository
) {
    /**
     * 观察指定设备的传输进度更新。
     */
    operator fun invoke(deviceId: String): Flow<NearbyTransferUpdate> {
        return repository.observeNearbyTransferUpdates(deviceId)
    }
}