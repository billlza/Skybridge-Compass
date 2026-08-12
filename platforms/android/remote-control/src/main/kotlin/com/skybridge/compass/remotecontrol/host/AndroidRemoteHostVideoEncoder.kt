package com.skybridge.compass.remotecontrol.host

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.view.Surface
import com.skybridge.compass.core.utils.Logger
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicBoolean

/**
 * MediaCodec-based H.264/HEVC surface encoder for the Android remote-desktop host.
 *
 * The encoder is configured from a clamped [AndroidRemoteHostStreamPlan] (15–60 fps, <= 1920x1080).
 * It exposes an input [Surface] (fed by a MediaProjection virtual display) and pushes encoded frames
 * to a callback as [HostEncodedFrame], which is exactly what is needed to build a
 * `ScreenData`/`SCREEN_DATA` frame.
 *
 * All MediaCodec interaction is isolated in this class so the plan/clamp/decision logic
 * ([AndroidRemoteHostStreamPlan], [AndroidRemoteControlHostAccessPolicy]) stays testable without a
 * device.
 */
class AndroidRemoteHostVideoEncoder(
    private val plan: AndroidRemoteHostStreamPlan,
    private val onFrame: (HostEncodedFrame) -> Unit,
    private val onError: (Throwable) -> Unit = {},
) {
    private var codec: MediaCodec? = null
    private var inputSurface: Surface? = null
    private var drainThread: Thread? = null
    private val running = AtomicBoolean(false)

    /** The surface the virtual display should render into. Valid only between [start] and [stop]. */
    val surface: Surface?
        get() = inputSurface

    /**
     * Configure and start the encoder. Returns the input [Surface] to attach to the virtual display.
     * Throws on encoder initialization failure so the caller can present an error and tear down.
     */
    fun start(): Surface {
        check(codec == null) { "encoder already started" }
        val format = MediaFormat.createVideoFormat(plan.codec.mimeType, plan.width, plan.height).apply {
            setInteger(
                MediaFormat.KEY_COLOR_FORMAT,
                MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface,
            )
            setInteger(MediaFormat.KEY_BIT_RATE, plan.bitRateBitsPerSecond)
            setInteger(MediaFormat.KEY_FRAME_RATE, plan.frameRate)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, plan.keyFrameIntervalSeconds)
        }
        val created = MediaCodec.createEncoderByType(plan.codec.mimeType)
        try {
            created.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            val surface = created.createInputSurface()
            created.start()
            codec = created
            inputSurface = surface
            running.set(true)
            startDrainLoop()
            Logger.remoteControl(
                "host encoder started ${plan.codec.wireFormat} ${plan.width}x${plan.height}@${plan.frameRate}",
            )
            return surface
        } catch (t: Throwable) {
            runCatching { created.release() }
            codec = null
            inputSurface = null
            throw t
        }
    }

    private fun startDrainLoop() {
        val thread = Thread({ drainLoop() }, "host-video-encoder-drain")
        thread.isDaemon = true
        drainThread = thread
        thread.start()
    }

    private fun drainLoop() {
        val bufferInfo = MediaCodec.BufferInfo()
        try {
            while (running.get()) {
                val encoder = codec ?: break
                val outputIndex = encoder.dequeueOutputBuffer(bufferInfo, DEQUEUE_TIMEOUT_US)
                if (outputIndex < 0) continue
                val outputBuffer: ByteBuffer? = encoder.getOutputBuffer(outputIndex)
                if (outputBuffer != null && bufferInfo.size > 0 &&
                    (bufferInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) == 0
                ) {
                    outputBuffer.position(bufferInfo.offset)
                    outputBuffer.limit(bufferInfo.offset + bufferInfo.size)
                    val bytes = ByteArray(bufferInfo.size)
                    outputBuffer.get(bytes)
                    val isKey = (bufferInfo.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME) != 0
                    onFrame(
                        HostEncodedFrame(
                            data = bytes,
                            width = plan.width,
                            height = plan.height,
                            format = plan.codec.wireFormat,
                            presentationTimeUs = bufferInfo.presentationTimeUs,
                            isKeyFrame = isKey,
                        ),
                    )
                }
                encoder.releaseOutputBuffer(outputIndex, false)
                if ((bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) break
            }
        } catch (t: Throwable) {
            if (running.get()) {
                Logger.remoteControl("host encoder drain failed", t)
                onError(t)
            }
        }
    }

    /** Stop and release the encoder and its input surface. Idempotent. */
    fun stop() {
        if (!running.compareAndSet(true, false) && codec == null) return
        running.set(false)
        runCatching { drainThread?.join(DRAIN_JOIN_TIMEOUT_MS) }
        drainThread = null
        codec?.let { encoder ->
            runCatching { encoder.stop() }
            runCatching { encoder.release() }
        }
        codec = null
        runCatching { inputSurface?.release() }
        inputSurface = null
        Logger.remoteControl("host encoder stopped")
    }

    private companion object {
        const val DEQUEUE_TIMEOUT_US: Long = 10_000
        const val DRAIN_JOIN_TIMEOUT_MS: Long = 500
    }
}
