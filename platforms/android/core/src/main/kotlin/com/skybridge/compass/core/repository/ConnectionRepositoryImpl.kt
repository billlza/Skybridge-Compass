package com.skybridge.compass.core.repository

import com.skybridge.compass.core.data.dao.ConnectionDao
import com.skybridge.compass.core.data.model.Connection
import com.skybridge.compass.core.data.model.ConnectionStatus
import kotlinx.coroutines.flow.Flow
import javax.inject.Inject
import javax.inject.Singleton

/**
 * 连接仓库实现
 */
@Singleton
class ConnectionRepositoryImpl @Inject constructor(
    private val connectionDao: ConnectionDao
) : ConnectionRepository {

    override fun getAllConnections(): Flow<List<Connection>> =
        connectionDao.getAllConnections()

    override fun getConnectionsByDevice(deviceId: String): Flow<List<Connection>> =
        connectionDao.getConnectionsByDevice(deviceId)

    override fun getActiveConnections(): Flow<List<Connection>> =
        connectionDao.getActiveConnections()

    override suspend fun getConnectionById(connectionId: String): Connection? =
        connectionDao.getConnectionById(connectionId)

    override suspend fun getActiveConnectionForDevice(deviceId: String): Connection? =
        connectionDao.getActiveConnectionForDevice(deviceId)

    override suspend fun saveConnection(connection: Connection): Result<Unit> = runCatching<Unit> {
        connectionDao.insertConnection(connection)
    }

    override suspend fun updateConnectionStatus(
        connectionId: String,
        status: ConnectionStatus
    ): Result<Unit> = runCatching<Unit> {
        val now = System.currentTimeMillis()
        connectionDao.updateConnectionStatus(connectionId, status, now)
    }

    override suspend fun updateConnectionMetrics(
        connectionId: String,
        latency: Long,
        bandwidth: Long
    ): Result<Unit> = runCatching<Unit> {
        val now = System.currentTimeMillis()
        connectionDao.updateConnectionMetrics(connectionId, latency, bandwidth, now)
    }

    override suspend fun incrementErrorCount(connectionId: String): Result<Unit> =
        runCatching<Unit> {
            val now = System.currentTimeMillis()
            connectionDao.incrementErrorCount(connectionId, now)
        }

    override suspend fun deleteConnection(connectionId: String): Result<Unit> =
        runCatching<Unit> {
            connectionDao.deleteConnectionById(connectionId)
        }

    override suspend fun deleteConnectionsByDevice(deviceId: String): Result<Unit> =
        runCatching<Unit> {
            connectionDao.deleteConnectionsByDevice(deviceId)
        }

    override suspend fun cleanupInactiveConnections(olderThanMillis: Long): Result<Unit> =
        runCatching<Unit> {
            val threshold = System.currentTimeMillis() - olderThanMillis
            connectionDao.deleteInactiveConnectionsOlderThan(threshold)
        }
}
