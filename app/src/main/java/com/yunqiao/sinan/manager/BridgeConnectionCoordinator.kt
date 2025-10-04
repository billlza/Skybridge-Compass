package com.yunqiao.sinan.manager

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.content.Context
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiManager
import android.net.wifi.p2p.WifiP2pConfig
import android.net.wifi.p2p.WifiP2pDeviceList
import android.net.wifi.p2p.WifiP2pInfo
import android.net.wifi.p2p.WifiP2pManager
import android.net.wifi.p2p.WpsInfo
import android.os.Build
import android.os.Looper
import android.os.SystemClock
import android.nfc.NfcAdapter
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.net.SocketTimeoutException
import java.util.Locale
import java.util.UUID
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

enum class BridgeTransportHint {
    WifiDirect,
    Lan,
    Cloud,
    UltraWideband,
    Bluetooth,
    Nfc,
    AirPlay,
    UniversalBridge
}

data class BridgeDevice(
    val deviceId: String,
    val displayName: String,
    val deviceAddress: String,
    val ipAddress: String?,
    val signalLevel: Int,
    val lastSeen: Long,
    val capabilities: Set<BridgeTransportHint>,
    val platform: BridgeDevicePlatform = BridgeDevicePlatform.UNKNOWN,
    val compatibilityRemark: String = ""
)

data class BridgeAccountEndpoint(
    val accountId: String,
    val relayId: String,
    val throughputMbps: Float,
    val latencyMs: Int,
    val lastUpdated: Long = System.currentTimeMillis()
)

sealed class BridgeTransport {
    data class DirectHotspot(
        val groupOwnerAddress: InetAddress,
        val port: Int,
        val medium: BridgeTransportHint = BridgeTransportHint.WifiDirect,
        val throughputHintMbps: Float = 0f,
        val latencyHintMs: Int = 0
    ) : BridgeTransport()
    data class LocalLan(val ipAddress: String, val port: Int) : BridgeTransport()
    data class CloudRelay(val relayId: String, val accountId: String?, val negotiatedPort: Int) : BridgeTransport()
    data class Peripheral(
        val medium: BridgeTransportHint,
        val identifier: String,
        val channel: Int,
        val throughputHintMbps: Float,
        val latencyHintMs: Int
    ) : BridgeTransport()
}

data class BridgeLinkQuality(
    val hint: BridgeTransportHint,
    val latencyMs: Int,
    val throughputMbps: Float,
    val isDirect: Boolean,
    val supportsLossless: Boolean,
    val measuredAt: Long = System.currentTimeMillis()
)

class BridgeConnectionCoordinator(context: Context) {

    private val appContext = context.applicationContext
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    private val compatibilityManager = CrossPlatformCompatibilityManager()

    private val wifiP2pManager = appContext.getSystemService(Context.WIFI_P2P_SERVICE) as? WifiP2pManager
    private val wifiChannel = wifiP2pManager?.initialize(appContext, Looper.getMainLooper(), null)
    private val wifiManager = appContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
    private val connectivityManager = appContext.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    private val bluetoothAdapter = BluetoothAdapter.getDefaultAdapter()
    private val packageManager = appContext.packageManager
    private val nfcAdapter = NfcAdapter.getDefaultAdapter(appContext)
    private val uwbAvailable = packageManager.hasSystemFeature(PackageManager.FEATURE_UWB)

    private val _nearbyDevices = MutableStateFlow<List<BridgeDevice>>(emptyList())
    val nearbyDevices: StateFlow<List<BridgeDevice>> = _nearbyDevices.asStateFlow()

    val compatibilityProfiles: StateFlow<Map<BridgeDevicePlatform, BridgeCompatibilityProfile>> =
        compatibilityManager.profiles

    private val _remoteAccounts = MutableStateFlow<List<BridgeAccountEndpoint>>(loadRemoteAccountsFromCache())
    val remoteAccounts: StateFlow<List<BridgeAccountEndpoint>> = _remoteAccounts.asStateFlow()

    private val _activeTransport = MutableStateFlow<BridgeTransport>(
        BridgeTransport.CloudRelay(relayId = "", accountId = null, negotiatedPort = DEFAULT_RELAY_PORT)
    )
    val activeTransport: StateFlow<BridgeTransport> = _activeTransport.asStateFlow()

