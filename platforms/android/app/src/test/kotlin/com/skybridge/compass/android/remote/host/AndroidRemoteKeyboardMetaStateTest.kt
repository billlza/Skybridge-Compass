package com.skybridge.compass.android.remote.host

import android.view.KeyEvent
import com.skybridge.compass.android.remote.mac.KeyboardEventType
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class AndroidRemoteKeyboardMetaStateTest {

    @Test
    fun shiftDown_contributesShiftMetaStateToFollowingKeys() {
        val afterShiftDown = AndroidRemoteKeyboardMetaState.updatedMetaState(
            currentMetaState = 0,
            keyCode = KeyEvent.KEYCODE_SHIFT_LEFT,
            type = KeyboardEventType.KEY_DOWN
        )

        val metaForA = AndroidRemoteKeyboardMetaState.metaStateForEvent(
            currentMetaState = afterShiftDown,
            keyCode = KeyEvent.KEYCODE_A,
            type = KeyboardEventType.KEY_DOWN
        )

        assertTrue(metaForA and KeyEvent.META_SHIFT_ON != 0)
    }

    @Test
    fun modifierKeyUp_clearsStoredMetaState() {
        val withShift = AndroidRemoteKeyboardMetaState.updatedMetaState(
            currentMetaState = 0,
            keyCode = KeyEvent.KEYCODE_SHIFT_LEFT,
            type = KeyboardEventType.KEY_DOWN
        )

        val cleared = AndroidRemoteKeyboardMetaState.updatedMetaState(
            currentMetaState = withShift,
            keyCode = KeyEvent.KEYCODE_SHIFT_LEFT,
            type = KeyboardEventType.KEY_UP
        )

        assertEquals(0, cleared)
    }

    @Test
    fun capsLock_togglesOnKeyDownAndIgnoresKeyUp() {
        val enabled = AndroidRemoteKeyboardMetaState.updatedMetaState(
            currentMetaState = 0,
            keyCode = KeyEvent.KEYCODE_CAPS_LOCK,
            type = KeyboardEventType.KEY_DOWN
        )
        val afterKeyUp = AndroidRemoteKeyboardMetaState.updatedMetaState(
            currentMetaState = enabled,
            keyCode = KeyEvent.KEYCODE_CAPS_LOCK,
            type = KeyboardEventType.KEY_UP
        )
        val disabled = AndroidRemoteKeyboardMetaState.updatedMetaState(
            currentMetaState = afterKeyUp,
            keyCode = KeyEvent.KEYCODE_CAPS_LOCK,
            type = KeyboardEventType.KEY_DOWN
        )

        assertTrue(enabled and KeyEvent.META_CAPS_LOCK_ON != 0)
        assertEquals(enabled, afterKeyUp)
        assertEquals(0, disabled)
    }
}
