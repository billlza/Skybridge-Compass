package com.skybridge.compass.filetransfer.webrtc.resume

import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.io.TempDir
import java.io.IOException
import java.nio.file.Files
import java.nio.file.Path

class AndroidBatchManifestStoreTest {
    @TempDir
    lateinit var filesDirectory: Path

    private val json = Json { ignoreUnknownKeys = true; explicitNulls = false }

    @Test
    fun stagesBeforeAuthorizedAtomicCommit_andRoundTrips() = runBlocking {
        val store = AndroidBatchManifestStore.forFilesDirectory(filesDirectory.toFile(), json)
        val manifest = manifest(BATCH_ID)
        var gateObservedStaging = false

        store.save(manifest) { commit ->
            val storageDirectory = filesDirectory.resolve("skybridge_batch_manifests")
            gateObservedStaging = Files.list(storageDirectory).use { children ->
                children.anyMatch { it.fileName.toString().endsWith(".staging.tmp") }
            }
            assertFalse(Files.exists(storageDirectory.resolve("$BATCH_ID.json")))
            commit()
            true
        }

        assertTrue(gateObservedStaging)
        assertEquals(manifest, store.load(BATCH_ID))
        assertNoStagingFiles()
    }

    @Test
    fun rejectedAtomicCommitLeavesNoManifestOrStagingResidue() = runBlocking {
        val store = AndroidBatchManifestStore.forFilesDirectory(filesDirectory.toFile(), json)

        assertThrows(BatchManifestCommitRejectedException::class.java) {
            runBlocking { store.save(manifest(BATCH_ID)) { false } }
        }

        assertNull(store.load(BATCH_ID))
        assertNoStagingFiles()
    }

    @Test
    fun deleteIsIdempotent_butFilesystemFailureIsExplicit() = runBlocking {
        val store = AndroidBatchManifestStore.forFilesDirectory(filesDirectory.toFile(), json)
        store.delete(BATCH_ID)

        val target = filesDirectory
            .resolve("skybridge_batch_manifests")
            .resolve("$BATCH_ID.json")
        Files.createDirectories(target)
        Files.writeString(target.resolve("child"), "blocks directory deletion")

        assertThrows(IOException::class.java) {
            runBlocking { store.delete(BATCH_ID) }
        }
        assertTrue(Files.exists(target))
    }

    private fun assertNoStagingFiles() {
        val storageDirectory = filesDirectory.resolve("skybridge_batch_manifests")
        if (!Files.exists(storageDirectory)) return
        Files.list(storageDirectory).use { children ->
            assertFalse(children.anyMatch { it.fileName.toString().endsWith(".staging.tmp") })
        }
    }

    private fun manifest(batchId: String): BatchManifest = BatchManifest(
        batchId = batchId,
        batchTotal = 1,
        entries = listOf(
            BatchManifestEntry(
                transferId = TRANSFER_ID,
                batchIndex = 0,
                relativePath = "file.txt",
                fileName = "file.txt",
                fileSize = 4,
                status = BatchManifestEntry.Status.IN_PROGRESS,
                updatedAtMs = 1,
            ),
        ),
        createdAtMs = 1,
        updatedAtMs = 1,
    )

    private companion object {
        const val BATCH_ID = "10000000-0000-0000-0000-000000000001"
        const val TRANSFER_ID = "20000000-0000-0000-0000-000000000001"
    }
}
