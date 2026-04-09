package com.skybridge.compass.screenmirroring

import android.util.Log
import com.skybridge.compass.core.network.NetworkClient
import com.skybridge.compass.core.utils.Logger

import kotlinx.coroutines.*
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.*
import java.net.*
import java.nio.ByteBuffer
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong

// WebSocket 服务器处理器占位类
private class WebSocketServerHandler

/**
 * 网络传输服务
 * 负责屏幕镜像数据的网络传输
 */
class NetworkTransmissionService constructor() {
    
    companion object {
        private const val TAG = "NetworkTransmissionService"
        private const val MAX_PACKET_SIZE = 1400 // MTU考虑
        private const val SEND_BUFFER_SIZE = 64 * 1024 // 64KB
        private const val RECEIVE_BUFFER_SIZE = 64 * 1024 // 64KB
        private const val CONNECTION_TIMEOUT = 10000 // 10秒
        private const val HEARTBEAT_INTERVAL = 5000L // 5秒心跳
        private const val MAX_RETRY_COUNT = 3
        private const val RETRY_DELAY = 1000L // 1秒重试延迟
    }

    private val coroutineScope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    
    private val _connectionState = MutableStateFlow<ConnectionState>(ConnectionState.Disconnected)
    val connectionState: StateFlow<ConnectionState> = _connectionState.asStateFlow()
    
    private val _transmissionStats = MutableStateFlow(TransmissionStats())
    val transmissionStats: StateFlow<TransmissionStats> = _transmissionStats.asStateFlow()
    
    private val _receivedData = MutableSharedFlow<ReceivedData>(
        replay = 0,
        extraBufferCapacity = 100,
        onBufferOverflow = BufferOverflow.DROP_OLDEST
    )
    val receivedData: SharedFlow<ReceivedData> = _receivedData.asSharedFlow()
    
    private var tcpSocket: Socket? = null
    private var udpSocket: DatagramSocket? = null
    private var serverSocket: ServerSocket? = null
    
    private val sendQueue = Channel<TransmissionPacket>(Channel.UNLIMITED)
    private val pendingAcks = ConcurrentHashMap<Long, PendingPacket>()
    private val sequenceNumber = AtomicLong(0)
    
    private var sendJob: Job? = null
    private var receiveJob: Job? = null
    private var heartbeatJob: Job? = null
    private var ackTimeoutJob: Job? = null
    
    private var currentConfiguration: NetworkConfiguration? = null
    
    /**
     * 启动服务器模式
     */
    suspend fun startServer(configuration: NetworkConfiguration): Result<Unit> {
        return withContext(Dispatchers.IO) {
            try {
                _connectionState.value = ConnectionState.Connecting
                currentConfiguration = configuration
                
                when (configuration.protocol) {
                    TransmissionProtocol.TCP -> startTcpServer(configuration)
                    TransmissionProtocol.UDP -> startUdpServer(configuration)
                    TransmissionProtocol.WEBSOCKET -> startWebSocketServer(configuration)
                    TransmissionProtocol.WEBRTC -> {
                        val err = UnsupportedOperationException("WEBRTC protocol not implemented")
                        _connectionState.value = ConnectionState.Error(err.message ?: "WEBRTC not implemented")
                        return@withContext Result.failure(err)
                    }
                }
                
                startTransmissionJobs()
                _connectionState.value = ConnectionState.Connected(
                    remoteAddress = "0.0.0.0",
                    port = configuration.port,
                    protocol = configuration.protocol
                )
                
                Log.d(TAG, "Server started on port ${configuration.port} with protocol ${configuration.protocol}")
                Result.success(Unit)
                
            } catch (e: Exception) {
                Log.e(TAG, "Failed to start server", e)
                cleanup()
                _connectionState.value = ConnectionState.Error(e.message ?: "Server start failed")
                Result.failure(e)
            }
        }
    }
    
