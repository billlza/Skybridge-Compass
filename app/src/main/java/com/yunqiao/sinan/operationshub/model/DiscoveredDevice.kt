package com.yunqiao.sinan.operationshub.model

import com.yunqiao.sinan.manager.BridgeDevicePlatform
import com.yunqiao.sinan.manager.BridgeTransportHint

/**
 * 发现的设备数据类
 */
data class DiscoveredDevice(
    /** 设备 ID */
    val deviceId: String,
    
    /** 设备名称 */
    val deviceName: String,
    
    /** 设备 IP 地址 */
    val ipAddress: String,
    
    /** 设备类型 */
    val deviceType: DeviceType,
    
    /** MAC 地址 */
    val macAddress: String? = null,
    
    /** 发现时间 */
    val discoveredTime: Long = System.currentTimeMillis(),
    
    /** 是否在线 */
    val isOnline: Boolean = true,
    
    /** 设备信号强度 */
    val signalStrength: Int = -1,
    
    /** 设备描述 */
    val description: String? = null,
    
    /** 可用服务列表 */
    val availableServices: List<String> = emptyList(),

    val platform: BridgeDevicePlatform = BridgeDevicePlatform.UNKNOWN,

    val compatibilityRemark: String = "",

    val supportedTransports: Set<BridgeTransportHint> = emptySet()
)
