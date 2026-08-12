package com.skybridge.compass.filetransfer.webrtc

import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.nio.file.StandardOpenOption
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ReceiveFileFinalizationTest {
    @Test
    fun syncAndCloseBothRunAndEveryFailureIsReported() {
        val timeline = mutableListOf<String>()

        val result = performReceiveFileFinalizationClose(
            sync = {
                timeline += "sync"
                throw IllegalStateException("sync failed")
            },
            close = {
                timeline += "close"
                throw IllegalStateException("close failed")
            }
        )

        assertEquals(listOf("sync", "close"), timeline)
        assertEquals(listOf("sync", "close"), result.failedStages)
        assertFalse(result.isSuccessful)
    }

    @Test
    fun realTemporaryFileIsFlushedAndClosedBeforeSuccess() {
        val file = File.createTempFile("skybridge-finalization-", ".partial")
        try {
            val randomAccessFile = RandomAccessFile(file, "rw")
            randomAccessFile.write(byteArrayOf(1, 2, 3))

            val result = closeReceiveFileForFinalization(randomAccessFile)

            assertTrue(result.isSuccessful)
            assertEquals(byteArrayOf(1, 2, 3).toList(), file.readBytes().toList())
        } finally {
            file.delete()
        }
    }

    @Test
    fun exclusiveFileChannelIsForcedAndClosedBeforeCommitEligibility() {
        val file = File.createTempFile("skybridge-channel-finalization-", ".partial")
        try {
            val channel = FileChannel.open(
                file.toPath(),
                StandardOpenOption.READ,
                StandardOpenOption.WRITE,
            )
            channel.write(ByteBuffer.wrap(byteArrayOf(4, 5, 6)))

            val result = closeReceiveFileForFinalization(channel)

            assertTrue(result.isSuccessful)
            assertFalse(channel.isOpen)
            assertEquals(byteArrayOf(4, 5, 6).toList(), file.readBytes().toList())
        } finally {
            file.delete()
        }
    }
}
