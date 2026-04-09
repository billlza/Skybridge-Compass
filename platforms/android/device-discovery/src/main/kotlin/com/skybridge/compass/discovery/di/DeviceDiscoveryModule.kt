package com.skybridge.compass.discovery.di

import android.content.Context
import android.net.nsd.NsdManager
import android.net.wifi.p2p.WifiP2pManager
import com.google.android.gms.nearby.connection.ConnectionsClient
import com.skybridge.compass.discovery.data.nearby.NearbyConnectionsManager
import com.skybridge.compass.discovery.data.aware.WifiAwareDataPathManager
import com.skybridge.compass.discovery.data.datasources.BonjourAdvertiserDataSource
import com.skybridge.compass.discovery.data.datasources.BonjourDiscoveryDataSource
import com.skybridge.compass.discovery.data.datasources.WiFiDirectDiscoveryDataSource
import com.skybridge.compass.discovery.data.datasources.WifiAwareDiscoveryDataSource
import com.skybridge.compass.discovery.data.datasources.NearbyConnectionsDiscoveryDataSource
import com.skybridge.compass.discovery.data.datasources.BleDiscoveryDataSource
import com.skybridge.compass.discovery.data.datasources.UdpBroadcastDiscoveryDataSource
import com.skybridge.compass.discovery.data.network.MulticastLockManager
import com.skybridge.compass.discovery.data.telemetry.DiscoveryTelemetry
import com.skybridge.compass.discovery.data.aware.WifiAwarePeerRegistry
import com.skybridge.compass.discovery.data.repositories.DeviceDiscoveryRepositoryImpl
import com.skybridge.compass.discovery.data.services.QuantumOptimizerService
import com.skybridge.compass.discovery.data.services.UnifiedDeviceDiscoveryService
import com.skybridge.compass.discovery.domain.repositories.DeviceDiscoveryRepository
import com.skybridge.compass.discovery.domain.usecases.ConnectToDeviceUseCase
import com.skybridge.compass.discovery.domain.usecases.DisconnectFromDeviceUseCase
import com.skybridge.compass.discovery.domain.usecases.StartDeviceDiscoveryUseCase
import com.skybridge.compass.discovery.domain.usecases.StopDeviceDiscoveryUseCase
import com.skybridge.compass.discovery.domain.usecases.ObserveNearbyPayloadsUseCase
import com.skybridge.compass.discovery.domain.usecases.SendNearbyPayloadUseCase
import com.skybridge.compass.discovery.domain.usecases.GetWifiAwareNetworkUseCase
import com.skybridge.compass.discovery.domain.usecases.SendNearbyFileUseCase
import com.skybridge.compass.discovery.domain.usecases.SendNearbyStreamUseCase
import com.skybridge.compass.discovery.domain.usecases.ObserveNearbyTransferUpdatesUseCase
import com.skybridge.compass.discovery.domain.usecases.CancelNearbyPayloadUseCase
import com.skybridge.compass.discovery.data.services.DeviceListService
import com.skybridge.compass.discovery.data.services.DeviceListServiceImpl
import com.skybridge.compass.core.p2p.TcpControlClient
import dagger.Binds
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.android.qualifiers.ApplicationContext
import dagger.hilt.components.SingletonComponent
import javax.inject.Singleton

/**
 * 设备发现模块的依赖注入配置
 */
@Module
@InstallIn(SingletonComponent::class)
object DeviceDiscoveryModule {
    
    /**
     * 提供NSD管理器
     */
    @Provides
    @Singleton
    fun provideNsdManager(@ApplicationContext context: Context): NsdManager {
        return context.getSystemService(Context.NSD_SERVICE) as NsdManager
    }
    
    /**
     * 提供Wi-Fi P2P管理器
     */
    @Provides
    @Singleton
    fun provideWifiP2pManager(@ApplicationContext context: Context): WifiP2pManager {
        return context.getSystemService(Context.WIFI_P2P_SERVICE) as WifiP2pManager
    }
    
    /**
     * 提供量子优化服务
     */
    @Provides
    @Singleton
    fun provideQuantumOptimizerService(): QuantumOptimizerService {
        return QuantumOptimizerService()
    }
    
    /**
     * 提供Bonjour发现数据源
     */
    @Provides
    @Singleton
    fun provideBonjourDiscoveryDataSource(
        @ApplicationContext context: Context
    ): BonjourDiscoveryDataSource {
        return BonjourDiscoveryDataSource(context)
    }

