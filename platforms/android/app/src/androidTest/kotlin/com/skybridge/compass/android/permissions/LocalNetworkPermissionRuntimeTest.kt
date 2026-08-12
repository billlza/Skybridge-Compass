package com.skybridge.compass.android.permissions

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.skybridge.compass.discovery.data.datasources.BonjourLocalNetworkPermissionPolicy
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class LocalNetworkPermissionRuntimeTest {
    @Test
    fun api37ManifestRequestAndRuntimeGateMatchHarnessGrantState() {
        assumeTrue("ACCESS_LOCAL_NETWORK is an Android 17 / API 37 permission", Build.VERSION.SDK_INT >= 37)

        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext.applicationContext
        val permission = Manifest.permission.ACCESS_LOCAL_NETWORK
        val expectedGranted = when (
            val raw = InstrumentationRegistry.getArguments()
                .getString(EXPECTED_PERMISSION_STATE_ARGUMENT)
        ) {
            "true" -> true
            "false" -> false
            else -> error(
                "instrumentation argument $EXPECTED_PERMISSION_STATE_ARGUMENT must be true or false, was $raw",
            )
        }
        val requestedPermissions = context.packageManager
            .getPackageInfo(context.packageName, PackageManager.GET_PERMISSIONS)
            .requestedPermissions
            ?.toSet()
            .orEmpty()

        assertTrue("merged manifest must declare $permission", permission in requestedPermissions)
        assertEquals(
            permission,
            BonjourLocalNetworkPermissionPolicy.requiredPermission(Build.VERSION.SDK_INT),
        )
        assertTrue(
            permission in PermissionManager.permissionsFor(
                PermissionManager.Feature.DEVICE_DISCOVERY,
                Build.VERSION.SDK_INT,
            ),
        )

        val actualGranted =
            context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED
        assertEquals(expectedGranted, actualGranted)
        if (expectedGranted) {
            assertTrue(
                BonjourLocalNetworkPermissionPolicy.isGranted(context, Build.VERSION.SDK_INT),
            )
        } else {
            assertFalse(
                BonjourLocalNetworkPermissionPolicy.isGranted(context, Build.VERSION.SDK_INT),
            )
        }
    }

    private companion object {
        const val EXPECTED_PERMISSION_STATE_ARGUMENT =
            "expectedLocalNetworkPermissionGranted"
    }
}