    /**
     * 连接到服务器
     */
    suspend fun connectToServer(
        address: String,
        configuration: NetworkConfiguration
    ): Result<Unit> {
        return withContext(Dispatchers.IO) {
            try {
                _connectionState.value = ConnectionState.Connecting
                currentConfiguration = configuration
                
                when (configuration.protocol) {
                    TransmissionProtocol.TCP -> connectTcp(address, configuration)
                    TransmissionProtocol.UDP -> connectUdp(address, configuration)
                    TransmissionProtocol.WEBSOCKET -> connectWebSocket(address, configuration)
                    TransmissionProtocol.WEBRTC -> {
                        val err = UnsupportedOperationException("WEBRTC protocol not implemented")
                        _connectionState.value = ConnectionState.Error(err.message ?: "WEBRTC not implemented")
                        return@withContext Result.failure(err)
                    }
                }
                
                startTransmissionJobs()
                _connectionState.value = ConnectionState.Connected(
                    remoteAddress = address,
                    port = configuration.port,
                    protocol = configuration.protocol
                )
                
                Log.d(TAG, "Connected to server $address:${configuration.port}")
                Result.success(Unit)
                
            } catch (e: Exception) {
                Log.e(TAG, "Failed to connect to server", e)
                cleanup()
                _connectionState.value = ConnectionState.Error(e.message ?: "Connection failed")
                Result.failure(e)
            }
        }
    }
    
    /**
     * 发送数据
     */
    suspend fun sendData(data: ByteArray, dataType: DataType, priority: PacketPriority = PacketPriority.NORMAL): Result<Unit> {
        return try {
            if (_connectionState.value !is ConnectionState.Connected) {
                return Result.failure(IllegalStateException("Not connected"))
            }
            
            val packets = fragmentData(data, dataType, priority)
            packets.forEach { packet ->
                sendQueue.send(packet)
            }
            
            // 更新统计信息
            _transmissionStats.value = _transmissionStats.value.copy(
                bytesSent = _transmissionStats.value.bytesSent + data.size,
                packetsSent = _transmissionStats.value.packetsSent + packets.size
            )
            
            Result.success(Unit)
            
        } catch (e: Exception) {
            Log.e(TAG, "Failed to send data", e)
            Result.failure(e)
        }
    }
    
    /**
     * 断开连接
     */
    suspend fun disconnect() {
        withContext(Dispatchers.IO) {
            try {
                _connectionState.value = ConnectionState.Disconnecting
                
                // 停止所有任务
                sendJob?.cancelAndJoin()
                receiveJob?.cancelAndJoin()
                heartbeatJob?.cancelAndJoin()
                ackTimeoutJob?.cancelAndJoin()
                
                cleanup()
                _connectionState.value = ConnectionState.Disconnected
                
                Log.d(TAG, "Disconnected successfully")
                
            } catch (e: Exception) {
                Log.e(TAG, "Error during disconnect", e)
                _connectionState.value = ConnectionState.Error(e.message ?: "Disconnect failed")
            }
        }
    }
    
    /**
     * 启动TCP服务器
     */
    private suspend fun startTcpServer(configuration: NetworkConfiguration) {
        serverSocket = ServerSocket(configuration.port).apply {
            soTimeout = CONNECTION_TIMEOUT
            reuseAddress = true
        }
        
        // 等待客户端连接
        tcpSocket = withContext(Dispatchers.IO) {
            serverSocket!!.accept()
        }.apply {
            tcpNoDelay = true
            sendBufferSize = SEND_BUFFER_SIZE
            receiveBufferSize = RECEIVE_BUFFER_SIZE
            soTimeout = CONNECTION_TIMEOUT
        }
    }
    
    /**
     * 启动UDP服务器
     */
    private suspend fun startUdpServer(configuration: NetworkConfiguration) {
        udpSocket = DatagramSocket(configuration.port).apply {
            sendBufferSize = SEND_BUFFER_SIZE
            receiveBufferSize = RECEIVE_BUFFER_SIZE
            soTimeout = CONNECTION_TIMEOUT
        }
    }
    
