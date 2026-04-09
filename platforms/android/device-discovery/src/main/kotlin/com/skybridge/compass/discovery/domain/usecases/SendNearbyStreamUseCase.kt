package com.skybridge.compass.discovery.domain.usecases

import com.skybridge.compass.discovery.domain.repositories.DeviceDiscoveryRepository
import java.io.InputStream
import javax.inject.Inject

class SendNearbyStreamUseCase @Inject constructor(
    private val repository: DeviceDiscoveryRepository
) {
    /**
     * 发送流到指定设备，成功返回 payloadId。
     */
    suspend operator fun invoke(deviceId: String, input: InputStream): Long? {
        return repository.sendNearbyStream(deviceId, input)
    }
}