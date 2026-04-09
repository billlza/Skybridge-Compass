package com.skybridge.compass.core.data.dao

import androidx.room.*
import kotlinx.coroutines.flow.Flow
import com.skybridge.compass.core.data.model.Device
import com.skybridge.compass.core.data.model.DeviceType

/**
 * 设备数据访问对象
 */
@Dao
interface DeviceDao {
    
    @Query("SELECT * FROM devices ORDER BY lastSeen DESC")
    fun getAllDevices(): Flow<List<Device>>
    
    @Query("SELECT * FROM devices WHERE isOnline = 1 ORDER BY lastSeen DESC")
    fun getOnlineDevices(): Flow<List<Device>>
    
    @Query("SELECT * FROM devices WHERE id = :deviceId")
    suspend fun getDeviceById(deviceId: String): Device?
    
    @Query("SELECT * FROM devices WHERE type = :type ORDER BY lastSeen DESC")
    fun getDevicesByType(type: DeviceType): Flow<List<Device>>
    
    @Query("SELECT * FROM devices WHERE isConnected = 1")
    fun getConnectedDevices(): Flow<List<Device>>
    
    @Query("SELECT * FROM devices WHERE name LIKE '%' || :query || '%' OR ipAddress LIKE '%' || :query || '%'")
    fun searchDevices(query: String): Flow<List<Device>>
    
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertDevice(device: Device)
    
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertDevices(devices: List<Device>)
    
    @Update
    suspend fun updateDevice(device: Device)
    
    @Query("UPDATE devices SET isOnline = :isOnline, lastSeen = :lastSeen WHERE id = :deviceId")
    suspend fun updateDeviceOnlineStatus(deviceId: String, isOnline: Boolean, lastSeen: Long)
    
    @Query("UPDATE devices SET isConnected = :isConnected WHERE id = :deviceId")
    suspend fun updateDeviceConnectionStatus(deviceId: String, isConnected: Boolean)
    
    @Query("UPDATE devices SET batteryLevel = :batteryLevel WHERE id = :deviceId")
    suspend fun updateDeviceBatteryLevel(deviceId: String, batteryLevel: Int?)
    
    @Delete
    suspend fun deleteDevice(device: Device)
    
    @Query("DELETE FROM devices WHERE id = :deviceId")
    suspend fun deleteDeviceById(deviceId: String)
    
    @Query("DELETE FROM devices WHERE isOnline = 0 AND lastSeen < :threshold")
    suspend fun deleteOfflineDevicesOlderThan(threshold: Long)
    
    @Query("DELETE FROM devices")
    suspend fun deleteAllDevices()
}