    // WebSocket 相关变量
    private var webSocketServer: WebSocketServerHandler? = null
    private var webSocketClient: okhttp3.WebSocket? = null
    private val okHttpClient = okhttp3.OkHttpClient.Builder()
        .connectTimeout(CONNECTION_TIMEOUT.toLong(), java.util.concurrent.TimeUnit.MILLISECONDS)
        .readTimeout(30, java.util.concurrent.TimeUnit.SECONDS)
        .writeTimeout(30, java.util.concurrent.TimeUnit.SECONDS)
        .pingInterval(HEARTBEAT_INTERVAL, java.util.concurrent.TimeUnit.MILLISECONDS)
        .build()
    
    /**
     * 启动WebSocket服务器
     * 使用简单的 TCP ServerSocket 模拟 WebSocket 握手
     */
    private suspend fun startWebSocketServer(configuration: NetworkConfiguration) {
        withContext(Dispatchers.IO) {
            serverSocket = ServerSocket(configuration.port).apply {
                soTimeout = CONNECTION_TIMEOUT
                reuseAddress = true
            }
            
            // 启动服务器监听协程
            coroutineScope.launch {
                while (currentCoroutineContext().isActive) {
                    try {
                        val clientSocket = serverSocket?.accept() ?: break
                        handleWebSocketHandshake(clientSocket)
                        tcpSocket = clientSocket
                        Log.d(TAG, "WebSocket client connected from ${clientSocket.inetAddress}")
                    } catch (e: SocketTimeoutException) {
                        // 超时继续等待
                    } catch (e: Exception) {
                        Log.e(TAG, "Error accepting WebSocket connection", e)
                        break
                    }
                }
            }
            
            Log.d(TAG, "WebSocket server started on port ${configuration.port}")
        }
    }
    
    /**
     * 处理 WebSocket 握手
     */
    private suspend fun handleWebSocketHandshake(socket: Socket) {
        withContext(Dispatchers.IO) {
            try {
                val reader = socket.getInputStream().bufferedReader()
                val writer = socket.getOutputStream().bufferedWriter()
                
                // 读取 HTTP 请求头
                val requestLines = mutableListOf<String>()
                var line = reader.readLine()
                while (line != null && line.isNotEmpty()) {
                    requestLines.add(line)
                    line = reader.readLine()
                }
                
                // 查找 Sec-WebSocket-Key
                var webSocketKey = ""
                for (requestLine in requestLines) {
                    if (requestLine.startsWith("Sec-WebSocket-Key:", ignoreCase = true)) {
                        webSocketKey = requestLine.substringAfter(":").trim()
                        break
                    }
                }
                
                // 计算 Accept Key
                val acceptKey = calculateWebSocketAcceptKey(webSocketKey)
                
                // 发送握手响应
                val response = """
                    HTTP/1.1 101 Switching Protocols
                    Upgrade: websocket
                    Connection: Upgrade
                    Sec-WebSocket-Accept: $acceptKey
                    
                """.trimIndent().replace("\n", "\r\n") + "\r\n"
                
                writer.write(response)
                writer.flush()
                
                Log.d(TAG, "WebSocket handshake completed")
                
            } catch (e: Exception) {
                Log.e(TAG, "WebSocket handshake failed", e)
                throw e
            }
        }
    }
    
    /**
     * 计算 WebSocket Accept Key
     */
    private fun calculateWebSocketAcceptKey(key: String): String {
        val magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        val combined = key + magic
        val sha1 = java.security.MessageDigest.getInstance("SHA-1")
        val hash = sha1.digest(combined.toByteArray())
        return android.util.Base64.encodeToString(hash, android.util.Base64.NO_WRAP)
    }
    
    /**
     * TCP客户端连接
     */
    private suspend fun connectTcp(address: String, configuration: NetworkConfiguration) {
        tcpSocket = withContext(Dispatchers.IO) {
            Socket().apply {
                tcpNoDelay = true
                sendBufferSize = SEND_BUFFER_SIZE
                receiveBufferSize = RECEIVE_BUFFER_SIZE
                soTimeout = CONNECTION_TIMEOUT
                connect(InetSocketAddress(address, configuration.port), CONNECTION_TIMEOUT)
            }
        }
    }
    
