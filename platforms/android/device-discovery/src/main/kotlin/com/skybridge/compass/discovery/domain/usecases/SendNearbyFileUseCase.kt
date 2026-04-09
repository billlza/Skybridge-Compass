package com.skybridge.compass.discovery.domain.usecases

import com.skybridge.compass.discovery.domain.repositories.DeviceDiscoveryRepository
import android.os.ParcelFileDescriptor
import javax.inject.Inject

class SendNearbyFileUseCase @Inject constructor(
    private val repository: DeviceDiscoveryRepository
) {
    /**
     * 发送文件到指定设备，成功返回 payloadId。
     */
    suspend operator fun invoke(deviceId: String, pfd: ParcelFileDescriptor): Long? {
        return repository.sendNearbyFile(deviceId, pfd)
    }
}