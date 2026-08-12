package com.skybridge.compass.android.ui.screens.securityprompts

import android.content.Context
import android.provider.MediaStore
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import androidx.navigation.NavController
import com.skybridge.compass.android.data.SecuritySettings
import com.skybridge.compass.android.data.SecuritySettingsStore
import com.skybridge.compass.android.notifications.SecurityPromptNotifier
import com.skybridge.compass.android.securityprompts.SecurityPromptStore
import java.util.Locale

@Composable
fun IncomingTransferReviewScreen(navController: NavController, transferId: String) {
    val context = LocalContext.current
    val settings by SecuritySettingsStore.observe(context).collectAsState(initial = SecuritySettings())
    val prompt = remember(transferId) { SecurityPromptStore.getInboundPrompt(transferId) }

    var showOverwriteConfirm by remember { mutableStateOf(false) }

    fun declineAndClose() {
        SecurityPromptStore.resolveInbound(transferId, SecurityPromptStore.InboundFileTransferDecision.Decline)
        SecurityPromptNotifier.cancelInboundFilePrompt(context, transferId)
        navController.popBackStack()
    }

    fun accept(displayName: String, overwriteExisting: Boolean) {
        SecurityPromptStore.resolveInbound(
            transferId,
            SecurityPromptStore.InboundFileTransferDecision.Accept(
                downloadsDisplayName = displayName,
                overwriteExisting = overwriteExisting
            )
        )
        SecurityPromptNotifier.cancelInboundFilePrompt(context, transferId)
        navController.popBackStack()
    }

    if (prompt == null) {
        AlertDialog(
            onDismissRequest = { navController.popBackStack() },
            title = { Text("Incoming file transfer") },
            text = { Text("No pending transfer request found.", style = MaterialTheme.typography.bodyMedium) },
            confirmButton = { TextButton(onClick = { navController.popBackStack() }) { Text("OK") } }
        )
        return
    }

    val sender = prompt.senderDeviceId ?: "Unauthenticated sender"
    val declaredName = prompt.senderDeviceName?.takeIf { it.isNotBlank() && it != sender }
    val size = prompt.fileSizeBytes?.let { formatBytes(it) } ?: "Unknown size"
    val desiredName = sanitizeFileName(prompt.fileName)
    val exists = remember(desiredName) { downloadsItemExists(context, desiredName) }

    AlertDialog(
        onDismissRequest = { declineAndClose() },
        title = { Text("Incoming file transfer") },
        text = {
            Text(
                buildString {
                    append("From: $sender\n")
                    if (declaredName != null) append("Declared name: $declaredName\n")
                    append("File: ${prompt.fileName}\nSize: $size\nSave to: Downloads")
                },
                style = MaterialTheme.typography.bodyMedium
            )
        },
        confirmButton = {
            TextButton(
                onClick = {
                    if (settings.confirmOverwriteOnInbound && exists) {
                        showOverwriteConfirm = true
                    } else {
                        val finalName = if (!settings.confirmOverwriteOnInbound && exists) {
                            uniqueDownloadsDisplayName(context, desiredName)
                        } else {
                            desiredName
                        }
                        accept(displayName = finalName, overwriteExisting = false)
                    }
                }
            ) { Text("Accept") }
        },
        dismissButton = {
            TextButton(onClick = { declineAndClose() }) { Text("Decline") }
        }
    )

    if (showOverwriteConfirm) {
        AlertDialog(
            onDismissRequest = { showOverwriteConfirm = false },
            title = { Text("Overwrite existing file?") },
            text = { Text("“$desiredName” already exists in Downloads.\nOverwrite it?") },
            confirmButton = {
                TextButton(onClick = { accept(displayName = desiredName, overwriteExisting = true) }) {
                    Text("Overwrite")
                }
            },
            dismissButton = {
                TextButton(onClick = { showOverwriteConfirm = false }) { Text("Cancel") }
            }
        )
    }
}

private fun sanitizeFileName(raw: String): String {
    val cleaned = raw
        .replace('/', '_')
        .replace('\\', '_')
        .trim()
    return cleaned.ifBlank { "skybridge-received" }
}

private fun downloadsItemExists(context: Context, displayName: String): Boolean {
    val resolver = context.contentResolver
    val uri = MediaStore.Downloads.EXTERNAL_CONTENT_URI
    val projection = arrayOf(MediaStore.MediaColumns._ID)
    val selection = "${MediaStore.MediaColumns.DISPLAY_NAME}=?"
    val args = arrayOf(displayName)
    resolver.query(uri, projection, selection, args, null)?.use { cursor ->
        return cursor.moveToFirst()
    }
    return false
}

private fun uniqueDownloadsDisplayName(context: Context, desiredName: String): String {
    if (!downloadsItemExists(context, desiredName)) return desiredName

    val dot = desiredName.lastIndexOf('.')
    val hasExt = dot > 0 && dot < desiredName.lastIndex
    val base = if (hasExt) desiredName.substring(0, dot) else desiredName
    val ext = if (hasExt) desiredName.substring(dot + 1) else ""

    for (i in 1..999) {
        val candidate = if (hasExt) "$base ($i).$ext" else "$base ($i)"
        if (!downloadsItemExists(context, candidate)) return candidate
    }
    // Fallback
    return "${base}-${System.currentTimeMillis()}${if (hasExt) ".$ext" else ""}"
}

private fun formatBytes(bytes: Long): String {
    val units = arrayOf("B", "KB", "MB", "GB", "TB")
    var size = bytes.toDouble()
    var unit = 0
    while (size >= 1024.0 && unit < units.lastIndex) {
        size /= 1024.0
        unit++
    }
    return if (unit == 0) {
        "${bytes} ${units[unit]}"
    } else {
        String.format(Locale.ROOT, "%.1f %s", size, units[unit])
    }
}