    /**
     * UDP客户端连接
     */
    private suspend fun connectUdp(address: String, configuration: NetworkConfiguration) {
        udpSocket = DatagramSocket().apply {
            sendBufferSize = SEND_BUFFER_SIZE
            receiveBufferSize = RECEIVE_BUFFER_SIZE
            soTimeout = CONNECTION_TIMEOUT
            connect(InetSocketAddress(address, configuration.port))
        }
    }
    
    /**
     * WebSocket客户端连接
     * 使用 OkHttp WebSocket 客户端
     */
    private suspend fun connectWebSocket(address: String, configuration: NetworkConfiguration) {
        withContext(Dispatchers.IO) {
            val url = "ws://$address:${configuration.port}/skybridge"
            val request = okhttp3.Request.Builder()
                .url(url)
                .build()
            
            val connectionResult = kotlinx.coroutines.CompletableDeferred<Boolean>()
            
            val listener = object : okhttp3.WebSocketListener() {
                override fun onOpen(webSocket: okhttp3.WebSocket, response: okhttp3.Response) {
                    Log.d(TAG, "WebSocket connected to $url")
                    webSocketClient = webSocket
                    connectionResult.complete(true)
                }
                
                override fun onMessage(webSocket: okhttp3.WebSocket, text: String) {
                    coroutineScope.launch {
                        try {
                            val data = text.toByteArray()
                            val packet = deserializePacket(data)
                            processReceivedPacket(packet)
                        } catch (e: Exception) {
                            Log.e(TAG, "Error processing WebSocket text message", e)
                        }
                    }
                }
                
                override fun onMessage(webSocket: okhttp3.WebSocket, bytes: okio.ByteString) {
                    coroutineScope.launch {
                        try {
                            val data = bytes.toByteArray()
                            val packet = deserializePacket(data)
                            processReceivedPacket(packet)
                        } catch (e: Exception) {
                            Log.e(TAG, "Error processing WebSocket binary message", e)
                        }
                    }
                }
                
                override fun onClosing(webSocket: okhttp3.WebSocket, code: Int, reason: String) {
                    Log.d(TAG, "WebSocket closing: $code - $reason")
                    webSocket.close(1000, null)
                }
                
                override fun onClosed(webSocket: okhttp3.WebSocket, code: Int, reason: String) {
                    Log.d(TAG, "WebSocket closed: $code - $reason")
                    _connectionState.value = ConnectionState.Disconnected
                }
                
                override fun onFailure(webSocket: okhttp3.WebSocket, t: Throwable, response: okhttp3.Response?) {
                    Log.e(TAG, "WebSocket failure", t)
                    if (!connectionResult.isCompleted) {
                        connectionResult.complete(false)
                    }
                    _connectionState.value = ConnectionState.Error(t.message ?: "WebSocket connection failed")
                }
            }
            
            okHttpClient.newWebSocket(request, listener)
            
            // 等待连接结果
            val connected = withTimeoutOrNull(CONNECTION_TIMEOUT.toLong()) {
                connectionResult.await()
            } ?: false
            
            if (!connected) {
                throw java.io.IOException("WebSocket connection timeout or failed")
            }
        }
    }
    
    /**
     * 通过 WebSocket 发送数据
     */
    private fun sendViaWebSocket(data: ByteArray): Boolean {
        return try {
            webSocketClient?.send(okio.ByteString.of(*data)) ?: false
        } catch (e: Exception) {
            Log.e(TAG, "Failed to send via WebSocket", e)
            false
        }
    }
    
    /**
     * 发送 WebSocket 帧（服务器模式）
     */
    private fun sendWebSocketFrame(data: ByteArray) {
        try {
            val outputStream = tcpSocket?.getOutputStream() ?: return
            
            // WebSocket 帧格式
            // FIN + opcode (binary = 0x82)
            outputStream.write(0x82)
            
            // 长度
            when {
                data.size <= 125 -> {
                    outputStream.write(data.size)
                }
                data.size <= 65535 -> {
                    outputStream.write(126)
                    outputStream.write((data.size shr 8) and 0xFF)
                    outputStream.write(data.size and 0xFF)
                }
                else -> {
                    outputStream.write(127)
                    for (i in 7 downTo 0) {
                        outputStream.write((data.size.toLong() shr (i * 8)).toInt() and 0xFF)
                    }
                }
            }
            
            // 数据
            outputStream.write(data)
            outputStream.flush()
            
        } catch (e: Exception) {
            Log.e(TAG, "Failed to send WebSocket frame", e)
        }
    }
    
