import XCTest

final class SettingsRuntimeTruthSourceContractTests: XCTestCase {
    func testSettingsManagerDrivesRuntimeConsumers() throws {
        let source = try readSource("Sources/SkyBridgeCore/Settings/SettingsManager.swift")

        XCTAssertTrue(source.contains("DeviceManagementSettingsManager.shared.wifiScanInterval = interval"))
        XCTAssertTrue(source.contains("postBluetoothSettingsChanged([\"scanInterval\": interval])"))
        XCTAssertTrue(source.contains("postAirPlaySettingsChanged([\"scanInterval\": interval])"))
        XCTAssertTrue(source.contains("scheduleFileTransferSettingsApply()"))
        XCTAssertTrue(source.contains("clearCryptoProviderCacheForSettingsChange()"))
        XCTAssertTrue(source.contains("\"enableRealTimeWeather\": enableRealTimeWeather"))
        XCTAssertTrue(source.contains("\"enablePQC\": enablePQC"))
        XCTAssertTrue(source.contains("userDefaults.set(true, forKey: \"Settings.EnablePQC\")"))
        XCTAssertTrue(source.contains("normalizedPQCSignatureAlgorithm"))
        XCTAssertTrue(source.contains("scheduleDiscoveryRuntimeApply(restartIfNeeded: true)"))
        XCTAssertTrue(source.contains("@Published public var preferXWingHybrid: Bool = false"))
        XCTAssertTrue(source.contains("\"preferXWingHybrid\": preferXWingHybrid"))
        XCTAssertTrue(source.contains("userDefaults.bool(forKey: SettingsStorageKeys.preferXWingHybrid, defaultValue: false)"))
    }

    func testDiscoverySettingsReachRunningDiscoveryManagers() throws {
        let service = try readSource("Sources/SkyBridgeCore/DeviceDiscoveryService.swift")
        let optimized = try readSource("Sources/SkyBridgeCore/DeviceDiscovery/DeviceDiscoveryManagerOptimized.swift")
        let unified = try readSource("Sources/SkyBridgeCore/DeviceDiscovery/UnifiedOnlineDeviceManager.swift")

        XCTAssertTrue(service.contains("$enableIPv6Support"))
        XCTAssertTrue(service.contains("$useNewDiscoveryAlgorithm"))
        XCTAssertTrue(service.contains("applyRuntimeDiscoverySettings(restartIfNeeded: Bool = true)"))
        XCTAssertTrue(optimized.contains("public func applyRuntimeSettings("))
        XCTAssertTrue(optimized.contains("enableBonjourDiscovery: Bool = true"))
        XCTAssertTrue(optimized.contains("scanCustomPorts: Bool = false"))
        XCTAssertTrue(optimized.contains("customServiceTypes: [String] = []"))
        XCTAssertTrue(optimized.contains("discoveryTimeout: Int = 30"))
        XCTAssertTrue(optimized.contains("guard enableBonjourDiscovery else { return [] }"))
        XCTAssertTrue(optimized.contains("self.enableMDNSResolution != enableMDNSResolution"))
        XCTAssertTrue(optimized.contains("if enableMDNSResolution && (enableCompatibilityMode || useNewDiscoveryAlgorithm)"))
        XCTAssertTrue(optimized.contains("guard enableMDNSResolution else { return nil }"))
        XCTAssertTrue(optimized.contains("return (nil, nil, 0)"))
        XCTAssertTrue(service.contains("enableBonjourDiscovery: settingsManager.enableBonjourDiscovery"))
        XCTAssertTrue(service.contains("customServiceTypes: settingsManager.customServiceTypes"))
        XCTAssertTrue(optimized.contains("enableCompatibilityMode || useNewDiscoveryAlgorithm"))
        XCTAssertTrue(unified.contains("networkDiscovery.applyRuntimeSettings("))
        XCTAssertTrue(unified.contains("enableBonjourDiscovery: settings.enableBonjourDiscovery"))
        XCTAssertTrue(unified.contains("settings.minimumSignalStrength"))
    }

