package com.skybridge.compass.android.webrtc

import android.content.Context
import com.skybridge.compass.android.account.AccountBusinessIdentityProvider
import com.skybridge.compass.auth.AuthRepository
import com.skybridge.compass.core.webrtc.AndroidCrossNetworkWebRtcTransportAdapter
import com.skybridge.compass.core.webrtc.CrossNetworkWebRtcTransportAdapter
import com.skybridge.compass.core.webrtc.SkyBridgeWebRtcConnectionManager
import com.skybridge.compass.shared.productsession.ProductSessionAuthorityStore
import dagger.hilt.android.qualifiers.ApplicationContext
import javax.inject.Inject

class AppWebRtcTransportFactory @Inject constructor(
    @ApplicationContext context: Context,
    private val productSessionAuthorityStore: ProductSessionAuthorityStore,
    authRepository: AuthRepository
) {
    private val appContext = context.applicationContext
    private val accountBusinessIdentityProvider =
        AccountBusinessIdentityProvider(authRepository::currentUserIdOrNull)
    private val authContextProvider =
        AppWebRtcAuthContextProvider(
            sessionSnapshotProvider = { authRepository.currentSessionSnapshotOrNull() }
        )

    fun create(): CrossNetworkWebRtcTransportAdapter =
        AndroidCrossNetworkWebRtcTransportAdapter(
            SkyBridgeWebRtcConnectionManager(
                appContext,
                userAuthContextProvider = authContextProvider::current,
                localBusinessIdentityProvider = accountBusinessIdentityProvider::current,
                productSessionAuthorityStore = productSessionAuthorityStore
            )
        )
}
