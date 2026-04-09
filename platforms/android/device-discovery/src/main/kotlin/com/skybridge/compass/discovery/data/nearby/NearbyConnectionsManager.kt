package com.skybridge.compass.discovery.data.nearby

import com.google.android.gms.nearby.connection.ConnectionLifecycleCallback
import com.google.android.gms.nearby.connection.ConnectionResolution
import com.google.android.gms.nearby.connection.ConnectionsClient
import com.google.android.gms.nearby.connection.ConnectionsStatusCodes
import com.google.android.gms.nearby.connection.Payload
import com.google.android.gms.nearby.connection.PayloadCallback
import com.google.android.gms.nearby.connection.PayloadTransferUpdate
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import javax.inject.Inject
import javax.inject.Singleton

/**
 * 封装 Nearby Connections 的连接与数据收发。
 */
@Singleton
class NearbyConnectionsManager @Inject constructor(
    private val connectionsClient: ConnectionsClient
) {
    private val payloadFlows: MutableMap<String, MutableSharedFlow<Payload>> = mutableMapOf()
    private val transferUpdateFlows: MutableMap<String, MutableSharedFlow<PayloadTransferUpdate>> = mutableMapOf()

    /**
     * 发起与指定端点的连接，并在连接建立后提供数据回调。
     */
    suspend fun requestConnection(localName: String, endpointId: String): Boolean {
        val result = CompletableDeferred<Boolean>()

        val payloadCallback = object : PayloadCallback() {
            override fun onPayloadReceived(remoteEndpointId: String, payload: Payload) {
                val flow = payloadFlows.getOrPut(remoteEndpointId) {
                    MutableSharedFlow(replay = 0, extraBufferCapacity = 64)
                }
                flow.tryEmit(payload)
            }

            override fun onPayloadTransferUpdate(remoteEndpointId: String, update: PayloadTransferUpdate) {
                val flow = transferUpdateFlows.getOrPut(remoteEndpointId) {
                    MutableSharedFlow(replay = 0, extraBufferCapacity = 64)
                }
                flow.tryEmit(update)
            }
        }

        val lifecycleCallback = object : ConnectionLifecycleCallback() {
            override fun onConnectionInitiated(remoteEndpointId: String, connectionInfo: com.google.android.gms.nearby.connection.ConnectionInfo) {
                connectionsClient.acceptConnection(remoteEndpointId, payloadCallback)
            }

            override fun onConnectionResult(remoteEndpointId: String, resolution: ConnectionResolution) {
                when (resolution.status.statusCode) {
                    ConnectionsStatusCodes.STATUS_OK -> result.complete(true)
                    ConnectionsStatusCodes.STATUS_CONNECTION_REJECTED -> result.complete(false)
                    ConnectionsStatusCodes.STATUS_ERROR -> result.complete(false)
                    else -> result.complete(false)
                }
            }

            override fun onDisconnected(remoteEndpointId: String) {
                // 连接断开：不主动清除 flow，以便调用方仍可拉取断开前缓存的数据
            }
        }

        connectionsClient.requestConnection(localName, endpointId, lifecycleCallback)
            .addOnFailureListener { result.complete(false) }

        return result.await()
    }

    /**
     * 观察指定端点的负载数据。
     */
    fun observePayloads(endpointId: String): Flow<Payload> {
        return payloadFlows.getOrPut(endpointId) {
            MutableSharedFlow(replay = 0, extraBufferCapacity = 64)
        }
    }

    /**
     * 观察指定端点的传输进度更新。
     */
    fun observeTransferUpdates(endpointId: String): Flow<PayloadTransferUpdate> {
        return transferUpdateFlows.getOrPut(endpointId) {
            MutableSharedFlow(replay = 0, extraBufferCapacity = 64)
        }
    }

    /**
     * 发送字节数据到指定端点。
     */
    suspend fun sendBytes(endpointId: String, data: ByteArray): Boolean {
        val payload = Payload.fromBytes(data)
        val result = CompletableDeferred<Boolean>()
        connectionsClient.sendPayload(endpointId, payload)
            .addOnSuccessListener { result.complete(true) }
            .addOnFailureListener { result.complete(false) }
        return result.await()
    }

    /**
     * 发送文件到指定端点，成功返回 payloadId，失败返回 null。
     */
    suspend fun sendFile(endpointId: String, pfd: android.os.ParcelFileDescriptor): Long? {
        val payload = try {
            Payload.fromFile(pfd)
        } catch (t: Throwable) {
            try { pfd.close() } catch (_: Throwable) {}
            return null
        }
        val result = CompletableDeferred<Long?>()
        connectionsClient.sendPayload(endpointId, payload)
            .addOnSuccessListener { result.complete(payload.id) }
            .addOnFailureListener {
                try { pfd.close() } catch (_: Throwable) {}
                result.complete(null)
            }
        return result.await()
    }

    /**
     * 发送流到指定端点，成功返回 payloadId，失败返回 null。
     */
    suspend fun sendStream(endpointId: String, input: java.io.InputStream): Long? {
        val payload = try {
            Payload.fromStream(input)
        } catch (t: Throwable) {
            try { input.close() } catch (_: Throwable) {}
            return null
        }
        val result = CompletableDeferred<Long?>()
        connectionsClient.sendPayload(endpointId, payload)
            .addOnSuccessListener { result.complete(payload.id) }
            .addOnFailureListener {
                try { input.close() } catch (_: Throwable) {}
                result.complete(null)
            }
        return result.await()
    }

    /**
     * 取消指定 payload 的传输。
     */
    suspend fun cancelPayload(payloadId: Long): Boolean {
        val result = CompletableDeferred<Boolean>()
        connectionsClient.cancelPayload(payloadId)
            .addOnSuccessListener { result.complete(true) }
            .addOnFailureListener { result.complete(false) }
        return result.await()
    }

    /**
     * 主动断开与指定端点的连接。
     */
    fun disconnect(endpointId: String) {
        connectionsClient.disconnectFromEndpoint(endpointId)
    }
}