package com.skybridge.compass.mirroring.data.services

import android.util.Log
import com.skybridge.compass.mirroring.domain.entities.NetworkProtocol
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.io.*
import java.net.*
import java.nio.ByteBuffer
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference

/**
 * 镜像网络服务
 * 负责网络连接和数据传输
 */
class MirroringNetworkService {
    
    private val connections = ConcurrentHashMap<String, NetworkConnection>()
    private val networkScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    
    /**
     * 建立网络连接
     */
    suspend fun connect(
        deviceId: String,
        protocol: NetworkProtocol,
        host: String = "192.168.1.100", // 默认目标设备IP
        port: Int = 8080
    ) = withContext(Dispatchers.IO) {
        try {
            val connection = when (protocol) {
                NetworkProtocol.TCP -> createTcpConnection(deviceId, host, port)
                NetworkProtocol.UDP -> createUdpConnection(deviceId, host, port)
                NetworkProtocol.QUIC -> createQuicConnection(deviceId, host, port)
                NetworkProtocol.WEBRTC -> createWebRtcConnection(deviceId, host, port)
            }
            
            connections[deviceId] = connection
            connection.connect()
            
            Log.d(TAG, "网络连接建立成功: $deviceId, 协议: $protocol")
            
        } catch (e: Exception) {
            Log.e(TAG, "建立网络连接失败: $deviceId", e)
            throw e
        }
    }
    
    /**
     * 断开网络连接
     */
    suspend fun disconnect(deviceId: String) = withContext(Dispatchers.IO) {
        try {
            connections[deviceId]?.let { connection ->
                connection.disconnect()
                connections.remove(deviceId)
                Log.d(TAG, "网络连接断开: $deviceId")
            }
        } catch (e: Exception) {
            Log.e(TAG, "断开网络连接失败: $deviceId", e)
        }
    }
    
    /**
     * 重新连接
     */
    suspend fun reconnect(deviceId: String) = withContext(Dispatchers.IO) {
        connections[deviceId]?.reconnect()
    }
    
    /**
     * 发送视频数据
     */
    suspend fun sendVideoData(
        deviceId: String,
        data: ByteBuffer,
        timestamp: Long,
        isKeyFrame: Boolean
    ): Boolean = withContext(Dispatchers.IO) {
        try {
            val connection = connections[deviceId] ?: return@withContext false
            
            val packet = VideoPacket(
                timestamp = timestamp,
                isKeyFrame = isKeyFrame,
                data = data.array(),
                sequenceNumber = connection.getNextSequenceNumber()
            )
            
            connection.sendVideoPacket(packet)
            true
        } catch (e: Exception) {
            Log.e(TAG, "发送视频数据失败: $deviceId", e)
            false
        }
    }
    
    /**
     * 发送音频数据
     */
    suspend fun sendAudioData(
        deviceId: String,
        data: ByteArray,
        timestamp: Long
    ): Boolean = withContext(Dispatchers.IO) {
        try {
            val connection = connections[deviceId] ?: return@withContext false
            
            val packet = AudioPacket(
                timestamp = timestamp,
                data = data,
                sequenceNumber = connection.getNextSequenceNumber()
            )
            
            connection.sendAudioPacket(packet)
            true
        } catch (e: Exception) {
            Log.e(TAG, "发送音频数据失败: $deviceId", e)
            false
        }
    }
    
    /**
     * 获取网络统计信息
     */
    fun getNetworkStats(deviceId: String): Map<String, Any> {
        return connections[deviceId]?.getStats() ?: emptyMap()
    }
    
    /**
     * 更新网络协议
     */
    suspend fun updateProtocol(deviceId: String, protocol: NetworkProtocol) {
        val currentConnection = connections[deviceId]
        if (currentConnection != null) {
            // 断开当前连接
            currentConnection.disconnect()
            connections.remove(deviceId)
            
            // 使用新协议重新连接
            connect(deviceId, protocol)
        }
    }
    
    /**
     * 创建TCP连接
     */
    private fun createTcpConnection(deviceId: String, host: String, port: Int): NetworkConnection {
        return TcpConnection(deviceId, host, port)
    }
    
