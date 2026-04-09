package com.skybridge.compass.discovery.domain.usecases

import javax.inject.Inject
import javax.inject.Singleton
import com.skybridge.compass.discovery.domain.repositories.DeviceDiscoveryRepository

/**
 * 发送字节数据到 Nearby 端点（简洁封装）。
 */
@Singleton
class SendNearbyPayloadUseCase @Inject constructor(
    private val repository: DeviceDiscoveryRepository
){
    suspend operator fun invoke(deviceId: String, data: ByteArray): Boolean {
        return repository.sendNearbyBytes(deviceId, data)
    }
}