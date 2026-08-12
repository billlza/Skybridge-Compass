package com.skybridge.compass.filetransfer.webrtc

import android.content.Context
import java.io.File
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.nio.file.FileAlreadyExistsException
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.Path
import java.nio.file.StandardOpenOption
import java.nio.file.attribute.BasicFileAttributes
import java.util.UUID

/**
 * Durable destination for an accepted inbound file that must remain inside the calling app's data
 * directory.
 *
 * The committer owns the complete storage transaction: an unpredictable `CREATE_NEW` staging file,
 * caller-triggered fd sync/close before validation, a hard-link based no-replace commit, removal of
 * the staging name, and a directory fsync before success is returned. A hard link is used because
 * Android's Java `move` APIs do not expose Linux `RENAME_NOREPLACE`; pre-checking followed by an
 * ordinary rename would leave an overwrite race.
 *
 * This class does not decide whether bytes are valid. [commitValidated] is intentionally only
 * callable after the controller has checked the declared size, file SHA-256, optional Merkle proof,
 * and exact secure-operation owner.
 */
class AppPrivateInboundFileCommitter internal constructor(
    directory: File,
    private val fileSystem: AppPrivateDurableFileSystem = NioAppPrivateDurableFileSystem,
) {
    internal class OwnedTemporaryFile internal constructor(
        val transferId: String,
        val path: Path,
        private val channel: FileChannel,
    ) {
        fun size(): Long = channel.size()

        fun writeAt(offset: Long, bytes: ByteArray) {
            require(offset >= 0L) { "inbound file offset must be non-negative" }
            channel.position(offset)
            val buffer = ByteBuffer.wrap(bytes)
            while (buffer.hasRemaining()) {
                val written = channel.write(buffer)
                check(written > 0) { "inbound file write made no progress" }
            }
        }

        internal fun synchronizeAndClose(): ReceiveFileFinalizationCloseResult =
            closeReceiveFileForFinalization(channel)

        internal fun close() {
            channel.close()
        }

        internal val isOpen: Boolean get() = channel.isOpen
    }

    private val directory: Path = directory.toPath().toAbsolutePath().normalize()

    init {
        prepareDirectory()
    }

    internal fun createExclusiveTemporaryFile(transferId: String): OwnedTemporaryFile {
        val canonicalTransferId = CrossNetworkFileTransferValidator.canonicalTransferId(transferId)
        validateDirectory()
        repeat(MAX_TEMPORARY_FILE_ATTEMPTS) {
            val name = "$TEMPORARY_FILE_PREFIX$canonicalTransferId-${UUID.randomUUID()}$TEMPORARY_FILE_SUFFIX"
            val path = directory.resolve(name)
            try {
                return OwnedTemporaryFile(
                    transferId = canonicalTransferId,
                    path = path,
                    channel = fileSystem.openExclusive(path),
                )
            } catch (_: FileAlreadyExistsException) {
                // The random name collided. Try another bounded candidate; never open an existing
                // path and never fall back to a predictable non-exclusive file.
            }
        }
        throw AppPrivateInboundFileCommitException("unable to allocate an exclusive inbound staging file")
    }

    internal fun reopenOwnedTemporaryFile(
        transferId: String,
        file: File,
    ): OwnedTemporaryFile {
        val canonicalTransferId = CrossNetworkFileTransferValidator.canonicalTransferId(transferId)
        val path = file.toPath().toAbsolutePath().normalize()
        validateOwnedTemporaryPath(path, canonicalTransferId)
        return OwnedTemporaryFile(
            transferId = canonicalTransferId,
            path = path,
            channel = fileSystem.openExisting(path),
        )
    }

    internal fun ownsTemporaryFile(file: File, transferId: String): Boolean = runCatching {
        validateOwnedTemporaryPath(
            file.toPath().toAbsolutePath().normalize(),
            CrossNetworkFileTransferValidator.canonicalTransferId(transferId),
        )
    }.isSuccess

    internal fun commitValidated(
        temporaryFile: OwnedTemporaryFile,
        preferredFileName: String,
    ): File {
        val safeFileName = requireSafeDestinationName(preferredFileName)
        var linkedDestination: Path? = null
        try {
            validateOwnedTemporaryPath(temporaryFile.path, temporaryFile.transferId)
            check(!temporaryFile.isOpen) {
                "inbound staging file must be synchronized and closed before commit"
            }

            for (collisionIndex in 0..DownloadsFilenameDeduper.MAX_SUFFIX) {
                val candidateName = DownloadsFilenameDeduper.collisionCandidate(
                    desiredName = safeFileName,
                    collisionIndex = collisionIndex,
                )
                val destination = directory.resolve(candidateName)
                try {
                    fileSystem.createNoReplaceLink(
                        existing = temporaryFile.path,
                        link = destination,
                    )
                    linkedDestination = destination
                    break
                } catch (_: FileAlreadyExistsException) {
                    // Collision is expected and must never overwrite the existing entry.
                }
            }

            val committed = linkedDestination
                ?: throw AppPrivateInboundFileCommitException("inbound destination name space exhausted")

            fileSystem.deleteIfExists(temporaryFile.path)
            fileSystem.synchronizeDirectory(directory)
            return committed.toFile()
        } catch (failure: Exception) {
            cleanupAfterFailure(temporaryFile.path, linkedDestination, failure)
            if (failure is AppPrivateInboundFileCommitException) throw failure
            throw AppPrivateInboundFileCommitException("app-private inbound commit failed", failure)
        }
    }

    internal fun discard(temporaryFile: OwnedTemporaryFile) {
        val failures = mutableListOf<Exception>()
        try {
            temporaryFile.close()
        } catch (error: Exception) {
            failures += error
        }
        try {
            fileSystem.deleteIfExists(temporaryFile.path)
        } catch (error: Exception) {
            failures += error
        }
        try {
            fileSystem.synchronizeDirectory(directory)
        } catch (error: Exception) {
            failures += error
        }
        if (failures.isNotEmpty()) {
            val error = AppPrivateInboundFileCommitException("failed to discard inbound staging file")
            failures.forEach(error::addSuppressed)
            throw error
        }
    }

    private fun prepareDirectory() {
        val parent = directory.parent
            ?: throw AppPrivateInboundFileCommitException("inbound directory has no parent")
        require(!Files.isSymbolicLink(parent)) { "inbound directory parent must not be a symbolic link" }
        if (Files.exists(directory, LinkOption.NOFOLLOW_LINKS)) {
            validateDirectory()
            return
        }
        try {
            fileSystem.createDirectory(directory)
            fileSystem.synchronizeDirectory(parent)
            validateDirectory()
        } catch (failure: Exception) {
            runCatching { fileSystem.deleteIfExists(directory) }
                .exceptionOrNull()
                ?.let(failure::addSuppressed)
            throw AppPrivateInboundFileCommitException("failed to prepare app-private inbound directory", failure)
        }
    }

    private fun validateDirectory() {
        require(!Files.isSymbolicLink(directory)) { "inbound directory must not be a symbolic link" }
        val attributes = Files.readAttributes(
            directory,
            BasicFileAttributes::class.java,
            LinkOption.NOFOLLOW_LINKS,
        )
        require(attributes.isDirectory) { "inbound destination is not a directory" }
    }

    private fun validateOwnedTemporaryPath(path: Path, transferId: String) {
        validateDirectory()
        require(path.parent == directory) { "inbound staging file escaped its owned directory" }
        require(!Files.isSymbolicLink(path)) { "inbound staging file must not be a symbolic link" }
        val expectedPrefix = "$TEMPORARY_FILE_PREFIX$transferId-"
        val name = path.fileName.toString()
        require(name.startsWith(expectedPrefix) && name.endsWith(TEMPORARY_FILE_SUFFIX)) {
            "inbound staging file is not owned by this transfer"
        }
        val randomPart = name.removePrefix(expectedPrefix).removeSuffix(TEMPORARY_FILE_SUFFIX)
        require(runCatching { UUID.fromString(randomPart).toString() == randomPart }.getOrDefault(false)) {
            "inbound staging file has an invalid ownership token"
        }
        val attributes = Files.readAttributes(
            path,
            BasicFileAttributes::class.java,
            LinkOption.NOFOLLOW_LINKS,
        )
        require(attributes.isRegularFile) { "inbound staging path is not a regular file" }
    }

    private fun requireSafeDestinationName(raw: String): String {
        require(raw == raw.trim() && raw.isNotEmpty()) { "inbound destination name is empty or padded" }
        require(raw != "." && raw != "..") { "inbound destination name is invalid" }
        require(raw.none { it == '/' || it == '\\' || it == '\u0000' }) {
            "inbound destination must be a file name, not a path"
        }
        require(raw.toByteArray(Charsets.UTF_8).size <= MAX_DESTINATION_NAME_BYTES) {
            "inbound destination name exceeds the app-private limit"
        }
        return raw
    }

    private fun cleanupAfterFailure(
        temporaryPath: Path,
        linkedDestination: Path?,
        failure: Exception,
    ) {
        if (linkedDestination != null) {
            runCatching { fileSystem.deleteIfExists(linkedDestination) }
                .exceptionOrNull()
                ?.let(failure::addSuppressed)
        }
        runCatching { fileSystem.deleteIfExists(temporaryPath) }
            .exceptionOrNull()
            ?.let(failure::addSuppressed)
        runCatching { fileSystem.synchronizeDirectory(directory) }
            .exceptionOrNull()
            ?.let(failure::addSuppressed)
    }

    companion object {
        private const val DIRECTORY_NAME = "skybridge_inbound_files"
        private const val TEMPORARY_FILE_PREFIX = ".skybridge-inbound-"
        private const val TEMPORARY_FILE_SUFFIX = ".partial"
        private const val MAX_TEMPORARY_FILE_ATTEMPTS = 32
        private const val MAX_DESTINATION_NAME_BYTES = 220

        fun forContext(context: Context): AppPrivateInboundFileCommitter =
            AppPrivateInboundFileCommitter(
                File(context.applicationContext.filesDir, DIRECTORY_NAME),
            )

        /** Flushes metadata after the formal owner removes its exact committed payload. */
        fun synchronizeCommittedDirectory(context: Context) {
            NioAppPrivateDurableFileSystem.synchronizeDirectory(
                File(context.applicationContext.filesDir, DIRECTORY_NAME).toPath(),
            )
        }
    }
}

