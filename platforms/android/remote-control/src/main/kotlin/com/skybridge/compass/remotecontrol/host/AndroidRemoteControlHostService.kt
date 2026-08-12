package com.skybridge.compass.remotecontrol.host

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import androidx.core.app.NotificationCompat
import com.skybridge.compass.core.utils.Logger
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Foreground [Service] that owns the Android remote-desktop host capture session (R6.5/R6.6/R6.12).
 *
 * Lifecycle:
 *  - On [ACTION_START_REMOTE_CAPTURE] carrying a granted MediaProjection result, it starts a
 *    foreground service with a persistent, continuously-visible notification and — within the 2s
 *    budget — begins MediaProjection capture into an [AndroidRemoteHostVideoEncoder], pushing encoded
 *    frames through the [HostFrameSink] send seam.
 *  - On [ACTION_STOP_REMOTE_CAPTURE] (the exact action the RemoteControlViewModel stop-hook sends),
 *    within the 3s budget it stops capture, stops the service, removes the notification and emits a
 *    session-end notice to the peer.
 *  - If MediaProjection authorization is denied/revoked (missing result, projection failure, or the
 *    projection `onStop` callback), it does not start (or stops within 3s), surfaces a
 *    missing-authorization notice, and keeps the viewing session usable (the service does not touch
 *    the viewer transport).
 *
 * The FQN is `com.skybridge.compass.remotecontrol.host.AndroidRemoteControlHostService` and the stop
 * action is `com.skybridge.compass.action.STOP_REMOTE_CAPTURE`, matching the guarded stop-hook wired
 * by task 13.2.
 */
class AndroidRemoteControlHostService : Service() {

    private val mainHandler = Handler(Looper.getMainLooper())
    private var projection: MediaProjection? = null
    private var virtualDisplay: VirtualDisplay? = null
    private var encoder: AndroidRemoteHostVideoEncoder? = null
    private val capturing = AtomicBoolean(false)

    private val projectionCallback = object : MediaProjection.Callback() {
        override fun onStop() {
            // R6.12: authorization revoked at runtime.
            Logger.remoteControl("host MediaProjection revoked (onStop)")
            mainHandler.post { onAuthorizationLost(wasCapturing = capturing.get()) }
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP_REMOTE_CAPTURE -> {
                handleUserStop()
                return START_NOT_STICKY
            }
            ACTION_START_REMOTE_CAPTURE -> handleStart(intent)
            else -> {
                // Unknown/empty start (e.g. process restart): nothing to capture, don't linger.
                stopSelfAndNotification()
            }
        }
        return START_NOT_STICKY
    }

    private fun handleStart(intent: Intent) {
        val resultCode = intent.getIntExtra(EXTRA_RESULT_CODE, RESULT_CODE_INVALID)
        val resultData: Intent? = projectionResultData(intent)
        val authState = if (resultCode != RESULT_CODE_INVALID && resultData != null) {
            HostAuthorizationState.GRANTED
        } else {
            HostAuthorizationState.DENIED
        }

        val decision = AndroidRemoteControlHostAccessPolicy.decideStart(authState)
        // Always run as a foreground service with a visible notification before touching projection,
        // as required for mediaProjection foreground service type on modern Android.
        startForegroundWithNotification()

        if (!decision.startCapture) {
            // R6.12: denied — present missing-authorization notice, keep viewing session usable,
            // and stop within the budget without ever starting capture.
            if (decision.presentMissingAuthorizationNotice) presentMissingAuthorizationNotice()
            Logger.remoteControl("host capture not started: authorization $authState")
            stopSelfAndNotification()
            return
        }

        val started = runCatching {
            beginCapture(resultCode, requireNotNull(resultData))
        }
        if (started.isFailure) {
            Logger.remoteControl("host capture start failed", started.exceptionOrNull())
            teardown(errorStopDecision())
        }
    }

    private fun projectionResultData(intent: Intent): Intent? =
        intent.getParcelableExtra(EXTRA_RESULT_DATA, Intent::class.java)

    private fun errorStopDecision(): HostStopDecision = HostStopDecision(
        stopCapture = true,
        stopForegroundService = true,
        removeNotification = true,
        sendSessionEndNotice = true,
        sessionEndReason = HostSessionEndReason.ERROR,
        presentMissingAuthorizationNotice = false,
        keepViewingSessionUsable = true,
    )

    private fun beginCapture(resultCode: Int, resultData: Intent) {
        val manager = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        val mediaProjection = manager.getMediaProjection(resultCode, resultData)
            ?: throw IllegalStateException("MediaProjection unavailable (authorization denied)")
        projection = mediaProjection
        mediaProjection.registerCallback(projectionCallback, mainHandler)

        val metrics = resources.displayMetrics
        val plan = AndroidRemoteHostStreamPlan.from(
            requestedWidth = metrics.widthPixels,
            requestedHeight = metrics.heightPixels,
            requestedFrameRate = DEFAULT_FRAME_RATE,
            requestedCodec = null,
        )

        val hostEncoder = AndroidRemoteHostVideoEncoder(
            plan = plan,
            onFrame = { frame -> frameSink?.onEncodedFrame(frame) },
            onError = { t ->
                Logger.remoteControl("host encoder error", t)
                mainHandler.post { teardown(errorStopDecision()) }
            },
        )
        val surface = hostEncoder.start()
        encoder = hostEncoder

        virtualDisplay = mediaProjection.createVirtualDisplay(
            VIRTUAL_DISPLAY_NAME,
            plan.width,
            plan.height,
            metrics.densityDpi,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
            surface,
            null,
            mainHandler,
        )
        capturing.set(true)
        Logger.remoteControl("host capture started ${plan.width}x${plan.height}@${plan.frameRate}")
    }

