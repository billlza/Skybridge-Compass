package com.skybridge.compass.android.permissions

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import androidx.activity.ComponentActivity
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import com.skybridge.compass.discovery.data.datasources.BonjourLocalNetworkPermissionPolicy

class PermissionManager(private val activity: ComponentActivity) {
    enum class Feature {
        BONJOUR_LOCAL_NETWORK,
        DEVICE_DISCOVERY,
        NOTIFICATIONS,
        WEATHER_LOCATION,
    }

    private var permissionLauncher: ActivityResultLauncher<Array<String>>? = null
    private var onPermissionResult: ((Map<String, Boolean>) -> Unit)? = null

    init {
        setupPermissionLauncher()
    }

    private fun setupPermissionLauncher() {
        permissionLauncher = activity.registerForActivityResult(
            ActivityResultContracts.RequestMultiplePermissions()
        ) { permissions ->
            onPermissionResult?.invoke(permissions)
        }
    }

    fun requestPermissions(
        feature: Feature,
        onResult: (Map<String, Boolean>) -> Unit
    ) {
        onPermissionResult = onResult
        val permissions = permissionsFor(feature)
        if (permissions.isEmpty()) {
            onResult(emptyMap())
        } else {
            permissionLauncher?.launch(permissions.toTypedArray())
        }
    }

    fun arePermissionsGranted(feature: Feature): Boolean =
        arePermissionsGranted(activity, feature)

    fun getMissingPermissions(feature: Feature): List<String> =
        permissionsFor(feature).filterNot(::isPermissionGranted)

    fun isPermissionGranted(permission: String): Boolean =
        ContextCompat.checkSelfPermission(activity, permission) == PackageManager.PERMISSION_GRANTED

    private fun permissionsFor(feature: Feature): List<String> =
        permissionsFor(feature, Build.VERSION.SDK_INT)

    companion object {
        fun permissionsFor(feature: Feature, sdkInt: Int = Build.VERSION.SDK_INT): List<String> =
            when (feature) {
                Feature.BONJOUR_LOCAL_NETWORK ->
                    listOfNotNull(BonjourLocalNetworkPermissionPolicy.requiredPermission(sdkInt))

                Feature.DEVICE_DISCOVERY -> buildList {
                    addAll(permissionsFor(Feature.BONJOUR_LOCAL_NETWORK, sdkInt))
                    add(Manifest.permission.BLUETOOTH_SCAN)
                    add(Manifest.permission.BLUETOOTH_ADVERTISE)
                    add(Manifest.permission.BLUETOOTH_CONNECT)
                    add(Manifest.permission.NEARBY_WIFI_DEVICES)
                }

                Feature.NOTIFICATIONS -> listOf(Manifest.permission.POST_NOTIFICATIONS)

                // Weather resolves to a city, so a coarse fix is sufficient. Asking for
                // ACCESS_FINE_LOCATION here would request precision the feature discards.
                Feature.WEATHER_LOCATION -> listOf(Manifest.permission.ACCESS_COARSE_LOCATION)
            }

        fun arePermissionsGranted(
            context: Context,
            feature: Feature,
            sdkInt: Int = Build.VERSION.SDK_INT
        ): Boolean = permissionsFor(feature, sdkInt).all { permission ->
            ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED
        }
    }
}
