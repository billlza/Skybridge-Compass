package com.skybridge.compass.android.data

import android.content.Context
import dagger.hilt.android.qualifiers.ApplicationContext
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.flow.Flow

/** Injectable read port so presentation orchestration does not own DataStore access. */
@Singleton
class SecuritySettingsSource @Inject constructor(
    @ApplicationContext private val context: Context
) {
    fun observe(): Flow<SecuritySettings> = SecuritySettingsStore.observe(context)
}
