package com.skybridge.compass.discovery.presentation.viewmodels

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.skybridge.compass.discovery.domain.entities.DiscoveredDevice
import com.skybridge.compass.discovery.domain.entities.DiscoveryProtocol
import com.skybridge.compass.discovery.domain.entities.DiscoveryProtocolProfiles
import com.skybridge.compass.discovery.domain.repositories.DeviceDiscoveryRepository
import com.skybridge.compass.discovery.domain.usecases.ConnectToDeviceUseCase
import com.skybridge.compass.discovery.domain.usecases.DisconnectFromDeviceUseCase
import com.skybridge.compass.discovery.domain.usecases.StartDeviceDiscoveryUseCase
import com.skybridge.compass.discovery.domain.usecases.StopDeviceDiscoveryUseCase
import com.skybridge.compass.discovery.domain.usecases.ObserveNearbyPayloadsUseCase
import com.skybridge.compass.discovery.domain.usecases.SendNearbyPayloadUseCase
import com.skybridge.compass.discovery.domain.usecases.GetWifiAwareNetworkUseCase
import com.skybridge.compass.discovery.domain.usecases.SendNearbyFileUseCase
import com.skybridge.compass.discovery.domain.usecases.SendNearbyStreamUseCase
import com.skybridge.compass.discovery.domain.usecases.ObserveNearbyTransferUpdatesUseCase
import com.skybridge.compass.discovery.domain.usecases.CancelNearbyPayloadUseCase
import com.skybridge.compass.discovery.domain.entities.NearbyPayload
import com.skybridge.compass.discovery.domain.entities.NearbyTransferUpdate
import com.skybridge.compass.discovery.data.services.DeviceListService
import android.net.Uri
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.ParcelFileDescriptor
import java.io.BufferedInputStream
import java.io.InputStream
import kotlin.math.max
import com.skybridge.compass.discovery.presentation.events.DeviceDiscoveryEvent
import com.skybridge.compass.discovery.presentation.states.DeviceDiscoveryState
import com.skybridge.compass.discovery.presentation.states.DeviceSortBy
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.flow.onStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import javax.inject.Inject

/**
 * 设备发现ViewModel
 * 
 * 管理设备发现的UI状态和用户交互
 */