    func testRemoteDesktopSettingsReachP2PAndWebRTCRuntimeConsumers() throws {
        let remoteSettings = try readSource("Sources/SkyBridgeCore/RemoteDesktopSettings.swift")
        let budget = try readSource("Sources/SkyBridgeCore/RemoteConnection/WebRTC/WebRTCRemoteDesktopBudget.swift")
        let streamingPolicy = try readSource("Sources/SkyBridgeCore/RemoteConnection/WebRTC/WebRTCScreenStreamingPolicy.swift")
        let crossNetwork = try readSource("Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift")
        let webRTCFileTransfer = try readSource("Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager+WebRTCFileTransfer.swift")
        let rdpManager = try readSource("Sources/SkyBridgeCore/RemoteDesktopManager.swift")
        let remoteControlManager = try readSource("Sources/SkyBridgeCore/RemoteControl/RemoteControlManager.swift")
        let screenCaptureStreamer = try readSource("Sources/SkyBridgeCore/RemoteControl/ScreenCaptureKitStreamer.swift")
        let sshClient = try readSource("Sources/SkyBridgeCore/RemoteConnection/SSHClientImpl.swift")
        let sshSession = try readSource("Sources/SkyBridgeCore/RemoteConnection/SSHSession.swift")
        let vncClient = try readSource("Sources/SkyBridgeCore/RemoteConnection/VNCClientImpl.swift")

        XCTAssertTrue(remoteSettings.contains("enforceStrictTransportSecurity()"))
        XCTAssertTrue(remoteSettings.contains("settings.networkSettings.enforceStrictTransportSecurity()"))
        XCTAssertTrue(remoteSettings.contains("public var boundedCompressionLevelPercent: Int"))
        XCTAssertTrue(remoteSettings.contains("public var boundedDoubleClickIntervalMilliseconds: Int"))
        XCTAssertTrue(remoteSettings.contains("public var boundedConnectionTimeoutSeconds: Int"))
        XCTAssertTrue(remoteSettings.contains("public func reconnectBackoffDelayMilliseconds(forAttempt attempt: Int) -> Int"))
        XCTAssertTrue(remoteSettings.contains("maxBufferedAmountOverrideBytes"))
        XCTAssertTrue(budget.contains("frameRateCap(forBandwidthLimitMbps: boundedBandwidthLimit, codec: codec)"))
        XCTAssertTrue(budget.contains("reason += \"+manual-quality\""))
        XCTAssertTrue(streamingPolicy.contains("compressionLevel: Int = 6"))
        XCTAssertTrue(streamingPolicy.contains("jpegProfile(base: base, compressionLevel: compressionLevel)"))
        XCTAssertTrue(crossNetwork.contains("networkSettings.enableAdaptiveQuality"))
        XCTAssertTrue(crossNetwork.contains("udp_transport_disabled_by_settings"))
        XCTAssertTrue(crossNetwork.contains("remote_desktop_file_transfer_disabled_by_settings"))
        XCTAssertTrue(crossNetwork.contains("networkSettings.boundedConnectionTimeoutSeconds"))
        XCTAssertTrue(crossNetwork.contains("settings.networkSettings.enableNetworkStats"))
        XCTAssertTrue(crossNetwork.contains("remoteDesktopReconnectBackoffDelayMilliseconds(forAttempt:"))
        XCTAssertTrue(webRTCFileTransfer.contains("guard RemoteDesktopSettingsManager.shared.settings.interactionSettings.enableFileTransfer"))
        XCTAssertTrue(rdpManager.contains("guard interactionSettings.enableContextMenu || !Self.isRightMouseEvent(eventType)"))
        XCTAssertTrue(rdpManager.contains("guard interactionSettings.enableTrackpadGestures"))
        XCTAssertTrue(rdpManager.contains("settings.enableMouseAcceleration"))
        XCTAssertTrue(rdpManager.contains("\"compressionLevel\": settings.displaySettings.boundedCompressionLevelPercent"))
        XCTAssertTrue(rdpManager.contains("\"connectionTimeout\": settings.networkSettings.boundedConnectionTimeoutSeconds * 1_000"))
        XCTAssertTrue(rdpManager.contains("\"enableNetworkStats\": settings.networkSettings.enableNetworkStats"))
        XCTAssertTrue(remoteControlManager.contains("boundedDoubleClickIntervalMilliseconds"))
        XCTAssertTrue(remoteControlManager.contains("videoCompressionLevel: settings.displaySettings.boundedCompressionLevelPercent"))
        XCTAssertTrue(screenCaptureStreamer.contains("settings.displaySettings.boundedCompressionLevelPercent"))
        XCTAssertTrue(sshClient.contains("connectionTimeout: TimeInterval(networkSettings.boundedConnectionTimeoutSeconds)"))
        XCTAssertTrue(sshClient.contains("timeoutPromise.fail(SSHClientImplError.timeout)"))
        XCTAssertTrue(sshSession.contains("boundedReconnectBackoffInitialMilliseconds"))
        XCTAssertTrue(sshSession.contains("boundedReconnectBackoffMaxMilliseconds"))
        XCTAssertTrue(sshSession.contains("boundedReconnectBackoffMultiplier"))
        XCTAssertTrue(vncClient.contains("VNCConnectionContinuationGate"))
        XCTAssertTrue(vncClient.contains("configuration.connectionTimeout"))
        XCTAssertTrue(vncClient.contains("VNCClientError.timeout"))
    }

