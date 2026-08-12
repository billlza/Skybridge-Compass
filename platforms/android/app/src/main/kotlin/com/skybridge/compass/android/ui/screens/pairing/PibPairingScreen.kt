package com.skybridge.compass.android.ui.screens.pairing

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Computer
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import androidx.navigation.NavController
import com.skybridge.compass.android.discovery.DiscoveryPeerLaunchTarget
import com.skybridge.compass.android.remote.mac.LanRemotePeer
import com.skybridge.compass.android.ui.components.LiquidGlassSurface
import com.skybridge.compass.android.ui.navigation.Screen
import com.skybridge.compass.android.ui.theme.IOSParityTokens
import com.skybridge.compass.core.p2p.FormalLanPeerAction
import com.skybridge.compass.discovery.domain.entities.DeviceType
import com.skybridge.compass.discovery.domain.entities.DiscoveredDevice
import com.skybridge.compass.discovery.presentation.events.DeviceDiscoveryEvent
import com.skybridge.compass.discovery.presentation.viewmodels.DeviceDiscoveryViewModel

/**
 * Outbound PIB-1 SAS pairing UX (Android = requester, Mac = responder).
 *
 * iOS-parity with the Pro-release `PQCVerificationView` (6-digit code confirmation) and
 * `PairingTrustRequestSheet`: the user discovers a Mac, initiates pairing, then both devices display
 * the same 6-digit Short Authentication String. The user confirms it matches on Android, which writes
 * the trusted-peer record so the Mac's `RemoteControlInboundTrustResolver` resolves the device and
 * subsequent connects skip re-pairing.
 *
 * All logic lives in [PibPairingViewModel]; this Composable is presentation-only.
 */
@Composable
fun PibPairingScreen(
    navController: NavController,
    pairingViewModel: PibPairingViewModel = hiltViewModel(),
    discoveryViewModel: DeviceDiscoveryViewModel = hiltViewModel()
) {
    val pairingState by pairingViewModel.state.collectAsState()
    val pairingPeers by pairingViewModel.peerItems.collectAsState()
    val discoveryState by discoveryViewModel.uiState.collectAsState()

    DisposableEffect(Unit) {
        discoveryViewModel.onEvent(DeviceDiscoveryEvent.StartDiscovery())
        onDispose { discoveryViewModel.onEvent(DeviceDiscoveryEvent.StopDiscovery) }
    }

    LaunchedEffect(discoveryState.devices) {
        pairingViewModel.updateDiscoveredDevices(discoveryState.devices)
    }

    val trusted = pairingState as? PibPairingViewModel.PairingUiState.Trusted
    LaunchedEffect(trusted?.peer?.endpointDigest, trusted?.connectNow) {
        val ready = trusted?.takeIf { it.connectNow } ?: return@LaunchedEffect
        navController.navigate(Screen.RemoteControl.routeFor(ready.peer.toRemoteLaunchTarget())) {
            launchSingleTop = true
            popUpTo(Screen.PibPairing.route) { inclusive = true }
        }
    }

    Scaffold { innerPadding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
                .padding(IOSParityTokens.SpacingTokens.ItemPadding)
        ) {
            Text(
                text = "Pair with Mac",
                style = MaterialTheme.typography.headlineSmall,
                fontWeight = FontWeight.SemiBold
            )
            Spacer(Modifier.height(4.dp))
            Text(
                text = "Establish a trusted link so this device can remotely control your Mac. " +
                    "You'll confirm a 6-digit code shown on both devices.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            Spacer(Modifier.height(16.dp))

            when (val state = pairingState) {
                is PibPairingViewModel.PairingUiState.AwaitingConfirmation ->
                    SasConfirmationCard(
                        state = state,
                        localName = pairingViewModel.localName,
                        onConfirm = pairingViewModel::confirmSasMatches,
                        onReject = pairingViewModel::rejectSas
                    )

                is PibPairingViewModel.PairingUiState.Trusted ->
                    ResultCard(
                        title = "Secure LAN trust ready",
                        body = "${state.macName} has a durable PIB pin and verified X-Wing key. Opening Remote Control…",
                        onDone = { navController.popBackStack() },
                        onDoneLabel = "Done"
                    )

                is PibPairingViewModel.PairingUiState.Failed ->
                    ResultCard(
                        title = "Pairing failed",
                        body = state.message,
                        onDone = pairingViewModel::reset,
                        onDoneLabel = "Try again"
                    )

                is PibPairingViewModel.PairingUiState.RefreshPending ->
                    ResultCard(
                        title = "Identity paired; key refresh pending",
                        body = "${state.macName} is durably paired. ${state.message}",
                        onDone = { pairingViewModel.retrySignedRefresh(state.peerId) },
                        onDoneLabel = "Refresh again"
                    )

                is PibPairingViewModel.PairingUiState.ReadyButRouteChanged ->
                    ResultCard(
                        title = "Pairing and keys are ready",
                        body = "${state.macName} is durably paired. ${state.message}",
                        onDone = { navController.popBackStack() },
                        onDoneLabel = "Continue"
                    )

                is PibPairingViewModel.PairingUiState.LocalTrustRecovery ->
                    ResultCard(
                        title = if (state.rollbackConfirmed) {
                            "Mac accepted; Android pin not stored"
                        } else {
                            "Local trust state is uncertain"
                        },
                        body = state.message,
                        onDone = if (state.rollbackConfirmed) {
                            { pairingViewModel.retryFullPairing(state.peerId) }
                        } else {
                            pairingViewModel::reset
                        },
                        onDoneLabel = if (state.rollbackConfirmed) "Repeat SAS pairing" else "Close"
                    )

                is PibPairingViewModel.PairingUiState.Exchanging ->
                    ExchangingCard(macName = state.macName)

                is PibPairingViewModel.PairingUiState.Completing ->
                    ExchangingCard(macName = state.macName)

                is PibPairingViewModel.PairingUiState.Refreshing ->
                    RefreshingCard(macName = state.macName)

                PibPairingViewModel.PairingUiState.Idle ->
                    MacPickerList(
                        peers = pairingPeers,
                        isScanning = discoveryState.isDiscovering,
                        onRescan = { discoveryViewModel.onEvent(DeviceDiscoveryEvent.StartDiscovery()) },
                        onPair = { item -> pairingViewModel.startOrRefresh(item.peer.id) }
                    )
            }
        }
    }
}

