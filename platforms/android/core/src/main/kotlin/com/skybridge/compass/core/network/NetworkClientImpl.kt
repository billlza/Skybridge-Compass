package com.skybridge.compass.core.network

import com.skybridge.compass.core.data.model.Device
import com.skybridge.compass.core.data.model.NetworkMessage
import io.ktor.client.HttpClient
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import javax.inject.Inject
import javax.inject.Singleton

/**
 * 一个基础的 NetworkClient 实现，用于满足依赖注入并提供可用的消息与连接状态流。
 * 后续可替换为真实的网络协议实现（Ktor WebSocket/UDP/TCP 等）。
 */
@Singleton
class NetworkClientImpl @Inject constructor(
    private val httpClient: HttpClient
) : NetworkClient {

    private val messages = MutableSharedFlow<NetworkMessage>(replay = 0, extraBufferCapacity = 64)
    private val connectionStatus = MutableStateFlow<Map<String, Boolean>>(emptyMap())

    override suspend fun initialize() {
        // 预留：进行客户端初始化（如握手、配置加载等）
    }

    override suspend fun connect(device: Device): Result<Unit> {
        val current = connectionStatus.value.toMutableMap()
        current[device.id] = true
        connectionStatus.value = current
        return Result.success(Unit)
    }

    override suspend fun disconnect(deviceId: String): Result<Unit> {
        val current = connectionStatus.value.toMutableMap()
        current[deviceId] = false
        connectionStatus.value = current
        return Result.success(Unit)
    }

    override suspend fun sendMessage(message: NetworkMessage): Result<Unit> {
        messages.tryEmit(message)
        return Result.success(Unit)
    }

    override suspend fun broadcastMessage(message: NetworkMessage): Result<Unit> {
        messages.tryEmit(message)
        return Result.success(Unit)
    }

    override fun receiveMessages(): Flow<NetworkMessage> = messages.asSharedFlow()

    override fun getConnectionStatus(): Flow<Map<String, Boolean>> = connectionStatus.asStateFlow()

    override suspend fun isDeviceOnline(deviceId: String): Boolean {
        return connectionStatus.value[deviceId] == true
    }

    override suspend fun getLatency(deviceId: String): Long {
        // 预留：实际应通过 ping/心跳或测量往返时间
        return 50L
    }

    override suspend fun close() {
        // 关闭底层客户端
        httpClient.close()
    }
}