    /**
     * 提供Bonjour广播数据源（NSD registerService）
     */
    @Provides
    @Singleton
    fun provideBonjourAdvertiserDataSource(
        @ApplicationContext context: Context
    ): BonjourAdvertiserDataSource {
        return BonjourAdvertiserDataSource(context)
    }
    
    /**
     * 提供Wi-Fi Direct发现数据源
     */
    @Provides
    @Singleton
    fun provideWiFiDirectDiscoveryDataSource(
        @ApplicationContext context: Context,
        telemetry: DiscoveryTelemetry
    ): WiFiDirectDiscoveryDataSource {
        return WiFiDirectDiscoveryDataSource(context, telemetry)
    }

    /**
     * 提供 Wi‑Fi Aware 发现数据源
     */
    @Provides
    @Singleton
    fun provideWifiAwareDiscoveryDataSource(
        @ApplicationContext context: Context,
        wifiAwarePeerRegistry: com.skybridge.compass.discovery.data.aware.WifiAwarePeerRegistry
    ): WifiAwareDiscoveryDataSource {
        return WifiAwareDiscoveryDataSource(context, wifiAwarePeerRegistry)
    }

    /**
     * 提供 Nearby Connections 发现数据源
     */
    @Provides
    @Singleton
    fun provideNearbyConnectionsDiscoveryDataSource(
        @ApplicationContext context: Context,
        telemetry: DiscoveryTelemetry
    ): NearbyConnectionsDiscoveryDataSource {
        return NearbyConnectionsDiscoveryDataSource(context, telemetry)
    }

    /**
     * 提供 BLE 发现数据源
     */
    @Provides
    @Singleton
    fun provideBleDiscoveryDataSource(
        @ApplicationContext context: Context,
        telemetry: DiscoveryTelemetry
    ): BleDiscoveryDataSource {
        return BleDiscoveryDataSource(context, telemetry)
    }

    /**
     * 提供 UDP 广播/组播发现数据源
     */
    @Provides
    @Singleton
    fun provideUdpBroadcastDiscoveryDataSource(
        @ApplicationContext context: Context,
        multicastLockManager: MulticastLockManager,
        telemetry: DiscoveryTelemetry
    ): UdpBroadcastDiscoveryDataSource {
        return UdpBroadcastDiscoveryDataSource(context, multicastLockManager, telemetry)
    }

    /**
     * 提供 Nearby ConnectionsClient
     */
    @Provides
    @Singleton
    fun provideConnectionsClient(@ApplicationContext context: Context): ConnectionsClient {
        return com.google.android.gms.nearby.Nearby.getConnectionsClient(context)
    }

    /**
     * 提供 WifiAwarePeerRegistry
     */
    @Provides
    @Singleton
    fun provideWifiAwarePeerRegistry(): WifiAwarePeerRegistry {
        return WifiAwarePeerRegistry()
    }

    /**
     * 提供发现 Telemetry
     */
    @Provides
    @Singleton
    fun provideDiscoveryTelemetry(): DiscoveryTelemetry {
        return DiscoveryTelemetry()
    }

    /**
     * 提供 NearbyConnectionsManager
     */
    @Provides
    @Singleton
    fun provideNearbyConnectionsManager(
        connectionsClient: ConnectionsClient
    ): NearbyConnectionsManager {
        return NearbyConnectionsManager(connectionsClient)
    }

    /**
     * 提供 WifiAwareDataPathManager
     */
    @Provides
    @Singleton
    fun provideWifiAwareDataPathManager(
        @ApplicationContext context: Context,
        wifiAwarePeerRegistry: WifiAwarePeerRegistry
    ): WifiAwareDataPathManager {
        return WifiAwareDataPathManager(context, wifiAwarePeerRegistry)
    }


    
    /**
     * 提供统一设备发现服务
     */
    @Provides
    @Singleton
    fun provideUnifiedDeviceDiscoveryService(
        bonjourDataSource: BonjourDiscoveryDataSource,
        wifiDirectDataSource: WiFiDirectDiscoveryDataSource,
        wifiAwareDataSource: WifiAwareDiscoveryDataSource,
        nearbyDataSource: NearbyConnectionsDiscoveryDataSource,
        bleDataSource: BleDiscoveryDataSource,
        udpDataSource: UdpBroadcastDiscoveryDataSource,
        quantumOptimizer: QuantumOptimizerService
    ): UnifiedDeviceDiscoveryService {
        return UnifiedDeviceDiscoveryService(
            bonjourDataSource,
            wifiDirectDataSource,
            wifiAwareDataSource,
            nearbyDataSource,
            bleDataSource,
            udpDataSource,
            quantumOptimizer
        )
    }
    