    func testPreferencesPermissionWeatherAndFPSRowsAreTruthful() throws {
        let source = try readSource("Sources/SkyBridgeCompassApp/PreferencesView.swift")

        XCTAssertFalse(source.contains("isNetworkConfigured = true"))
        XCTAssertFalse(source.contains("For now, return false so UI won't lie."))
        XCTAssertTrue(source.contains("CLLocationManager()"))
        XCTAssertTrue(source.contains("NetworkEntitlementProbe.current()"))
        let networkProbeBody = try extract(
            source: source,
            from: "private enum NetworkEntitlementProbe",
            to: "enum PermissionRowState"
        )
        XCTAssertTrue(networkProbeBody.contains("SecTaskCopyValueForEntitlement"))
        XCTAssertFalse(networkProbeBody.contains("object(forInfoDictionaryKey: \"com.apple.security.network.client\")"))
        XCTAssertTrue(source.contains(".disabled(!settingsManager.enableRealTimeWeather)"))
        XCTAssertTrue(source.contains("SystemRequirementProbe.current()"))
        XCTAssertTrue(source.contains("RequirementRow(icon: \"cpu\", title: \"处理器\", requirement: \"Apple M1 或更新\", status: requirements.minimumProcessor)"))
        XCTAssertFalse(source.contains("RequirementRow(icon: \"cpu\", title: \"处理器\", requirement: \"Apple M1 或更新\", met: true)"))
        XCTAssertFalse(source.contains("RequirementRow(icon: \"wifi\", title: \"网络\", requirement: \"Wi-Fi 6E (802.11ax)\", met: false)"))

        let fpsToggleCount = source.components(separatedBy: "Toggle(\"显示实时FPS\"").count - 1
        XCTAssertEqual(fpsToggleCount, 1)
    }

    func testWeatherDashboardDoesNotTreatDisabledWeatherAsLoading() throws {
        let cardSource = try readSource("Sources/SkyBridgeCompassApp/Views/WeatherDashboardCard.swift")
        let managerSource = try readSource("Sources/SkyBridgeCore/Weather/WeatherIntegrationManager.swift")
        let weatherServiceSource = try readSource("Sources/SkyBridgeCore/Weather/WeatherService.swift")
        let locationSource = try readSource("Sources/SkyBridgeCore/Weather/LocationManager.swift")

        let cardBody = try extract(
            source: cardSource,
            from: "public var body: some View",
            to: "private func synchronizeWeatherService"
        )
        XCTAssertTrue(cardBody.contains("if !settingsManager.enableRealTimeWeather"))
        XCTAssertTrue(cardBody.contains("disabledView"))
        XCTAssertTrue(cardBody.contains(".task(id: settingsManager.enableRealTimeWeather)"))
        XCTAssertLessThan(
            try XCTUnwrap(cardBody.range(of: "if !settingsManager.enableRealTimeWeather")).lowerBound,
            try XCTUnwrap(cardBody.range(of: "loadingView")).lowerBound,
            "The dashboard weather card must not show an infinite loading state while real-time weather is disabled."
        )

        let startBody = try extract(
            source: managerSource,
            from: "public func start() async",
            to: "/// 手动刷新"
        )
        XCTAssertTrue(startBody.contains("defer"))
        XCTAssertTrue(startBody.contains("lifecycleGeneration == generation"))
        XCTAssertTrue(startBody.contains("error = \"无法获取位置信息\""))
        XCTAssertTrue(startBody.contains("error = runtime.weatherService.error?.localizedDescription ?? \"无法获取天气数据\""))

        XCTAssertFalse(weatherServiceSource.contains("URLSession.shared"))
        XCTAssertFalse(locationSource.contains("URLSession.shared"))
        XCTAssertTrue(weatherServiceSource.contains("waitsForConnectivity = false"))
        XCTAssertTrue(locationSource.contains("waitsForConnectivity = false"))
    }

