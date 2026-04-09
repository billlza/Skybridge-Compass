package com.skybridge.compass.android.permissions

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import androidx.activity.ComponentActivity
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat

class PermissionManager(private val activity: ComponentActivity) {
    
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
    
    /**
     * Request all necessary permissions for Android 13+
     */
    fun requestAllPermissions(onResult: (Map<String, Boolean>) -> Unit) {
        onPermissionResult = onResult
        val permissions = getRequiredPermissions()
        permissionLauncher?.launch(permissions.toTypedArray())
    }
    
    /**
     * Check if all required permissions are granted
     */
    fun areAllPermissionsGranted(): Boolean {
        val permissions = getRequiredPermissions()
        return permissions.all { permission ->
            ContextCompat.checkSelfPermission(activity, permission) == PackageManager.PERMISSION_GRANTED
        }
    }
    
    /**
     * Get list of required permissions based on Android version
     */
    private fun getRequiredPermissions(): List<String> {
        val permissions = mutableListOf<String>()
        
        // Network and basic permissions
        permissions.addAll(listOf(
            Manifest.permission.INTERNET,
            Manifest.permission.ACCESS_NETWORK_STATE,
            Manifest.permission.ACCESS_WIFI_STATE,
            Manifest.permission.CHANGE_WIFI_STATE
        ))
        
        // Location permissions
        permissions.addAll(listOf(
            Manifest.permission.ACCESS_COARSE_LOCATION,
            Manifest.permission.ACCESS_FINE_LOCATION
        ))
        
        // Bluetooth permissions for Android 12+
        permissions.addAll(listOf(
            Manifest.permission.BLUETOOTH_SCAN,
            Manifest.permission.BLUETOOTH_ADVERTISE,
            Manifest.permission.BLUETOOTH_CONNECT
        ))
        
        // Nearby Wi-Fi devices permission for Android 13+
        permissions.add(Manifest.permission.NEARBY_WIFI_DEVICES)
        
        // Notification permission for Android 13+
        permissions.add(Manifest.permission.POST_NOTIFICATIONS)
        
        // Media permissions for Android 13+
        permissions.addAll(listOf(
            Manifest.permission.READ_MEDIA_IMAGES,
            Manifest.permission.READ_MEDIA_VIDEO,
            Manifest.permission.READ_MEDIA_AUDIO
        ))
        
        // Camera and audio permissions
        permissions.addAll(listOf(
            Manifest.permission.CAMERA,
            Manifest.permission.RECORD_AUDIO
        ))
        
        return permissions
    }
    
    /**
     * Check if a specific permission is granted
     */
    fun isPermissionGranted(permission: String): Boolean {
        return ContextCompat.checkSelfPermission(activity, permission) == PackageManager.PERMISSION_GRANTED
    }
    
    /**
     * Get missing permissions
     */
    fun getMissingPermissions(): List<String> {
        return getRequiredPermissions().filter { permission ->
            !isPermissionGranted(permission)
        }
    }
}