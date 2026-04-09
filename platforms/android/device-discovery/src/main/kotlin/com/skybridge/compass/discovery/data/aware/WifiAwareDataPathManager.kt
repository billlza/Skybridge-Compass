package com.skybridge.compass.discovery.data.aware

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.aware.WifiAwareNetworkSpecifier
import android.os.Build
import kotlinx.coroutines.CompletableDeferred
import javax.inject.Inject
import javax.inject.Singleton

/**
 * 管理 Wi‑Fi Aware 数据通道建立，并将可用的 Network 存入注册表。
 */
@Singleton
class WifiAwareDataPathManager @Inject constructor(
    private val appContext: Context,
    private val peerRegistry: WifiAwarePeerRegistry
) {
    /**
     * 根据注册表中的 Peer/Session 发起数据通道，并在 Network 可用后写入注册表。
     */
    suspend fun initiateDataPath(deviceId: String): Boolean {
        val ref = peerRegistry.get(deviceId) ?: return false
        val networkSpecifier = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            WifiAwareNetworkSpecifier.Builder(ref.session, ref.peer)
                .build()
        } else {
            @Suppress("DEPRECATION")
            ref.session.createNetworkSpecifierOpen(ref.peer)
        }
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI_AWARE)
            .setNetworkSpecifier(networkSpecifier)
            .build()

        val cm = appContext.getSystemService(ConnectivityManager::class.java)
        val result = CompletableDeferred<Boolean>()

        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                // 保存可用的 Network，供后续 Socket/Channel 建链使用
                peerRegistry.putNetwork(deviceId, network)
                result.complete(true)
            }

            override fun onLost(network: Network) {
                // 网络丢失，清理注册表中的引用
                peerRegistry.removeNetwork(deviceId)
            }

            override fun onUnavailable() {
                result.complete(false)
            }
        }

        cm.requestNetwork(request, callback)
        return result.await()
    }
}