    func testSidebarNavigationSelectionDoesNotAnimateHeavyDashboardContent() throws {
        let sidebarSource = try readSource("Sources/SkyBridgeCompassApp/GlassSidebar.swift")
        let dashboardSource = try readSource("Sources/SkyBridgeCompassApp/Dashboard/DashboardView.swift")
        let remoteDesktopSource = try readSource("Sources/SkyBridgeCompassApp/RemoteDesktopView.swift")
        let systemMonitorViewSource = try readSource("Sources/SkyBridgeCore/SystemMonitor/SystemMonitorView.swift")
        let systemPerformanceMonitorSource = try readSource("Sources/SkyBridgeCore/Performance/SystemPerformanceMonitor.swift")
        let usbManagerSource = try readSource("Sources/SkyBridgeCore/Connection/USBCConnectionManager.swift")
        let usbViewSource = try readSource("Sources/SkyBridgeCompassApp/Views/USBDeviceManagementView.swift")
        let deviceDiscoverySource = try readSource("Sources/SkyBridgeCompassApp/Views/EnhancedDeviceDiscoveryView.swift")

        let sidebarBody = try extract(
            source: sidebarSource,
            from: "var body: some View",
            to: "// MARK: - macOS 原生窗口管理"
        )
        XCTAssertFalse(
            sidebarBody.contains(".animation(.spring(response: 0.4, dampingFraction: 0.9), value: selectedTab)"),
            "Selecting a sidebar tab must not install a broad implicit animation over the whole sidebar/root tree."
        )

        let navigationSection = try extract(
            source: sidebarSource,
            from: "private var navigationSection: some View",
            to: "// MARK: - 侧边栏本地化快照"
        )
        XCTAssertTrue(
            navigationSection.contains("guard selectedTab.id != tab.id else { return }"),
            "Repeated clicks on the already selected sidebar row should not rebuild dashboard content."
        )
        XCTAssertFalse(
            navigationSection.contains("withAnimation(.spring(response: 0.4, dampingFraction: 0.9))"),
            "The sidebar selection mutation should not wrap the dashboard detail switch in an animated transaction."
        )
        XCTAssertFalse(
            navigationSection.contains("withAnimation(.easeInOut(duration: 0.2))"),
            "Hover changes should rely on the row-local animation instead of opening a parent transaction."
        )

        XCTAssertTrue(
            sidebarSource.contains("@State private var localizedSidebarText = LocalizedSidebarText.resolve()"),
            "Sidebar labels should be resolved once per language change, not from Bundle resources on every hover/click render."
        )
        XCTAssertTrue(
            dashboardSource.contains("guard navigationItem != selectedNavigation else { return }"),
            "Dashboard selection binding should ignore duplicate selections."
        )
        XCTAssertFalse(
            dashboardSource.contains("DispatchQueue.main.async { [navigationItem]"),
            "DashboardView is already MainActor-isolated; queueing the selection update adds jitter to clicks."
        )
        XCTAssertTrue(dashboardSource.contains("@State private var didSetupLifecycle = false"))
        XCTAssertTrue(
            dashboardSource.contains("guard !didSetupLifecycle else { return }"),
            "Dashboard lifecycle hooks should not stack notification observers and timers on repeated appearances."
        )
        XCTAssertTrue(
            dashboardSource.contains("guard fpsTimer == nil else { return }"),
            "Realtime FPS polling must not create duplicate timers."
        )
        XCTAssertTrue(
            dashboardSource.contains("removeNotificationObservers()\n        let center = NotificationCenter.default"),
            "Notification observer setup should clear any prior tokens before adding new observers."
        )

        XCTAssertTrue(remoteDesktopSource.contains("bootstrapRemoteDesktopManagerIfNeeded()"))
        XCTAssertFalse(
            remoteDesktopSource.contains("remoteDesktopManager.shutdown()"),
            "Switching away from the remote desktop tab must not tear down global sessions and timers."
        )

        let systemMonitorSuspend = try extract(
            source: systemMonitorViewSource,
            from: "private func suspendViewMonitoring()",
            to: "/// 用户显式停止系统监控时，才停止共享监控器。"
        )
        XCTAssertFalse(
            systemMonitorSuspend.contains("systemPerformanceMonitor?.stopMonitoring()"),
            "Leaving the system monitor tab should cancel view-local polling, not stop the shared performance monitor."
        )
        XCTAssertTrue(
            systemPerformanceMonitorSource.contains("guard startupDelayTimer == nil else { return }"),
            "Repeated tab appearances should not keep resetting the shared monitor startup delay."
        )

        XCTAssertTrue(usbManagerSource.contains("public static let shared = USBCConnectionManager()"))
        XCTAssertTrue(usbManagerSource.contains("@Published public private(set) var lastScanCompletedAt: Date?"))
        XCTAssertTrue(usbViewSource.contains("USBCConnectionManager = .shared"))
        XCTAssertTrue(
            usbViewSource.contains("if usbManager.lastScanCompletedAt == nil"),
            "USB management should reuse the cached shared scan and reserve enumeration for first load or explicit refresh."
        )

        XCTAssertTrue(deviceDiscoverySource.contains("startDiscoveryForInitialPresentationIfNeeded()"))
        XCTAssertTrue(deviceDiscoverySource.contains("guard SettingsManager.shared.autoScanOnStartup else { return }"))
        XCTAssertTrue(deviceDiscoverySource.contains("guard !unifiedDeviceManager.isScanning else { return }"))
    }

