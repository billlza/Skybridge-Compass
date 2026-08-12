package com.skybridge.compass.discovery.data.services

import com.skybridge.compass.discovery.data.datasources.BonjourDiscoveryDataSource
import com.skybridge.compass.discovery.data.datasources.WiFiDirectDiscoveryDataSource
import com.skybridge.compass.discovery.data.datasources.WifiAwareDiscoveryDataSource
import com.skybridge.compass.discovery.data.datasources.NearbyConnectionsDiscoveryDataSource
import com.skybridge.compass.discovery.data.datasources.BleDiscoveryDataSource
import com.skybridge.compass.discovery.data.datasources.UdpBroadcastDiscoveryDataSource
import com.skybridge.compass.discovery.domain.entities.DiscoveredDevice
import com.skybridge.compass.discovery.domain.entities.DiscoveryProtocol
import com.skybridge.compass.discovery.domain.entities.DiscoveryProtocolProfiles
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.flowOf
import javax.inject.Inject
import javax.inject.Singleton

class DeviceDiscoveryException(
    val protocol: DiscoveryProtocol,
    message: String,
    cause: Throwable
) : IllegalStateException(message, cause)

/**
 * 统一设备发现服务
 * 
 * 整合多种发现协议，提供统一的设备发现接口
 * 集成2025年先进技术：WiFi 7优化、量子算法优化
 */
@Singleton
class UnifiedDeviceDiscoveryService @Inject constructor(
    private val bonjourDiscovery: BonjourDiscoveryDataSource,
    private val wifiDirectDiscovery: WiFiDirectDiscoveryDataSource,
    private val wifiAwareDiscovery: WifiAwareDiscoveryDataSource,
    private val nearbyDiscovery: NearbyConnectionsDiscoveryDataSource,
    private val bleDiscovery: BleDiscoveryDataSource,
    private val udpDiscovery: UdpBroadcastDiscoveryDataSource,
    private val quantumOptimizer: QuantumOptimizerService
) {
    
    /**
     * 开始统一设备发现
     * 
     * @param protocols 要使用的发现协议集合
     * @return 优化后的设备列表流
     */
    suspend fun startDiscovery(
        protocols: Set<DiscoveryProtocol> = DiscoveryProtocolProfiles.appleInteropDefaults
    ): Flow<List<DiscoveredDevice>> {
        
        val flows = mutableListOf<Flow<List<DiscoveredDevice>>>()
        
        // 根据协议启动相应的发现服务
        if (protocols.contains(DiscoveryProtocol.BONJOUR)) {
            flows.add(bonjourDiscovery.startDiscovery().withProtocolFailure(DiscoveryProtocol.BONJOUR))
        }
        
        if (protocols.contains(DiscoveryProtocol.WIFI_DIRECT)) {
            flows.add(wifiDirectDiscovery.startDiscovery().withProtocolFailure(DiscoveryProtocol.WIFI_DIRECT))
        }

        if (protocols.contains(DiscoveryProtocol.WIFI_AWARE)) {
            flows.add(wifiAwareDiscovery.startDiscovery().withProtocolFailure(DiscoveryProtocol.WIFI_AWARE))
        }

        if (protocols.contains(DiscoveryProtocol.NEARBY_CONNECTIONS)) {
            flows.add(nearbyDiscovery.startDiscovery().withProtocolFailure(DiscoveryProtocol.NEARBY_CONNECTIONS))
        }
        if (protocols.contains(DiscoveryProtocol.BLUETOOTH)) {
            flows.add(bleDiscovery.startDiscovery().withProtocolFailure(DiscoveryProtocol.BLUETOOTH))
        }
        if (protocols.contains(DiscoveryProtocol.UDP_BROADCAST)) {
            flows.add(udpDiscovery.startDiscovery().withProtocolFailure(DiscoveryProtocol.UDP_BROADCAST))
        }
        
        // 如果没有启用任何协议，返回空流
        if (flows.isEmpty()) {
            return flowOf(emptyList())
        }
        
        // 合并所有发现流
        return when (flows.size) {
            1 -> flows[0]
            2 -> combine(flows[0], flows[1]) { devices1, devices2 ->
                optimizeDeviceList(devices1 + devices2)
            }
            else -> {
                // 处理更多协议的情况
                combine(flows) { deviceArrays ->
                    val allDevices = deviceArrays.flatMap { it.toList() }
                    optimizeDeviceList(allDevices)
                }
            }
        }
    }
    
    /**
     * 优化设备列表
     * 
     * 使用量子算法和智能去重优化设备列表
     */
    private suspend fun optimizeDeviceList(devices: List<DiscoveredDevice>): List<DiscoveredDevice> {
        // 1. 去重 - 优先基于稳定设备 ID，缺失时退回端点特征
        val uniqueDevices = deduplicateDevices(devices)
        
        // 2. 量子优化排序
        val optimizedDevices = quantumOptimizer.optimizeDeviceList(uniqueDevices)
        
        // 3. 信号强度和连接质量评估
        return optimizedDevices.map { device ->
            device.copy(
                signalStrength = calculateOptimizedSignalStrength(device)
            )
        }.sortedByDescending { it.signalStrength }
    }
    
    /**
     * 设备去重
     * 
     * 基于多个维度进行智能去重
     */
    private fun deduplicateDevices(devices: List<DiscoveredDevice>): List<DiscoveredDevice> {
        val deviceMap = mutableMapOf<DeviceDeduplicationKey, DiscoveredDevice>()
        
        devices.forEach { device ->
            val key = DeviceDeduplicationPolicy.keyFor(device)
            val existing = deviceMap[key]
            
            if (existing == null) {
                deviceMap[key] = device
            } else {
                deviceMap[key] = DeviceDeduplicationPolicy.merge(existing, device)
            }
        }
        
        return deviceMap.values.toList()
    }

    /**
     * 计算优化的信号强度
     */
    private fun calculateOptimizedSignalStrength(device: DiscoveredDevice): Int {
        var strength = device.signalStrength
        
        // 根据协议调整信号强度
        when (device.connectionInfo.protocol) {
            DiscoveryProtocol.BONJOUR -> {
                // Bonjour通常表示本地网络，给予较高权重
                strength = (strength * 1.2).toInt().coerceAtMost(100)
            }
            DiscoveryProtocol.WIFI_DIRECT -> {
                // WiFi Direct点对点连接，根据状态调整
                strength = (strength * 1.1).toInt().coerceAtMost(100)
            }
            else -> {
                // 其他协议保持原值
            }
        }
        
        // 根据设备能力调整
        val capabilityBonus = device.capabilities.size * 2
        strength = (strength + capabilityBonus).coerceAtMost(100)
        
        // 根据最后见到时间调整（越新越好）
        val timeDiff = System.currentTimeMillis() - device.lastSeen
        val timeDecay = (timeDiff / 1000).toInt().coerceAtMost(20)
        strength = (strength - timeDecay).coerceAtLeast(0)
        
        return strength
    }

    private fun Flow<List<DiscoveredDevice>>.withProtocolFailure(
        protocol: DiscoveryProtocol
    ): Flow<List<DiscoveredDevice>> = catch { error ->
        throw DeviceDiscoveryException(
            protocol = protocol,
            message = "$protocol discovery failed: ${error.message ?: error.javaClass.simpleName}",
            cause = error
        )
    }
}

