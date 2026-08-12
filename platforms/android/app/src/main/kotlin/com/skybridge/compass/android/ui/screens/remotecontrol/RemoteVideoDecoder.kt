package com.skybridge.compass.android.ui.screens.remotecontrol

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageDecoder
import android.media.MediaCodec
import android.media.MediaFormat
import android.view.Surface
import android.view.SurfaceHolder
import android.view.SurfaceView
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.viewinterop.AndroidView
import com.skybridge.compass.core.webrtc.AndroidRemoteVideoFormats
import kotlin.math.max

internal fun decodeRemoteStaticBitmap(payload: ByteArray): Bitmap? {
    if (payload.isEmpty()) return null
    runCatching {
        val source = ImageDecoder.createSource(java.nio.ByteBuffer.wrap(payload))
        return ImageDecoder.decodeBitmap(source) { decoder, _, _ ->
            decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
        }
    }
    return BitmapFactory.decodeByteArray(payload, 0, payload.size)
}

@Composable
internal fun RemoteVideoSurface(
    modifier: Modifier,
    frame: RemoteFrame,
    normalizedFormat: String,
    onDecoderError: (String?) -> Unit = {}
) {
    val context = LocalContext.current
    val decoder = remember(context) { SurfaceBackedRemoteVideoDecoder() }

    DisposableEffect(decoder) {
        onDispose { decoder.release() }
    }

    LaunchedEffect(decoder, onDecoderError) {
        decoder.onError = onDecoderError
    }

    LaunchedEffect(frame, normalizedFormat) {
        decoder.submit(frame, normalizedFormat)
    }

    AndroidView(
        modifier = modifier,
        factory = {
            SurfaceView(it).apply {
                holder.addCallback(object : SurfaceHolder.Callback {
                    override fun surfaceCreated(holder: SurfaceHolder) {
                        decoder.attachSurface(holder.surface)
                    }

                    override fun surfaceChanged(
                        holder: SurfaceHolder,
                        format: Int,
                        width: Int,
                        height: Int
                    ) {
                        decoder.attachSurface(holder.surface)
                    }

                    override fun surfaceDestroyed(holder: SurfaceHolder) {
                        decoder.detachSurface()
                    }
                })
            }
        }
    )
}

private class SurfaceBackedRemoteVideoDecoder {
    private data class PendingFrame(
        val frame: RemoteFrame,
        val normalizedFormat: String
    )

    private val lock = Any()
    private var surface: Surface? = null
    private var codec: MediaCodec? = null
    private var codecMimeType: String? = null
    private var codecWidth: Int = 0
    private var codecHeight: Int = 0
    private var pendingFrame: PendingFrame? = null
    private var lastQueuedPtsUs: Long = 0L

    /**
     * Surfaced to the ViewModel when the codec cannot render a frame (R6.11): either the normalized
     * format is not a video codec, or `MediaCodec` init/decode threw. On the throw path the codec is
     * released synchronously in [releaseCodecLocked] (well within the 2s bound R6.11 requires) and
     * this callback makes that stop-and-release observable to the UI so it presents the reason
     * instead of silently dropping the frame.
     */
    @Volatile
    var onError: (String?) -> Unit = {}

    fun attachSurface(newSurface: Surface?) {
        synchronized(lock) {
            if (surface === newSurface) return
            releaseCodecLocked()
            surface = newSurface
            renderPendingFrameLocked()
        }
    }

    fun detachSurface() {
        synchronized(lock) {
            releaseCodecLocked()
            surface = null
        }
    }

    fun submit(frame: RemoteFrame, normalizedFormat: String) {
        synchronized(lock) {
            pendingFrame = PendingFrame(frame = frame, normalizedFormat = normalizedFormat)
            renderPendingFrameLocked()
        }
    }

    fun release() {
        synchronized(lock) {
            pendingFrame = null
            releaseCodecLocked()
            surface = null
            lastQueuedPtsUs = 0L
        }
    }

    private fun renderPendingFrameLocked() {
        val pending = pendingFrame ?: return
        val targetSurface = surface ?: return
        val mimeType = when (pending.normalizedFormat) {
            AndroidRemoteVideoFormats.H264 -> MediaFormat.MIMETYPE_VIDEO_AVC
            AndroidRemoteVideoFormats.HEVC -> MediaFormat.MIMETYPE_VIDEO_HEVC
            else -> {
                // Not a video codec this decoder can render (R6.11): stop, release, surface the reason.
                pendingFrame = null
                releaseCodecLocked()
                onError(pending.normalizedFormat)
                return
            }
        }
        val payload = pending.frame.imageBytes
        if (payload.isEmpty()) return

        try {
            ensureCodecLocked(
                targetSurface = targetSurface,
                mimeType = mimeType,
                width = pending.frame.width,
                height = pending.frame.height,
                inputSize = payload.size
            )
            val activeCodec = codec ?: return
            val inputIndex = activeCodec.dequeueInputBuffer(0)
            if (inputIndex < 0) {
                return
            }

            val inputBuffer = activeCodec.getInputBuffer(inputIndex) ?: return
            inputBuffer.clear()
            inputBuffer.put(payload)

            val candidatePtsUs = (pending.frame.timestampSeconds * 1_000_000.0).toLong().coerceAtLeast(0L)
            val ptsUs = max(candidatePtsUs, lastQueuedPtsUs + 1L)
            lastQueuedPtsUs = ptsUs

            activeCodec.queueInputBuffer(
                inputIndex,
                0,
                payload.size,
                ptsUs,
                0
            )
            pendingFrame = null
            drainOutputLocked(activeCodec)
        } catch (t: Throwable) {
            // MediaCodec init/decode failed (R6.11): release decode resources promptly (synchronous,
            // well inside the 2s bound) and surface the decoder failure instead of dropping silently.
            pendingFrame = null
            releaseCodecLocked()
            onError(t.message ?: t.javaClass.simpleName)
        }
    }

    private fun ensureCodecLocked(
        targetSurface: Surface,
        mimeType: String,
        width: Int,
        height: Int,
        inputSize: Int
    ) {
        val activeCodec = codec
        if (
            activeCodec != null &&
            codecMimeType == mimeType &&
            codecWidth == width &&
            codecHeight == height
        ) {
            return
        }

        releaseCodecLocked()

        val mediaFormat = MediaFormat.createVideoFormat(mimeType, width, height).apply {
            setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, max(width * height, inputSize))
            setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
        }

        codec = MediaCodec.createDecoderByType(mimeType).apply {
            configure(mediaFormat, targetSurface, null, 0)
            start()
        }
        codecMimeType = mimeType
        codecWidth = width
        codecHeight = height
    }

    private fun drainOutputLocked(activeCodec: MediaCodec) {
        val info = MediaCodec.BufferInfo()
        while (true) {
            when (val outputIndex = activeCodec.dequeueOutputBuffer(info, 0)) {
                MediaCodec.INFO_TRY_AGAIN_LATER -> return
                MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> Unit
                else -> {
                    if (outputIndex >= 0) {
                        activeCodec.releaseOutputBuffer(outputIndex, true)
                    } else {
                        return
                    }
                }
            }
        }
    }

    private fun releaseCodecLocked() {
        runCatching { codec?.stop() }
        runCatching { codec?.release() }
        codec = null
        codecMimeType = null
        codecWidth = 0
        codecHeight = 0
        lastQueuedPtsUs = 0L
    }
}
