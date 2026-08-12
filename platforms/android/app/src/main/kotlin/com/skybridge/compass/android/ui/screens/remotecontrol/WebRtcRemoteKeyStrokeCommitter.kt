package com.skybridge.compass.android.ui.screens.remotecontrol

/**
 * Commits one encoded key Down/Up pair under one exact WebRTC secure-owner boundary.
 * A partial transport failure terminalizes only the captured owner; callers never re-resolve a
 * replacement for the second half of the pair.
 */
internal object WebRtcRemoteKeyStrokeCommitter {
    fun commit(
        encodedKeyEvents: List<ByteArray>,
        commitIfCurrentAcknowledgedOwner: (commit: () -> Unit) -> Boolean,
        sendForCapturedOwner: (ByteArray) -> Boolean,
        terminalizeCapturedOwner: () -> Unit
    ): Boolean {
        require(encodedKeyEvents.size == 2) { "remote key stroke must contain Down and Up" }
        var sentCount = 0
        val ownerWasCurrent = commitIfCurrentAcknowledgedOwner {
            for (event in encodedKeyEvents) {
                if (!sendForCapturedOwner(event)) break
                sentCount += 1
            }
        }
        val complete = ownerWasCurrent && sentCount == encodedKeyEvents.size
        if (ownerWasCurrent && !complete) {
            terminalizeCapturedOwner()
        }
        return complete
    }
}
