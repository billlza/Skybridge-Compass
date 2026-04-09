package com.skybridge.compass.mirroring.data.services

import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.media.MediaCodec
import android.media.MediaFormat
import android.media.MediaCodecInfo
import android.util.Log
import android.Manifest
import androidx.annotation.RequiresPermission
import android.annotation.SuppressLint
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.launch
import kotlinx.coroutines.delay
import kotlinx.coroutines.cancel
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong

/**
 * 音频镜像服务
 * 负责音频录制和传输
 */
class AudioMirroringService {
    
    private val audioSessions = ConcurrentHashMap<String, AudioSession>()
    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    
    /**
     * 开始音频捕获
     */
    @RequiresPermission(Manifest.permission.RECORD_AUDIO)
    suspend fun startAudioCapture(
        sessionId: String,
        sampleRate: Int = 44100,
        channelConfig: Int = AudioFormat.CHANNEL_IN_STEREO,
        audioFormat: Int = AudioFormat.ENCODING_PCM_16BIT
    ) = withContext(Dispatchers.IO) {
        try {
            if (audioSessions.containsKey(sessionId)) {
                Log.w(TAG, "音频会话已存在: $sessionId")
                return@withContext
            }
            
            val audioSession = AudioSession(
                sessionId = sessionId,
                sampleRate = sampleRate,
                channelConfig = channelConfig,
                audioFormat = audioFormat
            )
            
            audioSessions[sessionId] = audioSession
            audioSession.start()
            
            Log.d(TAG, "音频捕获开始: $sessionId")
            
        } catch (e: Exception) {
            Log.e(TAG, "开始音频捕获失败: $sessionId", e)
            throw e
        }
    }
    
    /**
     * 停止音频捕获
     */
    suspend fun stopAudioCapture(sessionId: String) = withContext(Dispatchers.IO) {
        try {
            audioSessions[sessionId]?.let { session ->
                session.stop()
                audioSessions.remove(sessionId)
                Log.d(TAG, "音频捕获停止: $sessionId")
            }
        } catch (e: Exception) {
            Log.e(TAG, "停止音频捕获失败: $sessionId", e)
        }
    }
    
    /**
     * 暂停音频捕获
     */
    suspend fun pauseAudioCapture(sessionId: String) {
        audioSessions[sessionId]?.pause()
    }
    
    /**
     * 恢复音频捕获
     */
    suspend fun resumeAudioCapture(sessionId: String) {
        audioSessions[sessionId]?.resume()
    }
    
    /**
     * 设置音频数据回调
     */
    fun setAudioDataCallback(
        sessionId: String,
        callback: (ByteArray, Long) -> Unit
    ) {
        audioSessions[sessionId]?.setDataCallback(callback)
    }
    
    /**
     * 获取音频统计信息
     */
    fun getAudioStats(sessionId: String): Map<String, Any>? {
        return audioSessions[sessionId]?.getStats()
    }
    
    /**
     * 更新音频质量
     */
    suspend fun updateAudioQuality(
        sessionId: String,
        sampleRate: Int,
        bitrate: Int
    ) {
        audioSessions[sessionId]?.updateQuality(sampleRate, bitrate)
    }
    
    /**
     * 清理所有音频会话
     */
    fun cleanup() {
        try {
            serviceScope.cancel()
            audioSessions.values.forEach { it.stop() }
            audioSessions.clear()
            Log.d(TAG, "音频镜像服务已清理")
        } catch (e: Exception) {
            Log.e(TAG, "清理音频镜像服务失败", e)
        }
    }
    
    companion object {
        private const val TAG = "AudioMirroringService"
    }
}

/**
 * 音频会话
 */