    /**
     * 创建UDP连接
     */
    private fun createUdpConnection(deviceId: String, host: String, port: Int): NetworkConnection {
        return UdpConnection(deviceId, host, port)
    }
    
    /**
     * 创建QUIC连接
     */
    private fun createQuicConnection(deviceId: String, host: String, port: Int): NetworkConnection {
        // QUIC实现（简化版，实际需要使用专门的QUIC库）
        return QuicConnection(deviceId, host, port)
    }
    
    /**
     * 创建WebRTC连接
     */
    private fun createWebRtcConnection(deviceId: String, host: String, port: Int): NetworkConnection {
        // WebRTC实现（简化版，实际需要使用WebRTC库）
        return WebRtcConnection(deviceId, host, port)
    }
    
    companion object {
        private const val TAG = "MirroringNetworkService"
    }
    
    /**
     * 清理资源
     */
    fun cleanup() {
        try {
            networkScope.cancel()
            connections.values.forEach { connection ->
                try {
                    runBlocking { connection.disconnect() }
                } catch (e: Exception) {
                    Log.w(TAG, "断开连接失败", e)
                }
            }
            connections.clear()
            Log.d(TAG, "网络服务已清理")
        } catch (e: Exception) {
            Log.e(TAG, "清理网络服务失败", e)
        }
    }
}

/**
 * 网络连接抽象类
 */
abstract class NetworkConnection(
    protected val deviceId: String,
    protected val host: String,
    protected val port: Int
) {
    protected var isConnected = false
    protected val stats = NetworkStats()
    private val sequenceNumber = AtomicLong(0)
    
    abstract suspend fun connect()
    abstract suspend fun disconnect()
    abstract suspend fun reconnect()
    abstract suspend fun sendVideoPacket(packet: VideoPacket)
    abstract suspend fun sendAudioPacket(packet: AudioPacket)
    
    fun getNextSequenceNumber(): Long = sequenceNumber.incrementAndGet()
    
    fun getStats(): Map<String, Any> {
        return mapOf(
            "deviceId" to deviceId,
            "isConnected" to isConnected,
            "latency" to stats.averageLatency.get(),
            "packetLoss" to stats.packetLossRate.get(),
            "bandwidth" to stats.bandwidth.get(),
            "packetsSent" to stats.packetsSent.get(),
            "packetsLost" to stats.packetsLost.get(),
            "bytesSent" to stats.bytesSent.get(),
            "reconnectCount" to stats.reconnectCount.get()
        )
    }
    
    protected fun updateLatency(latency: Long) {
        val current = stats.averageLatency.get()
        stats.averageLatency.set((current + latency) / 2)
    }
    
    protected fun updatePacketStats(sent: Boolean, bytes: Int) {
        if (sent) {
            stats.packetsSent.incrementAndGet()
            stats.bytesSent.addAndGet(bytes.toLong())
        } else {
            stats.packetsLost.incrementAndGet()
        }
        
        // 计算丢包率
        val totalPackets = stats.packetsSent.get() + stats.packetsLost.get()
        if (totalPackets > 0) {
            stats.packetLossRate.set(stats.packetsLost.get().toFloat() / totalPackets)
        }
    }
}

/**
 * TCP连接实现
 */
class TcpConnection(deviceId: String, host: String, port: Int) : NetworkConnection(deviceId, host, port) {
    
    private var socket: Socket? = null
    private var outputStream: DataOutputStream? = null
    
    override suspend fun connect() {
        withContext(Dispatchers.IO) {
            try {
                socket = Socket().apply {
                    soTimeout = 5000
                    connect(InetSocketAddress(host, port), 5000)
                }
                outputStream = DataOutputStream(socket?.getOutputStream())
                isConnected = true
                
                Log.d(TAG, "TCP连接建立: $deviceId -> $host:$port")
            } catch (e: Exception) {
                Log.e(TAG, "TCP连接失败: $deviceId", e)
                throw e
            }
        }
    }
    
    override suspend fun disconnect() {
        withContext(Dispatchers.IO) {
            try {
                outputStream?.close()
                socket?.close()
                isConnected = false
                Log.d(TAG, "TCP连接断开: $deviceId")
            } catch (e: Exception) {
                Log.e(TAG, "TCP断开连接失败: $deviceId", e)
            }
        }
    }
    
