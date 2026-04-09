package com.skybridge.compass.discovery.presentation.events

import com.skybridge.compass.discovery.domain.entities.DiscoveredDevice
import com.skybridge.compass.discovery.domain.entities.DiscoveryProtocol
import com.skybridge.compass.discovery.presentation.states.DeviceSortBy

/**
 * 设备发现UI事件
 * 
 * 定义用户在设备发现界面的所有交互事件
 */
sealed class DeviceDiscoveryEvent {
    
    /**
     * 开始设备发现
     */
    data class StartDiscovery(
        val protocols: Set<DiscoveryProtocol>? = null
    ) : DeviceDiscoveryEvent()
    
    /**
     * 停止设备发现
     */
    object StopDiscovery : DeviceDiscoveryEvent()
    
    /**
     * 连接到设备
     */
    data class ConnectToDevice(
        val device: DiscoveredDevice
    ) : DeviceDiscoveryEvent()
    
    /**
     * 断开设备连接
     */
    data class DisconnectFromDevice(
        val deviceId: String
    ) : DeviceDiscoveryEvent()
    
    /**
     * 刷新设备列表
     */
    object RefreshDevices : DeviceDiscoveryEvent()
    
    /**
     * 清除错误信息
     */
    object ClearError : DeviceDiscoveryEvent()
    
    /**
     * 选择设备
     */
    data class SelectDevice(
        val device: DiscoveredDevice?
    ) : DeviceDiscoveryEvent()
    
    /**
     * 切换发现协议
     */
    data class ToggleProtocol(
        val protocol: DiscoveryProtocol
    ) : DeviceDiscoveryEvent()
    
    /**
     * 更新搜索查询
     */
    data class UpdateSearchQuery(
        val query: String
    ) : DeviceDiscoveryEvent()
    
    /**
     * 切换设备类型过滤器
     */
    data class ToggleDeviceTypeFilter(
        val deviceType: com.skybridge.compass.discovery.domain.entities.DeviceType
    ) : DeviceDiscoveryEvent()
    
    /**
     * 更改排序方式
     */
    data class ChangeSortBy(
        val sortBy: DeviceSortBy
    ) : DeviceDiscoveryEvent()
    
    /**
     * 切换详细信息显示
     */
    object ToggleDetails : DeviceDiscoveryEvent()
    
    /**
     * 清除所有过滤器
     */
    object ClearFilters : DeviceDiscoveryEvent()
    
    /**
     * 重试连接
     */
    data class RetryConnection(
        val device: DiscoveredDevice
    ) : DeviceDiscoveryEvent()
    
    /**
     * 查看设备详情
     */
    data class ViewDeviceDetails(
        val device: DiscoveredDevice
    ) : DeviceDiscoveryEvent()
    
    /**
     * 导出设备列表
     */
    object ExportDeviceList : DeviceDiscoveryEvent()
    
    /**
     * 导入设备列表
     */
    data class ImportDeviceList(
        val json: String
    ) : DeviceDiscoveryEvent()
}