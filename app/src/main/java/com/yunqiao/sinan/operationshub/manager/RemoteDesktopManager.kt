package com.yunqiao.sinan.operationshub.manager

import android.content.Context
import com.yunqiao.sinan.operationshub.model.RemoteConnectionStatus
import com.yunqiao.sinan.operationshub.model.RemoteSession
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch
import java.util.Locale
import com.yunqiao.sinan.manager.RemoteDesktopManager as CoreRemoteDesktopManager

/**
 * 远程桌面管理器包装器，桥接核心远程桌面引擎。
 */
class RemoteDesktopManager(context: Context) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val coreManager = CoreRemoteDesktopManager(context)

    private val _activeSessions = MutableStateFlow<List<RemoteSession>>(emptyList())
    val activeSessions: StateFlow<List<RemoteSession>> = _activeSessions.asStateFlow()

    private val _connectionStatus = MutableStateFlow(RemoteConnectionStatus.DISCONNECTED)
    val connectionStatus: StateFlow<RemoteConnectionStatus> = _connectionStatus.asStateFlow()

    init {
        scope.launch {
            coreManager.activeSessions.collect { sessions ->
                _activeSessions.value = sessions.map { it.toOperationsSession() }
            }
        }
        scope.launch {
            coreManager.connectionStatus.collect { status ->
                _connectionStatus.value = status.toOperationsStatus()
            }
        }
    }

    suspend fun initialize(): Boolean {
        return coreManager.startServer()
    }

    fun connectToDevice(deviceId: String, fallbackAccount: String? = null) {
        coreManager.connectToDevice(deviceId, fallbackAccount)
    }

    fun connectViaAccount(accountId: String) {
        coreManager.connectViaAccount(accountId)
    }

    fun getServerStatus(): Map<String, Any> = coreManager.getServerStatus()

    fun disconnect() {
        coreManager.disconnect()
    }

    fun cleanup() {
        coreManager.release()
        scope.cancel()
        _activeSessions.value = emptyList()
        _connectionStatus.value = RemoteConnectionStatus.DISCONNECTED
    }
}

private fun com.yunqiao.sinan.manager.RemoteSession.toOperationsSession(): RemoteSession {
    val status = if (isActive) {
        RemoteConnectionStatus.STREAMING
    } else {
        RemoteConnectionStatus.CONNECTED
    }
    return RemoteSession(
        sessionId = sessionId,
        deviceName = clientAddress,
        deviceIp = clientAddress,
        status = status,
        startTime = startTime,
        width = frameWidth,
        height = frameHeight,
        username = null,
        connectionType = "QUIC"
    )
}

private fun String.toOperationsStatus(): RemoteConnectionStatus {
    return when (lowercase(Locale.getDefault())) {
        "connecting" -> RemoteConnectionStatus.CONNECTING
        "connected" -> RemoteConnectionStatus.CONNECTED
        else -> RemoteConnectionStatus.DISCONNECTED
    }
}