    /**
     * 启动传输任务
     */
    private fun startTransmissionJobs() {
        sendJob = coroutineScope.launch {
            processSendQueue()
        }
        
        receiveJob = coroutineScope.launch {
            processReceiveData()
        }
        
        heartbeatJob = coroutineScope.launch {
            sendHeartbeat()
        }
        
        ackTimeoutJob = coroutineScope.launch {
            processAckTimeouts()
        }
    }
    
    /**
     * 处理发送队列
     */
    private suspend fun processSendQueue() {
        while (currentCoroutineContext().isActive) {
            try {
                val packet = sendQueue.receive()
                sendPacket(packet)
            } catch (e: Exception) {
                Log.e(TAG, "Error processing send queue", e)
                delay(100)
            }
        }
    }
    
    /**
     * 发送数据包
     */
    private suspend fun sendPacket(packet: TransmissionPacket) {
        try {
            val data = serializePacket(packet)
            
            when (currentConfiguration?.protocol) {
                TransmissionProtocol.TCP -> {
                    tcpSocket?.getOutputStream()?.write(data)
                }
                TransmissionProtocol.UDP -> {
                    val remoteAddress = udpSocket?.remoteSocketAddress as? InetSocketAddress
                    if (remoteAddress != null) {
                        val datagramPacket = DatagramPacket(
                            data, data.size,
                            remoteAddress.address, remoteAddress.port
                        )
                        udpSocket?.send(datagramPacket)
                    }
                }
                TransmissionProtocol.WEBSOCKET -> {
                    // WebSocket发送逻辑
                    if (webSocketClient != null) {
                        sendViaWebSocket(data)
                    } else if (tcpSocket != null) {
                        // 服务器模式：通过 TCP socket 发送 WebSocket 帧
                        sendWebSocketFrame(data)
                    }
                }
                TransmissionProtocol.WEBRTC -> {
                }
                null -> return
            }
            
            // 如果需要确认，添加到待确认列表
            if (packet.requiresAck) {
                pendingAcks[packet.sequenceNumber] = PendingPacket(
                    packet = packet,
                    timestamp = System.currentTimeMillis(),
                    retryCount = 0
                )
            }
            
        } catch (e: Exception) {
            Log.e(TAG, "Failed to send packet", e)
        }
    }
    
    /**
     * 处理接收数据
     */
    private suspend fun processReceiveData() {
        while (currentCoroutineContext().isActive) {
            try {
                val data = receiveRawData()
                if (data != null) {
                    val packet = deserializePacket(data)
                    processReceivedPacket(packet)
                }
            } catch (e: Exception) {
                Log.e(TAG, "Error processing receive data", e)
                delay(100)
            }
        }
    }
    
    /**
     * 接收原始数据
     */
    private suspend fun receiveRawData(): ByteArray? {
        return try {
            when (currentConfiguration?.protocol) {
                TransmissionProtocol.TCP -> {
                    val inputStream = tcpSocket?.getInputStream() ?: return null
                    val lengthBytes = ByteArray(4)
                    inputStream.read(lengthBytes)
                    val length = ByteBuffer.wrap(lengthBytes).int
                    
                    val data = ByteArray(length)
                    var totalRead = 0
                    while (totalRead < length) {
                        val read = inputStream.read(data, totalRead, length - totalRead)
                        if (read == -1) break
                        totalRead += read
                    }
                    data
                }
                
                TransmissionProtocol.UDP -> {
                    val buffer = ByteArray(MAX_PACKET_SIZE)
                    val packet = DatagramPacket(buffer, buffer.size)
                    udpSocket?.receive(packet)
                    packet.data.copyOf(packet.length)
                }
                
                TransmissionProtocol.WEBSOCKET -> {
                    // WebSocket接收逻辑
                    null
                }
                TransmissionProtocol.WEBRTC -> {
                    null
                }
                
                null -> null
            }
        } catch (e: SocketTimeoutException) {
            null // 超时是正常的，继续循环
        } catch (e: Exception) {
            Log.e(TAG, "Error receiving data", e)
            null
        }
    }
    
