package com.skybridge.compass.android.remote.host

import android.view.KeyEvent
import com.skybridge.compass.android.remote.mac.KeyboardEventType

/**
 * Tracks modifier state for RemoteKeyboardEvent frames that only carry keyCode
 * and key up/down transitions. This lets Android reconstruct effective meta
 * state for subsequent printable keys so macOS/iOS modifier sequences remain
 * meaningful on the host side.
 */
internal object AndroidRemoteKeyboardMetaState {

    fun isModifierKey(keyCode: Int): Boolean = when (keyCode) {
        KeyEvent.KEYCODE_SHIFT_LEFT,
        KeyEvent.KEYCODE_SHIFT_RIGHT,
        KeyEvent.KEYCODE_CTRL_LEFT,
        KeyEvent.KEYCODE_CTRL_RIGHT,
        KeyEvent.KEYCODE_ALT_LEFT,
        KeyEvent.KEYCODE_ALT_RIGHT,
        KeyEvent.KEYCODE_META_LEFT,
        KeyEvent.KEYCODE_META_RIGHT,
        KeyEvent.KEYCODE_CAPS_LOCK,
        KeyEvent.KEYCODE_FUNCTION -> true

        else -> false
    }

    fun metaStateForEvent(currentMetaState: Int, keyCode: Int, type: KeyboardEventType): Int {
        return if (type == KeyboardEventType.KEY_DOWN && isModifierKey(keyCode)) {
            updatedMetaState(currentMetaState, keyCode, type)
        } else {
            normalizeMetaStateCompat(currentMetaState)
        }
    }

    fun updatedMetaState(currentMetaState: Int, keyCode: Int, type: KeyboardEventType): Int {
        val pressed = type == KeyboardEventType.KEY_DOWN
        val updated = when (keyCode) {
            KeyEvent.KEYCODE_SHIFT_LEFT -> applyFlag(currentMetaState, KeyEvent.META_SHIFT_LEFT_ON, pressed)
            KeyEvent.KEYCODE_SHIFT_RIGHT -> applyFlag(currentMetaState, KeyEvent.META_SHIFT_RIGHT_ON, pressed)
            KeyEvent.KEYCODE_CTRL_LEFT -> applyFlag(currentMetaState, KeyEvent.META_CTRL_LEFT_ON, pressed)
            KeyEvent.KEYCODE_CTRL_RIGHT -> applyFlag(currentMetaState, KeyEvent.META_CTRL_RIGHT_ON, pressed)
            KeyEvent.KEYCODE_ALT_LEFT -> applyFlag(currentMetaState, KeyEvent.META_ALT_LEFT_ON, pressed)
            KeyEvent.KEYCODE_ALT_RIGHT -> applyFlag(currentMetaState, KeyEvent.META_ALT_RIGHT_ON, pressed)
            KeyEvent.KEYCODE_META_LEFT -> applyFlag(currentMetaState, KeyEvent.META_META_LEFT_ON, pressed)
            KeyEvent.KEYCODE_META_RIGHT -> applyFlag(currentMetaState, KeyEvent.META_META_RIGHT_ON, pressed)
            KeyEvent.KEYCODE_FUNCTION -> applyFlag(currentMetaState, KeyEvent.META_FUNCTION_ON, pressed)
            KeyEvent.KEYCODE_CAPS_LOCK -> {
                if (pressed) {
                    currentMetaState xor KeyEvent.META_CAPS_LOCK_ON
                } else {
                    currentMetaState
                }
            }

            else -> currentMetaState
        }
        return normalizeMetaStateCompat(updated)
    }

    private fun applyFlag(currentMetaState: Int, flag: Int, pressed: Boolean): Int {
        return if (pressed) {
            currentMetaState or flag
        } else {
            currentMetaState and flag.inv()
        }
    }

    private fun normalizeMetaStateCompat(metaState: Int): Int {
        var normalized = metaState

        normalized = promoteDirectionalFlags(
            normalized,
            directionalMask = KeyEvent.META_SHIFT_LEFT_ON or KeyEvent.META_SHIFT_RIGHT_ON,
            aggregateFlag = KeyEvent.META_SHIFT_ON
        )
        normalized = promoteDirectionalFlags(
            normalized,
            directionalMask = KeyEvent.META_ALT_LEFT_ON or KeyEvent.META_ALT_RIGHT_ON,
            aggregateFlag = KeyEvent.META_ALT_ON
        )
        normalized = promoteDirectionalFlags(
            normalized,
            directionalMask = KeyEvent.META_CTRL_LEFT_ON or KeyEvent.META_CTRL_RIGHT_ON,
            aggregateFlag = KeyEvent.META_CTRL_ON
        )
        normalized = promoteDirectionalFlags(
            normalized,
            directionalMask = KeyEvent.META_META_LEFT_ON or KeyEvent.META_META_RIGHT_ON,
            aggregateFlag = KeyEvent.META_META_ON
        )

        return normalized
    }

    private fun promoteDirectionalFlags(
        metaState: Int,
        directionalMask: Int,
        aggregateFlag: Int
    ): Int {
        return if (metaState and directionalMask != 0) {
            metaState or aggregateFlag
        } else {
            metaState and aggregateFlag.inv()
        }
    }
}
