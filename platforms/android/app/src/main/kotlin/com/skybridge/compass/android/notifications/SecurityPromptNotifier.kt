package com.skybridge.compass.android.notifications

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.net.Uri
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import com.skybridge.compass.android.MainActivity
import com.skybridge.compass.android.securityprompts.SecurityPromptStore
import com.skybridge.compass.core.p2p.PairingTrustConflict
import com.skybridge.compass.core.p2p.PairingTrustRequest
import java.util.Locale

/**
 * Dedicated system notifications for security prompts (inbound file transfers, remote-control approvals).
 *
 * Important: these notifications are NOT gated by the general "Notifications" setting, since they are
 * required to complete security-critical flows.
 */
object SecurityPromptNotifier {
    private const val CHANNEL_SECURITY = "skybridge_security"

    const val ACTION_INBOUND_FILE_DECLINE = "com.skybridge.compass.android.action.INBOUND_FILE_DECLINE"
    const val ACTION_PAIRING_TRUST_DECLINE = "com.skybridge.compass.android.action.PAIRING_TRUST_DECLINE"

    const val EXTRA_TRANSFER_ID = "extra_transfer_id"
    const val EXTRA_PAIRING_REQUEST_ID = "extra_pairing_request_id"
    internal const val EXTRA_REVIEW_KIND = "extra_security_review_kind"
    internal const val EXTRA_REVIEW_ID = "extra_security_review_id"
    internal const val REVIEW_KIND_INBOUND_FILE = "inbound_file"
    internal const val REVIEW_KIND_PAIRING_TRUST = "pairing_trust"

    private var initialized = false

    fun init(context: Context) {
        if (initialized) return
        createChannels(context)
        initialized = true
    }

