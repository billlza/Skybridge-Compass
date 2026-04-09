package com.skybridge.compass.discovery.data.aware

import android.net.Network
import android.net.wifi.aware.DiscoverySession
import android.net.wifi.aware.PeerHandle
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Wi‑Fi Aware 对等注册表：在发现阶段记录 deviceId 与 PeerHandle/DiscoverySession 的关联，并跟踪数据通道的 Network。
 */
@Singleton
class WifiAwarePeerRegistry @Inject constructor() {
    data class AwarePeerRef(val peer: PeerHandle, val session: DiscoverySession)

    private val peers: MutableMap<String, AwarePeerRef> = mutableMapOf()
    private val networks: MutableMap<String, Network> = mutableMapOf()

    fun put(deviceId: String, peerHandle: PeerHandle, session: DiscoverySession) {
        peers[deviceId] = AwarePeerRef(peerHandle, session)
    }

    fun get(deviceId: String): AwarePeerRef? = peers[deviceId]

    fun remove(deviceId: String) {
        peers.remove(deviceId)
        networks.remove(deviceId)
    }

    fun clear() {
        peers.clear()
        networks.clear()
    }

    fun putNetwork(deviceId: String, network: Network) {
        networks[deviceId] = network
    }

    fun getNetwork(deviceId: String): Network? = networks[deviceId]

    fun removeNetwork(deviceId: String) {
        networks.remove(deviceId)
    }
}