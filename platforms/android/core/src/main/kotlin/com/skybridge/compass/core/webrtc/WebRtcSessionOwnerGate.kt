package com.skybridge.compass.core.webrtc

import com.skybridge.compass.shared.productsession.ProductSessionOwner

/**
 * Serializes ownership changes for one connection manager.
 *
 * Callback code must use [runIfCurrent] before publishing state or mutating manager-wide session
 * fields. The check and mutation run under the same re-entrant monitor, so a replacement cannot
 * slip between the ownership check and the protected mutation.
 */
internal class WebRtcSessionOwnerGate {
    data class Transition(
        val owner: ProductSessionOwner,
        val replacedOwner: ProductSessionOwner?
    )

    private val lock = Any()
    private var currentOwner: ProductSessionOwner? = null
    private var generation: Long = 0

    fun begin(sessionId: String): Transition = synchronized(lock) {
        val nextGeneration = try {
            Math.addExact(generation, 1L)
        } catch (_: ArithmeticException) {
            throw IllegalStateException("WebRTC session owner generation exhausted")
        }
        generation = nextGeneration
        val replacement = ProductSessionOwner.create(sessionId, nextGeneration)
        val previous = currentOwner
        currentOwner = replacement
        Transition(owner = replacement, replacedOwner = previous)
    }

    fun current(): ProductSessionOwner? = synchronized(lock) { currentOwner }

    fun isCurrent(owner: ProductSessionOwner): Boolean =
        synchronized(lock) { currentOwner == owner }

    fun runIfCurrent(owner: ProductSessionOwner, action: () -> Unit): Boolean =
        synchronized(lock) {
            if (currentOwner != owner) {
                return@synchronized false
            }
            action()
            true
        }

    fun runIfNoCurrent(action: () -> Unit): Boolean =
        synchronized(lock) {
            if (currentOwner != null) {
                return@synchronized false
            }
            action()
            true
        }

    fun releaseIfCurrent(owner: ProductSessionOwner): Boolean =
        synchronized(lock) {
            if (currentOwner != owner) {
                return@synchronized false
            }
            currentOwner = null
            true
        }
}

internal class StaleWebRtcSessionOwnerException : IllegalStateException(
    "WebRTC session operation belongs to a stale owner"
)
