package com.skybridge.compass.android.discovery

import com.skybridge.compass.discovery.domain.entities.DeviceCapability
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class VerifiedCapabilityResolverTest {
    private val resolver = DefaultVerifiedCapabilityResolver

    @Test
    fun capabilityAppearsOnlyWhenPermissionGrantedAndServiceReady() {
        val state = CapabilityRuntimeState(
            preconditions = mapOf(
                DeviceCapability.FILE_TRANSFER to CapabilityPrecondition(
                    permissionGranted = true,
                    serviceReady = true
                )
            )
        )

        assertEquals(setOf(DeviceCapability.FILE_TRANSFER), resolver.resolve(state))
    }

    @Test
    fun capabilityIsExcludedWhenPermissionMissing() {
        val state = CapabilityRuntimeState(
            preconditions = mapOf(
                DeviceCapability.FILE_TRANSFER to CapabilityPrecondition(
                    permissionGranted = false,
                    serviceReady = true
                )
            )
        )

        assertTrue(resolver.resolve(state).isEmpty())
    }

    @Test
    fun capabilityIsExcludedWhenServiceNotReady() {
        val state = CapabilityRuntimeState(
            preconditions = mapOf(
                DeviceCapability.SCREEN_SHARING to CapabilityPrecondition(
                    permissionGranted = true,
                    serviceReady = false
                )
            )
        )

        assertTrue(resolver.resolve(state).isEmpty())
    }

    @Test
    fun resolvesExactlyTheSatisfiedSubset() {
        val state = CapabilityRuntimeState(
            preconditions = mapOf(
                DeviceCapability.FILE_TRANSFER to CapabilityPrecondition(
                    permissionGranted = true,
                    serviceReady = true
                ),
                DeviceCapability.CLIPBOARD_SYNC to CapabilityPrecondition(
                    permissionGranted = true,
                    serviceReady = true
                ),
                DeviceCapability.REMOTE_CONTROL to CapabilityPrecondition(
                    permissionGranted = true,
                    serviceReady = false
                ),
                DeviceCapability.SCREEN_SHARING to CapabilityPrecondition(
                    permissionGranted = false,
                    serviceReady = true
                )
            )
        )

        assertEquals(
            setOf(DeviceCapability.FILE_TRANSFER, DeviceCapability.CLIPBOARD_SYNC),
            resolver.resolve(state)
        )
    }

    @Test
    fun emptyStateResolvesToEmptySet() {
        assertTrue(resolver.resolve(CapabilityRuntimeState(preconditions = emptyMap())).isEmpty())
    }
}