@Composable
private fun MacPickerList(
    peers: List<PibPairingViewModel.PairingPeerItem>,
    isScanning: Boolean,
    onRescan: () -> Unit,
    onPair: (PibPairingViewModel.PairingPeerItem) -> Unit
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.SpaceBetween
    ) {
        Text(
            text = if (isScanning) "Scanning for Macs…" else "Nearby Macs",
            style = MaterialTheme.typography.titleMedium
        )
        TextButton(onClick = onRescan) {
            Icon(Icons.Filled.Refresh, contentDescription = "Rescan")
            Spacer(Modifier.height(0.dp))
            Text(" Rescan")
        }
    }
    Spacer(Modifier.height(8.dp))

    if (peers.isEmpty()) {
        LiquidGlassSurface(modifier = Modifier.fillMaxWidth()) {
            Text(
                text = if (isScanning)
                    "Looking for Macs running SkyBridge Compass on this network…"
                else
                    "No Macs found. Make sure SkyBridge Compass is open on your Mac and on the same Wi-Fi.",
                style = MaterialTheme.typography.bodyMedium,
                textAlign = TextAlign.Center,
                modifier = Modifier.fillMaxWidth()
            )
        }
        return
    }

    LazyColumn(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        items(peers, key = { it.peer.id }) { item ->
            val peer = item.peer
            val handshake = requireNotNull(peer.handshakeEndpoint)
            LiquidGlassSurface(modifier = Modifier.fillMaxWidth()) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Filled.Computer, contentDescription = null)
                        Spacer(Modifier.height(0.dp))
                        Column(modifier = Modifier.padding(start = 12.dp)) {
                            Text(peer.name, style = MaterialTheme.typography.titleSmall)
                            Text(
                                text = "${handshake.hostAddress}:${handshake.port}  •  " +
                                    "${peer.host}:${peer.port}",
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }
                    }
                    Button(
                        enabled = item.enabled,
                        onClick = { onPair(item) }
                    ) {
                        Text(
                            when (item.action) {
                                FormalLanPeerAction.PAIR -> "Pair"
                                FormalLanPeerAction.REFRESH_AND_CONNECT -> "Refresh & connect"
                                FormalLanPeerAction.BLOCKED -> "Blocked"
                            }
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun RefreshingCard(macName: String) {
    LiquidGlassSurface(modifier = Modifier.fillMaxWidth()) {
        Column(
            modifier = Modifier.fillMaxWidth(),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            CircularProgressIndicator()
            Text(
                text = "Refreshing signed X-Wing keys for $macName…",
                style = MaterialTheme.typography.bodyMedium,
                textAlign = TextAlign.Center
            )
        }
    }
}

private fun LanRemotePeer.toRemoteLaunchTarget(): DiscoveryPeerLaunchTarget =
    DiscoveryPeerLaunchTarget(
        peerId = id,
        peerName = name,
        peerType = deviceType,
        serviceType = remoteDesktopEndpoint.serviceType,
        instanceName = remoteDesktopEndpoint.instanceName,
        host = remoteDesktopEndpoint.hostAddress,
        port = remoteDesktopEndpoint.port,
        routeProvenance = com.skybridge.compass.discovery.data.interop.AppleBonjourEndpointProvenance
            .valueOf(remoteDesktopEndpoint.routeProvenance),
        deviceIdHint = remoteDesktopEndpoint.advertisedDeviceId,
        advertisedFingerprint = remoteDesktopEndpoint.advertisedProtocolFingerprint,
        authenticatedProductRoute = true
    )

@Composable
private fun ExchangingCard(macName: String) {
    LiquidGlassSurface(modifier = Modifier.fillMaxWidth()) {
        Column(
            modifier = Modifier.fillMaxWidth(),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            CircularProgressIndicator()
            Text(
                text = "Exchanging identities with $macName…",
                style = MaterialTheme.typography.bodyMedium,
                textAlign = TextAlign.Center
            )
        }
    }
}

@Composable
private fun SasConfirmationCard(
    state: PibPairingViewModel.PairingUiState.AwaitingConfirmation,
    localName: String,
    onConfirm: () -> Unit,
    onReject: () -> Unit
) {
    LiquidGlassSurface(modifier = Modifier.fillMaxWidth()) {
        Column(
            modifier = Modifier.fillMaxWidth(),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            Text(
                text = "Confirm pairing code",
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold
            )
            Text(
                text = "This code should appear on ${state.macName}. A match authenticates the " +
                    "pairing transcript and peer identity; the remote session will perform its " +
                    "own secure handshake. If it differs, decline.",
                style = MaterialTheme.typography.bodyMedium,
                textAlign = TextAlign.Center,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )

            // 6-digit SAS, grouped 3 + 3 for readability, monospace for unambiguous compare.
            val grouped = if (state.sasCode.length == 6)
                "${state.sasCode.substring(0, 3)} ${state.sasCode.substring(3)}"
            else state.sasCode
            Text(
                text = grouped,
                fontSize = 44.sp,
                fontWeight = FontWeight.Bold,
                fontFamily = FontFamily.Monospace,
                letterSpacing = 4.sp
            )

            Text(
                text = "$localName  •  ${state.macName}",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            Text(
                text = "Fingerprint ${state.macFingerprint.take(16)}…  (${state.macSigningAlgorithm})",
                style = MaterialTheme.typography.bodySmall,
                fontFamily = FontFamily.Monospace,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )

            Spacer(Modifier.height(4.dp))
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                OutlinedButton(onClick = onReject, modifier = Modifier.weight(1f)) {
                    Text("Doesn't match")
                }
                Button(onClick = onConfirm, modifier = Modifier.weight(1f)) {
                    Text("Codes match")
                }
            }
        }
    }
}

@Composable
private fun ResultCard(
    title: String,
    body: String,
    onDone: () -> Unit,
    onDoneLabel: String
) {
    LiquidGlassSurface(modifier = Modifier.fillMaxWidth()) {
        Column(
            modifier = Modifier.fillMaxWidth(),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            Text(title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
            Text(
                text = body,
                style = MaterialTheme.typography.bodyMedium,
                textAlign = TextAlign.Center,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            Button(onClick = onDone) { Text(onDoneLabel) }
        }
    }
}
