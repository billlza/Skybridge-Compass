package com.skybridge.compass.android.account

import com.skybridge.compass.shared.account.AccountStore
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test

class AccountBusinessIdentityProviderTest {
    private val provider = AccountBusinessIdentityProvider { "user-1" }

    @Before
    fun setUp() {
        AccountStore.clearPrimaryAccount()
    }

    @After
    fun tearDown() {
        AccountStore.clearPrimaryAccount()
    }

    @Test
    fun currentReturnsSanitizedIdentityForValidNebulaProfile() {
        AccountStore.setPrimaryAccount(
            AccountStore.AccountProfile(
                id = "user-1",
                displayName = "  Bill  ",
                email = "bill@example.com",
                phone = "+15551234567",
                avatarUrl = "https://example.com/avatar.png",
                nebulaId = "  NEBULA-2026-ABCDEF123456  "
            )
        )

        val identity = provider.current()

        assertEquals("Bill", identity?.accountDisplayName)
        assertEquals("NEBULA-2026-ABCDEF123456", identity?.nebulaId)
    }

    @Test
    fun currentReturnsNullForGuestProfile() {
        AccountStore.setPrimaryAccount(
            AccountStore.AccountProfile(
                id = "guest",
                displayName = "Guest",
                nebulaId = "NEBULA-2026-ABCDEF123456"
            )
        )

        assertNull(provider.current())
    }

    @Test
    fun currentReturnsNullWhenNebulaIdIsMissingOrInvalid() {
        AccountStore.setPrimaryAccount(
            AccountStore.AccountProfile(
                id = "user-1",
                displayName = "Bill",
                nebulaId = null
            )
        )
        assertNull(provider.current())

        AccountStore.setPrimaryAccount(
            AccountStore.AccountProfile(
                id = "user-1",
                displayName = "Bill",
                nebulaId = "NEBULA-2026-NOT_VALID"
            )
        )
        assertNull(provider.current())
    }

    @Test
    fun currentAllowsBlankDisplayNameWhenNebulaIdIsValid() {
        AccountStore.setPrimaryAccount(
            AccountStore.AccountProfile(
                id = "user-1",
                displayName = "   ",
                nebulaId = "NEBULA-2026-ABCDEF123456"
            )
        )

        val identity = provider.current()

        assertNull(identity?.accountDisplayName)
        assertEquals("NEBULA-2026-ABCDEF123456", identity?.nebulaId)
    }

    @Test
    fun currentReturnsNullWhenSessionSubjectIsMissingOrDifferent() {
        AccountStore.setPrimaryAccount(
            AccountStore.AccountProfile(
                id = "user-1",
                displayName = "Bill",
                nebulaId = "NEBULA-2026-ABCDEF123456"
            )
        )

        assertNull(AccountBusinessIdentityProvider { null }.current())
        assertNull(AccountBusinessIdentityProvider { "other-user" }.current())
    }
}
