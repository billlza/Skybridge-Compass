package com.skybridge.compass.core.webrtc

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class WebSocketSignalingClientTest {
    @Test
    fun bypassesProxyOnlyForLoopbackWebSocketUrls() {
        assertTrue(WebSocketSignalingClient.shouldBypassProxyForUrl("ws://127.0.0.1:18443/ws"))
        assertTrue(WebSocketSignalingClient.shouldBypassProxyForUrl("ws://localhost:18443/ws"))
        assertTrue(WebSocketSignalingClient.shouldBypassProxyForUrl("ws://[::1]:18443/ws"))
        assertTrue(WebSocketSignalingClient.shouldBypassProxyForUrl("ws://10.0.2.2:18443/ws"))

        assertFalse(WebSocketSignalingClient.shouldBypassProxyForUrl("wss://api.nebula-technologies.net/ws"))
        assertFalse(WebSocketSignalingClient.shouldBypassProxyForUrl("http://127.0.0.1:18443"))
        assertFalse(WebSocketSignalingClient.shouldBypassProxyForUrl("http://10.0.2.2:18443"))
    }

    @Test
    fun redactsCredentialBearingWebSocketUrlsForLogs() {
        val redactedUrl = WebSocketSignalingClient.redactedUrlString(
            "ws://10.0.2.2:18443/ws?st=secret-session-token&session=raw-session&token=raw-token&tenant=prod"
        )

        assertTrue(redactedUrl.contains("st=%3Credacted%3E"))
        assertTrue(redactedUrl.contains("session=%3Credacted%3E"))
        assertTrue(redactedUrl.contains("token=%3Credacted%3E"))
        assertTrue(redactedUrl.contains("tenant=prod"))
        assertFalse(redactedUrl.contains("secret-session-token"))
        assertFalse(redactedUrl.contains("raw-session"))
        assertFalse(redactedUrl.contains("raw-token"))
    }
}
