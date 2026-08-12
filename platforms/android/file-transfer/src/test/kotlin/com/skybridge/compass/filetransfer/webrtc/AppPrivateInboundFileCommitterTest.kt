package com.skybridge.compass.filetransfer.webrtc

import java.io.IOException
import java.nio.channels.FileChannel
import java.nio.file.Files
import java.nio.file.Path
import java.util.UUID
import org.junit.jupiter.api.Assertions.assertArrayEquals
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNotEquals
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class AppPrivateInboundFileCommitterTest {
    @Test
    fun exclusiveTemporaryFilesAreRunOwnedAndNeverReuseAPath() {
        withTemporaryParent { parent ->
            val committer = AppPrivateInboundFileCommitter(parent.resolve("inbound").toFile())
            val transferId = UUID.randomUUID().toString()

            val first = committer.createExclusiveTemporaryFile(transferId)
            val second = committer.createExclusiveTemporaryFile(transferId)
            try {
                assertNotEquals(first.path, second.path)
                assertTrue(Files.isRegularFile(first.path))
                assertTrue(Files.isRegularFile(second.path))
                assertTrue(committer.ownsTemporaryFile(first.path.toFile(), transferId))
                assertTrue(committer.ownsTemporaryFile(second.path.toFile(), transferId))
            } finally {
                committer.discard(first)
                committer.discard(second)
            }
        }
    }

    @Test
    fun collisionGetsUniqueNameWithoutOverwritingExistingFile() {
        withTemporaryParent { parent ->
            val directory = parent.resolve("inbound")
            val committer = AppPrivateInboundFileCommitter(directory.toFile())
            val existing = directory.resolve("payload.bin")
            val original = "existing".encodeToByteArray()
            Files.write(existing, original)

            val received = "received".encodeToByteArray()
            val temporary = stagedFile(committer, received)
            val committed = committer.commitValidated(temporary, "payload.bin").toPath()

            assertEquals("payload (1).bin", committed.fileName.toString())
            assertArrayEquals(original, Files.readAllBytes(existing))
            assertArrayEquals(received, Files.readAllBytes(committed))
            assertFalse(Files.exists(temporary.path))
        }
    }

    @Test
    fun symbolicLinkSubstitutionIsRejectedAndExternalTargetIsUntouched() {
        withTemporaryParent { parent ->
            val directory = parent.resolve("inbound")
            val committer = AppPrivateInboundFileCommitter(directory.toFile())
            val external = parent.resolve("external.bin")
            val externalBytes = "outside".encodeToByteArray()
            Files.write(external, externalBytes)

            val temporary = stagedFile(committer, "received".encodeToByteArray())
            Files.delete(temporary.path)
            Files.createSymbolicLink(temporary.path, external)

            val failure = assertThrows(AppPrivateInboundFileCommitException::class.java) {
                committer.commitValidated(temporary, "payload.bin")
            }
            assertTrue(failure.cause is IllegalArgumentException)
            assertArrayEquals(externalBytes, Files.readAllBytes(external))
            assertFalse(Files.exists(temporary.path, java.nio.file.LinkOption.NOFOLLOW_LINKS))
            assertFalse(Files.exists(directory.resolve("payload.bin")))
        }
    }

    @Test
    fun directorySyncFailureRollsBackBothTemporaryAndFinalNames() {
        withTemporaryParent { parent ->
            val directory = parent.resolve("inbound")
            Files.createDirectory(directory)
            val fileSystem = RecordingFileSystem()
            val committer = AppPrivateInboundFileCommitter(directory.toFile(), fileSystem)
            val temporary = stagedFile(committer, "received".encodeToByteArray())
            fileSystem.failNextDirectorySync = true

            assertThrows(AppPrivateInboundFileCommitException::class.java) {
                committer.commitValidated(temporary, "payload.bin")
            }

            assertFalse(Files.exists(temporary.path))
            assertFalse(Files.exists(directory.resolve("payload.bin")))
            assertTrue(Files.list(directory).use { entries -> entries.findAny().isEmpty })
        }
    }

    @Test
    fun directoryCreationAndSuccessfulCommitSynchronizeTheirDirectoryEntries() {
        withTemporaryParent { parent ->
            val directory = parent.resolve("inbound")
            val fileSystem = RecordingFileSystem()
            val committer = AppPrivateInboundFileCommitter(directory.toFile(), fileSystem)

            assertEquals(listOf(parent), fileSystem.synchronizedDirectories)
            fileSystem.synchronizedDirectories.clear()

            val temporary = stagedFile(committer, "received".encodeToByteArray())
            val committed = committer.commitValidated(temporary, "payload.bin").toPath()

            assertEquals(listOf(directory), fileSystem.synchronizedDirectories)
            assertTrue(Files.isRegularFile(committed))
            assertFalse(Files.exists(temporary.path))
        }
    }

    @Test
    fun symbolicLinkDestinationDirectoryIsRejected() {
        withTemporaryParent { parent ->
            val external = parent.resolve("external")
            val link = parent.resolve("inbound")
            Files.createDirectory(external)
            Files.createSymbolicLink(link, external)

            assertThrows(IllegalArgumentException::class.java) {
                AppPrivateInboundFileCommitter(link.toFile())
            }
            assertTrue(Files.isDirectory(external))
            assertTrue(Files.isSymbolicLink(link))
        }
    }

    private fun stagedFile(
        committer: AppPrivateInboundFileCommitter,
        bytes: ByteArray,
    ): AppPrivateInboundFileCommitter.OwnedTemporaryFile {
        val temporary = committer.createExclusiveTemporaryFile(UUID.randomUUID().toString())
        temporary.writeAt(0, bytes)
        val finalization = temporary.synchronizeAndClose()
        check(finalization.isSuccessful) { "test staging finalization failed: ${finalization.failedStages}" }
        return temporary
    }

    private inline fun withTemporaryParent(block: (Path) -> Unit) {
        val parent = Files.createTempDirectory("skybridge-private-commit-")
        try {
            block(parent)
        } finally {
            parent.toFile().deleteRecursively()
        }
    }

    private class RecordingFileSystem : AppPrivateDurableFileSystem {
        val synchronizedDirectories = mutableListOf<Path>()
        var failNextDirectorySync = false

        override fun createDirectory(directory: Path) =
            NioAppPrivateDurableFileSystem.createDirectory(directory)

        override fun openExclusive(path: Path): FileChannel =
            NioAppPrivateDurableFileSystem.openExclusive(path)

        override fun openExisting(path: Path): FileChannel =
            NioAppPrivateDurableFileSystem.openExisting(path)

        override fun createNoReplaceLink(existing: Path, link: Path) =
            NioAppPrivateDurableFileSystem.createNoReplaceLink(existing, link)

        override fun deleteIfExists(path: Path) =
            NioAppPrivateDurableFileSystem.deleteIfExists(path)

        override fun synchronizeDirectory(directory: Path) {
            synchronizedDirectories.add(directory)
            if (failNextDirectorySync) {
                failNextDirectorySync = false
                throw IOException("injected directory sync failure")
            }
            NioAppPrivateDurableFileSystem.synchronizeDirectory(directory)
        }
    }
}