    /**
     * 处理接收到的数据包
     */
    private suspend fun processReceivedPacket(packet: TransmissionPacket) {
        // 发送确认包（如果需要）
        if (packet.requiresAck) {
            sendAckPacket(packet.sequenceNumber)
        }
        
        // 处理确认包
        if (packet.packetType == PacketType.ACK) {
            pendingAcks.remove(packet.ackNumber)
            return
        }
        
        // 处理心跳包
        if (packet.packetType == PacketType.HEARTBEAT) {
            return
        }
        
        // 处理数据包
        val receivedData = ReceivedData(
            sequenceNumber = packet.sequenceNumber,
            dataType = packet.dataType,
            data = packet.data,
            timestamp = System.currentTimeMillis()
        )
        
        _receivedData.tryEmit(receivedData)
        
        // 更新统计信息
        _transmissionStats.value = _transmissionStats.value.copy(
            bytesReceived = _transmissionStats.value.bytesReceived + packet.data.size,
            packetsReceived = _transmissionStats.value.packetsReceived + 1
        )
    }
    
    /**
     * 发送确认包
     */
    private suspend fun sendAckPacket(ackNumber: Long) {
        val ackPacket = TransmissionPacket(
            sequenceNumber = sequenceNumber.incrementAndGet(),
            packetType = PacketType.ACK,
            dataType = DataType.CONTROL,
            data = ByteArray(0),
            ackNumber = ackNumber,
            requiresAck = false,
            priority = PacketPriority.HIGH
        )
        
        sendQueue.send(ackPacket)
    }
    
    /**
     * 发送心跳包
     */
    private suspend fun sendHeartbeat() {
        while (currentCoroutineContext().isActive) {
            try {
                if (_connectionState.value is ConnectionState.Connected) {
                    val heartbeatPacket = TransmissionPacket(
                        sequenceNumber = sequenceNumber.incrementAndGet(),
                        packetType = PacketType.HEARTBEAT,
                        dataType = DataType.CONTROL,
                        data = ByteArray(0),
                        requiresAck = false,
                        priority = PacketPriority.HIGH
                    )
                    
                    sendQueue.send(heartbeatPacket)
                }
                
                delay(HEARTBEAT_INTERVAL)
                
            } catch (e: Exception) {
                Log.e(TAG, "Error sending heartbeat", e)
            }
        }
    }
    
    /**
     * 处理确认超时
     */
    private suspend fun processAckTimeouts() {
        while (currentCoroutineContext().isActive) {
            try {
                val currentTime = System.currentTimeMillis()
                val timeoutPackets = pendingAcks.values.filter { 
                    currentTime - it.timestamp > RETRY_DELAY 
                }
                
                timeoutPackets.forEach { pendingPacket ->
                    if (pendingPacket.retryCount < MAX_RETRY_COUNT) {
                        // 重传
                        val updatedPacket = pendingPacket.copy(
                            retryCount = pendingPacket.retryCount + 1,
                            timestamp = currentTime
                        )
                        pendingAcks[pendingPacket.packet.sequenceNumber] = updatedPacket
                        sendQueue.send(pendingPacket.packet)
                        
                        Log.d(TAG, "Retransmitting packet ${pendingPacket.packet.sequenceNumber}, retry ${updatedPacket.retryCount}")
                        
                    } else {
                        // 超过最大重试次数，移除
                        pendingAcks.remove(pendingPacket.packet.sequenceNumber)
                        Log.w(TAG, "Packet ${pendingPacket.packet.sequenceNumber} failed after ${MAX_RETRY_COUNT} retries")
                    }
                }
                
                delay(RETRY_DELAY)
                
            } catch (e: Exception) {
                Log.e(TAG, "Error processing ACK timeouts", e)
            }
        }
    }
    
