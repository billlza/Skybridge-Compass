package com.skybridge.compass.discovery.domain.usecases

import com.skybridge.compass.discovery.domain.entities.DiscoveredDevice
import com.skybridge.compass.discovery.domain.entities.DiscoveryProtocol
import com.skybridge.compass.discovery.domain.entities.DiscoveryProtocolProfiles
import com.skybridge.compass.discovery.domain.repositories.DeviceDiscoveryRepository
import kotlinx.coroutines.flow.Flow
import javax.inject.Inject
import javax.inject.Singleton

/**
 * 开始设备发现用例
 * 
 * 封装设备发现的业务逻辑，包括协议选择和结果优化
 */
@Singleton
class StartDeviceDiscoveryUseCase @Inject constructor(
    private val repository: DeviceDiscoveryRepository
) {
    
    /**
     * 执行设备发现
     * 
     * @param protocols 要使用的发现协议
     * @param enableQuantumOptimization 是否启用量子优化算法
     * @return 优化后的设备列表流
     */
    suspend operator fun invoke(
        protocols: Set<DiscoveryProtocol> = DiscoveryProtocolProfiles.appleInteropDefaults,
        enableQuantumOptimization: Boolean = true
    ): Flow<List<DiscoveredDevice>> {
        return repository.startDiscovery(protocols)
    }
}

/**
 * 停止设备发现用例
 */
@Singleton
class StopDeviceDiscoveryUseCase @Inject constructor(
    private val repository: DeviceDiscoveryRepository
) {
    
    suspend operator fun invoke() {
        repository.stopDiscovery()
    }
}

/**
 * 连接设备用例
 */
@Singleton
class ConnectToDeviceUseCase @Inject constructor(
    private val repository: DeviceDiscoveryRepository
) {
    
    suspend operator fun invoke(device: DiscoveredDevice): Boolean {
        return repository.connectToDevice(device)
    }
}

/**
 * 断开设备连接用例
 */
@Singleton
class DisconnectFromDeviceUseCase @Inject constructor(
    private val repository: DeviceDiscoveryRepository
) {
    
    suspend operator fun invoke(deviceId: String) {
        repository.disconnectFromDevice(deviceId)
    }
}
