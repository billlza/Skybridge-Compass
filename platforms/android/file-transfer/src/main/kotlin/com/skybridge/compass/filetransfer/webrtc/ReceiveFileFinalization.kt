package com.skybridge.compass.filetransfer.webrtc

import java.io.RandomAccessFile
import java.nio.channels.FileChannel

/** Flush/close transaction that must succeed before a received file can be delivered. */
internal data class ReceiveFileFinalizationCloseResult(
    val failedStages: List<String>
) {
    val isSuccessful: Boolean get() = failedStages.isEmpty()
}

internal fun closeReceiveFileForFinalization(
    file: RandomAccessFile
): ReceiveFileFinalizationCloseResult = performReceiveFileFinalizationClose(
    sync = { file.fd.sync() },
    close = file::close
)

internal fun closeReceiveFileForFinalization(
    channel: FileChannel
): ReceiveFileFinalizationCloseResult = performReceiveFileFinalizationClose(
    sync = { channel.force(true) },
    close = channel::close
)

internal fun performReceiveFileFinalizationClose(
    sync: () -> Unit,
    close: () -> Unit
): ReceiveFileFinalizationCloseResult {
    val failures = mutableListOf<String>()
    try {
        sync()
    } catch (_: Exception) {
        failures += "sync"
    }
    try {
        close()
    } catch (_: Exception) {
        failures += "close"
    }
    return ReceiveFileFinalizationCloseResult(failures)
}
