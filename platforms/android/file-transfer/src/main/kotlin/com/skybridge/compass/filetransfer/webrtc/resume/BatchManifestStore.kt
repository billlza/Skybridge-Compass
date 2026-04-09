package com.skybridge.compass.filetransfer.webrtc.resume

interface BatchManifestStore {
    suspend fun save(manifest: BatchManifest)
    suspend fun load(batchId: String): BatchManifest?
    suspend fun delete(batchId: String)
    suspend fun list(): List<BatchManifest>
}


