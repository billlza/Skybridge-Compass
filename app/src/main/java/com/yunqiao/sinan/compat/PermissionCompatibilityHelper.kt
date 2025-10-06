package com.yunqiao.sinan.compat

import android.Manifest
import android.content.Context
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.content.pm.PermissionInfo
import android.os.Build
import android.util.Log
import androidx.core.content.ContextCompat
import java.util.LinkedHashSet

/**
 * Runtime permission compatibility helper that filters out unsupported or
 * non-runtime permissions before requesting them. This avoids illegal or
 * duplicated requests that could crash on older or future Android versions.
 */
class PermissionCompatibilityHelper(private val context: Context) {

    companion object {
        private const val TAG = "PermissionCompat"
    }

    private val packageManager: PackageManager = context.packageManager

    private val requestedPermissions: Set<String> by lazy { loadRequestedPermissions() }

    fun filterRequestable(permissions: Collection<String>): List<String> {
        val sanitized = LinkedHashSet<String>()
        permissions.forEach { permission ->
            val trimmed = permission.trim()
            if (trimmed.isEmpty()) {
                return@forEach
            }

            if (isRequestablePermission(trimmed)) {
                sanitized.add(trimmed)
            }
        }
        return sanitized.toList()
    }

    fun isRequestablePermission(permission: String): Boolean {
        if (!isPermissionDeclared(permission)) {
            Log.w(TAG, "Permission $permission not declared in manifest; skipping request")
            return false
        }

        if (!isRuntimePermission(permission)) {
            return false
        }

        if (!isPermissionSupported(permission)) {
            Log.w(TAG, "Permission $permission not supported on this device; skipping request")
            return false
        }

        return true
    }

    fun hasAllPermissions(permissions: Collection<String>): Boolean {
        return permissions.all { ContextCompat.checkSelfPermission(context, it) == PackageManager.PERMISSION_GRANTED }
    }

    private fun loadRequestedPermissions(): Set<String> {
        val packageInfo: PackageInfo = try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                packageManager.getPackageInfo(
                    context.packageName,
                    PackageManager.PackageInfoFlags.of(PackageManager.GET_PERMISSIONS.toLong())
                )
            } else {
                @Suppress("DEPRECATION")
                packageManager.getPackageInfo(context.packageName, PackageManager.GET_PERMISSIONS)
            }
        } catch (error: Exception) {
            Log.w(TAG, "Unable to load manifest permissions", error)
            return emptySet()
        }

        val requested = packageInfo.requestedPermissions ?: emptyArray()
        return requested.filterNotNull().toSet()
    }

    private fun isPermissionDeclared(permission: String): Boolean {
        return requestedPermissions.contains(permission)
    }

    private fun isRuntimePermission(permission: String): Boolean {
        if (permission == Manifest.permission.MANAGE_EXTERNAL_STORAGE) {
            return false
        }
        val info = try {
            @Suppress("DEPRECATION")
            packageManager.getPermissionInfo(permission, 0)
        } catch (error: Exception) {
            Log.w(TAG, "Permission $permission metadata not available", error)
            return true
        }

        val protectionBase = info.protection and PermissionInfo.PROTECTION_MASK_BASE
        val isDangerous = protectionBase == PermissionInfo.PROTECTION_DANGEROUS
        val hasRuntimeFlags = (info.protectionLevel and PermissionInfo.PROTECTION_FLAG_APPOP) != 0 ||
            (info.protectionLevel and PermissionInfo.PROTECTION_FLAG_PRE23) != 0 ||
            (info.protectionLevel and PermissionInfo.PROTECTION_FLAG_INSTALLER) != 0
        return isDangerous || hasRuntimeFlags
    }

    private fun isPermissionSupported(permission: String): Boolean {
        return when (permission) {
            Manifest.permission.CAMERA -> packageManager.hasSystemFeature(PackageManager.FEATURE_CAMERA_ANY)
            Manifest.permission.RECORD_AUDIO -> packageManager.hasSystemFeature(PackageManager.FEATURE_MICROPHONE)
            Manifest.permission.NEARBY_WIFI_DEVICES,
            Manifest.permission.ACCESS_WIFI_STATE,
            Manifest.permission.CHANGE_WIFI_STATE -> packageManager.hasSystemFeature(PackageManager.FEATURE_WIFI)
            Manifest.permission.BLUETOOTH_SCAN,
            Manifest.permission.BLUETOOTH_CONNECT,
            Manifest.permission.BLUETOOTH_ADVERTISE,
            Manifest.permission.BLUETOOTH,
            Manifest.permission.BLUETOOTH_ADMIN -> packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH)
            else -> true
        }
    }
}
