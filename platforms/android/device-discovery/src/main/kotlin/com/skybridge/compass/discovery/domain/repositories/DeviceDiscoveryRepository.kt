package com.skybridge.compass.discovery.domain.repositories

import com.skybridge.compass.discovery.domain.entities.DiscoveredDevice
import com.skybridge.compass.discovery.domain.entities.DiscoveryProtocol
import com.skybridge.compass.discovery.domain.entities.DiscoveryProtocolProfiles
import android.net.Network
import com.skybridge.compass.discovery.domain.entities.NearbyPayload
import com.skybridge.compass.discovery.domain.entities.NearbyTransferUpdate
import android.os.ParcelFileDescriptor
import java.io.InputStream
import kotlinx.coroutines.flow.Flow

/**
 * 设备发现仓库接口
 * 
 * 定义设备发现的核心业务逻辑
 */
interface DeviceDiscoveryRepository {
    
    /**
     * 开始设备发现
     * 
     * @param protocols 要使用的发现协议列表
     * @return 发现的设备流
     */
    suspend fun startDiscovery(
        protocols: Set<DiscoveryProtocol> = DiscoveryProtocolProfiles.appleInteropDefaults
    ): Flow<List<DiscoveredDevice>>
    
    /**
     * 停止设备发现
     */
    suspend fun stopDiscovery()
    
    /**
     * 获取已发现的设备列表
     */
    suspend fun getDiscoveredDevices(): List<DiscoveredDevice>
    
    /**
     * 连接到指定设备
     * 
     * @param device 要连接的设备
     * @return 连接是否成功
     */
    suspend fun connectToDevice(device: DiscoveredDevice): Boolean
    
    /**
     * 断开与设备的连接
     * 
     * @param deviceId 设备ID
     */
    suspend fun disconnectFromDevice(deviceId: String)
    
    /**
     * 获取设备连接状态
     * 
     * @param deviceId 设备ID
     * @return 连接状态流
     */
    fun getDeviceConnectionStatus(deviceId: String): Flow<Boolean>
    
    /**
     * 清除设备缓存
     */
    suspend fun clearDeviceCache()

    /**
     * 观察 Nearby 的负载数据（支持 BYTES/FILE/STREAM）。
     *
     * @param deviceId 设备ID（需与 Nearby endpoint 映射一致）
     * @return 封装后的 NearbyPayload 流
     */
    fun observeNearbyPayloads(deviceId: String): Flow<NearbyPayload>

    /**
     * 发送字节数据到 Nearby 端点。
     *
     * @param deviceId 设备ID（需与 Nearby endpoint 映射一致）
     * @param data 字节数据
     * @return 是否发送成功
     */
    suspend fun sendNearbyBytes(deviceId: String, data: ByteArray): Boolean

    /**
     * 发送文件到 Nearby 端点。
     *
     * @param deviceId 设备ID（需与 Nearby endpoint 映射一致）
     * @param pfd 发送的文件描述符
     * @return 成功返回 payloadId，失败返回 null
     */
    suspend fun sendNearbyFile(deviceId: String, pfd: ParcelFileDescriptor): Long?

    /**
     * 发送流到 Nearby 端点。
     *
     * @param deviceId 设备ID（需与 Nearby endpoint 映射一致）
     * @param input 输入流（成功发送后由 Nearby 持有，失败时会关闭）
     * @return 成功返回 payloadId，失败返回 null
     */
    suspend fun sendNearbyStream(deviceId: String, input: InputStream): Long?

    /**
     * 观察指定设备的传输进度更新。
     */
    fun observeNearbyTransferUpdates(deviceId: String): Flow<NearbyTransferUpdate>

    /**
     * 取消指定 payload 的传输。
     */
    suspend fun cancelNearbyPayload(payloadId: Long): Boolean

    /**
     * 获取 Wi‑Fi Aware 已建立的数据通道网络。
     *
     * @param deviceId 设备ID
     * @return 可用的 Network，如未建立则为 null
     */
    fun getWifiAwareNetwork(deviceId: String): Network?
}
