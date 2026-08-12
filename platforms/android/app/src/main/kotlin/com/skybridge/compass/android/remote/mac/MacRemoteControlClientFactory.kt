package com.skybridge.compass.android.remote.mac

import android.content.Context
import com.skybridge.compass.android.account.AccountBusinessIdentityProvider
import com.skybridge.compass.auth.AuthRepository
import com.skybridge.compass.core.p2p.LocalP2PIdentity
import dagger.hilt.android.qualifiers.ApplicationContext
import javax.inject.Inject

class MacRemoteControlClientFactory @Inject constructor(
    @ApplicationContext context: Context,
    authRepository: AuthRepository
) {
    private val appContext = context.applicationContext
    private val accountBusinessIdentityProvider =
        AccountBusinessIdentityProvider(authRepository::currentUserIdOrNull)

    fun create(): MacRemoteControlClient =
        MacRemoteControlClient(
            appContext = appContext,
            accountBusinessIdentityProvider = accountBusinessIdentityProvider
        )

    /**
     * Client for a PIB/SKR-authorized LAN route. It can only consume formal, read-only trust
     * material and therefore cannot fall back to legacy pins or mutate trust during the handshake.
     * The caller must retain an exact route lease for both the pre-dial and Finished commit gates.
     */
    internal fun createFormalLanAcceptance(
        routeAuthorizationLease: MacRemoteFormalRouteAuthorizationLease
    ): MacRemoteControlClient =
        createFormalLanAcceptanceClient(routeAuthorizationLease)

    private fun createFormalLanAcceptanceClient(
        routeAuthorizationLease: MacRemoteFormalRouteAuthorizationLease
    ): MacRemoteControlClient {
        val localIdentity = LocalP2PIdentity(appContext)
        return MacRemoteControlClient(
            appContext = appContext,
            accountBusinessIdentityProvider = accountBusinessIdentityProvider,
            localIdentityOverride = localIdentity,
            trustContextOverride = MacRemoteControlTrustContextFactory.persistentReadOnly(
                appContext = appContext,
                localIdentity = localIdentity
            ),
            formalRouteAuthorizationLease = routeAuthorizationLease
        )
    }
}
