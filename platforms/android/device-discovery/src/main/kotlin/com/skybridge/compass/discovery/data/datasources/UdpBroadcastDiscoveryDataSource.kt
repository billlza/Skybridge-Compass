package com.skybridge.compass.discovery.data.datasources

import android.content.Context
import com.skybridge.compass.core.utils.Constants
import com.skybridge.compass.discovery.data.network.MulticastLockManager
import com.skybridge.compass.discovery.data.telemetry.DiscoveryTelemetry
import com.skybridge.compass.discovery.domain.entities.PreferredConnect
import com.skybridge.compass.discovery.domain.entities.ConnectionInfo
import com.skybridge.compass.discovery.domain.entities.DeviceCapability
import com.skybridge.compass.discovery.domain.entities.DeviceType
import com.skybridge.compass.discovery.domain.entities.DiscoveredDevice
import com.skybridge.compass.discovery.domain.entities.DiscoveryProtocol
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import org.json.JSONObject
import java.net.DatagramPacket
import java.net.InetAddress
import java.net.MulticastSocket
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class UdpBroadcastDiscoveryDataSource @Inject constructor(
    @param:dagger.hilt.android.qualifiers.ApplicationContext private val context: Context,
    private val multicastLockManager: MulticastLockManager,
    private val telemetry: DiscoveryTelemetry
) {

    fun startDiscovery(): Flow<List<DiscoveredDevice>> = callbackFlow {
        val discovered = mutableMapOf<String, DiscoveredDevice>()
        val port = Constants.Network.DISCOVERY_PORT
        val groupAddr = InetAddress.getByName(Constants.Discovery.MULTICAST_ADDRESS)

        telemetry.recordDiscoveryStart(DiscoveryProtocol.UDP_BROADCAST)
        multicastLockManager.acquire()
        telemetry.recordMulticastLockAcquired()
        val socket = MulticastSocket(port)
        try {
            socket.joinGroup(groupAddr)
        } catch (e: Exception) {
        }

        val buffer = ByteArray(2048)
        val packet = DatagramPacket(buffer, buffer.size)

        val receiver = Thread {
            try {
                while (!Thread.currentThread().isInterrupted) {
                    socket.receive(packet)
                    val msg = String(packet.data, 0, packet.length)
                    val addr = packet.address
                    val device = parseMessage(msg, addr, port)
                    if (device != null) {
                        discovered[device.id] = device.copy(lastSeen = System.currentTimeMillis())
                        trySend(discovered.values.toList())
                    }
                }
            } catch (e: Exception) {
            }
        }
        receiver.isDaemon = true
        receiver.start()

        awaitClose {
            val lockStart = System.currentTimeMillis() // duration measurement fallback
            try { receiver.interrupt() } catch (e: Exception) {}
            try { socket.leaveGroup(groupAddr) } catch (e: Exception) {}
            try { socket.close() } catch (e: Exception) {}
            multicastLockManager.release()
            telemetry.recordMulticastLockReleased()
            val held = System.currentTimeMillis() - lockStart
            telemetry.recordMulticastLockHeld(held)
        }
    }

    private fun parseMessage(message: String, address: InetAddress, port: Int): DiscoveredDevice? {
        if (message.trim().startsWith("{")) {
            return parseJsonAnnounce(message, address, port)
        }
        if (message.startsWith(Constants.Discovery.RESPONSE_MESSAGE)) {
            return parseLegacyResponse(message, address)
        }
        return null
    }

    private fun parseJsonAnnounce(json: String, address: InetAddress, port: Int): DiscoveredDevice? {
        return try {
            val obj = JSONObject(json)
            if (obj.optString("op") != "announce") return null

            val id: String = obj.optString("id", "udp-${address.hostAddress}-$port")
            val name: String = obj.optString("name", "SkyBridge Device")
            val type = when (obj.optString("type").lowercase()) {
                "ios" -> DeviceType.IOS
                "macos" -> DeviceType.MACOS
                "android" -> DeviceType.ANDROID
                "windows" -> DeviceType.WINDOWS
                "linux" -> DeviceType.LINUX
                else -> DeviceType.UNKNOWN
            }
            val caps = parseCapsArray(obj)
            val endpoint = obj.optJSONObject("endpoint")
            val endpointIp: String? = endpoint?.optString("ip")
            val addressStr: String = endpointIp?.takeIf { it.isNotBlank() } ?: address.hostAddress
            val portVal: Int = if (endpoint != null) {
                endpoint.optInt("port", port)
            } else {
                port
            }

            // 元数据统一：解析 proto / ver / extra
            val protoStr = obj.optString("proto", "")
            val preferred = when (protoStr.lowercase()) {
                "webrtc" -> PreferredConnect.WEBRTC
                "tcp" -> PreferredConnect.TCP
                "ble" -> PreferredConnect.BLE
                "nan" -> PreferredConnect.NAN
                else -> null
            }
            val verRaw = obj.optInt("ver", -1)
            val version = if (verRaw >= 0) verRaw else null
            val extraObj = obj.optJSONObject("extra")
            val extraMap = if (extraObj != null) {
                val keys = extraObj.keys()
                val map = mutableMapOf<String, String>()
                while (keys.hasNext()) {
                    val k = keys.next()
                    map[k] = extraObj.optString(k)
                }
                map.toMap()
            } else emptyMap()

            val device = DiscoveredDevice(
                id = id,
                name = name,
                type = type,
                capabilities = caps,
                connectionInfo = ConnectionInfo(
                    protocol = DiscoveryProtocol.UDP_BROADCAST,
                    address = addressStr,
                    port = portVal,
                    serviceType = null,
                    txtRecords = emptyMap(),
                    preferredConnect = preferred,
                    version = version,
                    extra = extraMap
                ),
                signalStrength = 60,
                lastSeen = System.currentTimeMillis()
            )
            telemetry.recordDeviceDiscovered(DiscoveryProtocol.UDP_BROADCAST, id)
            device
        } catch (e: Exception) {
            telemetry.recordError(DiscoveryProtocol.UDP_BROADCAST, "UDP_JSON_PARSE_ERROR", e.message)
            null
        }
    }

    private fun parseLegacyResponse(message: String, address: InetAddress): DiscoveredDevice? {
        return try {
            val parts = message.split("|")
            val name: String = parts.find { it.startsWith("DEVICE_NAME=") }?.substringAfter("=") ?: "SkyBridge Device"
            val port = parts.find { it.startsWith("PORT=") }?.substringAfter("=")?.toIntOrNull() ?: Constants.Network.DISCOVERY_PORT

            val device = DiscoveredDevice(
                id = "udp-${address.hostAddress}-$port",
                name = name,
                type = DeviceType.UNKNOWN,
                capabilities = setOf(DeviceCapability.FILE_TRANSFER, DeviceCapability.REMOTE_CONTROL),
                connectionInfo = ConnectionInfo(
                    protocol = DiscoveryProtocol.UDP_BROADCAST,
                    address = address.hostAddress.orEmpty(),
                    port = port,
                    preferredConnect = PreferredConnect.TCP
                ),
                signalStrength = 50,
                lastSeen = System.currentTimeMillis()
            )
            telemetry.recordDeviceDiscovered(DiscoveryProtocol.UDP_BROADCAST, "udp-${address.hostAddress}-$port")
            device
        } catch (e: Exception) {
            telemetry.recordError(DiscoveryProtocol.UDP_BROADCAST, "UDP_LEGACY_PARSE_ERROR", e.message)
            null
        }
    }

    private fun parseCapsArray(obj: JSONObject): Set<DeviceCapability> {
        val arr = obj.optJSONArray("cap") ?: return setOf(DeviceCapability.SCREEN_SHARING, DeviceCapability.FILE_TRANSFER)
        val caps = mutableSetOf<DeviceCapability>()
        for (i in 0 until arr.length()) {
            when (arr.optString(i).lowercase()) {
                "screen_sharing" -> caps.add(DeviceCapability.SCREEN_SHARING)
                "file_transfer" -> caps.add(DeviceCapability.FILE_TRANSFER)
                "remote_control" -> caps.add(DeviceCapability.REMOTE_CONTROL)
                "audio_streaming" -> caps.add(DeviceCapability.AUDIO_STREAMING)
                "video_streaming" -> caps.add(DeviceCapability.VIDEO_STREAMING)
                "clipboard_sync" -> caps.add(DeviceCapability.CLIPBOARD_SYNC)
                "notification_sync" -> caps.add(DeviceCapability.NOTIFICATION_SYNC)
                "camera_access" -> caps.add(DeviceCapability.CAMERA_ACCESS)
                "microphone_access" -> caps.add(DeviceCapability.MICROPHONE_ACCESS)
            }
        }
        return caps
    }
}