    /**
     * 提供设备发现仓库
     */
    @Provides
    @Singleton
    fun provideDeviceDiscoveryRepository(
        unifiedDiscoveryService: UnifiedDeviceDiscoveryService,
        connectionsClient: ConnectionsClient,
        @ApplicationContext context: Context,
        wifiAwarePeerRegistry: WifiAwarePeerRegistry,
        nearbyConnectionsManager: NearbyConnectionsManager,
        wifiAwareDataPathManager: WifiAwareDataPathManager,
        tcpControlClient: TcpControlClient
    ): DeviceDiscoveryRepository {
        return DeviceDiscoveryRepositoryImpl(
            unifiedDiscoveryService,
            connectionsClient,
            context,
            wifiAwarePeerRegistry,
            nearbyConnectionsManager,
            wifiAwareDataPathManager,
            tcpControlClient
        )
    }
    
    /**
     * 提供开始设备发现用例
     */
    @Provides
    fun provideStartDeviceDiscoveryUseCase(
        repository: DeviceDiscoveryRepository
    ): StartDeviceDiscoveryUseCase {
        return StartDeviceDiscoveryUseCase(repository)
    }
    
    /**
     * 提供停止设备发现用例
     */
    @Provides
    fun provideStopDeviceDiscoveryUseCase(
        repository: DeviceDiscoveryRepository
    ): StopDeviceDiscoveryUseCase {
        return StopDeviceDiscoveryUseCase(repository)
    }
    
    /**
     * 提供连接设备用例
     */
    @Provides
    fun provideConnectToDeviceUseCase(
        repository: DeviceDiscoveryRepository
    ): ConnectToDeviceUseCase {
        return ConnectToDeviceUseCase(repository)
    }
    
    /**
     * 提供断开设备连接用例
     */
    @Provides
    fun provideDisconnectFromDeviceUseCase(
        repository: DeviceDiscoveryRepository
    ): DisconnectFromDeviceUseCase {
        return DisconnectFromDeviceUseCase(repository)
    }

    /**
     * 提供观察 Nearby 字节负载用例
     */
    @Provides
    fun provideObserveNearbyPayloadsUseCase(
        repository: DeviceDiscoveryRepository
    ): ObserveNearbyPayloadsUseCase {
        return ObserveNearbyPayloadsUseCase(repository)
    }

    /**
     * 提供发送 Nearby 字节负载用例
     */
    @Provides
    fun provideSendNearbyPayloadUseCase(
        repository: DeviceDiscoveryRepository
    ): SendNearbyPayloadUseCase {
        return SendNearbyPayloadUseCase(repository)
    }

    /** 提供发送文件用例 */
    @Provides
    fun provideSendNearbyFileUseCase(
        repository: DeviceDiscoveryRepository
    ): SendNearbyFileUseCase {
        return SendNearbyFileUseCase(repository)
    }

    /** 提供发送流用例 */
    @Provides
    fun provideSendNearbyStreamUseCase(
        repository: DeviceDiscoveryRepository
    ): SendNearbyStreamUseCase {
        return SendNearbyStreamUseCase(repository)
    }

    /** 提供观察传输进度用例 */
    @Provides
    fun provideObserveNearbyTransferUpdatesUseCase(
        repository: DeviceDiscoveryRepository
    ): ObserveNearbyTransferUpdatesUseCase {
        return ObserveNearbyTransferUpdatesUseCase(repository)
    }

    /** 提供取消传输用例 */
    @Provides
    fun provideCancelNearbyPayloadUseCase(
        repository: DeviceDiscoveryRepository
    ): CancelNearbyPayloadUseCase {
        return CancelNearbyPayloadUseCase(repository)
    }

    /**
     * 提供获取 Wi‑Fi Aware Network 用例
     */
    @Provides
    fun provideGetWifiAwareNetworkUseCase(
        repository: DeviceDiscoveryRepository
    ): GetWifiAwareNetworkUseCase {
        return GetWifiAwareNetworkUseCase(repository)
    }
    
    /**
     * 提供设备列表服务
     */
    @Provides
    @Singleton
    fun provideDeviceListService(): DeviceListService {
        return DeviceListServiceImpl()
    }
}