    private val _isInProximity = MutableStateFlow(false)
    val isInProximity: StateFlow<Boolean> = _isInProximity.asStateFlow()

    private val _linkQuality = MutableStateFlow(
        BridgeLinkQuality(
            hint = BridgeTransportHint.Cloud,
            latencyMs = DEFAULT_CLOUD_LATENCY,
            throughputMbps = DEFAULT_CLOUD_THROUGHPUT,
            isDirect = false,
            supportsLossless = false
        )
    )
    val linkQuality: StateFlow<BridgeLinkQuality> = _linkQuality.asStateFlow()

    private val networkCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            updateProximityState()
        }

        override fun onLost(network: Network) {
            updateProximityState()
        }
    }

    init {
        registerNetworkCallback()
        updateProximityState()
        scope.launch { maintainWifiDirectDiscovery() }
        scope.launch { refreshRemoteAccountDirectory() }
    }

    suspend fun negotiateTransport(targetDeviceId: String?, fallbackAccount: String?): BridgeTransport {
        val device = targetDeviceId?.let { id ->
            nearbyDevices.value.firstOrNull { it.deviceId == id }
        }

        device?.let { candidate ->
            connectWifiDirect(candidate)?.let { info ->
                val quality = estimateWifiDirectQuality(info, candidate)
                publishLinkQuality(quality)
                info.groupOwnerAddress?.let { owner ->
                    val transport = BridgeTransport.DirectHotspot(
                        groupOwnerAddress = owner,
                        port = DIRECT_STREAM_PORT,
                        medium = quality.hint,
                        throughputHintMbps = quality.throughputMbps,
                        latencyHintMs = quality.latencyMs
                    )
                    _activeTransport.value = transport
                    return transport
                }
            }

            if (BridgeTransportHint.Bluetooth in candidate.capabilities) {
                val quality = estimateBluetoothQuality(candidate)
                publishLinkQuality(quality)
                val transport = BridgeTransport.Peripheral(
                    medium = BridgeTransportHint.Bluetooth,
                    identifier = candidate.deviceAddress,
                    channel = BLUETOOTH_FILE_CHANNEL,
                    throughputHintMbps = quality.throughputMbps,
                    latencyHintMs = quality.latencyMs
                )
                _activeTransport.value = transport
                return transport
            }

            if (BridgeTransportHint.Nfc in candidate.capabilities) {
                val quality = estimateNfcQuality(candidate)
                publishLinkQuality(quality)
                val transport = BridgeTransport.Peripheral(
                    medium = BridgeTransportHint.Nfc,
                    identifier = candidate.deviceAddress,
                    channel = NFC_HANDOFF_CHANNEL,
                    throughputHintMbps = quality.throughputMbps,
                    latencyHintMs = quality.latencyMs
                )
                _activeTransport.value = transport
                return transport
            }

            if (BridgeTransportHint.AirPlay in candidate.capabilities) {
                val quality = estimateAirPlayQuality(candidate.displayName)
                publishLinkQuality(quality)
                val transport = BridgeTransport.Peripheral(
                    medium = BridgeTransportHint.AirPlay,
                    identifier = candidate.displayName,
                    channel = AIRPLAY_STREAM_PORT,
                    throughputHintMbps = quality.throughputMbps,
                    latencyHintMs = quality.latencyMs
                )
                _activeTransport.value = transport
                return transport
            }

            if (BridgeTransportHint.UniversalBridge in candidate.capabilities) {
                val quality = estimateUniversalBridgeQuality(candidate)
                publishLinkQuality(quality)
                val transport = BridgeTransport.Peripheral(
                    medium = BridgeTransportHint.UniversalBridge,
                    identifier = candidate.deviceId,
                    channel = UNIVERSAL_BRIDGE_CHANNEL,
                    throughputHintMbps = quality.throughputMbps,
                    latencyHintMs = quality.latencyMs
                )
                _activeTransport.value = transport
                return transport
            }
        }

        val lanAddress = locateLanAddress(device)
        if (lanAddress != null) {
            val lanQuality = measureLanQuality(lanAddress)
            publishLinkQuality(lanQuality)
            val lanTransport = BridgeTransport.LocalLan(lanAddress, LOCAL_FALLBACK_PORT)
            _activeTransport.value = lanTransport
            return lanTransport
        }

        val accountId = fallbackAccount ?: remoteAccounts.value.firstOrNull()?.accountId ?: DEFAULT_ACCOUNT_ID
        if (accountSupportsAirPlay(accountId)) {
            val airQuality = estimateAirPlayQuality(accountId)
            publishLinkQuality(airQuality)
            val transport = BridgeTransport.Peripheral(
                medium = BridgeTransportHint.AirPlay,
                identifier = accountId,
                channel = AIRPLAY_STREAM_PORT,
                throughputHintMbps = airQuality.throughputMbps,
                latencyHintMs = airQuality.latencyMs
            )
            _activeTransport.value = transport
            return transport
        }

        val endpoint = ensureAccountEndpoint(accountId)
        publishLinkQuality(
            BridgeLinkQuality(
                hint = BridgeTransportHint.Cloud,
                latencyMs = DEFAULT_CLOUD_LATENCY,
                throughputMbps = DEFAULT_CLOUD_THROUGHPUT,
                isDirect = false,
                supportsLossless = false
            )
        )
        val relayTransport = BridgeTransport.CloudRelay(endpoint.relayId, endpoint.accountId, DEFAULT_RELAY_PORT)
        _activeTransport.value = relayTransport
        return relayTransport
    }

    suspend fun forceAccountBridge(accountId: String): BridgeAccountEndpoint {
        val normalized = accountId.ifBlank { DEFAULT_ACCOUNT_ID }
        val endpoint = BridgeAccountEndpoint(
            accountId = normalized,
            relayId = "relay-${UUID.randomUUID()}",
            throughputMbps = DEFAULT_CLOUD_THROUGHPUT,
            latencyMs = DEFAULT_CLOUD_LATENCY
        )
        _remoteAccounts.update { accounts ->
            listOf(endpoint) + accounts.filterNot { it.accountId == normalized }
        }
        cacheRemoteAccounts(_remoteAccounts.value)
        _activeTransport.value = BridgeTransport.CloudRelay(endpoint.relayId, endpoint.accountId, DEFAULT_RELAY_PORT)
        publishLinkQuality(
            BridgeLinkQuality(
                hint = BridgeTransportHint.Cloud,
                latencyMs = DEFAULT_CLOUD_LATENCY,
                throughputMbps = DEFAULT_CLOUD_THROUGHPUT,
                isDirect = false,
                supportsLossless = false
            )
        )
        return endpoint
    }

    fun release() {
        try {
            connectivityManager.unregisterNetworkCallback(networkCallback)
        } catch (_: Exception) {
        }
        scope.cancel()
    }

    private suspend fun ensureAccountEndpoint(accountId: String): BridgeAccountEndpoint {
        val normalized = accountId.ifBlank { DEFAULT_ACCOUNT_ID }
        val existing = remoteAccounts.value.firstOrNull { it.accountId == normalized }
        return existing ?: forceAccountBridge(normalized)
    }

    @SuppressLint("MissingPermission")
    private suspend fun maintainWifiDirectDiscovery() {
        val manager = wifiP2pManager ?: return
        val channel = wifiChannel ?: return
        while (scope.isActive) {
            try {
                discoverWifiPeers(manager, channel)
            } catch (_: Exception) {
            }
            delay(WIFI_DISCOVERY_INTERVAL_MS)
        }
    }

    @SuppressLint("MissingPermission")
    private suspend fun discoverWifiPeers(manager: WifiP2pManager, channel: WifiP2pManager.Channel) {
        withContext(Dispatchers.Main) {
            suspendCancellableCoroutine { continuation ->
                manager.discoverPeers(channel, object : WifiP2pManager.ActionListener {
                    override fun onSuccess() {
                        continuation.resume(Unit)
                    }

                    override fun onFailure(reason: Int) {
                        continuation.resumeWithException(IllegalStateException("discoverPeers failure: $reason"))
                    }
                })
            }
        }

        val peers = requestPeers(manager, channel)
        val now = System.currentTimeMillis()
        val signal = wifiManager?.connectionInfo?.rssi ?: DEFAULT_RSSI
        val level = WifiManager.calculateSignalLevel(signal, 5)
        val devices = peers.deviceList.mapNotNull { device ->
            if (compatibilityManager.shouldExclude(device.deviceName, device.deviceAddress)) {
                return@mapNotNull null
            }
            val platform = compatibilityManager.resolvePlatform(device.deviceName, device.deviceAddress)
            val capabilities = mutableSetOf(BridgeTransportHint.WifiDirect, BridgeTransportHint.Lan)
            val normalizedAddress = device.deviceAddress.replace(":", "").lowercase(Locale.ROOT)
            val hasBondedBluetooth = bluetoothAdapter?.bondedDevices?.any { bt ->
                bt.address.replace(":", "").lowercase(Locale.ROOT) == normalizedAddress
            } == true
            if (hasBondedBluetooth) {
                capabilities += BridgeTransportHint.Bluetooth
            }
            if (nfcAdapter?.isEnabled == true) {
                capabilities += BridgeTransportHint.Nfc
            }
            val linkSpeed = wifiManager?.connectionInfo?.linkSpeed ?: 0
            if (isLosslessCandidate(signalLevel = level, linkSpeed = linkSpeed)) {
                capabilities += BridgeTransportHint.UltraWideband
            }
            if (isAirPlayDevice(device.deviceName)) {
                capabilities += BridgeTransportHint.AirPlay
            }
            val platformTransports = compatibilityManager.transportsFor(platform)
            if (platformTransports.isEmpty()) {
                capabilities += BridgeTransportHint.UniversalBridge
            } else {
                capabilities += platformTransports
            }

            BridgeDevice(
                deviceId = device.deviceAddress,
                displayName = device.deviceName ?: device.deviceAddress,
                deviceAddress = device.deviceAddress,
                ipAddress = device.deviceAddress.takeIf { it.contains(':').not() },
                signalLevel = level,
                lastSeen = now,
                capabilities = capabilities,
                platform = platform,
                compatibilityRemark = compatibilityManager.remarkFor(platform)
            )
        }
        _nearbyDevices.value = devices
        updateProximityState()
    }

    @SuppressLint("MissingPermission")
    private suspend fun connectWifiDirect(device: BridgeDevice): WifiP2pInfo? {
        val manager = wifiP2pManager ?: return null
        val channel = wifiChannel ?: return null

        val config = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            WifiP2pConfig.Builder()
                .setDeviceAddress(device.deviceAddress)
                .enablePersistentMode(false)
                .setGroupOperatingBand(WifiP2pConfig.GROUP_OWNER_BAND_AUTO)
                .build()
        } else {
            @Suppress("DEPRECATION")
            WifiP2pConfig().apply {
                deviceAddress = device.deviceAddress
                wps = WpsInfo().apply { setup = WpsInfo.PBC }
                groupOwnerIntent = GROUP_OWNER_INTENT_HIGH
            }
        }

        withContext(Dispatchers.Main) {
            suspendCancellableCoroutine<Unit> { continuation ->
                manager.connect(channel, config, object : WifiP2pManager.ActionListener {
                    override fun onSuccess() {
                        continuation.resume(Unit)
                    }

                    override fun onFailure(reason: Int) {
                        continuation.resumeWithException(IllegalStateException("connect failure: $reason"))
                    }
                })
            }
        }

        return withContext(Dispatchers.Main) {
            suspendCancellableCoroutine { continuation ->
                manager.requestConnectionInfo(channel) { info ->
                    continuation.resume(info)
                }
            }
        }
    }

    private suspend fun requestPeers(manager: WifiP2pManager, channel: WifiP2pManager.Channel): WifiP2pDeviceList {
        return withContext(Dispatchers.Main) {
            suspendCancellableCoroutine { continuation ->
                manager.requestPeers(channel) { peers ->
                    continuation.resume(peers)
                }
            }
        }
    }

    private suspend fun locateLanAddress(device: BridgeDevice?): String? {
        val candidates = buildLanCandidates(device)
        if (candidates.isEmpty()) return null
        return withContext(Dispatchers.IO) {
            for (candidate in candidates) {
                try {
                    Socket().use { socket ->
                        socket.connect(InetSocketAddress(candidate, LOCAL_FALLBACK_PORT), LAN_PROBE_TIMEOUT_MS)
                        return@withContext candidate
                    }
                } catch (_: SocketTimeoutException) {
                } catch (_: Exception) {
                }
            }
            null
        }
    }

    private fun buildLanCandidates(device: BridgeDevice?): List<String> {
        val results = mutableListOf<String>()
        device?.ipAddress?.let { results += it }
        val dhcp = wifiManager?.dhcpInfo
        if (dhcp != null) {
            val gateway = intToIp(dhcp.gateway)
            val prefix = gateway.substringBeforeLast('.', prefix = gateway)
            results += listOf("$prefix.1", "$prefix.100", "$prefix.101")
        }
        return results.distinct()
    }

    private fun intToIp(value: Int): String {
        return String.format(
            Locale.US,
            "%d.%d.%d.%d",
            value and 0xff,
            value shr 8 and 0xff,
            value shr 16 and 0xff,
            value shr 24 and 0xff
        )
    }

    private fun registerNetworkCallback() {
        val request = NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .build()
        try {
            connectivityManager.registerNetworkCallback(request, networkCallback)
        } catch (_: Exception) {
        }
    }

    private fun updateProximityState() {
        val devices = _nearbyDevices.value
        val hasNearbyWifi = devices.isNotEmpty()
        val hasLossless = devices.any { BridgeTransportHint.UltraWideband in it.capabilities }
        val hasPeripheral = devices.any {
            BridgeTransportHint.Bluetooth in it.capabilities || BridgeTransportHint.Nfc in it.capabilities
        }
        val hasAirPlay = devices.any { BridgeTransportHint.AirPlay in it.capabilities }
        val hasBondedBluetooth = bluetoothAdapter?.bondedDevices?.isNotEmpty() == true
        val activeNetwork = connectivityManager.activeNetwork
        val capabilities = connectivityManager.getNetworkCapabilities(activeNetwork)
        val sameLan = capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true && wifiManager?.connectionInfo?.bssid != null
        _isInProximity.value = hasNearbyWifi || hasLossless || hasPeripheral || hasBondedBluetooth || hasAirPlay || sameLan
    }

    private fun publishLinkQuality(quality: BridgeLinkQuality?) {
        quality?.let { _linkQuality.value = it }
    }

    private fun estimateWifiDirectQuality(info: WifiP2pInfo, device: BridgeDevice): BridgeLinkQuality {
        val linkSpeed = wifiManager?.connectionInfo?.linkSpeed?.toFloat()?.takeIf { it > 0f }
            ?: DEFAULT_WIFI_LINK_SPEED
        val latency = if (info.groupFormed) DIRECT_BASE_LATENCY else DEFAULT_DIRECT_LATENCY
        val supportsLossless = isLosslessCandidate(device.signalLevel, linkSpeed.toInt())
        val throughputFactor = if (supportsLossless) ULTRA_WIFI_THROUGHPUT_FACTOR else WIFI_THROUGHPUT_FACTOR
        val throughput = (linkSpeed * throughputFactor).coerceAtLeast(MIN_THROUGHPUT)
        val hint = if (supportsLossless) BridgeTransportHint.UltraWideband else BridgeTransportHint.WifiDirect
        return BridgeLinkQuality(
            hint = hint,
            latencyMs = latency,
            throughputMbps = throughput,
            isDirect = true,
            supportsLossless = supportsLossless
        )
    }

    private fun measureLanQuality(address: String): BridgeLinkQuality {
        val latency = try {
            val host = InetAddress.getByName(address)
            val start = SystemClock.elapsedRealtime()
            val reachable = host.isReachable(LAN_PROBE_TIMEOUT_MS)
            if (reachable) {
                (SystemClock.elapsedRealtime() - start).toInt().coerceAtLeast(MIN_LATENCY)
            } else {
                DEFAULT_LAN_LATENCY
            }
        } catch (_: Exception) {
            DEFAULT_LAN_LATENCY
        }
        val linkSpeed = wifiManager?.connectionInfo?.linkSpeed?.toFloat()?.takeIf { it > 0f }
            ?: DEFAULT_WIFI_LINK_SPEED
        val throughput = (linkSpeed * LAN_THROUGHPUT_FACTOR).coerceAtLeast(MIN_THROUGHPUT)
        val supportsLossless = linkSpeed >= LOSSLESS_LINK_SPEED_MIN
        return BridgeLinkQuality(
            hint = BridgeTransportHint.Lan,
            latencyMs = latency,
            throughputMbps = throughput,
            isDirect = false,
            supportsLossless = supportsLossless
        )
    }

    private fun estimateBluetoothQuality(device: BridgeDevice): BridgeLinkQuality {
        val signalFactor = (device.signalLevel + 1).coerceIn(1, 5)
        val throughput = (DEFAULT_BLUETOOTH_THROUGHPUT * signalFactor).coerceAtLeast(MIN_BLUETOOTH_THROUGHPUT)
        val latency = (DEFAULT_BLUETOOTH_LATENCY - signalFactor * 2).coerceAtLeast(MIN_LATENCY)
        return BridgeLinkQuality(
            hint = BridgeTransportHint.Bluetooth,
            latencyMs = latency,
            throughputMbps = throughput,
            isDirect = true,
            supportsLossless = false
        )
    }

    private fun estimateNfcQuality(device: BridgeDevice): BridgeLinkQuality {
        val throughput = DEFAULT_NFC_THROUGHPUT
        val latency = (DEFAULT_NFC_LATENCY - device.signalLevel).coerceAtLeast(MIN_LATENCY)
        return BridgeLinkQuality(
            hint = BridgeTransportHint.Nfc,
            latencyMs = latency,
            throughputMbps = throughput,
            isDirect = true,
            supportsLossless = false
        )
    }

    private fun estimateAirPlayQuality(identifier: String?): BridgeLinkQuality {
        val throughput = DEFAULT_AIRPLAY_THROUGHPUT
        val latency = DEFAULT_AIRPLAY_LATENCY
        return BridgeLinkQuality(
            hint = BridgeTransportHint.AirPlay,
            latencyMs = latency,
            throughputMbps = throughput,
            isDirect = true,
            supportsLossless = throughput >= LOSSLESS_LINK_SPEED_MIN
        )
    }

    private fun estimateUniversalBridgeQuality(device: BridgeDevice): BridgeLinkQuality {
        val hasUltraWideband = BridgeTransportHint.UltraWideband in device.capabilities
        val hasWifiDirect = BridgeTransportHint.WifiDirect in device.capabilities
        val hasLan = BridgeTransportHint.Lan in device.capabilities
        val throughput = when {
            hasUltraWideband -> 420f
            hasWifiDirect -> 280f
            hasLan -> 240f
            BridgeTransportHint.Bluetooth in device.capabilities -> 48f
            else -> 160f
        }
        val latency = when {
            hasUltraWideband -> 12
            hasWifiDirect -> 18
            hasLan -> 22
            BridgeTransportHint.Bluetooth in device.capabilities -> 38
            else -> 26
        }
        return BridgeLinkQuality(
            hint = BridgeTransportHint.UniversalBridge,
            latencyMs = latency,
            throughputMbps = throughput,
            isDirect = true,
            supportsLossless = throughput >= 240f
        )
    }

    private fun isLosslessCandidate(signalLevel: Int, linkSpeed: Int): Boolean {
        val strongSignal = signalLevel >= LOSSLESS_SIGNAL_THRESHOLD
        val fastLink = linkSpeed >= LOSSLESS_LINK_SPEED_MIN
        return (strongSignal && fastLink) || uwbAvailable
    }

    private fun isAirPlayDevice(name: String?): Boolean {
        if (name.isNullOrBlank()) return false
        return AIRPLAY_KEYWORDS.any { keyword -> name.contains(keyword, ignoreCase = true) }
    }

    private fun accountSupportsAirPlay(accountId: String): Boolean {
        return AIRPLAY_KEYWORDS.any { keyword -> accountId.contains(keyword, ignoreCase = true) }
    }

    private suspend fun refreshRemoteAccountDirectory() {
        while (scope.isActive) {
            val cached = loadRemoteAccountsFromCache()
            if (cached.isNotEmpty()) {
                _remoteAccounts.value = cached
            }
            delay(REMOTE_DIRECTORY_REFRESH_MS)
        }
    }

    private fun loadRemoteAccountsFromCache(): List<BridgeAccountEndpoint> {
        val preferences = appContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val encoded = preferences.getString(KEY_REMOTE_ACCOUNTS, null) ?: return defaultRemoteAccounts()
        return encoded.split(';')
            .mapNotNull { entry ->
                if (entry.isBlank()) return@mapNotNull null
                val parts = entry.split(',')
                if (parts.size < 4) return@mapNotNull null
                val accountId = parts[0]
                val relayId = parts[1]
                val throughput = parts[2].toFloatOrNull() ?: DEFAULT_CLOUD_THROUGHPUT
                val latency = parts[3].toIntOrNull() ?: DEFAULT_CLOUD_LATENCY
                BridgeAccountEndpoint(
                    accountId = accountId,
                    relayId = relayId,
                    throughputMbps = throughput,
                    latencyMs = latency
                )
            }
    }

    private fun cacheRemoteAccounts(accounts: List<BridgeAccountEndpoint>) {
        val preferences = appContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val encoded = accounts.joinToString(separator = ";") { endpoint ->
            listOf(endpoint.accountId, endpoint.relayId, endpoint.throughputMbps, endpoint.latencyMs)
                .joinToString(separator = ",")
        }
        preferences.edit().putString(KEY_REMOTE_ACCOUNTS, encoded).apply()
    }

    private fun defaultRemoteAccounts(): List<BridgeAccountEndpoint> {
        return listOf(
            BridgeAccountEndpoint(
                accountId = DEFAULT_ACCOUNT_ID,
                relayId = "relay-${DEFAULT_ACCOUNT_ID}",
                throughputMbps = DEFAULT_CLOUD_THROUGHPUT,
                latencyMs = DEFAULT_CLOUD_LATENCY
            )
        )
    }

    companion object {
        private const val WIFI_DISCOVERY_INTERVAL_MS = 15_000L
        private const val REMOTE_DIRECTORY_REFRESH_MS = 60_000L
        private const val LAN_PROBE_TIMEOUT_MS = 250
        private const val DEFAULT_RSSI = -55
        private const val GROUP_OWNER_INTENT_HIGH = 15
        private const val DIRECT_STREAM_PORT = 28_970
        private const val LOCAL_FALLBACK_PORT = 28_971
        private const val DEFAULT_RELAY_PORT = 28_972
        private const val DEFAULT_CLOUD_THROUGHPUT = 160f
        private const val DEFAULT_CLOUD_LATENCY = 55
        private const val DEFAULT_ACCOUNT_ID = "skybridge_cloud"
        private const val PREFS_NAME = "bridge_connection_coordinator"
        private const val KEY_REMOTE_ACCOUNTS = "remote_accounts"
        private const val DEFAULT_WIFI_LINK_SPEED = 240f
        private const val WIFI_THROUGHPUT_FACTOR = 0.85f
        private const val ULTRA_WIFI_THROUGHPUT_FACTOR = 1.12f
        private const val LAN_THROUGHPUT_FACTOR = 0.65f
        private const val MIN_THROUGHPUT = 32f
        private const val DIRECT_BASE_LATENCY = 22
        private const val DEFAULT_DIRECT_LATENCY = 36
        private const val DEFAULT_LAN_LATENCY = 48
        private const val MIN_LATENCY = 4
        private const val LOSSLESS_SIGNAL_THRESHOLD = 4
        private const val LOSSLESS_LINK_SPEED_MIN = 600
        private const val DEFAULT_BLUETOOTH_THROUGHPUT = 18f
        private const val MIN_BLUETOOTH_THROUGHPUT = 6f
        private const val DEFAULT_BLUETOOTH_LATENCY = 45
        private const val DEFAULT_NFC_THROUGHPUT = 2.2f
        private const val DEFAULT_NFC_LATENCY = 28
          private const val DEFAULT_AIRPLAY_THROUGHPUT = 340f
          private const val DEFAULT_AIRPLAY_LATENCY = 18
          private const val BLUETOOTH_FILE_CHANNEL = 19
          private const val NFC_HANDOFF_CHANNEL = 6
          private const val AIRPLAY_STREAM_PORT = 70_001
          private const val UNIVERSAL_BRIDGE_CHANNEL = 4_097
          private val AIRPLAY_KEYWORDS = listOf("airplay", "apple", "mac", "iphone", "ipad")
      }
  }