@HiltViewModel
class DeviceDiscoveryViewModel @Inject constructor(
    private val startDiscoveryUseCase: StartDeviceDiscoveryUseCase,
    private val stopDiscoveryUseCase: StopDeviceDiscoveryUseCase,
    private val connectToDeviceUseCase: ConnectToDeviceUseCase,
    private val disconnectFromDeviceUseCase: DisconnectFromDeviceUseCase,
    private val observeNearbyPayloadsUseCase: ObserveNearbyPayloadsUseCase,
    private val sendNearbyPayloadUseCase: SendNearbyPayloadUseCase,
    private val getWifiAwareNetworkUseCase: GetWifiAwareNetworkUseCase,
    private val sendNearbyFileUseCase: SendNearbyFileUseCase,
    private val sendNearbyStreamUseCase: SendNearbyStreamUseCase,
    private val observeNearbyTransferUpdatesUseCase: ObserveNearbyTransferUpdatesUseCase,
    private val cancelNearbyPayloadUseCase: CancelNearbyPayloadUseCase,
    private val deviceListService: DeviceListService
) : ViewModel() {
    private var discoveryJob: Job? = null
    
    // 导出/导入操作结果
    private val _exportImportResult = MutableStateFlow<ExportImportResult?>(null)
    val exportImportResult: StateFlow<ExportImportResult?> = _exportImportResult.asStateFlow()
    
    sealed class ExportImportResult {
        data class ExportSuccess(val json: String) : ExportImportResult()
        data class ImportSuccess(val count: Int) : ExportImportResult()
        data class Error(val message: String) : ExportImportResult()
    }
    
    private val _uiState = MutableStateFlow(DeviceDiscoveryState())
    val uiState: StateFlow<DeviceDiscoveryState> = _uiState.asStateFlow()
    
    /**
     * 处理UI事件
     */
    fun onEvent(event: DeviceDiscoveryEvent) {
        when (event) {
            is DeviceDiscoveryEvent.StartDiscovery -> {
                startDiscovery(event.protocols)
            }
            is DeviceDiscoveryEvent.StopDiscovery -> {
                stopDiscovery()
            }
            is DeviceDiscoveryEvent.ConnectToDevice -> {
                connectToDevice(event.device)
            }
            is DeviceDiscoveryEvent.DisconnectFromDevice -> {
                disconnectFromDevice(event.deviceId)
            }
            is DeviceDiscoveryEvent.RefreshDevices -> {
                refreshDevices()
            }
            is DeviceDiscoveryEvent.ClearError -> {
                clearError()
            }
            is DeviceDiscoveryEvent.SelectDevice -> {
                selectDevice(event.device)
            }
            is DeviceDiscoveryEvent.ToggleProtocol -> {
                toggleProtocol(event.protocol)
            }
            is DeviceDiscoveryEvent.UpdateSearchQuery -> {
                updateSearchQuery(event.query)
            }
            is DeviceDiscoveryEvent.ToggleDeviceTypeFilter -> {
                toggleDeviceTypeFilter(event.deviceType)
            }
            is DeviceDiscoveryEvent.ChangeSortBy -> {
                changeSortBy(event.sortBy)
            }
            is DeviceDiscoveryEvent.ToggleDetails -> {
                toggleDetails()
            }
            is DeviceDiscoveryEvent.ClearFilters -> {
                clearFilters()
            }
            is DeviceDiscoveryEvent.RetryConnection -> {
                connectToDevice(event.device)
            }
            is DeviceDiscoveryEvent.ViewDeviceDetails -> {
                selectDevice(event.device)
            }
            is DeviceDiscoveryEvent.ExportDeviceList -> {
                exportDeviceList()
            }
            is DeviceDiscoveryEvent.ImportDeviceList -> {
                importDeviceList(event.json)
            }
        }
    }

    /**
     * 示例：观察某设备的 Nearby 字节负载。
     * 调用后会在 ViewModel 作用域内持续收集数据，调用方可在此处接入 UI 更新。
     */
    fun observeNearbyFor(deviceId: String) {
        observeNearbyPayloadsUseCase(deviceId)
            .onEach { payload ->
                when (payload) {
                    is NearbyPayload.Bytes -> {
                        val text = try {
                            payload.data.toString(Charsets.UTF_8)
                        } catch (_: Throwable) {
                            "(binary ${payload.data.size} bytes)"
                        }
                        _nearbyMessages.tryEmit(UiNearbyMessage.Text(text))
                    }
                    is NearbyPayload.FilePayload -> {
                        val pfd: ParcelFileDescriptor? = payload.pfd
                        if (pfd != null) {
                            // 先仅解析文件头获取 MIME 与尺寸，避免直接解码大图导致内存压力
                            val info = peekImageInfo(pfd)
                            if (info != null && isImageMime(info.mime)) {
                                // 延迟加载：记录文件句柄，UI 需要时再调用 loadImageThumbnail()
                                pendingFilePayloads[payload.payloadId] = pfd
                                _nearbyMessages.tryEmit(
                                    UiNearbyMessage.ImageInfo(
                                        payloadId = payload.payloadId,
                                        mime = info.mime ?: "image/*",
                                        width = info.width,
                                        height = info.height
                                    )
                                )
                            } else {
                                // 非图片：关闭句柄并直接提示文件接收
                                try { pfd.close() } catch (_: Throwable) {}
                                _nearbyMessages.tryEmit(UiNearbyMessage.FileReceived(payload.payloadId))
                            }
                        } else {
                            _nearbyMessages.tryEmit(UiNearbyMessage.FileReceived(payload.payloadId))
                        }
                    }
                    is NearbyPayload.StreamPayload -> {
                        val input: InputStream = payload.input
                        viewModelScope.launch(kotlinx.coroutines.Dispatchers.IO) {
                            val preview = try {
                                val bis = BufferedInputStream(input)
                                val buf = ByteArray(8 * 1024)
                                val read = bis.read(buf)
                                if (read > 0) buf.copyOf(read) else ByteArray(0)
                            } catch (_: Throwable) {
                                ByteArray(0)
                            } finally {
                                try { input.close() } catch (_: Throwable) {}
                            }
                            _nearbyMessages.tryEmit(UiNearbyMessage.StreamPreview(payload.payloadId, preview))
                        }
                    }
                }
            }
            .catch { e -> _nearbyMessages.tryEmit(UiNearbyMessage.Error(e.message ?: "观察 Nearby 失败")) }
            .launchIn(viewModelScope)
    }

    /**
     * 示例：发送文本到指定设备的 Nearby 端点。
     */
    fun sendNearbyText(deviceId: String, text: String) {
        viewModelScope.launch {
            val ok = sendNearbyPayloadUseCase(deviceId, text.toByteArray())
            if (!ok) {
                // 上报发送失败到 UI 状态
                _uiState.value = _uiState.value.copy(
                    error = "发送消息失败：无法连接到设备 $deviceId"
                )
                _nearbyMessages.tryEmit(UiNearbyMessage.Error("发送失败：目标设备不可达"))
            }
        }
    }

    /** 发送文件到指定设备（返回 payloadId 或 null） */
    fun sendNearbyFile(deviceId: String, pfd: ParcelFileDescriptor, onResult: (Long?) -> Unit = {}) {
        viewModelScope.launch {
            val payloadId = sendNearbyFileUseCase(deviceId, pfd)
            onResult(payloadId)
        }
    }

    /** 发送流到指定设备（返回 payloadId 或 null） */
    fun sendNearbyStream(deviceId: String, input: InputStream, onResult: (Long?) -> Unit = {}) {
        viewModelScope.launch {
            val payloadId = sendNearbyStreamUseCase(deviceId, input)
            onResult(payloadId)
        }
    }

    /** 观察传输进度并转换为 UI 消息 */
    fun observeTransferProgress(deviceId: String) {
        observeNearbyTransferUpdatesUseCase(deviceId)
            .onEach { upd ->
                val total = if (upd.totalBytes > 0) upd.totalBytes.toFloat() else -1f
                val progress = if (total > 0) (upd.bytesTransferred / total) else -1f
                _nearbyMessages.tryEmit(
                    UiNearbyMessage.TransferProgress(
                        payloadId = upd.payloadId,
                        progress = progress,
                        bytesTransferred = upd.bytesTransferred,
                        totalBytes = upd.totalBytes,
                        status = upd.status
                    )
                )
            }
            .catch { e -> _nearbyMessages.tryEmit(UiNearbyMessage.Error(e.message ?: "观察进度失败")) }
            .launchIn(viewModelScope)
    }

    /** 取消指定 payload 的传输 */
    fun cancelPayload(payloadId: Long, onResult: (Boolean) -> Unit = {}) {
        viewModelScope.launch {
            val ok = cancelNearbyPayloadUseCase(payloadId)
            onResult(ok)
            // 取消后释放可能保留的文件句柄
            if (ok) releaseFilePayload(payloadId)
        }
    }

    /**
     * 示例：获取 Wi‑Fi Aware 的 Network（若已建立数据通道）。
     */
    fun findAwareNetwork(deviceId: String): android.net.Network? {
        return getWifiAwareNetworkUseCase(deviceId)
    }

    // UI 友好消息模型与流
    private val _nearbyMessages = kotlinx.coroutines.flow.MutableSharedFlow<UiNearbyMessage>(replay = 0, extraBufferCapacity = 64)
    val nearbyMessages: kotlinx.coroutines.flow.Flow<UiNearbyMessage> = _nearbyMessages

    // 延迟加载：缓存收到的文件句柄（仅图片），供后续解码缩略图或原图
    private val pendingFilePayloads = mutableMapOf<Long, ParcelFileDescriptor>()

    sealed class UiNearbyMessage {
        data class Text(val text: String) : UiNearbyMessage()
        data class ImageThumbnail(val payloadId: Long, val bitmap: Bitmap) : UiNearbyMessage()
        data class ImageInfo(val payloadId: Long, val mime: String, val width: Int, val height: Int) : UiNearbyMessage()
        data class FileReceived(val payloadId: Long) : UiNearbyMessage()
        data class StreamPreview(val payloadId: Long, val previewBytes: ByteArray) : UiNearbyMessage()
        data class TransferProgress(
            val payloadId: Long,
            val progress: Float, // -1 表示未知总大小
            val bytesTransferred: Long,
            val totalBytes: Long,
            val status: NearbyTransferUpdate.Status
        ) : UiNearbyMessage()
        data class Error(val message: String) : UiNearbyMessage()
    }

    /**
     * 延迟加载：按需解码图片缩略图（最大边不超过 maxSize），并输出 ImageThumbnail。
     * 注意：解码后保留文件句柄，便于后续可能的原图加载；调用 releaseFilePayload 可主动释放。
     */
    fun loadImageThumbnail(payloadId: Long, maxSize: Int = 512) {
        val pfd = pendingFilePayloads[payloadId] ?: return
        viewModelScope.launch(kotlinx.coroutines.Dispatchers.IO) {
            try {
                val bounds = peekImageInfo(pfd)
                if (bounds == null) {
                    _nearbyMessages.tryEmit(UiNearbyMessage.FileReceived(payloadId))
                    return@launch
                }
                val (reqW, reqH) = computeTargetSize(bounds.width, bounds.height, maxSize)
                val opts = BitmapFactory.Options().apply {
                    inPreferredConfig = Bitmap.Config.RGB_565
                    inSampleSize = calculateInSampleSize(bounds.width, bounds.height, reqW, reqH)
                }
                val bmp = BitmapFactory.decodeFileDescriptor(pfd.fileDescriptor, null, opts)
                if (bmp != null) {
                    _nearbyMessages.tryEmit(UiNearbyMessage.ImageThumbnail(payloadId, bmp))
                } else {
                    _nearbyMessages.tryEmit(UiNearbyMessage.FileReceived(payloadId))
                }
            } catch (t: Throwable) {
                _nearbyMessages.tryEmit(UiNearbyMessage.Error("图片解码失败: ${t.message ?: "unknown"}"))
            }
        }
    }

    /** 主动释放保留的文件句柄，避免资源泄露 */
    fun releaseFilePayload(payloadId: Long) {
        pendingFilePayloads.remove(payloadId)?.let { pfd ->
            try { pfd.close() } catch (_: Throwable) {}
        }
    }

    override fun onCleared() {
        discoveryJob?.cancel()
        super.onCleared()
        // 释放所有未处理的文件句柄
        val it = pendingFilePayloads.iterator()
        while (it.hasNext()) {
            val entry = it.next()
            try { entry.value.close() } catch (_: Throwable) {}
            it.remove()
        }
    }

    // --------- 工具方法：图片探测与采样计算 ---------
    private data class ImagePeek(val mime: String?, val width: Int, val height: Int)

    private fun peekImageInfo(pfd: ParcelFileDescriptor): ImagePeek? {
        return try {
            val opts = BitmapFactory.Options().apply {
                inJustDecodeBounds = true
            }
            BitmapFactory.decodeFileDescriptor(pfd.fileDescriptor, null, opts)
            if (opts.outWidth > 0 && opts.outHeight > 0) ImagePeek(opts.outMimeType, opts.outWidth, opts.outHeight) else null
        } catch (_: Throwable) {
            null
        }
    }

    private fun isImageMime(mime: String?): Boolean {
        if (mime.isNullOrBlank()) return false
        return mime.startsWith("image/")
    }

    private fun computeTargetSize(origW: Int, origH: Int, maxSize: Int): Pair<Int, Int> {
        val maxDim = max(origW, origH).coerceAtLeast(1)
        val scale = maxDim.toFloat() / maxSize.toFloat()
        return if (scale <= 1f) origW to origH else (origW / scale).toInt().coerceAtLeast(1) to (origH / scale).toInt().coerceAtLeast(1)
    }

    private fun calculateInSampleSize(origW: Int, origH: Int, reqW: Int, reqH: Int): Int {
        var inSampleSize = 1
        var halfW = origW / 2
        var halfH = origH / 2
        while ((halfW / inSampleSize) >= reqW && (halfH / inSampleSize) >= reqH) {
            inSampleSize *= 2
        }
        return inSampleSize.coerceAtLeast(1)
    }
    
    /**
     * 开始设备发现
     */
    private fun startDiscovery(protocols: Set<DiscoveryProtocol>? = null) {
        val previousJob = discoveryJob
        previousJob?.cancel()
        discoveryJob = viewModelScope.launch {
            previousJob?.join()
            val selectedProtocols = protocols ?: _uiState.value.selectedProtocols
            
            startDiscoveryUseCase(selectedProtocols)
                .onStart {
                    _uiState.value = _uiState.value.copy(
                        isLoading = true,
                        isDiscovering = true,
                        error = null
                    )
                }
                .catch { exception: Throwable ->
                    _uiState.value = _uiState.value.copy(
                        isLoading = false,
                        isDiscovering = false,
                        error = exception.message ?: "设备发现失败"
                    )
                }
                .collect { devices: List<DiscoveredDevice> ->
                    _uiState.value = _uiState.value.copy(
                        isLoading = false,
                        devices = devices,
                        isDiscovering = true,
                        error = null
                    )
                }
        }
    }
    
    /**
     * 停止设备发现
     */
    private fun stopDiscovery() {
        discoveryJob?.cancel()
        discoveryJob = null
        viewModelScope.launch {
            try {
                stopDiscoveryUseCase()
                _uiState.value = _uiState.value.copy(
                    isLoading = false,
                    isDiscovering = false
                )
            } catch (e: Exception) {
                _uiState.value = _uiState.value.copy(
                    error = e.message ?: "停止发现失败"
                )
            }
        }
    }
    
    /**
     * 连接到设备
     */
    private fun connectToDevice(device: DiscoveredDevice) {
        viewModelScope.launch {
            try {
                _uiState.value = _uiState.value.copy(
                    connectingDeviceId = device.id
                )
                
                val success = connectToDeviceUseCase(device)
                
                if (success) {
                    // 更新设备列表中的连接状态
                    val updatedDevices = _uiState.value.devices.map { d ->
                        if (d.id == device.id) {
                            d.copy(isConnected = true)
                        } else {
                            d
                        }
                    }
                    
                    _uiState.value = _uiState.value.copy(
                        devices = updatedDevices,
                        connectedDevices = _uiState.value.connectedDevices + device,
                        connectingDeviceId = null
                    )
                } else {
                    _uiState.value = _uiState.value.copy(
                        error = "连接设备失败: ${device.name}",
                        connectingDeviceId = null
                    )
                }
            } catch (e: Exception) {
                _uiState.value = _uiState.value.copy(
                    error = e.message ?: "连接设备时发生错误",
                    connectingDeviceId = null
                )
            }
        }
    }
    
    /**
     * 断开设备连接
     */
    private fun disconnectFromDevice(deviceId: String) {
        viewModelScope.launch {
            try {
                disconnectFromDeviceUseCase(deviceId)
                
                // 更新设备列表中的连接状态
                val updatedDevices = _uiState.value.devices.map { device ->
                    if (device.id == deviceId) {
                        device.copy(isConnected = false)
                    } else {
                        device
                    }
                }
                
                val updatedConnectedDevices = _uiState.value.connectedDevices.filter { 
                    it.id != deviceId 
                }
                
                _uiState.value = _uiState.value.copy(
                    devices = updatedDevices,
                    connectedDevices = updatedConnectedDevices
                )
            } catch (e: Exception) {
                _uiState.value = _uiState.value.copy(
                    error = e.message ?: "断开连接时发生错误"
                )
            }
        }
    }
    
    /**
     * 刷新设备列表
     */
    private fun refreshDevices() {
        stopDiscovery()
        startDiscovery()
    }
    
    /**
     * 清除错误信息
     */
    private fun clearError() {
        _uiState.value = _uiState.value.copy(error = null)
    }
    
    /**
     * 选择设备
     */
    private fun selectDevice(device: DiscoveredDevice?) {
        _uiState.value = _uiState.value.copy(selectedDevice = device)
    }
    
    /**
     * 切换发现协议
     */
    private fun toggleProtocol(protocol: DiscoveryProtocol) {
        val currentProtocols = _uiState.value.selectedProtocols.toMutableSet()
        
        if (currentProtocols.contains(protocol)) {
            currentProtocols.remove(protocol)
        } else {
            currentProtocols.add(protocol)
        }
        
        _uiState.value = _uiState.value.copy(
            selectedProtocols = currentProtocols.ifEmpty { DiscoveryProtocolProfiles.appleInteropDefaults }
        )
    }

    /**
     * 更新搜索查询
     */
    private fun updateSearchQuery(query: String) {
        _uiState.value = _uiState.value.copy(searchQuery = query)
    }

    /**
     * 切换设备类型过滤器
     */
    private fun toggleDeviceTypeFilter(deviceType: com.skybridge.compass.discovery.domain.entities.DeviceType) {
        val currentFilters = _uiState.value.deviceTypeFilter.toMutableSet()
        if (currentFilters.contains(deviceType)) {
            currentFilters.remove(deviceType)
        } else {
            currentFilters.add(deviceType)
        }
        _uiState.value = _uiState.value.copy(deviceTypeFilter = currentFilters)
    }

    /**
     * 更改排序方式
     */
    private fun changeSortBy(sortBy: DeviceSortBy) {
        _uiState.value = _uiState.value.copy(sortBy = sortBy)
    }

    /**
     * 切换详细信息显示
     */
    private fun toggleDetails() {
        _uiState.value = _uiState.value.copy(showDetails = !_uiState.value.showDetails)
    }

    /**
     * 清除所有过滤器
     */
    private fun clearFilters() {
        _uiState.value = _uiState.value.copy(
            searchQuery = "",
            deviceTypeFilter = emptySet()
        )
    }
    
    /**
     * 导出设备列表
     */
    private fun exportDeviceList() {
        viewModelScope.launch {
            try {
                val devices = _uiState.value.devices
                val json = deviceListService.exportDevices(devices)
                _exportImportResult.value = ExportImportResult.ExportSuccess(json)
            } catch (e: Exception) {
                _exportImportResult.value = ExportImportResult.Error(
                    e.message ?: "导出设备列表失败"
                )
            }
        }
    }
    
    /**
     * 导入设备列表
     */
    private fun importDeviceList(json: String) {
        viewModelScope.launch {
            try {
                val result = deviceListService.importDevices(json)
                result.fold(
                    onSuccess = { importedDevices ->
                        // 合并设备列表
                        val currentDevices = _uiState.value.devices
                        val mergedDevices = deviceListService.mergeDevices(
                            currentDevices,
                            importedDevices
                        )
                        
                        _uiState.value = _uiState.value.copy(devices = mergedDevices)
                        _exportImportResult.value = ExportImportResult.ImportSuccess(
                            importedDevices.size
                        )
                    },
                    onFailure = { error ->
                        _exportImportResult.value = ExportImportResult.Error(
                            error.message ?: "导入设备列表失败"
                        )
                    }
                )
            } catch (e: Exception) {
                _exportImportResult.value = ExportImportResult.Error(
                    e.message ?: "导入设备列表失败"
                )
            }
        }
    }
    
    /**
     * 清除导出/导入结果
     */
    fun clearExportImportResult() {
        _exportImportResult.value = null
    }
    
    /**
     * 获取设备统计信息
     */
    fun getDeviceStats(): Map<String, Int> {
        val devices = _uiState.value.devices
        return mapOf(
            "total" to devices.size,
            "connected" to devices.count { it.isConnected },
            "ios" to devices.count { it.type == com.skybridge.compass.discovery.domain.entities.DeviceType.IOS },
            "android" to devices.count { it.type == com.skybridge.compass.discovery.domain.entities.DeviceType.ANDROID },
            "macos" to devices.count { it.type == com.skybridge.compass.discovery.domain.entities.DeviceType.MACOS },
            "windows" to devices.count { it.type == com.skybridge.compass.discovery.domain.entities.DeviceType.WINDOWS }
        )
    }
}
