package com.skybridge.compass.android.account

import com.skybridge.compass.core.webrtc.LocalPeerBusinessIdentity
import com.skybridge.compass.shared.account.AccountStore
import com.skybridge.compass.shared.account.NebulaId

class AccountBusinessIdentityProvider(
    private val sessionSubjectProvider: () -> String?
) {
    fun current(): LocalPeerBusinessIdentity? {
        val profile = AccountStore.primaryAccount.value ?: return null
        if (profile.id == "guest") return null
        val authenticatedSubject = sessionSubjectProvider()?.trim()?.takeIf { it.isNotEmpty() } ?: return null
        if (profile.id != authenticatedSubject) return null
        val nebulaId = NebulaId.parseOrNull(profile.nebulaId)?.value ?: return null
        val displayName = profile.displayName.trim().takeIf { it.isNotEmpty() }
        return LocalPeerBusinessIdentity(
            accountDisplayName = displayName,
            nebulaId = nebulaId
        ).normalizedOrNull()
    }

}
