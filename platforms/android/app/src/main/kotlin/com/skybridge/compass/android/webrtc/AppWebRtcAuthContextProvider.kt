package com.skybridge.compass.android.webrtc

import com.skybridge.compass.auth.AuthSessionSnapshot
import com.skybridge.compass.auth.SupabaseJwtClaims
import com.skybridge.compass.core.webrtc.SignalServerClient
import kotlinx.serialization.json.Json

class AppWebRtcAuthContextProvider(
    private val sessionSnapshotProvider: () -> AuthSessionSnapshot?,
    private val json: Json = Json { ignoreUnknownKeys = true; explicitNulls = false },
    private val clockMs: () -> Long = System::currentTimeMillis
) {
    fun current(): SignalServerClient.UserAuthContext? {
        val snapshot = sessionSnapshotProvider() ?: return null
        if (snapshot.expiresAtEpochMs <= clockMs() + AUTH_EXPIRY_SKEW_MS) return null
        val accessToken = snapshot.accessToken.trim().takeIf { it.isNotEmpty() } ?: return null
        val tenantId = SupabaseJwtClaims.tenantIdentifierOrNull(json, accessToken)
            ?: return null
        return SignalServerClient.UserAuthContext(
            bearerToken = accessToken,
            tenantId = tenantId
        )
    }

    private companion object {
        private const val AUTH_EXPIRY_SKEW_MS = 30_000L
    }

}
