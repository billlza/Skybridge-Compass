package com.skybridge.compass.android.remote.host

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.os.Build
import android.os.Bundle
import android.view.Surface
import com.skybridge.compass.core.webrtc.AndroidRemoteVideoFormats
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.nio.ByteBuffer
import kotlin.math.max

internal data class AndroidRemoteHostStreamPlan(
    val width: Int,
    val height: Int,
    val codec: String,
    val frameRate: Int,
    val keyFrameInterval: Int,
    val bitrate: Int
) {
    val usesVideoEncoder: Boolean
        get() = codec == AndroidRemoteVideoFormats.H264 || codec == AndroidRemoteVideoFormats.HEVC
}

internal data class AndroidRemoteHostEncodedFrame(
    val bytes: ByteArray,
    val format: String,
    val width: Int,
    val height: Int,
    val isKeyFrame: Boolean
)

internal class AndroidRemoteHostVideoEncoder(
    private val scope: CoroutineScope,
    private val onFrame: (AndroidRemoteHostEncodedFrame) -> Unit,
    private val onError: (Throwable) -> Unit
) {
    private var codec: MediaCodec? = null
    private var inputSurface: Surface? = null
    private var drainJob: Job? = null
    private var currentPlan: AndroidRemoteHostStreamPlan? = null
    private var codecConfigAnnexB: ByteArray = ByteArray(0)

    fun start(plan: AndroidRemoteHostStreamPlan): Surface {
        require(plan.usesVideoEncoder) { "Video encoder requires H.264 or HEVC plan" }
        stop()

        val mimeType = when (plan.codec) {
            AndroidRemoteVideoFormats.HEVC -> MediaFormat.MIMETYPE_VIDEO_HEVC
            else -> MediaFormat.MIMETYPE_VIDEO_AVC
        }

        val iFrameIntervalSeconds = max(1, plan.keyFrameInterval / max(1, plan.frameRate))
        val mediaFormat = MediaFormat.createVideoFormat(mimeType, plan.width, plan.height).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, plan.bitrate)
            setInteger(MediaFormat.KEY_FRAME_RATE, plan.frameRate)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, iFrameIntervalSeconds)
            setInteger(MediaFormat.KEY_BITRATE_MODE, MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR)
            setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, max(plan.width * plan.height, plan.bitrate / 8))
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                setInteger(MediaFormat.KEY_PRIORITY, 0)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
            }
            when (plan.codec) {
                AndroidRemoteVideoFormats.H264 -> {
                    setInteger(
                        MediaFormat.KEY_PROFILE,
                        MediaCodecInfo.CodecProfileLevel.AVCProfileHigh
                    )
                }

                AndroidRemoteVideoFormats.HEVC -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                        setInteger(
                            MediaFormat.KEY_PROFILE,
                            MediaCodecInfo.CodecProfileLevel.HEVCProfileMain
                        )
                    }
                }
            }
        }

        val createdCodec = MediaCodec.createEncoderByType(mimeType).apply {
            configure(mediaFormat, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        }
        val createdSurface = createdCodec.createInputSurface()
        createdCodec.start()
        codec = createdCodec
        inputSurface = createdSurface
        currentPlan = plan
        codecConfigAnnexB = ByteArray(0)

        drainJob = scope.launch(Dispatchers.IO) {
            drainLoop(createdCodec, plan)
        }

        requestKeyFrame()
        return createdSurface
    }

    fun requestKeyFrame() {
        val activeCodec = codec ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.KITKAT) {
            runCatching {
                activeCodec.setParameters(Bundle().apply {
                    putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0)
                })
            }
        }
    }

    fun stop() {
        drainJob?.cancel()
        drainJob = null
        runCatching { codec?.signalEndOfInputStream() }
        runCatching { codec?.stop() }
        runCatching { codec?.release() }
        runCatching { inputSurface?.release() }
        codec = null
        inputSurface = null
        currentPlan = null
        codecConfigAnnexB = ByteArray(0)
    }

    private suspend fun drainLoop(
        activeCodec: MediaCodec,
        plan: AndroidRemoteHostStreamPlan
    ) {
        val bufferInfo = MediaCodec.BufferInfo()
        try {
            while (scope.isActive) {
                val outputIndex = activeCodec.dequeueOutputBuffer(bufferInfo, 10_000)
                when {
                    outputIndex == MediaCodec.INFO_TRY_AGAIN_LATER -> {
                        delay(4)
                    }

                    outputIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        codecConfigAnnexB = extractCodecConfigAnnexB(activeCodec.outputFormat)
                    }

                    outputIndex >= 0 -> {
                        val buffer = activeCodec.getOutputBuffer(outputIndex)
                        if (buffer != null && bufferInfo.size > 0) {
                            buffer.position(bufferInfo.offset)
                            buffer.limit(bufferInfo.offset + bufferInfo.size)
                            val bytes = ByteArray(bufferInfo.size)
                            buffer.get(bytes)

                            if ((bufferInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0) {
                                codecConfigAnnexB = normalizeCodecConfig(bytes)
                            } else {
                                val annexBPayload = toAnnexB(bytes)
                                val isKeyFrame = (bufferInfo.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME) != 0
                                val outbound = if (isKeyFrame && codecConfigAnnexB.isNotEmpty()) {
                                    codecConfigAnnexB + annexBPayload
                                } else {
                                    annexBPayload
                                }
                                if (outbound.isNotEmpty()) {
                                    onFrame(
                                        AndroidRemoteHostEncodedFrame(
                                            bytes = outbound,
                                            format = plan.codec,
                                            width = plan.width,
                                            height = plan.height,
                                            isKeyFrame = isKeyFrame
                                        )
                                    )
                                }
                            }
                        }
                        activeCodec.releaseOutputBuffer(outputIndex, false)

                        if ((bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                            return
                        }
                    }
                }
            }
        } catch (throwable: Throwable) {
            onError(throwable)
        }
    }

    private fun extractCodecConfigAnnexB(format: MediaFormat): ByteArray {
        val collected = ArrayList<ByteArray>(4)
        for (index in 0..3) {
            val key = "csd-$index"
            if (!format.containsKey(key)) continue
            val data = format.getByteBuffer(key)?.toByteArray() ?: continue
            val normalized = normalizeCodecConfig(data)
            if (normalized.isNotEmpty()) {
                collected += normalized
            }
        }
        if (collected.isEmpty()) return ByteArray(0)
        return collected.fold(ByteArray(0)) { acc, bytes -> acc + bytes }
    }

    private fun normalizeCodecConfig(bytes: ByteArray): ByteArray {
        if (bytes.isEmpty()) return ByteArray(0)
        if (looksLikeAnnexB(bytes)) return bytes
        val converted = convertLengthPrefixedToAnnexB(bytes)
        if (converted.isNotEmpty()) return converted
        return startCode() + bytes
    }

    private fun toAnnexB(bytes: ByteArray): ByteArray {
        if (bytes.isEmpty()) return ByteArray(0)
        if (looksLikeAnnexB(bytes)) return bytes
        val converted = convertLengthPrefixedToAnnexB(bytes)
        return if (converted.isNotEmpty()) converted else startCode() + bytes
    }

    private fun convertLengthPrefixedToAnnexB(bytes: ByteArray): ByteArray {
        if (bytes.size < 4) return ByteArray(0)
        var offset = 0
        val output = ArrayList<ByteArray>()
        while (offset + 4 <= bytes.size) {
            val length = ByteBuffer.wrap(bytes, offset, 4).int
            offset += 4
            if (length <= 0 || offset + length > bytes.size) {
                return ByteArray(0)
            }
            output += startCode() + bytes.copyOfRange(offset, offset + length)
            offset += length
        }
        if (offset != bytes.size || output.isEmpty()) {
            return ByteArray(0)
        }
        return output.fold(ByteArray(0)) { acc, chunk -> acc + chunk }
    }

    private fun looksLikeAnnexB(bytes: ByteArray): Boolean =
        bytes.size >= 4 && (
            (bytes[0] == 0x00.toByte() && bytes[1] == 0x00.toByte() && bytes[2] == 0x00.toByte() && bytes[3] == 0x01.toByte()) ||
                (bytes.size >= 3 && bytes[0] == 0x00.toByte() && bytes[1] == 0x00.toByte() && bytes[2] == 0x01.toByte())
            )

    private fun startCode(): ByteArray = byteArrayOf(0x00, 0x00, 0x00, 0x01)

    private fun ByteBuffer.toByteArray(): ByteArray {
        val duplicate = duplicate()
        duplicate.position(0)
        val bytes = ByteArray(duplicate.remaining())
        duplicate.get(bytes)
        return bytes
    }
}
