package com.skybridge.compass.core.repository

import com.skybridge.compass.core.data.model.Device
import com.skybridge.compass.core.data.model.DeviceType
import kotlinx.coroutines.flow.Flow

/**
 * 设备仓库接口
 * 定义设备数据管理的业务逻辑
 */
interface DeviceRepository {
    
    /**
     * 获取所有设备
     */
    fun getAllDevices(): Flow<List<Device>>
    
    /**
     * 获取在线设备
     */
    fun getOnlineDevices(): Flow<List<Device>>
    
    /**
     * 获取已连接设备
     */
    fun getConnectedDevices(): Flow<List<Device>>
    
    /**
     * 根据ID获取设备
     */
    suspend fun getDeviceById(deviceId: String): Device?
    
    /**
     * 根据类型获取设备
     */
    fun getDevicesByType(type: DeviceType): Flow<List<Device>>
    
    /**
     * 搜索设备
     */
    fun searchDevices(query: String): Flow<List<Device>>
    
    /**
     * 添加或更新设备
     */
    suspend fun saveDevice(device: Device): Result<Unit>
    
    /**
     * 更新设备
     */
    suspend fun updateDevice(device: Device): Result<Unit>
    
    /**
     * 批量保存设备
     */
    suspend fun saveDevices(devices: List<Device>): Result<Unit>
    
    /**
     * 更新设备在线状态
     */
    suspend fun updateDeviceOnlineStatus(deviceId: String, isOnline: Boolean): Result<Unit>
    
    /**
     * 更新设备连接状态
     */
    suspend fun updateDeviceConnectionStatus(deviceId: String, isConnected: Boolean): Result<Unit>
    
    /**
     * 更新设备电池电量
     */
    suspend fun updateDeviceBatteryLevel(deviceId: String, batteryLevel: Int?): Result<Unit>
    
    /**
     * 删除设备
     */
    suspend fun deleteDevice(deviceId: String): Result<Unit>
    
    /**
     * 删除所有设备
     */
    suspend fun deleteAllDevices(): Result<Unit>
    
    /**
     * 清理离线设备
     */
    suspend fun cleanupOfflineDevices(olderThanMillis: Long): Result<Unit>
    
    /**
     * 刷新设备列表
     */
    suspend fun refreshDevices(): Result<Unit>
}

/**
 * 连接仓库接口
 */
interface ConnectionRepository {
    
    /**
     * 获取所有连接
     */
    fun getAllConnections(): Flow<List<com.skybridge.compass.core.data.model.Connection>>
    
    /**
     * 获取设备的连接
     */
    fun getConnectionsByDevice(deviceId: String): Flow<List<com.skybridge.compass.core.data.model.Connection>>
    
    /**
     * 获取活跃连接
     */
    fun getActiveConnections(): Flow<List<com.skybridge.compass.core.data.model.Connection>>
    
    /**
     * 根据ID获取连接
     */
    suspend fun getConnectionById(connectionId: String): com.skybridge.compass.core.data.model.Connection?
    
    /**
     * 获取设备的活跃连接
     */
    suspend fun getActiveConnectionForDevice(deviceId: String): com.skybridge.compass.core.data.model.Connection?
    
    /**
     * 保存连接
     */
    suspend fun saveConnection(connection: com.skybridge.compass.core.data.model.Connection): Result<Unit>
    
    /**
     * 更新连接状态
     */
    suspend fun updateConnectionStatus(
        connectionId: String, 
        status: com.skybridge.compass.core.data.model.ConnectionStatus
    ): Result<Unit>
    
    /**
     * 更新连接指标
     */
    suspend fun updateConnectionMetrics(
        connectionId: String, 
        latency: Long, 
        bandwidth: Long
    ): Result<Unit>
    
    /**
     * 增加错误计数
     */
    suspend fun incrementErrorCount(connectionId: String): Result<Unit>
    
    /**
     * 删除连接
     */
    suspend fun deleteConnection(connectionId: String): Result<Unit>
    
    /**
     * 删除设备的所有连接
     */
    suspend fun deleteConnectionsByDevice(deviceId: String): Result<Unit>
    
    /**
     * 清理非活跃连接
     */
    suspend fun cleanupInactiveConnections(olderThanMillis: Long): Result<Unit>
}