    /**
     * 数据分片
     */
    private fun fragmentData(data: ByteArray, dataType: DataType, priority: PacketPriority): List<TransmissionPacket> {
        val maxPayloadSize = MAX_PACKET_SIZE - 64 // 预留协议头空间
        val packets = mutableListOf<TransmissionPacket>()
        
        var offset = 0
        var fragmentIndex = 0
        val totalFragments = (data.size + maxPayloadSize - 1) / maxPayloadSize
        
        while (offset < data.size) {
            val fragmentSize = minOf(maxPayloadSize, data.size - offset)
            val fragmentData = data.copyOfRange(offset, offset + fragmentSize)
            
            val packet = TransmissionPacket(
                sequenceNumber = sequenceNumber.incrementAndGet(),
                packetType = PacketType.DATA,
                dataType = dataType,
                data = fragmentData,
                fragmentIndex = fragmentIndex,
                totalFragments = totalFragments,
                requiresAck = currentConfiguration?.protocol != TransmissionProtocol.UDP,
                priority = priority
            )
            
            packets.add(packet)
            offset += fragmentSize
            fragmentIndex++
        }
        
        return packets
    }
    
    /**
     * 序列化数据包
     */
    private fun serializePacket(packet: TransmissionPacket): ByteArray {
        val buffer = ByteBuffer.allocate(1024 + packet.data.size)
        
        // 写入包头
        buffer.putLong(packet.sequenceNumber)
        buffer.putInt(packet.packetType.ordinal)
        buffer.putInt(packet.dataType.ordinal)
        buffer.putInt(packet.data.size)
        buffer.putInt(packet.fragmentIndex)
        buffer.putInt(packet.totalFragments)
        buffer.putLong(packet.ackNumber)
        buffer.put(if (packet.requiresAck) 1.toByte() else 0.toByte())
        buffer.putInt(packet.priority.ordinal)
        buffer.putLong(System.currentTimeMillis()) // 时间戳
        
        // 写入数据
        buffer.put(packet.data)
        
        val result = ByteArray(buffer.position())
        buffer.rewind()
        buffer.get(result)
        
        // 对于TCP，需要添加长度前缀
        return if (currentConfiguration?.protocol == TransmissionProtocol.TCP) {
            val lengthBuffer = ByteBuffer.allocate(4 + result.size)
            lengthBuffer.putInt(result.size)
            lengthBuffer.put(result)
            lengthBuffer.array()
        } else {
            result
        }
    }
    
    /**
     * 反序列化数据包
     */
    private fun deserializePacket(data: ByteArray): TransmissionPacket {
        val buffer = ByteBuffer.wrap(data)
        
        val sequenceNumber = buffer.long
        val packetType = PacketType.values()[buffer.int]
        val dataType = DataType.values()[buffer.int]
        val dataSize = buffer.int
        val fragmentIndex = buffer.int
        val totalFragments = buffer.int
        val ackNumber = buffer.long
        val requiresAck = buffer.get() == 1.toByte()
        val priority = PacketPriority.values()[buffer.int]
        val timestamp = buffer.long
        
        val packetData = ByteArray(dataSize)
        buffer.get(packetData)
        
        return TransmissionPacket(
            sequenceNumber = sequenceNumber,
            packetType = packetType,
            dataType = dataType,
            data = packetData,
            fragmentIndex = fragmentIndex,
            totalFragments = totalFragments,
            ackNumber = ackNumber,
            requiresAck = requiresAck,
            priority = priority
        )
    }
    
    /**
     * 清理资源
     */
    private fun cleanup() {
        try {
            tcpSocket?.close()
            tcpSocket = null
            
            udpSocket?.close()
            udpSocket = null
            
            serverSocket?.close()
            serverSocket = null
            
            sendQueue.close()
            pendingAcks.clear()
            
        } catch (e: Exception) {
            Log.e(TAG, "Error during cleanup", e)
        }
    }
}