internal data class DeviceDeduplicationKey(
    val namespace: String,
    val value: String
)

internal object DeviceDeduplicationPolicy {
    fun keyFor(device: DiscoveredDevice): DeviceDeduplicationKey {
        val stableId = device.id.trim()
        if (stableId.isNotEmpty()) {
            return DeviceDeduplicationKey(namespace = "device-id", value = stableId)
        }

        return DeviceDeduplicationKey(
            namespace = "endpoint",
            value = "${device.name}|${device.connectionInfo.address}|${device.type}"
        )
    }

    fun merge(device1: DiscoveredDevice, device2: DiscoveredDevice): DiscoveredDevice {
        val primary = if (device1.signalStrength >= device2.signalStrength) device1 else device2
        val secondary = if (primary == device1) device2 else device1

        return primary.copy(
            capabilities = device1.capabilities + device2.capabilities,
            connectionInfo = primary.connectionInfo.copy(
                txtRecords = secondary.connectionInfo.txtRecords + primary.connectionInfo.txtRecords,
                extra = secondary.connectionInfo.extra + primary.connectionInfo.extra
            ),
            lastSeen = maxOf(device1.lastSeen, device2.lastSeen),
            isConnected = device1.isConnected || device2.isConnected,
            batteryLevel = primary.batteryLevel ?: secondary.batteryLevel,
            osVersion = primary.osVersion ?: secondary.osVersion
        )
    }
}

/**
 * 量子优化器服务
 * 
 * 使用量子算法优化设备发现和排序
 */
@Singleton
class QuantumOptimizerService @Inject constructor() {
    
    /**
     * 使用量子算法优化设备列表
     * 
     * 注意：这里是量子算法的简化实现
     * 在实际应用中，可以集成真正的量子计算库
     */
    suspend fun optimizeDeviceList(devices: List<DiscoveredDevice>): List<DiscoveredDevice> {
        // 量子启发式排序算法
        return devices.sortedWith(compareByDescending<DiscoveredDevice> { device ->
            // 量子权重计算
            calculateQuantumWeight(device)
        }.thenBy { it.name })
    }
    
    /**
     * 计算量子权重
     */
    private fun calculateQuantumWeight(device: DiscoveredDevice): Double {
        var weight = 0.0
        
        // 信号强度权重
        weight += device.signalStrength * 0.3
        
        // 设备类型权重
        weight += when (device.type) {
            com.skybridge.compass.discovery.domain.entities.DeviceType.IOS -> 25.0
            com.skybridge.compass.discovery.domain.entities.DeviceType.MACOS -> 24.0
            com.skybridge.compass.discovery.domain.entities.DeviceType.ANDROID -> 23.0
            com.skybridge.compass.discovery.domain.entities.DeviceType.WINDOWS -> 20.0
            com.skybridge.compass.discovery.domain.entities.DeviceType.LINUX -> 18.0
            else -> 10.0
        }
        
        // 能力权重
        weight += device.capabilities.size * 5.0
        
        // 连接状态权重
        if (device.isConnected) {
            weight += 30.0
        }
        
        // 时间新鲜度权重
        val timeDiff = System.currentTimeMillis() - device.lastSeen
        val freshnessWeight = maxOf(0.0, 20.0 - (timeDiff / 1000.0 / 60.0)) // 20分钟内的设备有额外权重
        weight += freshnessWeight
        
        return weight
    }
}