internal interface AppPrivateDurableFileSystem {
    fun createDirectory(directory: Path)
    fun openExclusive(path: Path): FileChannel
    fun openExisting(path: Path): FileChannel
    fun createNoReplaceLink(existing: Path, link: Path)
    fun deleteIfExists(path: Path)
    fun synchronizeDirectory(directory: Path)
}

internal object NioAppPrivateDurableFileSystem : AppPrivateDurableFileSystem {
    override fun createDirectory(directory: Path) {
        Files.createDirectory(directory)
    }

    override fun openExclusive(path: Path): FileChannel = FileChannel.open(
        path,
        StandardOpenOption.CREATE_NEW,
        StandardOpenOption.READ,
        StandardOpenOption.WRITE,
        LinkOption.NOFOLLOW_LINKS,
    )

    override fun openExisting(path: Path): FileChannel = FileChannel.open(
        path,
        StandardOpenOption.READ,
        StandardOpenOption.WRITE,
        LinkOption.NOFOLLOW_LINKS,
    )

    override fun createNoReplaceLink(existing: Path, link: Path) {
        Files.createLink(link, existing)
    }

    override fun deleteIfExists(path: Path) {
        Files.deleteIfExists(path)
    }

    override fun synchronizeDirectory(directory: Path) {
        FileChannel.open(directory, StandardOpenOption.READ).use { channel ->
            channel.force(true)
        }
    }

}

class AppPrivateInboundFileCommitException(
    message: String,
    cause: Throwable? = null,
) : IOException(message, cause)