/**
 * 连接状态
 */
sealed class ConnectionState {
    object Disconnected : ConnectionState()
    object Connecting : ConnectionState()
    object Disconnecting : ConnectionState()
    
    data class Connected(
        val remoteAddress: String,
        val port: Int,
        val protocol: TransmissionProtocol
    ) : ConnectionState()
    
    data class Error(
        val message: String
    ) : ConnectionState()
}

/**
 * 传输数据包
 */
data class TransmissionPacket(
    val sequenceNumber: Long,
    val packetType: PacketType,
    val dataType: DataType,
    val data: ByteArray,
    val fragmentIndex: Int = 0,
    val totalFragments: Int = 1,
    val ackNumber: Long = 0,
    val requiresAck: Boolean = true,
    val priority: PacketPriority = PacketPriority.NORMAL
) {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (javaClass != other?.javaClass) return false

        other as TransmissionPacket

        if (sequenceNumber != other.sequenceNumber) return false
        if (packetType != other.packetType) return false
        if (dataType != other.dataType) return false
        if (!data.contentEquals(other.data)) return false
        if (fragmentIndex != other.fragmentIndex) return false
        if (totalFragments != other.totalFragments) return false
        if (ackNumber != other.ackNumber) return false
        if (requiresAck != other.requiresAck) return false
        if (priority != other.priority) return false

        return true
    }

    override fun hashCode(): Int {
        var result = sequenceNumber.hashCode()
        result = 31 * result + packetType.hashCode()
        result = 31 * result + dataType.hashCode()
        result = 31 * result + data.contentHashCode()
        result = 31 * result + fragmentIndex
        result = 31 * result + totalFragments
        result = 31 * result + ackNumber.hashCode()
        result = 31 * result + requiresAck.hashCode()
        result = 31 * result + priority.hashCode()
        return result
    }
}

/**
 * 数据包类型
 */
enum class PacketType {
    DATA,
    ACK,
    HEARTBEAT,
    CONTROL
}

/**
 * 数据类型
 */
enum class DataType {
    VIDEO,
    AUDIO,
    CONTROL,
    METADATA
}

/**
 * 数据包优先级
 */
enum class PacketPriority {
    LOW,
    NORMAL,
    HIGH,
    CRITICAL
}

/**
 * 接收到的数据
 */
data class ReceivedData(
    val sequenceNumber: Long,
    val dataType: DataType,
    val data: ByteArray,
    val timestamp: Long
) {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (javaClass != other?.javaClass) return false

        other as ReceivedData

        if (sequenceNumber != other.sequenceNumber) return false
        if (dataType != other.dataType) return false
        if (!data.contentEquals(other.data)) return false
        if (timestamp != other.timestamp) return false

        return true
    }

    override fun hashCode(): Int {
        var result = sequenceNumber.hashCode()
        result = 31 * result + dataType.hashCode()
        result = 31 * result + data.contentHashCode()
        result = 31 * result + timestamp.hashCode()
        return result
    }
}

/**
 * 传输统计信息
 */
data class TransmissionStats(
    val bytesSent: Long = 0,
    val bytesReceived: Long = 0,
    val packetsSent: Long = 0,
    val packetsReceived: Long = 0,
    val packetsLost: Long = 0,
    val averageLatency: Long = 0,
    val bandwidth: Long = 0
)

/**
 * 待确认数据包
 */
private data class PendingPacket(
    val packet: TransmissionPacket,
    val timestamp: Long,
    val retryCount: Int
)

/**
 * 传输协议
 */
enum class TransmissionProtocol {
    TCP,
    UDP,
    WEBSOCKET,
    WEBRTC
}

/**
 * 网络配置
 */
data class NetworkConfiguration(
    val protocol: TransmissionProtocol,
    val port: Int,
    val bufferSize: Int = 64 * 1024,
    val timeout: Int = 10000,
    val enableHeartbeat: Boolean = true,
    val enableRetry: Boolean = true,
    val maxRetryCount: Int = 3
)
