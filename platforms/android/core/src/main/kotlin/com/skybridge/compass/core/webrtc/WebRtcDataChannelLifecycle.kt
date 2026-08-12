package com.skybridge.compass.core.webrtc

/**
 * Linearizes access to the one native DataChannel owned by a WebRTC session.
 *
 * [withAttached] deliberately holds the lifecycle monitor while the operation executes. Native
 * `send` is a bounded, synchronous call, so this prevents `close`/`dispose` from racing the JNI
 * call without introducing an unbounded lease or a second lifecycle state machine.
 */
internal class WebRtcDataChannelLifecycle<T> {
    data class AttachResult(
        val admission: WebRtcDataChannelAdmission.Result,
        val registrationError: Exception? = null,
    ) {
        val accepted: Boolean
            get() = admission == WebRtcDataChannelAdmission.Result.ACCEPT && registrationError == null
    }

    private val monitor = Any()
    private var attached: T? = null
    private var closed = false

    fun attach(
        label: String,
        resource: T,
        register: (T) -> Unit,
    ): AttachResult = synchronized(monitor) {
        val admission = WebRtcDataChannelAdmission.evaluate(
            label = label,
            hasActiveChannel = attached != null,
            sessionClosed = closed,
        )
        if (admission != WebRtcDataChannelAdmission.Result.ACCEPT) {
            return@synchronized AttachResult(admission)
        }

        attached = resource
        try {
            register(resource)
            AttachResult(admission)
        } catch (error: Exception) {
            attached = null
            AttachResult(admission, error)
        }
    }

    fun <R> withAttached(operation: (T) -> R): R? = synchronized(monitor) {
        if (closed) return@synchronized null
        attached?.let(operation)
    }

    /** Executes only while [expected] is still the exact attached resource. */
    fun <R> withExactAttached(expected: T, operation: (T) -> R): R? = synchronized(monitor) {
        if (closed || attached !== expected) return@synchronized null
        operation(expected)
    }

    fun isAttached(predicate: (T) -> Boolean): Boolean = synchronized(monitor) {
        !closed && attached?.let(predicate) == true
    }

    /** Marks the lifecycle terminal and returns the resource to the sole cleanup owner. */
    fun closeAndDetach(): T? = synchronized(monitor) {
        closed = true
        attached.also { attached = null }
    }
}
