package com.skybridge.compass.android.ui.screens.account

import com.skybridge.compass.shared.account.AccountStore
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class AccountCenterScreenTest {
    @Test
    fun profileCompletenessReturnsNullWhenNoProfileIsLoaded() {
        assertNull(accountProfileCompleteness(null))
    }

    @Test
    fun profileCompletenessReportsMissingAvatarAndNebulaIdSeparately() {
        assertEquals(
            AccountProfileCompleteness.MissingAvatarAndNebulaId,
            accountProfileCompleteness(profile(avatarUrl = null, nebulaId = null))
        )

        assertEquals(
            AccountProfileCompleteness.MissingAvatar,
            accountProfileCompleteness(profile(avatarUrl = null, nebulaId = "NEBULA-2026-ABCDEF123456"))
        )

        assertEquals(
            AccountProfileCompleteness.MissingNebulaId,
            accountProfileCompleteness(profile(avatarUrl = "https://example.com/avatar.png", nebulaId = null))
        )
    }

    @Test
    fun profileCompletenessReportsCompleteWhenAvatarAndNebulaIdArePresent() {
        assertEquals(
            AccountProfileCompleteness.Complete,
            accountProfileCompleteness(
                profile(
                    avatarUrl = "https://example.com/avatar.png",
                    nebulaId = "NEBULA-2026-ABCDEF123456"
                )
            )
        )
    }

    private fun profile(
        avatarUrl: String?,
        nebulaId: String?
    ): AccountStore.AccountProfile =
        AccountStore.AccountProfile(
            id = "auth-user",
            displayName = "Alice",
            email = "alice@example.com",
            avatarUrl = avatarUrl,
            nebulaId = nebulaId
        )
}
