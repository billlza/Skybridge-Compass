package com.skybridge.compass.android.config

object FeatureFlags {
    @Volatile var ENABLE_REMOTE_CONTROL: Boolean = true
    @Volatile var ENABLE_SCREEN_MIRRORING: Boolean = true
    @Volatile var ENABLE_FILE_TRANSFER: Boolean = true
}