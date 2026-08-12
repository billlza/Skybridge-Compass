package com.skybridge.compass.filetransfer.webrtc

internal enum class ReceiveResourceCleanupStage(val wireName: String) {
    FINALIZE_PARTIAL_FILE("finalize_partial_file"),
    CLOSE_PARTIAL_FILE("close_partial_file"),
    DELETE_PARTIAL_FILE("delete_partial_file"),
}

internal data class ReceiveResourceCleanupFailure(
    val stage: ReceiveResourceCleanupStage,
    val cause: Exception,
)

internal enum class ReceiveCleanupCheckpointDisposition {
    DELETE,
    RETAIN_FOR_RECOVERY,
}

internal data class ReceiveResourceCleanupReport(
    val transferId: String,
    val failures: List<ReceiveResourceCleanupFailure> = emptyList(),
) {
    val isSuccessful: Boolean
        get() = failures.isEmpty()

    val failedStages: List<String>
        get() = failures.map { it.stage.wireName }

    val checkpointDisposition: ReceiveCleanupCheckpointDisposition
        get() = if (isSuccessful) {
            ReceiveCleanupCheckpointDisposition.DELETE
        } else {
            ReceiveCleanupCheckpointDisposition.RETAIN_FOR_RECOVERY
        }
}

/**
 * Ordered receive-resource teardown. A failed close prevents deletion so the checkpoint's partial
 * path remains recoverable; every failure is returned to the terminal-path owner for an explicit
 * status and checkpoint-retention decision.
 */
internal object ReceiveResourceCleanup {
    fun execute(
        transferId: String,
        closePartialFile: (() -> Unit)?,
        deletePartialFile: (() -> Unit)?,
    ): ReceiveResourceCleanupReport {
        val failures = mutableListOf<ReceiveResourceCleanupFailure>()
        if (closePartialFile != null) {
            try {
                closePartialFile()
            } catch (cause: Exception) {
                failures += ReceiveResourceCleanupFailure(
                    ReceiveResourceCleanupStage.CLOSE_PARTIAL_FILE,
                    cause,
                )
            }
        }
        if (failures.isEmpty() && deletePartialFile != null) {
            try {
                deletePartialFile()
            } catch (cause: Exception) {
                failures += ReceiveResourceCleanupFailure(
                    ReceiveResourceCleanupStage.DELETE_PARTIAL_FILE,
                    cause,
                )
            }
        }
        return ReceiveResourceCleanupReport(transferId, failures)
    }
}