    fun postInboundFilePrompt(context: Context, prompt: SecurityPromptStore.InboundFileTransferPrompt) {
        init(context)

        val notificationId = inboundNotificationId(prompt.transferId)

        val sender = prompt.senderDeviceId ?: "Unauthenticated sender"
        val declaredName = prompt.senderDeviceName?.takeIf { it.isNotBlank() && it != sender }
        val size = prompt.fileSizeBytes?.let { formatBytes(it) } ?: "Unknown size"
        val body = if (declaredName != null) {
            "$sender wants to send “${prompt.fileName}” ($size); declared name: $declaredName"
        } else {
            "$sender wants to send “${prompt.fileName}” ($size)"
        }

        val reviewIntent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra(EXTRA_REVIEW_KIND, REVIEW_KIND_INBOUND_FILE)
            putExtra(EXTRA_REVIEW_ID, prompt.transferId)
        }
        val reviewPending = PendingIntent.getActivity(
            context,
            notificationId,
            reviewIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val declineIntent = Intent(context, IncomingFileTransferActionReceiver::class.java).apply {
            action = ACTION_INBOUND_FILE_DECLINE
            putExtra(EXTRA_TRANSFER_ID, prompt.transferId)
        }
        val declinePending = PendingIntent.getBroadcast(
            context,
            notificationId + 1,
            declineIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val builder = NotificationCompat.Builder(context, CHANNEL_SECURITY)
            .setSmallIcon(android.R.drawable.stat_sys_warning)
            .setContentTitle("Incoming file transfer")
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setOngoing(true)
            .setAutoCancel(false)
            .setTimeoutAfter(SecurityPromptStore.INBOUND_DECISION_TIMEOUT_MS)
            .setContentIntent(reviewPending)
            .addAction(0, "Review", reviewPending)
            .addAction(0, "Decline", declinePending)

        notifySecurityPrompt(context, notificationId, builder)
    }

    fun cancelInboundFilePrompt(context: Context, transferId: String) {
        NotificationManagerCompat.from(context).cancel(inboundNotificationId(transferId))
    }

    fun postPairingTrustPrompt(context: Context, prompt: PairingTrustRequest) {
        init(context)

        val notificationId = pairingNotificationId(prompt.requestId)
        val sender = prompt.deviceName
            ?: prompt.declaredDeviceId
        val body = if (prompt.conflict == null) {
            "$sender wants to establish trusted-device pairing"
        } else {
            "$sender pairing request conflicts with an existing trusted identity"
        }
        val reviewIntent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra(EXTRA_REVIEW_KIND, REVIEW_KIND_PAIRING_TRUST)
            putExtra(EXTRA_REVIEW_ID, prompt.requestId)
        }
        val reviewPending = PendingIntent.getActivity(
            context,
            notificationId,
            reviewIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val declineIntent = Intent(context, IncomingFileTransferActionReceiver::class.java).apply {
            action = ACTION_PAIRING_TRUST_DECLINE
            putExtra(EXTRA_PAIRING_REQUEST_ID, prompt.requestId)
        }
        val declinePending = PendingIntent.getBroadcast(
            context,
            notificationId + 1,
            declineIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val title = if (prompt.conflict == null) {
            "Trusted-device request"
        } else {
            "Pairing conflict detected"
        }
        val builder = NotificationCompat.Builder(context, CHANNEL_SECURITY)
            .setSmallIcon(android.R.drawable.stat_sys_warning)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(bodyWithConflict(prompt)))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setOngoing(true)
            .setAutoCancel(false)
            .setTimeoutAfter(SecurityPromptStore.PAIRING_DECISION_TIMEOUT_MS)
            .setContentIntent(reviewPending)
            .addAction(0, "Review", reviewPending)
            .addAction(0, "Decline", declinePending)

        notifySecurityPrompt(context, notificationId, builder)
    }

    fun cancelPairingTrustPrompt(context: Context, requestId: String) {
        NotificationManagerCompat.from(context).cancel(pairingNotificationId(requestId))
    }

    internal sealed interface ReviewIntentResolution {
        data object NotPresent : ReviewIntentResolution
        data class Accepted(val route: String) : ReviewIntentResolution
        data class Rejected(val reason: String) : ReviewIntentResolution
    }

    /**
     * Resolves only notification intents that still name an exact live prompt.
     * The caller never accepts a route string supplied by an exported activity.
     */
    internal fun resolveReviewIntent(intent: Intent?): ReviewIntentResolution {
        if (intent == null) return ReviewIntentResolution.NotPresent
        val hasKind = intent.hasExtra(EXTRA_REVIEW_KIND)
        val hasId = intent.hasExtra(EXTRA_REVIEW_ID)
        if (!hasKind && !hasId) return ReviewIntentResolution.NotPresent
        if (!hasKind || !hasId) {
            return ReviewIntentResolution.Rejected("security review intent is incomplete")
        }

        val kind = intent.getStringExtra(EXTRA_REVIEW_KIND)
        val reviewId = intent.getStringExtra(EXTRA_REVIEW_ID)
        if (reviewId.isNullOrBlank() || reviewId.length > 256 || reviewId.any(Char::isISOControl)) {
            return ReviewIntentResolution.Rejected("security review identifier is invalid")
        }

        val encodedId = Uri.encode(reviewId)
        return when (kind) {
            REVIEW_KIND_INBOUND_FILE -> {
                if (SecurityPromptStore.getInboundPrompt(reviewId) == null) {
                    ReviewIntentResolution.Rejected("inbound file prompt is not current")
                } else {
                    ReviewIntentResolution.Accepted(
                        "security/incoming_transfer_review/$encodedId"
                    )
                }
            }
            REVIEW_KIND_PAIRING_TRUST -> {
                if (SecurityPromptStore.getPairingPrompt(reviewId) == null) {
                    ReviewIntentResolution.Rejected("pairing trust prompt is not current")
                } else {
                    ReviewIntentResolution.Accepted(
                        "security/pairing_trust_review/$encodedId"
                    )
                }
            }
            else -> ReviewIntentResolution.Rejected("security review kind is invalid")
        }
    }

    private fun createChannels(context: Context) {
        val mgr = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channel = NotificationChannel(
            CHANNEL_SECURITY,
            "SkyBridge Security",
            NotificationManager.IMPORTANCE_HIGH
        ).apply {
            description = "Security confirmations for inbound transfers and remote control"
            enableLights(true)
            lightColor = Color.YELLOW
        }
        mgr.createNotificationChannel(channel)
    }

    private fun notifySecurityPrompt(
        context: Context,
        notificationId: Int,
        builder: NotificationCompat.Builder
    ) {
        if (
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            throw SecurityException("POST_NOTIFICATIONS permission is required for security prompts")
        }
        NotificationManagerCompat.from(context).notify(notificationId, builder.build())
    }

    private fun inboundNotificationId(transferId: String): Int = transferId.hashCode()

    private fun pairingNotificationId(requestId: String): Int = requestId.hashCode()

    private fun bodyWithConflict(prompt: PairingTrustRequest): String {
        val base = buildString {
            append(prompt.deviceName ?: prompt.declaredDeviceId.ifBlank { prompt.peerId })
            append('\n')
            append("Device ID: ").append(prompt.declaredDeviceId)
            prompt.platform?.takeIf { it.isNotBlank() }?.let { append("\nPlatform: ").append(it) }
            prompt.osVersion?.takeIf { it.isNotBlank() }?.let { append("\nOS: ").append(it) }
        }
        val conflict = when (prompt.conflict) {
            PairingTrustConflict.IDENTITY_CONFLICT -> "Existing trusted device uses a different authoritative fingerprint."
            PairingTrustConflict.DEVICE_ID_MIGRATION_REQUIRED -> "This authoritative fingerprint is already pinned to another device ID."
            PairingTrustConflict.QUARANTINED_IDENTITY -> "This identity is quarantined and requires reverification."
            PairingTrustConflict.REVOKED_IDENTITY -> "This identity has been revoked."
            PairingTrustConflict.TRUST_STORE_CORRUPTED -> "The trusted-device store is corrupted and must be repaired before approving this peer."
            null -> null
        }
        return if (conflict == null) base else "$base\n\n$conflict"
    }

    private fun formatBytes(bytes: Long): String {
        val units = arrayOf("B", "KB", "MB", "GB", "TB")
        var size = bytes.toDouble()
        var unit = 0
        while (size >= 1024.0 && unit < units.lastIndex) {
            size /= 1024.0
            unit++
        }
        return if (unit == 0) {
            "${bytes} ${units[unit]}"
        } else {
            String.format(Locale.ROOT, "%.1f %s", size, units[unit])
        }
    }
}
