package com.skybridge.compass.android.remote.mac

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.util.Log
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow

/**
 * Discover SkyBridge Compass Pro remote control servers:
 * - Bonjour service: _skybridge-rd._tcp
 * - TCP port: 5901 (also available via resolved serviceInfo.port)
 */
class MacRemoteDiscovery(private val context: Context) {
    class DiscoveryException(message: String) : IllegalStateException(message)

    data class Service(
        val name: String,
        val host: String,
        val port: Int,
        val txt: Map<String, String>
    )

    private val nsdManager = context.getSystemService(Context.NSD_SERVICE) as NsdManager
    private val serviceType = "_skybridge-rd._tcp"

    fun discover(): Flow<List<Service>> = callbackFlow {
        val services = LinkedHashMap<String, Service>()
        var discoveryStarted = false

        val discoveryListener = object : NsdManager.DiscoveryListener {
            override fun onStartDiscoveryFailed(serviceType: String?, errorCode: Int) {
                close(DiscoveryException("NSD discovery start failed type=${serviceType.orEmpty()} code=$errorCode"))
            }

            override fun onStopDiscoveryFailed(serviceType: String?, errorCode: Int) {
                close(DiscoveryException("NSD discovery stop failed type=${serviceType.orEmpty()} code=$errorCode"))
            }

            override fun onDiscoveryStarted(serviceType: String?) {}
            override fun onDiscoveryStopped(serviceType: String?) {}

            override fun onServiceFound(serviceInfo: NsdServiceInfo?) {
                val svc = serviceInfo ?: return
                val resolveListener = object : NsdManager.ResolveListener {
                    override fun onResolveFailed(serviceInfo: NsdServiceInfo?, errorCode: Int) {
                        close(
                            DiscoveryException(
                                "NSD service resolve failed name=${serviceInfo?.serviceName.orEmpty()} code=$errorCode"
                            )
                        )
                    }

                    override fun onServiceResolved(serviceInfo: NsdServiceInfo?) {
                        val resolved = serviceInfo ?: return
                        val host = resolved.hostAddresses.firstOrNull()?.hostAddress ?: return

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

                @Suppress("DEPRECATION")
                nsdManager.resolveService(svc, context.mainExecutor, resolveListener)
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
                .onFailure { err ->
                    Log.w(TAG, "NSD discovery cleanup failed: ${err.message ?: err.javaClass.simpleName}")
                }
        }
    }

    private companion object {
        private const val TAG = "MacRemoteDiscovery"
    }
}
