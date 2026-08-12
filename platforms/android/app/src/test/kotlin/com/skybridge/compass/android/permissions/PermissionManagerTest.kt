package com.skybridge.compass.android.permissions

import android.Manifest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PermissionManagerTest {
    @Test
    fun bonjourRequestsAccessLocalNetworkOnlyFromApi37() {
        assertEquals(
            emptyList<String>(),
            PermissionManager.permissionsFor(
                PermissionManager.Feature.BONJOUR_LOCAL_NETWORK,
                sdkInt = 36,
            ),
        )
        assertEquals(
            listOf(Manifest.permission.ACCESS_LOCAL_NETWORK),
            PermissionManager.permissionsFor(
                PermissionManager.Feature.BONJOUR_LOCAL_NETWORK,
                sdkInt = 37,
            ),
        )
    }

    @Test
    fun api36DiscoveryUsesNearbyWifiWithoutRequestingApi37Permission() {
        val permissions = PermissionManager.permissionsFor(
            PermissionManager.Feature.DEVICE_DISCOVERY,
            sdkInt = 36,
        )

        assertTrue(Manifest.permission.NEARBY_WIFI_DEVICES in permissions)
        assertFalse(Manifest.permission.ACCESS_LOCAL_NETWORK in permissions)
    }

    @Test
    fun api37DiscoveryIncludesLocalNetworkAndNearbyPermissionsExactlyOnce() {
        val permissions = PermissionManager.permissionsFor(
            PermissionManager.Feature.DEVICE_DISCOVERY,
            sdkInt = 37,
        )

        assertTrue(Manifest.permission.ACCESS_LOCAL_NETWORK in permissions)
        assertTrue(Manifest.permission.NEARBY_WIFI_DEVICES in permissions)
        assertEquals(permissions.distinct(), permissions)
    }
}
