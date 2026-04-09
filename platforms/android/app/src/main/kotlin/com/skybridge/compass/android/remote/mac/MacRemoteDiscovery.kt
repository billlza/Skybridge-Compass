package com.skybridge.compass.android.remote.mac

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow

/**
 * Discover SkyBridge Compass Pro remote control servers:
 * - Bonjour service: _skybridge-remote._tcp
 * - TCP port: 5901 (also available via resolved serviceInfo.port)
 */
class MacRemoteDiscovery(private val context: Context) {

    data class Service(
        val name: String,
        val host: String,
        val port: Int,
        val txt: Map<String, String>
    )

    private val nsdManager = context.getSystemService(Context.NSD_SERVICE) as NsdManager
    private val serviceType = "_skybridge-remote._tcp"

    fun discover(): Flow<List<Service>> = callbackFlow {
        val services = LinkedHashMap<String, Service>()
        var discoveryStarted = false

        val discoveryListener = object : NsdManager.DiscoveryListener {
            override fun onStartDiscoveryFailed(serviceType: String?, errorCode: Int) {}
            override fun onStopDiscoveryFailed(serviceType: String?, errorCode: Int) {}
            override fun onDiscoveryStarted(serviceType: String?) {}
            override fun onDiscoveryStopped(serviceType: String?) {}

            override fun onServiceFound(serviceInfo: NsdServiceInfo?) {
                val svc = serviceInfo ?: return
                val resolveListener = object : NsdManager.ResolveListener {
                    override fun onResolveFailed(serviceInfo: NsdServiceInfo?, errorCode: Int) {}
                    override fun onServiceResolved(serviceInfo: NsdServiceInfo?) {
                        val resolved = serviceInfo ?: return
                        val host = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                            resolved.hostAddresses.firstOrNull()?.hostAddress
                        } else {
                            @Suppress("DEPRECATION")
                            resolved.host?.hostAddress
                        } ?: return

                        val txt = resolved.attributes?.mapValues { (_, v) -> runCatching { String(v, Charsets.UTF_8) }.getOrDefault("") } ?: emptyMap()
                        val s = Service(
                            name = resolved.serviceName,
                            host = host,
                            port = resolved.port,
                            txt = txt
                        )
                        services["${resolved.serviceName}|${resolved.port}|$host"] = s
                        trySend(services.values.toList())
                    }
                }

                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                    @Suppress("DEPRECATION")
                    nsdManager.resolveService(svc, context.mainExecutor, resolveListener)
                } else {
                    @Suppress("DEPRECATION")
                    nsdManager.resolveService(svc, resolveListener)
                }
            }

            override fun onServiceLost(serviceInfo: NsdServiceInfo?) {
                val svc = serviceInfo ?: return
                services.entries.removeIf { it.value.name == svc.serviceName }
                trySend(services.values.toList())
            }
        }

        runCatching {
            nsdManager.discoverServices(serviceType, NsdManager.PROTOCOL_DNS_SD, discoveryListener)
            discoveryStarted = true
        }.onFailure {
            close(it)
            return@callbackFlow
        }

        awaitClose {
            if (!discoveryStarted) return@awaitClose
            runCatching { nsdManager.stopServiceDiscovery(discoveryListener) }
        }
    }
}