private class AudioSession(
    private val sessionId: String,
    private val sampleRate: Int,
    private val channelConfig: Int,
    private val audioFormat: Int
) {
    
    private var audioRecord: AudioRecord? = null
    private var mediaCodec: MediaCodec? = null
    private var isRecording = false
    private var isPaused = false
    
    private val sessionScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val stats = AudioStats()
    
    private var audioDataCallback: ((ByteArray, Long) -> Unit)? = null
    
    /**
     * 开始音频会话
     */
    @RequiresPermission(Manifest.permission.RECORD_AUDIO)
    suspend fun start() = withContext(Dispatchers.IO) {
        try {
            // 初始化AudioRecord
            initializeAudioRecord()
            
            // 初始化音频编码器
            initializeAudioEncoder()
            
            // 开始录制
            audioRecord?.startRecording()
            isRecording = true
            
            // 启动音频捕获循环
            startAudioCapture()
            
            Log.d(TAG, "音频会话启动成功: $sessionId")
            
        } catch (e: Exception) {
            Log.e(TAG, "音频会话启动失败: $sessionId", e)
            throw e
        }
    }
    
    /**
     * 停止音频会话
     */
    fun stop() {
        isRecording = false
        sessionScope.cancel()
        
        try {
            audioRecord?.apply {
                stop()
                release()
            }
            
            mediaCodec?.apply {
                stop()
                release()
            }
            
            Log.d(TAG, "音频会话停止: $sessionId")
            
        } catch (e: Exception) {
            Log.e(TAG, "停止音频会话时出错: $sessionId", e)
        } finally {
            audioRecord = null
            mediaCodec = null
        }
    }
    
    /**
     * 暂停音频会话
     */
    fun pause() {
        isPaused = true
        audioRecord?.stop()
    }
    
    /**
     * 恢复音频会话
     */
    fun resume() {
        isPaused = false
        audioRecord?.startRecording()
    }
    
    /**
     * 设置音频数据回调
     */
    fun setDataCallback(callback: (ByteArray, Long) -> Unit) {
        audioDataCallback = callback
    }
    
    /**
     * 获取统计信息
     */
    fun getStats(): Map<String, Any> {
        return mapOf(
            "sessionId" to sessionId,
            "sampleRate" to sampleRate,
            "isRecording" to isRecording,
            "isPaused" to isPaused,
            "samplesRecorded" to stats.samplesRecorded.get(),
            "bytesRecorded" to stats.bytesRecorded.get(),
            "averageLevel" to stats.averageLevel.get(),
            "peakLevel" to stats.peakLevel.get(),
            "dropouts" to stats.dropouts.get()
        )
    }
    
    /**
     * 更新音频质量
     */
    suspend fun updateQuality(sampleRate: Int, bitrate: Int) = withContext(Dispatchers.IO) {
        try {
            // 重新配置编码器
            mediaCodec?.let { codec ->
                try {
                    codec.stop()
                } catch (e: Exception) {
                }
                val format = MediaFormat.createAudioFormat(
                    MediaFormat.MIMETYPE_AUDIO_AAC,
                    sampleRate,
                    getChannelCount()
                ).apply {
                    setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
                    setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
                    setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 16384)
                }
                codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
                codec.start()
            }
            
            Log.d(TAG, "音频质量更新: $sessionId, 比特率: ${bitrate}bps")
            
        } catch (e: Exception) {
            Log.e(TAG, "更新音频质量失败: $sessionId", e)
        }
    }
    
    /**
     * 初始化AudioRecord
     */
    @RequiresPermission(Manifest.permission.RECORD_AUDIO)
    @SuppressLint("MissingPermission")
    private fun initializeAudioRecord() {
        val bufferSize = AudioRecord.getMinBufferSize(sampleRate, channelConfig, audioFormat)
        audioRecord = AudioRecord(
            MediaRecorder.AudioSource.MIC,
            sampleRate,
            channelConfig,
            audioFormat,
            bufferSize * 2
        )
        if (audioRecord?.state != AudioRecord.STATE_INITIALIZED) {
            throw IllegalStateException("AudioRecord初始化失败")
        }
    }
    
    /**
     * 初始化音频编码器
     */
    private fun initializeAudioEncoder() {
        val format = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, sampleRate, getChannelCount()).apply {
            setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
            setInteger(MediaFormat.KEY_BIT_RATE, 128000) // 128kbps
            setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 16384)
        }
        
        mediaCodec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC).apply {
            configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            start()
        }
    }
    
    /**
     * 开始音频捕获循环
     */
    private fun startAudioCapture() {
        sessionScope.launch {
            val audioRecord = audioRecord ?: return@launch
            val mediaCodec = mediaCodec ?: return@launch
            
            val bufferSize = AudioRecord.getMinBufferSize(sampleRate, channelConfig, audioFormat)
            val buffer = ByteArray(bufferSize)
            
            while (isRecording) {
                try {
                    if (isPaused) {
                        delay(100)
                        continue
                    }
                    
                    val bytesRead = audioRecord.read(buffer, 0, buffer.size)
                    
                    if (bytesRead > 0) {
                        val timestamp = System.nanoTime() / 1000 // 转换为微秒
                        
                        // 更新统计信息
                        updateAudioStats(buffer, bytesRead)
                        
                        // 编码音频数据
                        encodeAudioData(mediaCodec, buffer, bytesRead, timestamp)
                        
                    } else {
                        // 读取失败，记录dropout
                        stats.dropouts.incrementAndGet()
                        Log.w(TAG, "音频读取失败: $bytesRead")
                    }
                    
                } catch (e: Exception) {
                    Log.e(TAG, "音频捕获循环出错: $sessionId", e)
                    stats.dropouts.incrementAndGet()
                }
            }
        }
    }
    
    /**
     * 编码音频数据
     */
    private suspend fun encodeAudioData(
        codec: MediaCodec,
        buffer: ByteArray,
        size: Int,
        timestamp: Long
    ) {
        withContext(Dispatchers.IO) {
            try {
            // 获取输入缓冲区
            val inputBufferIndex = codec.dequeueInputBuffer(TIMEOUT_US)
            if (inputBufferIndex >= 0) {
                val inputBuffer = codec.getInputBuffer(inputBufferIndex)
                inputBuffer?.clear()
                inputBuffer?.put(buffer, 0, size)
                
                codec.queueInputBuffer(inputBufferIndex, 0, size, timestamp, 0)
            }
            
            // 获取输出缓冲区
            val bufferInfo = MediaCodec.BufferInfo()
            val outputBufferIndex = codec.dequeueOutputBuffer(bufferInfo, TIMEOUT_US)
            
            if (outputBufferIndex >= 0) {
                val outputBuffer = codec.getOutputBuffer(outputBufferIndex)
                
                if (outputBuffer != null && bufferInfo.size > 0) {
                    val encodedData = ByteArray(bufferInfo.size)
                    outputBuffer.get(encodedData)
                    
                    // 回调编码后的音频数据
                    audioDataCallback?.invoke(encodedData, timestamp)
                }
                
                codec.releaseOutputBuffer(outputBufferIndex, false)
            } else {
                // 无可用输出缓冲区
            }
            
            } catch (e: Exception) {
                Log.e(TAG, "音频编码失败: $sessionId", e)
            }
        }
    }
    
    /**
     * 更新音频统计信息
     */
    private fun updateAudioStats(buffer: ByteArray, size: Int) {
        stats.samplesRecorded.addAndGet(size / 2L) // 16位音频，每个样本2字节
        stats.bytesRecorded.addAndGet(size.toLong())
        
        // 计算音频电平
        var sum = 0L
        var peak = 0
        
        for (i in 0 until size step 2) {
            val sample = ((buffer[i + 1].toInt() shl 8) or (buffer[i].toInt() and 0xFF))
            val level = kotlin.math.abs(sample)
            sum += level
            if (level > peak) peak = level
        }
        
        val sampleCount = size / 2
        if (sampleCount > 0) {
            val averageLevel = (sum / sampleCount).toInt()
            stats.averageLevel.set((stats.averageLevel.get() + averageLevel) / 2L)
            
            if (peak.toLong() > stats.peakLevel.get()) {
                stats.peakLevel.set(peak.toLong())
            }
        }
    }
    
    /**
     * 获取声道数
     */
    private fun getChannelCount(): Int {
        return when (channelConfig) {
            AudioFormat.CHANNEL_IN_MONO -> 1
            AudioFormat.CHANNEL_IN_STEREO -> 2
            else -> 1
        }
    }
    
    companion object {
        private const val TAG = "AudioSession"
        private const val TIMEOUT_US = 10000L
    }
}

/**
 * 音频统计信息
 */
private class AudioStats {
    val samplesRecorded = AtomicLong(0)
    val bytesRecorded = AtomicLong(0)
    val averageLevel = AtomicLong(0)
    val peakLevel = AtomicLong(0)
    val dropouts = AtomicLong(0)
}