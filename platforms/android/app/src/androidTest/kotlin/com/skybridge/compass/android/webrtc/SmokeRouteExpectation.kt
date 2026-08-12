package com.skybridge.compass.android.webrtc

import com.skybridge.compass.core.webrtc.SkyBridgeWebRtcConnectionManager
import com.skybridge.compass.core.webrtc.WebRtcSelectedRoute
import com.skybridge.compass.core.webrtc.WebRtcSecureOperationOwner
import java.util.Locale

internal data class SmokeRouteObservation(
    val route: WebRtcSelectedRoute,
    val admitted: Boolean
) {
    val wireName: String = route.name.lowercase(Locale.ROOT)
}

/** Optional direct-only acceptance gate; normal cross-network smoke keeps TURN semantics. */
internal class SmokeRouteExpectation(
    private val requireDirect: Boolean
) {
    fun observe(manager: SkyBridgeWebRtcConnectionManager): SmokeRouteObservation {
        val secureOwner = manager.currentSecureOperationOwner()
            ?: return SmokeRouteObservation(WebRtcSelectedRoute.UNKNOWN, admitted = false)
        return observe(manager, secureOwner)
    }

    fun observe(
        manager: SkyBridgeWebRtcConnectionManager,
        secureOwner: WebRtcSecureOperationOwner
    ): SmokeRouteObservation {
        val route = manager.selectedRoute(secureOwner) ?: WebRtcSelectedRoute.UNKNOWN
        if (requireDirect && route == WebRtcSelectedRoute.RELAY) {
            error("Direct route required but selected route=relay")
        }
        return SmokeRouteObservation(
            route = route,
            admitted = manager.isCurrentSecureOperationOwner(secureOwner) &&
                (!requireDirect || manager.hasDirectRoute(secureOwner))
        )
    }

    fun requireAdmittedAtCompletion(
        manager: SkyBridgeWebRtcConnectionManager
    ): SmokeRouteObservation {
        val observation = observe(manager)
        check(observation.admitted) {
            "Route acceptance changed before smoke completion: route=${observation.wireName}"
        }
        return observation
    }

    fun requireAdmittedAtCompletion(
        manager: SkyBridgeWebRtcConnectionManager,
        secureOwner: WebRtcSecureOperationOwner
    ): SmokeRouteObservation {
        val observation = observe(manager, secureOwner)
        check(observation.admitted) {
            "Route acceptance changed before smoke completion: route=${observation.wireName}"
        }
        return observation
    }
}
