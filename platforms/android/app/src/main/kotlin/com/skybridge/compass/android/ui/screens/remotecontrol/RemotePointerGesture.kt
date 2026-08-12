package com.skybridge.compass.android.ui.screens.remotecontrol

import kotlin.math.min

internal data class RemotePointerCoordinate(
    val x: Double,
    val y: Double
)

internal enum class RemotePointerContentMode {
    FILL_BOUNDS,
    FIT_INSIDE
}

internal enum class PointerPhase {
    Down,
    Move,
    Up
}

/** Pure local-view to remote-visible-frame coordinate projection. */
internal object RemotePointerCoordinateMapper {
    private const val NORMALIZED_EDGE_SNAP_EPSILON = 1e-12

    fun map(
        localX: Double,
        localY: Double,
        remoteWidth: Int,
        remoteHeight: Int,
        viewWidth: Double,
        viewHeight: Double,
        contentMode: RemotePointerContentMode
    ): RemotePointerCoordinate? {
        if (
            !localX.isFinite() || !localY.isFinite() ||
            !viewWidth.isFinite() || !viewHeight.isFinite() ||
            remoteWidth <= 0 || remoteHeight <= 0 || viewWidth <= 0.0 || viewHeight <= 0.0
        ) {
            return null
        }

        val contentLeft: Double
        val contentTop: Double
        val contentWidth: Double
        val contentHeight: Double
        when (contentMode) {
            RemotePointerContentMode.FILL_BOUNDS -> {
                contentLeft = 0.0
                contentTop = 0.0
                contentWidth = viewWidth
                contentHeight = viewHeight
            }
            RemotePointerContentMode.FIT_INSIDE -> {
                val scale = min(viewWidth / remoteWidth, viewHeight / remoteHeight)
                contentWidth = remoteWidth * scale
                contentHeight = remoteHeight * scale
                contentLeft = (viewWidth - contentWidth) / 2.0
                contentTop = (viewHeight - contentHeight) / 2.0
            }
        }

        val contentRight = contentLeft + contentWidth
        val contentBottom = contentTop + contentHeight
        if (
            localX < contentLeft || localX > contentRight ||
            localY < contentTop || localY > contentBottom
        ) {
            return null
        }

        val normalizedX = snapNormalizedEdge((localX - contentLeft) / contentWidth)
        val normalizedY = snapNormalizedEdge((localY - contentTop) / contentHeight)
        return RemotePointerCoordinate(
            x = (normalizedX * remoteWidth).coerceIn(0.0, (remoteWidth - 1).toDouble()),
            y = (normalizedY * remoteHeight).coerceIn(0.0, (remoteHeight - 1).toDouble())
        )
    }

    /** Normalizes only points already proven inside; outside rejection never receives a tolerance. */
    private fun snapNormalizedEdge(value: Double): Double = when {
        value <= NORMALIZED_EDGE_SNAP_EPSILON -> 0.0
        value >= 1.0 - NORMALIZED_EDGE_SNAP_EPSILON -> 1.0
        else -> value.coerceIn(0.0, 1.0)
    }
}

/**
 * One active-pointer state machine. A tap is Down+Up, a drag is Down+Move*+Up, and cancellation
 * releases the exact last accepted coordinate once.
 */
internal class RemotePointerGestureStateMachine(
    private val emit: (RemotePointerCoordinate, PointerPhase) -> Unit
) {
    private var active = false
    private var lastCoordinate: RemotePointerCoordinate? = null

    fun begin(coordinate: RemotePointerCoordinate?): Boolean {
        check(!active) { "remote pointer gesture already active" }
        val accepted = coordinate ?: return false
        active = true
        lastCoordinate = accepted
        emit(accepted, PointerPhase.Down)
        return true
    }

    fun move(coordinate: RemotePointerCoordinate?) {
        if (!active || coordinate == null) return
        lastCoordinate = coordinate
        emit(coordinate, PointerPhase.Move)
    }

    fun end(coordinate: RemotePointerCoordinate?) {
        if (!active) return
        coordinate?.let { lastCoordinate = it }
        release()
    }

    fun cancel() {
        if (!active) return
        release()
    }

    /** A second active pointer cancels this single-owner gesture and emits exactly one Up. */
    fun cancelIfMultiplePointers(pressedPointerCount: Int): Boolean {
        require(pressedPointerCount >= 0) { "pressed pointer count must not be negative" }
        if (pressedPointerCount <= 1) return false
        cancel()
        return true
    }

    private fun release() {
        val coordinate = checkNotNull(lastCoordinate)
        active = false
        lastCoordinate = null
        emit(coordinate, PointerPhase.Up)
    }
}
