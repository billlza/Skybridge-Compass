package com.skybridge.compass.core.data.database

import androidx.room.TypeConverter
import com.skybridge.compass.core.data.model.*
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.decodeFromString

/**
 * Room 数据库类型转换器
 */
class Converters {
    
    private val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
    }
    
    @TypeConverter
    fun fromDeviceCapabilityList(value: List<DeviceCapability>): String {
        return json.encodeToString(value)
    }
    
    @TypeConverter
    fun toDeviceCapabilityList(value: String): List<DeviceCapability> {
        return json.decodeFromString(value)
    }
    
    @TypeConverter
    fun fromOSInfo(value: OSInfo?): String? {
        return value?.let { json.encodeToString(it) }
    }
    
    @TypeConverter
    fun toOSInfo(value: String?): OSInfo? {
        return value?.let { json.decodeFromString(it) }
    }
    
    @TypeConverter
    fun fromStringMap(value: Map<String, String>): String {
        return json.encodeToString(value)
    }
    
    @TypeConverter
    fun toStringMap(value: String): Map<String, String> {
        return json.decodeFromString(value)
    }
    
    @TypeConverter
    fun fromDeviceType(value: DeviceType): String {
        return value.name
    }
    
    @TypeConverter
    fun toDeviceType(value: String): DeviceType {
        return DeviceType.valueOf(value)
    }
    
    @TypeConverter
    fun fromConnectionQuality(value: ConnectionQuality): String {
        return Json.encodeToString(value)
    }
    
    @TypeConverter
    fun toConnectionQuality(value: String): ConnectionQuality {
        return Json.decodeFromString(value)
    }
    
    @TypeConverter
    fun fromConnectionStatus(value: ConnectionStatus): String {
        return value.name
    }
    
    @TypeConverter
    fun toConnectionStatus(value: String): ConnectionStatus {
        return ConnectionStatus.valueOf(value)
    }
    
    @TypeConverter
    fun fromConnectionProtocol(value: ConnectionProtocol): String {
        return value.name
    }
    
    @TypeConverter
    fun toConnectionProtocol(value: String): ConnectionProtocol {
        return ConnectionProtocol.valueOf(value)
    }
}