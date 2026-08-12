package com.skybridge.compass.android.remote.mac

import kotlinx.serialization.json.Json

/**
 * Exact-owner WebRTC input sender.
 *
 * Pointer Down captures one acknowledged secure owner. Move and Up may only commit through that
 * same owner; they never re-resolve a replacement or rekey epoch. A local policy transition may
 * reject new Down/Move events while still allowing the one owned Up needed to release an already
 * accepted Down. Stateless scroll events capture and commit through one exact owner as well.
 */
internal class RemoteInputSender<Owner : Any>(
    private val json: Json,
    private val clockSeconds: () -> Double,
    private val currentAcknowledgedOwner: () -> Owner?,
    private val commitIfCurrentAcknowledgedOwner: (Owner, commit: () -> Unit) -> Boolean,
    private val sink: (Owner, RemoteMessage) -> Boolean,
    private val terminalize: (Owner) -> Unit
) {
    private val pointerLock = Any()
    private var activePointerOwner: Owner? = null

    fun sendPointer(
        controlEnabled: Boolean,
        type: MouseEventType,
        x: Double,
        y: Double
    ): Boolean {
        val message = RemoteInputMessages.mouse(json, type, x, y, clockSeconds())
        return when (type) {
            MouseEventType.LEFT_MOUSE_DOWN -> sendPointerDown(controlEnabled, message)
            MouseEventType.MOUSE_MOVED -> sendOwnedPointerEvent(controlEnabled, message, release = false)
            MouseEventType.LEFT_MOUSE_UP -> sendOwnedPointerEvent(
                controlEnabled = true,
                message = message,
                release = true
            )
            else -> throw IllegalArgumentException("unsupported pointer event type: $type")
        }
    }

    fun sendScroll(
        controlEnabled: Boolean,
        direction: RemoteInputMessages.ScrollDirection,
        x: Double,
        y: Double
    ): Boolean {
        if (!controlEnabled) return false
        val owner = currentAcknowledgedOwner() ?: return false
        val message = RemoteInputMessages.scroll(json, direction, x, y, clockSeconds())
        return commitOne(owner, message)
    }

    /** Owner replacement/session teardown invalidates local gesture authority without compensation. */
    fun clearPointerOwner() {
        synchronized(pointerLock) {
            activePointerOwner = null
        }
    }

    private fun sendPointerDown(controlEnabled: Boolean, message: RemoteMessage): Boolean {
        if (!controlEnabled) return false
        val owner = currentAcknowledgedOwner() ?: return false
        synchronized(pointerLock) {
            val active = activePointerOwner
            if (active === owner) return false
            if (active != null) activePointerOwner = null
        }

        var attempted = false
        var delivered = false
        val admitted = commitIfCurrentAcknowledgedOwner(owner) {
            synchronized(pointerLock) {
                if (activePointerOwner == null) {
                    attempted = true
                    delivered = sink(owner, message)
                    if (delivered) activePointerOwner = owner
                }
            }
        }
        if (admitted && attempted && !delivered) terminalize(owner)
        return admitted && attempted && delivered
    }

    private fun sendOwnedPointerEvent(
        controlEnabled: Boolean,
        message: RemoteMessage,
        release: Boolean
    ): Boolean {
        if (!controlEnabled && !release) return false
        val owner = synchronized(pointerLock) { activePointerOwner } ?: return false
        var attempted = false
        var delivered = false
        val admitted = commitIfCurrentAcknowledgedOwner(owner) {
            synchronized(pointerLock) {
                if (activePointerOwner === owner) {
                    attempted = true
                    delivered = sink(owner, message)
                    if (release || !delivered) activePointerOwner = null
                }
            }
        }
        if (!admitted) {
            clearPointerOwnerIfOwned(owner)
        } else if (attempted && !delivered) {
            terminalize(owner)
        }
        return admitted && attempted && delivered
    }

    private fun commitOne(owner: Owner, message: RemoteMessage): Boolean {
        var attempted = false
        var delivered = false
        val admitted = commitIfCurrentAcknowledgedOwner(owner) {
            attempted = true
            delivered = sink(owner, message)
        }
        if (admitted && attempted && !delivered) terminalize(owner)
        return admitted && attempted && delivered
    }

    private fun clearPointerOwnerIfOwned(owner: Owner) {
        synchronized(pointerLock) {
            if (activePointerOwner === owner) activePointerOwner = null
        }
    }
}
