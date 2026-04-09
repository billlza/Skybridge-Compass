package com.skybridge.compass.discovery.domain.usecases

import android.net.Network
import javax.inject.Inject
import javax.inject.Singleton
import com.skybridge.compass.discovery.domain.repositories.DeviceDiscoveryRepository

/**
 * 获取 Wi‑Fi Aware 数据通道 Network（简洁封装）。
 */
@Singleton
class GetWifiAwareNetworkUseCase @Inject constructor(
    private val repository: DeviceDiscoveryRepository
){
    operator fun invoke(deviceId: String): Network? {
        return repository.getWifiAwareNetwork(deviceId)
    }
}