package com.skybridge.compass.android.ui.screens.securityprompts

import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.foundation.layout.Row
import androidx.compose.ui.platform.LocalContext
import androidx.navigation.NavController
import com.skybridge.compass.android.notifications.SecurityPromptNotifier
import com.skybridge.compass.android.securityprompts.SecurityPromptStore
import com.skybridge.compass.core.p2p.PairingTrustConflict
import com.skybridge.compass.core.p2p.PairingTrustDecision

@Composable
fun PairingTrustReviewScreen(navController: NavController, requestId: String) {
    val context = LocalContext.current
    val prompt = remember(requestId) { SecurityPromptStore.getPairingPrompt(requestId) }

    fun resolve(decision: PairingTrustDecision) {
        SecurityPromptStore.resolvePairing(requestId, decision)
        SecurityPromptNotifier.cancelPairingTrustPrompt(context, requestId)
        navController.popBackStack()
    }

    if (prompt == null) {
        AlertDialog(
            onDismissRequest = { navController.popBackStack() },
            title = { Text("Trusted-device request") },
            text = { Text("No pending pairing request found.", style = MaterialTheme.typography.bodyMedium) },
            confirmButton = { TextButton(onClick = { navController.popBackStack() }) { Text("OK") } }
        )
        return
    }

    val sender = prompt.deviceName ?: prompt.declaredDeviceId.ifBlank { prompt.peerId }
    val message = buildString {
        append("Device: ").append(sender)
        append("\nDeclared ID: ").append(prompt.declaredDeviceId)
        prompt.platform?.takeIf { it.isNotBlank() }?.let { append("\nPlatform: ").append(it) }
        prompt.modelName?.takeIf { it.isNotBlank() }?.let { append("\nModel: ").append(it) }
        prompt.osVersion?.takeIf { it.isNotBlank() }?.let { append("\nOS: ").append(it) }
        prompt.protocolPublicKeyFingerprint?.takeIf { it.isNotBlank() }?.let {
            append("\nFingerprint: ").append(it.take(16)).append("...")
        }
        prompt.conflict?.let {
            append("\n\nConflict: ").append(conflictText(it))
        }
    }

    AlertDialog(
        onDismissRequest = { resolve(PairingTrustDecision.DECLINE) },
        title = {
            Text(if (prompt.conflict == null) "Trusted-device request" else "Pairing conflict detected")
        },
        text = { Text(message, style = MaterialTheme.typography.bodyMedium) },
        confirmButton = {
            if (prompt.conflict == null) {
                Row {
                    TextButton(onClick = { resolve(PairingTrustDecision.ALLOW_ONCE) }) {
                        Text("Allow Once")
                    }
                    TextButton(onClick = { resolve(PairingTrustDecision.TRUST_ALWAYS) }) {
                        Text("Trust Device")
                    }
                }
            } else {
                TextButton(onClick = { resolve(PairingTrustDecision.DECLINE) }) {
                    Text("Dismiss")
                }
            }
        },
        dismissButton = {
            if (prompt.conflict == null) {
                TextButton(onClick = { resolve(PairingTrustDecision.DECLINE) }) {
                    Text("Decline")
                }
            }
        }
    )
}

private fun conflictText(conflict: PairingTrustConflict): String = when (conflict) {
    PairingTrustConflict.IDENTITY_CONFLICT ->
        "This device ID is already associated with a different authoritative fingerprint."
    PairingTrustConflict.DEVICE_ID_MIGRATION_REQUIRED ->
        "This authoritative fingerprint is already trusted under another device ID."
    PairingTrustConflict.QUARANTINED_IDENTITY ->
        "This identity is quarantined and must be reverified before reuse."
    PairingTrustConflict.REVOKED_IDENTITY ->
        "This identity has been revoked and cannot be trusted."
}
