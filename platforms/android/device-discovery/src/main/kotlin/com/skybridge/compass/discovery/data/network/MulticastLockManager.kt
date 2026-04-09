package com.skybridge.compass.discovery.data.network

import android.content.Context
import android.net.wifi.WifiManager
import dagger.hilt.android.qualifiers.ApplicationContext
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class MulticastLockManager @Inject constructor(
    @ApplicationContext private val context: Context
) {
    private var lock: WifiManager.MulticastLock? = null

    fun acquire(tag: String = "SkyBridge_MulticastLock") {
        if (lock?.isHeld == true) return
        val wifi = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        val multicastLock = wifi.createMulticastLock(tag)
        multicastLock.setReferenceCounted(true)
        multicastLock.acquire()
        lock = multicastLock
    }

    fun release() {
        try {
            if (lock?.isHeld == true) {
                lock?.release()
            }
        } catch (_: Exception) {
        } finally {
            lock = null
        }
    }
}