    override suspend fun reconnect() {
        withContext(Dispatchers.IO) {
            disconnect()
            delay(1000)
            connect()
            stats.reconnectCount.incrementAndGet()
        }
    }
    
    override suspend fun sendVideoPacket(packet: VideoPacket) {
        withContext(Dispatchers.IO) {
            try {
                val startTime = System.currentTimeMillis()
                
                outputStream?.let { stream ->
                    // 发送包头
                    stream.writeInt(PACKET_TYPE_VIDEO)
                    stream.writeLong(packet.timestamp)
                    stream.writeLong(packet.sequenceNumber)
                    stream.writeBoolean(packet.isKeyFrame)
                    stream.writeInt(packet.data.size)
                    
                    // 发送数据
                    stream.write(packet.data)
                    stream.flush()
                    
                    val latency = System.currentTimeMillis() - startTime
                    updateLatency(latency)
                    updatePacketStats(true, packet.data.size + 25) // 包头大小约25字节
                }
            } catch (e: Exception) {
                Log.e(TAG, "TCP发送视频包失败: $deviceId", e)
                updatePacketStats(false, 0)
                throw e
            }
        }
    }
    
    override suspend fun sendAudioPacket(packet: AudioPacket) {
        withContext(Dispatchers.IO) {
            try {
                val startTime = System.currentTimeMillis()
                
                outputStream?.let { stream ->
                    // 发送包头
                    stream.writeInt(PACKET_TYPE_AUDIO)
                    stream.writeLong(packet.timestamp)
                    stream.writeLong(packet.sequenceNumber)
                    stream.writeInt(packet.data.size)
                    
                    // 发送数据
                    stream.write(packet.data)
                    stream.flush()
                    
                    val latency = System.currentTimeMillis() - startTime
                    updateLatency(latency)
                    updatePacketStats(true, packet.data.size + 20) // 包头大小约20字节
                }
            } catch (e: Exception) {
                Log.e(TAG, "TCP发送音频包失败: $deviceId", e)
                updatePacketStats(false, 0)
                throw e
            }
        }
    }
    
    companion object {
        private const val TAG = "TcpConnection"
        private const val PACKET_TYPE_VIDEO = 1
        private const val PACKET_TYPE_AUDIO = 2
    }
}

/**
 * UDP连接实现
 */
class UdpConnection(deviceId: String, host: String, port: Int) : NetworkConnection(deviceId, host, port) {
    
    private var socket: DatagramSocket? = null
    private var targetAddress: InetAddress? = null
    
    override suspend fun connect() {
        withContext(Dispatchers.IO) {
            try {
                socket = DatagramSocket()
                targetAddress = InetAddress.getByName(host)
                isConnected = true
                
                Log.d(TAG, "UDP连接建立: $deviceId -> $host:$port")
            } catch (e: Exception) {
                Log.e(TAG, "UDP连接失败: $deviceId", e)
                throw e
            }
        }
    }
    
    override suspend fun disconnect() {
        withContext(Dispatchers.IO) {
            try {
                socket?.close()
                isConnected = false
                Log.d(TAG, "UDP连接断开: $deviceId")
            } catch (e: Exception) {
                Log.e(TAG, "UDP断开连接失败: $deviceId", e)
            }
        }
    }
    
    override suspend fun reconnect() {
        withContext(Dispatchers.IO) {
            disconnect()
            delay(500)
            connect()
            stats.reconnectCount.incrementAndGet()
        }
    }
    
    override suspend fun sendVideoPacket(packet: VideoPacket) = withContext(Dispatchers.IO) {
        try {
            val startTime = System.currentTimeMillis()
            
            val buffer = ByteArrayOutputStream().apply {
                val dos = DataOutputStream(this)
                dos.writeInt(PACKET_TYPE_VIDEO)
                dos.writeLong(packet.timestamp)
                dos.writeLong(packet.sequenceNumber)
                dos.writeBoolean(packet.isKeyFrame)
                dos.writeInt(packet.data.size)
                dos.write(packet.data)
            }.toByteArray()
            
            val datagramPacket = DatagramPacket(
                buffer,
                buffer.size,
                targetAddress,
                port
            )
            
            socket?.send(datagramPacket)
            
            val latency = System.currentTimeMillis() - startTime
            updateLatency(latency)
            updatePacketStats(true, buffer.size)
            
        } catch (e: Exception) {
            Log.e(TAG, "UDP发送视频包失败: $deviceId", e)
            updatePacketStats(false, 0)
            throw e
        }
    }
    
