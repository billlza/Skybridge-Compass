package com.skybridge.compass.discovery.data.services

import android.content.Context
import android.net.Uri
import com.skybridge.compass.discovery.domain.entities.DiscoveredDevice
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.IOException
import javax.inject.Inject
import javax.inject.Singleton

/**
 * 设备列表导出/导入服务接口
 */
interface DeviceListService {
    /**
     * 导出设备列表为 JSON 字符串
     */
    fun exportDevices(devices: List<DiscoveredDevice>): String
    
    /**
     * 从 JSON 字符串导入设备列表
     */
    fun importDevices(json: String): Result<List<DiscoveredDevice>>
    
    /**
     * 合并设备列表（去重）
     */
    fun mergeDevices(
        existing: List<DiscoveredDevice>,
        imported: List<DiscoveredDevice>
    ): List<DiscoveredDevice>
    
    /**
     * 保存 JSON 到文件
     */
    suspend fun saveToFile(context: Context, json: String, uri: Uri): Boolean
    
    /**
     * 从文件读取 JSON
     */
    suspend fun readFromFile(context: Context, uri: Uri): Result<String>
}

/**
 * 设备列表导出格式
 */
@Serializable
data class DeviceListExport(
    val version: Int = 1,
    val exportTime: Long = System.currentTimeMillis(),
    val devices: List<DiscoveredDevice>
)

/**
 * 设备列表服务实现
 */
@Singleton
class DeviceListServiceImpl @Inject constructor() : DeviceListService {
    
    private val json = Json {
        prettyPrint = true
        ignoreUnknownKeys = true
        encodeDefaults = true
    }
    
    override fun exportDevices(devices: List<DiscoveredDevice>): String {
        val export = DeviceListExport(
            version = 1,
            exportTime = System.currentTimeMillis(),
            devices = devices
        )
        return json.encodeToString(export)
    }
    
    override fun importDevices(json: String): Result<List<DiscoveredDevice>> {
        return try {
            val export = this.json.decodeFromString<DeviceListExport>(json)
            if (export.version > 1) {
                Result.failure(UnsupportedVersionException("不支持的导出版本: ${export.version}"))
            } else {
                Result.success(export.devices)
            }
        } catch (e: Exception) {
            Result.failure(InvalidFormatException("无效的设备列表格式: ${e.message}"))
        }
    }
    
    override fun mergeDevices(
        existing: List<DiscoveredDevice>,
        imported: List<DiscoveredDevice>
    ): List<DiscoveredDevice> {
        val existingMap = existing.associateBy { it.id }.toMutableMap()
        
        for (device in imported) {
            val existingDevice = existingMap[device.id]
            if (existingDevice == null) {
                // 新设备，直接添加
                existingMap[device.id] = device
            } else {
                // 已存在，保留最新的（根据 lastSeen）
                if (device.lastSeen > existingDevice.lastSeen) {
                    existingMap[device.id] = device
                }
            }
        }
        
        return existingMap.values.toList()
    }
    
    override suspend fun saveToFile(context: Context, json: String, uri: Uri): Boolean {
        return try {
            context.contentResolver.openOutputStream(uri)?.use { outputStream ->
                outputStream.write(json.toByteArray(Charsets.UTF_8))
                outputStream.flush()
            }
            true
        } catch (e: IOException) {
            false
        }
    }
    
    override suspend fun readFromFile(context: Context, uri: Uri): Result<String> {
        return try {
            val content = context.contentResolver.openInputStream(uri)?.use { inputStream ->
                inputStream.bufferedReader(Charsets.UTF_8).readText()
            }
            if (content != null) {
                Result.success(content)
            } else {
                Result.failure(IOException("无法读取文件"))
            }
        } catch (e: Exception) {
            Result.failure(e)
        }
    }
}

/**
 * 不支持的版本异常
 */
class UnsupportedVersionException(message: String) : Exception(message)

/**
 * 无效格式异常
 */
class InvalidFormatException(message: String) : Exception(message)
