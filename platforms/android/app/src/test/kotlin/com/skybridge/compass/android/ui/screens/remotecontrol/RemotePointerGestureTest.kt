package com.skybridge.compass.android.ui.screens.remotecontrol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class RemotePointerGestureTest {
    @Test
    fun tapEmitsExactlyOneDownAndUpAtTheSameRemoteCoordinate() {
        val events = mutableListOf<Pair<RemotePointerCoordinate, PointerPhase>>()
        val gesture = RemotePointerGestureStateMachine { coordinate, phase ->
            events += coordinate to phase
        }
        val point = RemotePointerCoordinate(40.0, 20.0)

        gesture.begin(point)
        gesture.end(point)

        assertEquals(
            listOf(point to PointerPhase.Down, point to PointerPhase.Up),
            events
        )
    }

    @Test
    fun dragAndCancelAlwaysReleaseTheLastAcceptedCoordinateOnce() {
        val events = mutableListOf<Pair<RemotePointerCoordinate, PointerPhase>>()
        val gesture = RemotePointerGestureStateMachine { coordinate, phase ->
            events += coordinate to phase
        }
        val start = RemotePointerCoordinate(1.0, 2.0)
        val moved = RemotePointerCoordinate(3.0, 4.0)

        gesture.begin(start)
        gesture.move(moved)
        gesture.cancel()
        gesture.cancel()

        assertEquals(
            listOf(
                start to PointerPhase.Down,
                moved to PointerPhase.Move,
                moved to PointerPhase.Up
            ),
            events
        )
    }

    @Test
    fun cancelledGestureCanBeFollowedByANewTapWithoutDuplicateRelease() {
        val events = mutableListOf<Pair<RemotePointerCoordinate, PointerPhase>>()
        val gesture = RemotePointerGestureStateMachine { coordinate, phase ->
            events += coordinate to phase
        }
        val first = RemotePointerCoordinate(1.0, 2.0)
        val second = RemotePointerCoordinate(5.0, 6.0)

        gesture.begin(first)
        gesture.cancel()
        gesture.begin(second)
        gesture.end(second)

        assertEquals(
            listOf(
                first to PointerPhase.Down,
                first to PointerPhase.Up,
                second to PointerPhase.Down,
                second to PointerPhase.Up
            ),
            events
        )
    }

    @Test
    fun twoTapsProduceTwoAdjacentDownUpPairs() {
        val events = mutableListOf<Pair<RemotePointerCoordinate, PointerPhase>>()
        val gesture = RemotePointerGestureStateMachine { coordinate, phase ->
            events += coordinate to phase
        }
        val first = RemotePointerCoordinate(2.0, 3.0)
        val second = RemotePointerCoordinate(4.0, 5.0)

        gesture.begin(first)
        gesture.end(first)
        gesture.begin(second)
        gesture.end(second)

        assertEquals(
            listOf(
                first to PointerPhase.Down,
                first to PointerPhase.Up,
                second to PointerPhase.Down,
                second to PointerPhase.Up
            ),
            events
        )
    }

    @Test
    fun secondPointerCancelsTheSingleOwnerGestureWithOneRelease() {
        val events = mutableListOf<Pair<RemotePointerCoordinate, PointerPhase>>()
        val gesture = RemotePointerGestureStateMachine { coordinate, phase ->
            events += coordinate to phase
        }
        val point = RemotePointerCoordinate(7.0, 8.0)

        gesture.begin(point)
        assertEquals(false, gesture.cancelIfMultiplePointers(1))
        assertEquals(true, gesture.cancelIfMultiplePointers(2))
        gesture.cancel()

        assertEquals(
            listOf(point to PointerPhase.Down, point to PointerPhase.Up),
            events
        )
    }

    @Test
    fun rejectedStartNeverBeginsWhenPointerLaterMovesIntoContent() {
        val events = mutableListOf<Pair<RemotePointerCoordinate, PointerPhase>>()
        val gesture = RemotePointerGestureStateMachine { coordinate, phase ->
            events += coordinate to phase
        }

        gesture.begin(null)
        gesture.move(RemotePointerCoordinate(5.0, 6.0))
        gesture.end(RemotePointerCoordinate(5.0, 6.0))

        assertEquals(emptyList<Pair<RemotePointerCoordinate, PointerPhase>>(), events)
    }

    @Test
    fun fitInsideRejectsLetterboxAndMapsVisibleFrameEdgesToPixelBounds() {
        assertNull(
            RemotePointerCoordinateMapper.map(
                localX = 10.0,
                localY = 10.0,
                remoteWidth = 1_920,
                remoteHeight = 1_080,
                viewWidth = 1_000.0,
                viewHeight = 1_000.0,
                contentMode = RemotePointerContentMode.FIT_INSIDE
            )
        )
        assertNull(
            RemotePointerCoordinateMapper.map(
                localX = 0.0,
                localY = 218.75 - 1e-9,
                remoteWidth = 1_920,
                remoteHeight = 1_080,
                viewWidth = 1_000.0,
                viewHeight = 1_000.0,
                contentMode = RemotePointerContentMode.FIT_INSIDE
            )
        )
        assertNull(
            RemotePointerCoordinateMapper.map(
                localX = 1_000.0,
                localY = 781.25 + 1e-9,
                remoteWidth = 1_920,
                remoteHeight = 1_080,
                viewWidth = 1_000.0,
                viewHeight = 1_000.0,
                contentMode = RemotePointerContentMode.FIT_INSIDE
            )
        )

        val topLeft = RemotePointerCoordinateMapper.map(
            localX = 0.0,
            localY = 218.75,
            remoteWidth = 1_920,
            remoteHeight = 1_080,
            viewWidth = 1_000.0,
            viewHeight = 1_000.0,
            contentMode = RemotePointerContentMode.FIT_INSIDE
        )
        val bottomRight = RemotePointerCoordinateMapper.map(
            localX = 1_000.0,
            localY = 781.25,
            remoteWidth = 1_920,
            remoteHeight = 1_080,
            viewWidth = 1_000.0,
            viewHeight = 1_000.0,
            contentMode = RemotePointerContentMode.FIT_INSIDE
        )

        assertEquals(RemotePointerCoordinate(0.0, 0.0), topLeft)
        assertEquals(RemotePointerCoordinate(1_919.0, 1_079.0), bottomRight)
    }

    @Test
    fun coordinateMapperRejectsNonFiniteAndInvalidDimensions() {
        assertNull(
            RemotePointerCoordinateMapper.map(
                localX = Double.NaN,
                localY = 1.0,
                remoteWidth = 100,
                remoteHeight = 100,
                viewWidth = 100.0,
                viewHeight = 100.0,
                contentMode = RemotePointerContentMode.FILL_BOUNDS
            )
        )
        assertNull(
            RemotePointerCoordinateMapper.map(
                localX = 1.0,
                localY = 1.0,
                remoteWidth = 0,
                remoteHeight = 100,
                viewWidth = 100.0,
                viewHeight = 100.0,
                contentMode = RemotePointerContentMode.FILL_BOUNDS
            )
        )
    }
}
