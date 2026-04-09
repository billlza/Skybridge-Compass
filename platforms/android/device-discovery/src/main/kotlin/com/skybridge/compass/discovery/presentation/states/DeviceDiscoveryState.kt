package com.skybridge.compass.discovery.presentation.states

import com.skybridge.compass.discovery.domain.entities.DiscoveredDevice
import com.skybridge.compass.discovery.domain.entities.DiscoveryProtocol
import com.skybridge.compass.discovery.domain.entities.DiscoveryProtocolProfiles

/**
 * 设备发现UI状态
 * 
 * 包含设备发现界面的所有状态信息
 */
data class DeviceDiscoveryState(
    // 加载状态
    val isLoading: Boolean = false,
    
    // 发现的设备列表
    val devices: List<DiscoveredDevice> = emptyList(),
    
    // 已连接的设备列表
    val connectedDevices: List<DiscoveredDevice> = emptyList(),
    
    // 当前选中的设备
    val selectedDevice: DiscoveredDevice? = null,
    
    // 正在连接的设备ID
    val connectingDeviceId: String? = null,
    
    // 错误信息
    val error: String? = null,
    
    // 选中的发现协议
    val selectedProtocols: Set<DiscoveryProtocol> = DiscoveryProtocolProfiles.appleInteropDefaults,
    
    // 发现是否正在进行
    val isDiscovering: Boolean = false,
    
    // 搜索过滤器
    val searchQuery: String = "",
    
    // 设备类型过滤器
    val deviceTypeFilter: Set<com.skybridge.compass.discovery.domain.entities.DeviceType> = emptySet(),
    
    // 排序方式
    val sortBy: DeviceSortBy = DeviceSortBy.SIGNAL_STRENGTH,
    
    // 是否显示详细信息
    val showDetails: Boolean = false,
    
    // 刷新时间戳
    val lastRefreshTime: Long = 0L
) {
    
    /**
     * 获取过滤后的设备列表
     */
    val filteredDevices: List<DiscoveredDevice>
        get() = devices
            .filter { device ->
                // 搜索过滤
                if (searchQuery.isNotBlank()) {
                    device.name.contains(searchQuery, ignoreCase = true) ||
                    device.connectionInfo.address.contains(searchQuery, ignoreCase = true)
                } else {
                    true
                }
            }
            .filter { device ->
                // 设备类型过滤
                if (deviceTypeFilter.isNotEmpty()) {
                    deviceTypeFilter.contains(device.type)
                } else {
                    true
                }
            }
            .sortedWith(getSortComparator())
    
    /**
     * 获取排序比较器
     */
    private fun getSortComparator(): Comparator<DiscoveredDevice> {
        return when (sortBy) {
            DeviceSortBy.NAME -> compareBy { it.name }
            DeviceSortBy.SIGNAL_STRENGTH -> compareByDescending { it.signalStrength }
            DeviceSortBy.DEVICE_TYPE -> compareBy { it.type.name }
            DeviceSortBy.LAST_SEEN -> compareByDescending { it.lastSeen }
            DeviceSortBy.CONNECTION_STATUS -> compareByDescending { it.isConnected }
        }
    }
    
    /**
     * 检查是否有任何设备正在连接
     */
    val hasConnectingDevice: Boolean
        get() = connectingDeviceId != null
    
    /**
     * 检查是否有错误
     */
    val hasError: Boolean
        get() = error != null
    
    /**
     * 检查是否有设备
     */
    val hasDevices: Boolean
        get() = devices.isNotEmpty()
    
    /**
     * 检查是否有已连接的设备
     */
    val hasConnectedDevices: Boolean
        get() = connectedDevices.isNotEmpty()
}

/**
 * 设备排序方式
 */
enum class DeviceSortBy {
    NAME,           // 按名称排序
    SIGNAL_STRENGTH, // 按信号强度排序
    DEVICE_TYPE,    // 按设备类型排序
    LAST_SEEN,      // 按最后发现时间排序
    CONNECTION_STATUS // 按连接状态排序
}
