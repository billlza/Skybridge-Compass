package com.skybridge.compass.core.network

import com.skybridge.compass.core.data.model.NetworkMessage
import com.skybridge.compass.core.data.model.Device
import kotlinx.coroutines.flow.Flow

/**
 * 网络客户端接口
 * 定义跨平台网络通信的核心功能
 */
interface NetworkClient {
    
    /**
     * 初始化网络客户端
     */
    suspend fun initialize()
    
    /**
     * 连接到指定设备
     */
    suspend fun connect(device: Device): Result<Unit>
    
    /**
     * 断开与指定设备的连接
     */
    suspend fun disconnect(deviceId: String): Result<Unit>
    
    /**
     * 发送消息到指定设备
     */
    suspend fun sendMessage(message: NetworkMessage): Result<Unit>
    
    /**
     * 广播消息到所有连接的设备
     */
    suspend fun broadcastMessage(message: NetworkMessage): Result<Unit>
    
    /**
     * 接收消息流
     */
    fun receiveMessages(): Flow<NetworkMessage>
    
    /**
     * 获取连接状态流
     */
    fun getConnectionStatus(): Flow<Map<String, Boolean>>
    
    /**
     * 检查设备是否在线
     */
    suspend fun isDeviceOnline(deviceId: String): Boolean
    
    /**
     * 获取网络延迟
     */
    suspend fun getLatency(deviceId: String): Long
    
    /**
     * 关闭网络客户端
     */
    suspend fun close()
}

/**
 * WebSocket 客户端接口
 */
interface WebSocketClient {
    
    /**
     * 连接到 WebSocket 服务器
     */
    suspend fun connect(url: String): Result<Unit>
    
    /**
     * 发送文本消息
     */
    suspend fun sendText(message: String): Result<Unit>
    
    /**
     * 发送二进制数据
     */
    suspend fun sendBinary(data: ByteArray): Result<Unit>
    
    /**
     * 接收消息流
     */
    fun receiveMessages(): Flow<String>
    
    /**
     * 接收二进制数据流
     */
    fun receiveBinary(): Flow<ByteArray>
    
    /**
     * 获取连接状态
     */
    fun isConnected(): Boolean
    
    /**
     * 关闭连接
     */
    suspend fun close()
}

/**
 * HTTP 客户端接口
 */
interface HttpClient {
    
    /**
     * 发送 GET 请求
     */
    suspend fun get(url: String, headers: Map<String, String> = emptyMap()): Result<String>
    
    /**
     * 发送 POST 请求
     */
    suspend fun post(url: String, body: String, headers: Map<String, String> = emptyMap()): Result<String>
    
    /**
     * 发送 PUT 请求
     */
    suspend fun put(url: String, body: String, headers: Map<String, String> = emptyMap()): Result<String>
    
    /**
     * 发送 DELETE 请求
     */
    suspend fun delete(url: String, headers: Map<String, String> = emptyMap()): Result<String>
    
    /**
     * 上传文件
     */
    suspend fun uploadFile(url: String, filePath: String, headers: Map<String, String> = emptyMap()): Result<String>
    
    /**
     * 下载文件
     */
    suspend fun downloadFile(url: String, outputPath: String, headers: Map<String, String> = emptyMap()): Result<Unit>
}