    func testFileTransferSettingsAreNotCoupledToUnrelatedSwitches() throws {
        let source = try readSource("Sources/SkyBridgeCore/FileTransfer/FileTransferSettingsBridge.swift")
        let engine = try readSource("Sources/SkyBridgeCore/FileTransfer/FileTransferEngine.swift")
        let settingsView = try readSource("Sources/SkyBridgeCore/Views/SettingsView.swift")
        let crypto = try readSource("Sources/SkyBridgeCore/QuantumSecure/EnhancedPostQuantumCrypto.swift")

        XCTAssertFalse(source.contains("enableCompression: settings.enableConnectionEncryption"))
        XCTAssertTrue(source.contains("enableEncryption: settings.enableConnectionEncryption"))
        XCTAssertTrue(source.contains("ResumableTransferManager.shared.applyRuntimeSettings"))
        XCTAssertTrue(source.contains("autoRetryFailedTransfers: settings.autoRetryFailedTransfers"))
        XCTAssertTrue(source.contains("keepTransferHistory: settings.keepTransferHistory"))
        XCTAssertTrue(source.contains("keepSystemAwakeDuringTransfer: settings.keepSystemAwakeDuringTransfer"))
        XCTAssertTrue(source.contains("encryptionAlgorithm: settings.encryptionAlgorithm"))
        XCTAssertTrue(source.contains("settings.retryCount"))
        XCTAssertTrue(engine.contains("automaticRetryEnabled"))
        XCTAssertTrue(engine.contains("guard keepTransferHistory else { return }"))
        XCTAssertTrue(engine.contains("FileTransferPowerAssertionController"))
        XCTAssertTrue(settingsView.contains("settingsManager.encryptionAlgorithm.displayName"))
        XCTAssertFalse(settingsView.contains(#"Text("ChaCha20").tag("ChaCha20")"#))
        XCTAssertFalse(settingsView.contains(#"Text("AES-128").tag("AES-128")"#))
        XCTAssertTrue(engine.contains("pqCrypto.signPQCRequired"))
        XCTAssertTrue(engine.contains("verifyPQCRequired"))
        XCTAssertTrue(engine.contains("missing_strict_pqc_signature"))
        XCTAssertFalse(engine.contains(#"signatureAlgorithm: enablePQCFlag ? pqcAlgo : "P256""#))
        XCTAssertTrue(crypto.contains("public func signPQCRequired"))
        XCTAssertTrue(crypto.contains("public func verifyPQCRequired"))
        XCTAssertTrue(crypto.contains("Strict-PQC signing path"))
        XCTAssertTrue(crypto.contains("never falls back to P-256"))
    }

    func testDeviceIconToggleHasProductionConsumers() throws {
        let paths = [
            "Sources/SkyBridgeCompassApp/Dashboard/Components/OnlineDeviceRow.swift",
            "Sources/SkyBridgeCompassApp/Dashboard/Components/EnhancedDeviceRow.swift",
            "Sources/SkyBridgeCompassApp/Dashboard/Components/CompactDeviceRow.swift",
            "Sources/SkyBridgeCore/UI/DeviceListView.swift"
        ]

        for path in paths {
            let source = try readSource(path)
            XCTAssertTrue(source.contains("settingsManager.showDeviceIcons"), "\(path) must consume showDeviceIcons")
        }
    }

    func testWirelessSettingsNotifyRunningManagers() throws {
        let settings = try readSource("Sources/SkyBridgeCore/Settings/SettingsManager.swift")
        let wifi = try readSource("Sources/SkyBridgeCore/Device/WiFiManager.swift")
        let airplay = try readSource("Sources/SkyBridgeCore/Device/AirPlayManager.swift")
        let networkPreferences = try readSource("Sources/SkyBridgeCore/Network/NetworkPreferenceService.swift")

        XCTAssertTrue(settings.contains("postWiFiSettingsChanged([\"showHiddenNetworks\": value])"))
        XCTAssertTrue(settings.contains("postAirPlaySettingsChanged([\"autoDiscoverAppleTV\": value])"))
        XCTAssertTrue(settings.contains("$discoveryPassiveMode.sink"))
        XCTAssertTrue(settings.contains("$enableWiFiAwareDiscovery.sink"))
        XCTAssertTrue(wifi.contains("runtimeScanInterval = max(5.0, scanInterval)"))
        XCTAssertTrue(wifi.contains("userInfo[\"showHiddenNetworks\"] != nil"))
        XCTAssertTrue(airplay.contains("NotificationCenter.default.publisher(for: NSNotification.Name(\"AirPlaySettingsChanged\"))"))
        XCTAssertTrue(airplay.contains("refreshDevices()"))
        XCTAssertTrue(networkPreferences.contains("autoConnectRecommendedNetworkIfAppropriate()"))
        XCTAssertTrue(networkPreferences.contains("currentNetwork == nil"))
        XCTAssertTrue(networkPreferences.contains("recommendedNetwork?.isKnown == true"))
        XCTAssertTrue(networkPreferences.contains("applyRuntimeSettingsSnapshot(startMonitoringIfNeeded: false)"))
        XCTAssertTrue(networkPreferences.contains("public func startConfiguredNetworkMonitoring()"))
    }

    func testBackgroundScanningUsesSharedDiscoveryRuntimeSettings() throws {
        let source = try readSource("Sources/SkyBridgeCore/DeviceDiscovery/BackgroundScanningService.swift")

        XCTAssertTrue(source.contains("enableBonjourDiscovery: SettingsManager.shared.enableBonjourDiscovery"))
        XCTAssertTrue(source.contains("enableMDNSResolution: SettingsManager.shared.enableMDNSResolution"))
        XCTAssertTrue(source.contains("scanCustomPorts: SettingsManager.shared.scanCustomPorts"))
        XCTAssertTrue(source.contains("customServiceTypes: SettingsManager.shared.customServiceTypes"))
        XCTAssertTrue(source.contains("discoveryTimeout: SettingsManager.shared.discoveryTimeout"))
        XCTAssertTrue(source.contains("let scanWaitSeconds = min(max(TimeInterval(SettingsManager.shared.discoveryTimeout), 1), 60)"))
        XCTAssertFalse(source.contains("Task.sleep(nanoseconds: 10_000_000_000)"))
    }

    func testPreferXWingUsesSettingsManagerTruthSource() throws {
        let settingsView = try readSource("Sources/SkyBridgeCore/Views/SettingsView.swift")
        let preferencesView = try readSource("Sources/SkyBridgeCompassApp/PreferencesView.swift")
        let factory = try readSource("Sources/SkyBridgeCore/P2P/CryptoProviderFactory.swift")
        let selector = try readSource("Sources/SkyBridgeCore/P2P/CryptoProviderSelector.swift")
        let twoAttempt = try readSource("Sources/SkyBridgeCore/P2P/TwoAttemptHandshakeManager.swift")

        XCTAssertTrue(settingsView.contains("isOn: $settingsManager.preferXWingHybrid"))
        XCTAssertTrue(preferencesView.contains("isOn: $settingsManager.preferXWingHybrid"))
        XCTAssertFalse(settingsView.contains("@AppStorage(\"Settings.PreferXWingHybrid\")"))
        XCTAssertFalse(preferencesView.contains("@AppStorage(\"Settings.PreferXWingHybrid\")"))
        XCTAssertTrue(factory.contains("SettingsStorageKeys.preferXWingHybrid"))
        XCTAssertTrue(selector.contains("SettingsStorageKeys.preferXWingHybrid"))
        XCTAssertTrue(twoAttempt.contains("SettingsStorageKeys.preferXWingHybrid"))
        XCTAssertFalse(factory.contains("UserDefaults.standard.bool(forKey: \"Settings.PreferXWingHybrid\")"))
        XCTAssertFalse(selector.contains("UserDefaults.standard.bool(forKey: \"Settings.PreferXWingHybrid\")"))
        XCTAssertFalse(twoAttempt.contains("UserDefaults.standard.bool(forKey: \"Settings.PreferXWingHybrid\")"))
    }

    func testStrictPQCSecuritySourcesDoNotExposeFakeSuccessFallbacks() throws {
        let pake = try readSource("Sources/SkyBridgeCore/P2P/PAKEService.swift")
        let providers = try readSource("Sources/SkyBridgeCore/P2P/CryptoProviders.swift")
        let securitySettings = try readSource("Sources/SkyBridgeCore/UI/SecuritySettingsView.swift")

        XCTAssertFalse(pake.contains("\"fallback\": \"zero-nonce\""))
        XCTAssertFalse(pake.contains("return Data(repeating: 0, count: P2PConstants.nonceSize)"))
        XCTAssertTrue(pake.contains("\"action\": \"fail_closed\""))
        XCTAssertTrue(pake.contains("fatalError(\"SecRandomCopyBytes failed in PAKEMessageA.generateNonce"))
        XCTAssertTrue(pake.contains("fatalError(\"SecRandomCopyBytes failed in PAKEMessageB.generateNonce"))

        let liboqsKEMBody = try extract(
            source: providers,
            from: "public struct LiboqsKEMProvider",
            to: "// MARK: - Liboqs Signature Provider"
        )
        XCTAssertTrue(liboqsKEMBody.contains("OQSPQCCryptoProvider()"))
        XCTAssertTrue(liboqsKEMBody.contains("delegateProvider.kemEncapsulate"))
        XCTAssertTrue(liboqsKEMBody.contains("delegateProvider.kemDecapsulate"))
        XCTAssertFalse(liboqsKEMBody.contains("X25519KEMProvider()"))

        XCTAssertTrue(securitySettings.contains("CryptoProviderFactory.detectCapability()"))
        XCTAssertTrue(securitySettings.contains("cryptoCapability.hasApplePQC"))
        XCTAssertTrue(securitySettings.contains("cryptoCapability.hasLiboqs"))
        XCTAssertFalse(securitySettings.contains("#if canImport(OQSRAII)"))
    }

    func testRemoteDesktopSettingsAutosaveRuntimeMutations() throws {
        let source = try readSource("Sources/SkyBridgeCore/RemoteDesktopSettings.swift")

        XCTAssertTrue(source.contains("import Combine"))
        XCTAssertTrue(source.contains("private func bindSettingsAutosave()"))
        XCTAssertTrue(source.contains("settings.$displaySettings"))
        XCTAssertTrue(source.contains("settings.$interactionSettings"))
        XCTAssertTrue(source.contains("settings.$networkSettings"))
        XCTAssertTrue(source.contains("persistRuntimeSettingsChange()"))
        XCTAssertTrue(source.contains("guard !isLoadingSettings, !isSavingSettings else { return }"))
    }

    func testIOSBonjourAdvertisesProtocolIdentityNotLegacyMobileIdentity() throws {
        let discovery = try readSource("SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/DeviceDiscoveryManager.swift")
        let protocolIdentity = try readSource("SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Core/ProtocolDeviceIdentity.swift")

        XCTAssertTrue(discovery.contains("private func createTXTRecord(port: UInt16) async -> NWTXTRecord"))
        XCTAssertTrue(discovery.contains("await createTXTRecord(port: port)"))
        XCTAssertTrue(discovery.contains("ProtocolDeviceIdentity.stableDeviceId()"))
        XCTAssertTrue(discovery.contains("localProtocolIdentityFingerprintForAdvertisement()"))
        XCTAssertTrue(discovery.contains("SkyBridgeiOSCore.shared.getProtocolSigningPublicKey(for: algorithm)"))
        XCTAssertTrue(discovery.contains("let advertisedDeviceId = protocolDeviceId.isEmpty ? mobileStableId : protocolDeviceId"))
        XCTAssertTrue(discovery.contains("record[\"deviceId\"] = advertisedDeviceId"))
        XCTAssertTrue(discovery.contains("record[\"uniqueId\"] = advertisedDeviceId"))
        XCTAssertTrue(discovery.contains("record[\"appleMobileStableId\"] = mobileStableId"))
        XCTAssertFalse(discovery.contains("record[\"deviceId\"] = snapshot.stableDeviceId"))
        XCTAssertFalse(discovery.contains("record[\"deviceId\"] = mobileSnapshot.stableDeviceId"))

        XCTAssertTrue(protocolIdentity.contains("SkyBridge.P2P.DeviceIdentity.DeviceID"))
        XCTAssertTrue(protocolIdentity.contains("SkyBridge.DeviceId"))
        XCTAssertTrue(protocolIdentity.contains("UserDefaults.standard.string(forKey: protocolIdentityMirrorDefaultsKey)"))
        XCTAssertTrue(protocolIdentity.contains("mirrorDeviceIdToLegacyDefaultsIfNeeded"))

        let p2pModels = try readSource("SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Core/P2P/P2PModels.swift")
        let getDeviceIdBody = try extract(
            source: p2pModels,
            from: "private static func getOrCreateDeviceId() -> String",
            to: "@MainActor"
        )
        XCTAssertTrue(getDeviceIdBody.contains("ProtocolDeviceIdentity.stableDeviceId()"))
        XCTAssertFalse(
            getDeviceIdBody.contains("UUID().uuidString"),
            "Legacy iOS P2PDeviceInfo must mirror the protocol identity instead of generating a second device id that splits Bonjour/Cloud/P2P identity."
        )

        let macP2PModels = try readSource("Sources/SkyBridgeCore/P2P/P2PDeviceModels.swift")
        let macGetDeviceIdBody = try extract(
            source: macP2PModels,
            from: "private static func getOrCreateDeviceId() -> String",
            to: "private static func getDeviceName()"
        )
        XCTAssertTrue(macP2PModels.contains("SkyBridge.P2P.DeviceIdentity.DeviceID"))
        XCTAssertTrue(macP2PModels.contains("SkyBridge.DeviceId"))
        XCTAssertTrue(macGetDeviceIdBody.contains("mirrorDeviceIdToLegacyDefaultsIfNeeded"))
    }

    private func readSource(_ relativePath: String) throws -> String {
        let root = try repoRoot()
        let url = root.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func repoRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" {
            let candidate = url.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return url
            }
            url.deleteLastPathComponent()
        }
        throw NSError(domain: "SettingsRuntimeTruthSourceContractTests", code: 1)
    }

    private func extract(source: String, from start: String, to end: String) throws -> String {
        guard let startRange = source.range(of: start),
              let endRange = source.range(of: end, range: startRange.upperBound..<source.endIndex) else {
            throw NSError(domain: "SettingsRuntimeTruthSourceContractTests", code: 2)
        }
        return String(source[startRange.lowerBound..<endRange.lowerBound])
    }
}