    private fun handleUserStop() {
        val decision = AndroidRemoteControlHostAccessPolicy.decideUserStop()
        teardown(decision)
    }

    private fun onAuthorizationLost(wasCapturing: Boolean) {
        val decision = AndroidRemoteControlHostAccessPolicy.decideAuthorizationLost(wasCapturing)
        if (decision.presentMissingAuthorizationNotice) presentMissingAuthorizationNotice()
        teardown(decision)
    }

    private fun teardown(decision: HostStopDecision) {
        if (decision.stopCapture) stopCaptureInternal()
        if (decision.sendSessionEndNotice) {
            decision.sessionEndReason?.let { reason -> frameSink?.onSessionEnd(reason) }
        }
        // keepViewingSessionUsable is honoured implicitly: this service never touches the viewer
        // transport; tearing it down leaves the viewing session intact.
        if (decision.stopForegroundService || decision.removeNotification) {
            stopSelfAndNotification()
        }
    }

    private fun stopCaptureInternal() {
        capturing.set(false)
        runCatching { virtualDisplay?.release() }
        virtualDisplay = null
        runCatching { encoder?.stop() }
        encoder = null
        projection?.let { p ->
            runCatching { p.unregisterCallback(projectionCallback) }
            runCatching { p.stop() }
        }
        projection = null
    }

    private fun startForegroundWithNotification() {
        ensureNotificationChannel(this)
        val notification = buildNotification(TEXT_SHARING_ACTIVE)
        startForeground(
            NOTIFICATION_ID,
            notification,
            ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION,
        )
    }

    private fun presentMissingAuthorizationNotice() {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.notify(NOTIFICATION_ID, buildNotification(TEXT_AUTH_MISSING))
    }

    private fun buildNotification(text: String) =
        NotificationCompat.Builder(this, NOTIFICATION_CHANNEL_ID)
            .setContentTitle(TEXT_SHARING_TITLE)
            .setContentText(text)
            .setSmallIcon(android.R.drawable.stat_sys_upload)
            .setOngoing(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()

    private fun stopSelfAndNotification() {
        stopForeground(STOP_FOREGROUND_REMOVE)
        runCatching {
            (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).cancel(NOTIFICATION_ID)
        }
        stopSelf()
    }

    override fun onDestroy() {
        stopCaptureInternal()
        super.onDestroy()
    }

    companion object {
        /** Foreground channel id for the persistent capture notification. */
        const val NOTIFICATION_CHANNEL_ID = "skybridge_remote_host_capture"
        const val NOTIFICATION_ID = 0x5B10

        const val ACTION_START_REMOTE_CAPTURE =
            "com.skybridge.compass.action.START_REMOTE_CAPTURE"

        /** Must match the guarded stop-hook wired by task 13.2. */
        const val ACTION_STOP_REMOTE_CAPTURE =
            "com.skybridge.compass.action.STOP_REMOTE_CAPTURE"

        const val EXTRA_RESULT_CODE = "com.skybridge.compass.extra.RESULT_CODE"
        const val EXTRA_RESULT_DATA = "com.skybridge.compass.extra.RESULT_DATA"

        private const val RESULT_CODE_INVALID = 0
        private const val DEFAULT_FRAME_RATE = 30
        private const val VIRTUAL_DISPLAY_NAME = "SkyBridgeRemoteHost"

        // Notification copy kept local so the module needs no new string resources; the app may
        // override the notification content in a later task without changing the FQN or lifecycle.
        private const val TEXT_SHARING_TITLE = "SkyBridge Compass"
        private const val TEXT_SHARING_ACTIVE = "屏幕共享进行中"
        private const val TEXT_AUTH_MISSING = "屏幕录制授权缺失，共享未启动"

        /**
         * The send seam. The transport layer sets this to receive encoded frames + session-end
         * notices; the actual mapping onto `ScreenData`/`SCREEN_DATA` and the reverse-send direction
         * remain WP-04-pending (see gaps/wire-protocol-pending.md).
         */
        @Volatile
        var frameSink: HostFrameSink? = null

        /** Create the persistent notification channel used by the capture service. */
        fun ensureNotificationChannel(context: Context) {
            val manager =
                context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (manager.getNotificationChannel(NOTIFICATION_CHANNEL_ID) == null) {
                val channel = NotificationChannel(
                    NOTIFICATION_CHANNEL_ID,
                    "远程桌面共享",
                    NotificationManager.IMPORTANCE_LOW,
                ).apply {
                    description = "Android 屏幕共享（远程桌面宿主端）持续通知"
                    setShowBadge(false)
                }
                manager.createNotificationChannel(channel)
            }
        }

        /**
         * Build a start intent carrying a granted MediaProjection result (R6.5). Callers obtain
         * [resultCode]/[data] from `MediaProjectionManager.createScreenCaptureIntent()`.
         */
        fun startIntent(context: Context, resultCode: Int, data: Intent): Intent =
            Intent(context, AndroidRemoteControlHostService::class.java).apply {
                action = ACTION_START_REMOTE_CAPTURE
                putExtra(EXTRA_RESULT_CODE, resultCode)
                putExtra(EXTRA_RESULT_DATA, data)
            }

        /** Build the stop intent (mirrors the action the task 13.2 stop-hook already sends). */
        fun stopIntent(context: Context): Intent =
            Intent(context, AndroidRemoteControlHostService::class.java).apply {
                action = ACTION_STOP_REMOTE_CAPTURE
            }
    }
}
