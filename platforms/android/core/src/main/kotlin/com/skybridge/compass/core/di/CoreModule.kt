package com.skybridge.compass.core.di

import android.content.Context
import com.skybridge.compass.core.services.HardwareMonitorService
import com.skybridge.compass.core.services.HardwareMonitorServiceImpl
import com.skybridge.compass.core.webrtc.AndroidCrossNetworkWebRtcTransportAdapter
import com.skybridge.compass.core.webrtc.CrossNetworkWebRtcTransportAdapter
import com.skybridge.compass.core.webrtc.SkyBridgeWebRtcConnectionManager
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.android.qualifiers.ApplicationContext
import dagger.hilt.components.SingletonComponent
import javax.inject.Singleton

@Module
@InstallIn(SingletonComponent::class)
object CoreModule {
    
    @Provides
    @Singleton
    fun provideHardwareMonitorService(
        @ApplicationContext context: Context
    ): HardwareMonitorService {
        return HardwareMonitorServiceImpl(context)
    }

    @Provides
    @Singleton
    fun provideCrossNetworkWebRtcTransportAdapter(
        @ApplicationContext context: Context
    ): CrossNetworkWebRtcTransportAdapter {
        return AndroidCrossNetworkWebRtcTransportAdapter(
            SkyBridgeWebRtcConnectionManager(context.applicationContext)
        )
    }
}