    override suspend fun sendAudioPacket(packet: AudioPacket) = withContext(Dispatchers.IO) {
        try {
            val startTime = System.currentTimeMillis()
            
            val buffer = ByteArrayOutputStream().apply {
                val dos = DataOutputStream(this)
                dos.writeInt(PACKET_TYPE_AUDIO)
                dos.writeLong(packet.timestamp)
                dos.writeLong(packet.sequenceNumber)
                dos.writeInt(packet.data.size)
                dos.write(packet.data)
            }.toByteArray()
            
            val datagramPacket = DatagramPacket(
                buffer,
                buffer.size,
                targetAddress,
                port
            )
            
            socket?.send(datagramPacket)
            
            val latency = System.currentTimeMillis() - startTime
            updateLatency(latency)
            updatePacketStats(true, buffer.size)
            
        } catch (e: Exception) {
            Log.e(TAG, "UDP发送音频包失败: $deviceId", e)
            updatePacketStats(false, 0)
            throw e
        }
    }
    
    companion object {
        private const val TAG = "UdpConnection"
        private const val PACKET_TYPE_VIDEO = 1
        private const val PACKET_TYPE_AUDIO = 2
    }
}

/**
 * QUIC连接实现（简化版）
 */
class QuicConnection(deviceId: String, host: String, port: Int) : NetworkConnection(deviceId, host, port) {
    
    // 简化的QUIC实现，实际应使用专门的QUIC库
    private val tcpConnection = TcpConnection(deviceId, host, port)
    
    override suspend fun connect() {
        tcpConnection.connect()
        isConnected = true
    }
    
    override suspend fun disconnect() {
        tcpConnection.disconnect()
        isConnected = false
    }
    
    override suspend fun reconnect() {
        tcpConnection.reconnect()
        stats.reconnectCount.incrementAndGet()
    }
    
    override suspend fun sendVideoPacket(packet: VideoPacket) {
        tcpConnection.sendVideoPacket(packet)
    }
    
    override suspend fun sendAudioPacket(packet: AudioPacket) {
        tcpConnection.sendAudioPacket(packet)
    }
}

/**
 * WebRTC连接实现（简化版）
 */
class WebRtcConnection(deviceId: String, host: String, port: Int) : NetworkConnection(deviceId, host, port) {
    
    // 简化的WebRTC实现，实际应使用WebRTC库
    private val udpConnection = UdpConnection(deviceId, host, port)
    
    override suspend fun connect() {
        udpConnection.connect()
        isConnected = true
    }
    
    override suspend fun disconnect() {
        udpConnection.disconnect()
        isConnected = false
    }
    
    override suspend fun reconnect() {
        udpConnection.reconnect()
        stats.reconnectCount.incrementAndGet()
    }
    
    override suspend fun sendVideoPacket(packet: VideoPacket) {
        udpConnection.sendVideoPacket(packet)
    }
    
    override suspend fun sendAudioPacket(packet: AudioPacket) {
        udpConnection.sendAudioPacket(packet)
    }
}

/**
 * 视频数据包
 */
data class VideoPacket(
    val timestamp: Long,
    val sequenceNumber: Long,
    val isKeyFrame: Boolean,
    val data: ByteArray
)

/**
 * 音频数据包
 */
data class AudioPacket(
    val timestamp: Long,
    val sequenceNumber: Long,
    val data: ByteArray
)

/**
 * 网络统计信息
 */
class NetworkStats {
    val averageLatency = AtomicLong(0)
    val packetLossRate = AtomicReference(0f)
    val bandwidth = AtomicLong(0)
    val packetsSent = AtomicLong(0)
    val packetsLost = AtomicLong(0)
    val bytesSent = AtomicLong(0)
    val reconnectCount = AtomicLong(0)
}