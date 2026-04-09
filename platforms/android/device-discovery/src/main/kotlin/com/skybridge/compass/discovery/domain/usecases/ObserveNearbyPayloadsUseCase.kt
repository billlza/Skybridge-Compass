package com.skybridge.compass.discovery.domain.usecases

import kotlinx.coroutines.flow.Flow
import javax.inject.Inject
import javax.inject.Singleton
import com.skybridge.compass.discovery.domain.repositories.DeviceDiscoveryRepository
import com.skybridge.compass.discovery.domain.entities.NearbyPayload

/**
 * 观察指定设备的 Nearby 负载（支持 BYTES/FILE/STREAM）。
 */
@Singleton
class ObserveNearbyPayloadsUseCase @Inject constructor(
    private val repository: DeviceDiscoveryRepository
){
    operator fun invoke(deviceId: String): Flow<NearbyPayload> {
        return repository.observeNearbyPayloads(deviceId)
    }
}