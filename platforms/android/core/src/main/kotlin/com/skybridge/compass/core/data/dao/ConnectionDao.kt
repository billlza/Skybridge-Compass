package com.skybridge.compass.core.data.dao

import androidx.room.*
import kotlinx.coroutines.flow.Flow
import com.skybridge.compass.core.data.model.Connection
import com.skybridge.compass.core.data.model.ConnectionStatus
import com.skybridge.compass.core.data.model.ConnectionProtocol

/**
 * 连接数据访问对象
 */
@Dao
interface ConnectionDao {
    
    @Query("SELECT * FROM connections ORDER BY establishedAt DESC")
    fun getAllConnections(): Flow<List<Connection>>
    
    @Query("SELECT * FROM connections WHERE deviceId = :deviceId ORDER BY establishedAt DESC")
    fun getConnectionsByDevice(deviceId: String): Flow<List<Connection>>
    
    @Query("SELECT * FROM connections WHERE id = :connectionId")
    suspend fun getConnectionById(connectionId: String): Connection?
    
    @Query("SELECT * FROM connections WHERE status = :status ORDER BY establishedAt DESC")
    fun getConnectionsByStatus(status: ConnectionStatus): Flow<List<Connection>>
    
    @Query("SELECT * FROM connections WHERE protocol = :protocol ORDER BY establishedAt DESC")
    fun getConnectionsByProtocol(protocol: ConnectionProtocol): Flow<List<Connection>>
    
    @Query("SELECT * FROM connections WHERE status = 'CONNECTED' ORDER BY establishedAt DESC")
    fun getActiveConnections(): Flow<List<Connection>>
    
    @Query("SELECT * FROM connections WHERE deviceId = :deviceId AND status = 'CONNECTED' LIMIT 1")
    suspend fun getActiveConnectionForDevice(deviceId: String): Connection?
    
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertConnection(connection: Connection)
    
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertConnections(connections: List<Connection>)
    
    @Update
    suspend fun updateConnection(connection: Connection)
    
    @Query("UPDATE connections SET status = :status, lastActivity = :lastActivity WHERE id = :connectionId")
    suspend fun updateConnectionStatus(connectionId: String, status: ConnectionStatus, lastActivity: Long)
    
    @Query("UPDATE connections SET latency = :latency, bandwidth = :bandwidth, lastActivity = :lastActivity WHERE id = :connectionId")
    suspend fun updateConnectionMetrics(connectionId: String, latency: Long, bandwidth: Long, lastActivity: Long)
    
    @Query("UPDATE connections SET errorCount = errorCount + 1, lastActivity = :lastActivity WHERE id = :connectionId")
    suspend fun incrementErrorCount(connectionId: String, lastActivity: Long)
    
    @Delete
    suspend fun deleteConnection(connection: Connection)
    
    @Query("DELETE FROM connections WHERE id = :connectionId")
    suspend fun deleteConnectionById(connectionId: String)
    
    @Query("DELETE FROM connections WHERE deviceId = :deviceId")
    suspend fun deleteConnectionsByDevice(deviceId: String)
    
    @Query("DELETE FROM connections WHERE status IN ('DISCONNECTED', 'ERROR', 'TIMEOUT') AND lastActivity < :threshold")
    suspend fun deleteInactiveConnectionsOlderThan(threshold: Long)
    
    @Query("DELETE FROM connections")
    suspend fun deleteAllConnections()
}