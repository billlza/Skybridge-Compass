import XCTest

final class SettingsViewSourceContractTests: XCTestCase {
    func testRemoteNetworkCompressionAndEncryptionControlsUseMatchingSettings() throws {
        let source = try repositorySource("Sources/SkyBridgeCore/Views/SettingsView.swift")
        let networkSection = try sourceSlice(
            from: #"settingsSection(localizationManager.localizedString("settings.remote.network.title"))"#,
            to: #"// 添加设置操作按钮"#,
            in: source
        )

        XCTAssertFalse(networkSection.contains(#"isOn: $remoteDesktopSettingsManager.settings.networkSettings.enableEncryption"#))
        XCTAssertTrue(networkSection.contains(#"Text("Strict-PQC / TLS 1.3")"#))
        XCTAssertTrue(
            networkSection.contains(#"Toggle(localizationManager.localizedString("settings.remote.network.enableCompression"), isOn: remoteNetworkCompressionEnabled)"#)
        )
        XCTAssertTrue(
            source.contains(#"get: { remoteDesktopSettingsManager.settings.networkSettings.compressionLevel > 0 }"#)
        )
        XCTAssertTrue(
            source.contains(#"remoteDesktopSettingsManager.settings.networkSettings.compressionLevel = isEnabled ? restoredLevel : 0"#)
        )
        XCTAssertFalse(
            networkSection.contains(#"settings.remote.network.enableCompression"), isOn: $remoteDesktopSettingsManager.settings.networkSettings.enableEncryption"#),
            "Compression UI must not toggle encryption."
        )
        XCTAssertFalse(networkSection.contains(#"Text("32KB").tag(32768)"#))
        XCTAssertTrue(networkSection.contains(#"Text("1MB").tag(1024)"#))
    }

    func testSystemMonitorLabelsUseMatchingSettings() throws {
        let source = try repositorySource("Sources/SkyBridgeCore/Views/SettingsView.swift")
        let configSection = try sourceSlice(
            from: #"settingsSection(localizationManager.localizedString("settings.systemMonitor.config.title"))"#,
            to: #"settingsSection(localizationManager.localizedString("settings.systemMonitor.display.title"))"#,
            in: source
        )
        let displaySection = try sourceSlice(
            from: #"settingsSection(localizationManager.localizedString("settings.systemMonitor.display.title"))"#,
            to: #"settingsSection(localizationManager.localizedString("settings.systemMonitor.alerts.title"))"#,
            in: source
        )
        let alertsSection = try sourceSlice(
            from: #"settingsSection(localizationManager.localizedString("settings.systemMonitor.alerts.title"))"#,
            to: #"settingsSection(localizationManager.localizedString("settings.systemMonitor.advanced.title"))"#,
            in: source
        )

        XCTAssertTrue(
            configSection.contains(#"Text(localizationManager.localizedString("settings.systemMonitor.config.maxHistoryPoints"))"#)
        )
        XCTAssertTrue(
            configSection.contains(#"Slider(value: $settingsManager.maxHistoryPoints, in: 50...2000, step: 50)"#)
        )
        XCTAssertTrue(
            displaySection.contains(#"Toggle(localizationManager.localizedString("settings.systemMonitor.display.temperature"), isOn: $settingsManager.showMonitorTemperature)"#)
        )
        XCTAssertTrue(
            alertsSection.contains(#"Toggle(localizationManager.localizedString("settings.systemMonitor.alerts.enableTemperatureMonitoring"), isOn: $settingsManager.enableTemperatureMonitoring)"#)
        )
        XCTAssertTrue(
            displaySection.contains(#"Toggle(localizationManager.localizedString("settings.systemMonitor.display.fanSpeed"), isOn: $settingsManager.showMonitorFanSpeed)"#)
        )
        XCTAssertTrue(
            alertsSection.contains(#"Toggle(localizationManager.localizedString("settings.systemMonitor.alerts.enableFanSpeedMonitoring"), isOn: $settingsManager.enableFanSpeedMonitoring)"#)
        )
        XCTAssertFalse(
            configSection.contains(#"Text(localizationManager.localizedString("settings.systemMonitor.config.enableHistory"))"#),
            "History point slider must not reuse the enable-history label."
        )
        XCTAssertFalse(
            alertsSection.contains(#"settings.systemMonitor.display.temperature"), isOn: $settingsManager.enableTemperatureMonitoring"#),
            "Temperature monitoring toggle must not use the display-temperature label."
        )
        XCTAssertFalse(
            alertsSection.contains(#"settings.systemMonitor.display.fanSpeed"), isOn: $settingsManager.enableFanSpeedMonitoring"#),
            "Fan monitoring toggle must not use the display-fan label."
        )
    }

    func testSettingsViewLabelKeysAreLocalized() throws {
        let requiredKeys = [
            "status.unavailable",
            "settings.remote.network.enableEncryption",
            "settings.systemMonitor.config.maxHistoryPoints",
            "settings.systemMonitor.alerts.enableTemperatureMonitoring",
            "settings.systemMonitor.alerts.enableFanSpeedMonitoring",
            "settings.general.cacheSize.unavailable",
            "settings.general.cache.clearing",
            "settings.general.cache.clearComplete",
            "settings.general.cache.clearFailed",
            "settings.general.cache.sizeFailed"
        ]

        for locale in ["en.lproj", "zh-Hans.lproj", "ja.lproj"] {
            let source = try repositorySource("Sources/SkyBridgeCore/Resources/\(locale)/Localizable.strings")
            for key in requiredKeys {
                XCTAssertTrue(source.contains("\"\(key)\" ="), "\(key) missing from \(locale)")
            }
        }
    }

    func testCacheManagementFileIOStaysOutOfSettingsView() throws {
        let settingsSource = try repositorySource("Sources/SkyBridgeCore/Views/SettingsView.swift")
        let cacheServiceSource = try repositorySource("Sources/SkyBridgeCore/Settings/ApplicationCacheService.swift")

        XCTAssertTrue(settingsSource.contains("private let applicationCacheService = ApplicationCacheService.shared"))
        XCTAssertTrue(settingsSource.contains(".task(id: selectedTab)"))
        XCTAssertTrue(settingsSource.contains("try await applicationCacheService.cacheUsageSnapshot()"))
        XCTAssertTrue(settingsSource.contains("try await applicationCacheService.clearCaches()"))
        XCTAssertFalse(settingsSource.contains("getFormattedCacheSize()"))
        XCTAssertFalse(settingsSource.contains("FileManager.default.urls(for: .cachesDirectory"))

        XCTAssertTrue(cacheServiceSource.contains("public actor ApplicationCacheService"))
        XCTAssertTrue(cacheServiceSource.contains("case scanFailed([CacheOperationFailure])"))
        XCTAssertTrue(cacheServiceSource.contains("case clearFailed(CacheClearResult)"))
        XCTAssertFalse(cacheServiceSource.contains("try?"))
    }

    func testMetalHUDSettingsControlRenderedRootOverlay() throws {
        let settingsSource = try repositorySource("Sources/SkyBridgeCore/Views/SettingsView.swift")
        let appSource = try repositorySource("Sources/SkyBridgeCompassApp/SkyBridgeCompassApp.swift")
        let hudSource = try repositorySource("Sources/SkyBridgeCore/Performance/MetalPerformanceHUD.swift")

        XCTAssertTrue(hudSource.contains("public static let shared: MetalPerformanceHUD"))
        XCTAssertTrue(hudSource.contains("public var isAvailable: Bool"))
        XCTAssertTrue(settingsSource.contains("@StateObject private var hud = MetalPerformanceHUD.shared"))
        XCTAssertTrue(settingsSource.contains(".disabled(!hud.isAvailable)"))
        XCTAssertTrue(appSource.contains("@StateObject private var performanceHUD = MetalPerformanceHUD.shared"))
        XCTAssertTrue(appSource.contains("MetalPerformanceHUDView(hud: performanceHUD)"))
        XCTAssertFalse(settingsSource.contains("if hud.isEnabled {\n                            Divider()"))
    }

    func testPQCSignaturePickerOnlyExposesImplementedAlgorithms() throws {
        let settingsSource = try repositorySource("Sources/SkyBridgeCore/Views/SettingsView.swift")
        let settingsManagerSource = try repositorySource("Sources/SkyBridgeCore/Settings/SettingsManager.swift")
        let securitySettingsSource = try repositorySource("Sources/SkyBridgeCore/UI/SecuritySettingsView.swift")

        XCTAssertTrue(settingsSource.contains(#"Text("ML-DSA-65 · Category 3")"#))
        XCTAssertTrue(settingsSource.contains(#"Text("ML-DSA-87 · Category 5")"#))
        XCTAssertTrue(settingsSource.contains(#".tag(ProtocolSigningAlgorithm.mlDSA87)"#))
        XCTAssertTrue(settingsSource.contains(#""主协议 ML-DSA 私钥使用 Secure Enclave""#))
        XCTAssertTrue(settingsSource.contains("启用失败不会回退软件密钥"))
        XCTAssertFalse(settingsSource.contains(#"Text("SLH-DSA").tag("SLH-DSA")"#))
        XCTAssertFalse(settingsSource.contains(#"Text("Falcon").tag("Falcon")"#))
        XCTAssertTrue(settingsManagerSource.contains(#"@Published public var pqcSignatureAlgorithm: String = "ML-DSA-65""#))
        XCTAssertTrue(settingsManagerSource.contains(#"case "ML-DSA", "ML-DSA-65", "MLDSA", "MLDSA-65":"#))
        XCTAssertTrue(settingsManagerSource.contains(#"case "ML-DSA-87", "MLDSA-87":"#))
        XCTAssertTrue(securitySettingsSource.contains("仅对已认证并持久化 87 pin 的 peer 生效"))
        XCTAssertTrue(securitySettingsSource.contains("该精确密钥槽失败时绝不回退软件密钥"))
        XCTAssertFalse(securitySettingsSource.contains("尚未接入生产身份信任链"))
    }

    func testPQCEnablementIsReadOnlyRuntimePolicyNotAUserToggle() throws {
        let settingsSource = try repositorySource("Sources/SkyBridgeCore/Views/SettingsView.swift")
        let settingsManagerSource = try repositorySource("Sources/SkyBridgeCore/Settings/SettingsManager.swift")
        let securitySettingsSource = try repositorySource("Sources/SkyBridgeCore/UI/SecuritySettingsView.swift")

        XCTAssertFalse(settingsSource.contains(#"Toggle(localizationManager.localizedString("settings.advanced.pqc.enableAppLayer"), isOn: $settingsManager.enablePQC)"#))
        XCTAssertFalse(securitySettingsSource.contains(#"Toggle(isOn: $settingsManager.enablePQC)"#))
        XCTAssertTrue(settingsManagerSource.contains(#"enablePQC = true"#))
        XCTAssertTrue(settingsManagerSource.contains(#"userDefaults.set(true, forKey: "Settings.EnablePQC")"#))
        XCTAssertFalse(securitySettingsSource.contains(#"value: "TLS 1.3""#))
        XCTAssertFalse(securitySettingsSource.contains(#"value: "AES-256-GCM""#))
        XCTAssertFalse(securitySettingsSource.contains(#"value: "ECDH P-256""#))
        XCTAssertTrue(securitySettingsSource.contains(#"value: activePQCKeyExchangeText"#))
    }

    func testRemoteDesktopSettingsAreBoundToRuntimeConsumers() throws {
        let settingsView = try repositorySource("Sources/SkyBridgeCore/Views/SettingsView.swift")
        let remoteSettings = try repositorySource("Sources/SkyBridgeCore/RemoteDesktopSettings.swift")
        let budget = try repositorySource("Sources/SkyBridgeCore/RemoteConnection/WebRTC/WebRTCRemoteDesktopBudget.swift")
        let crossNetwork = try repositorySource("Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift")
        let webRTCFileTransfer = try repositorySource("Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager+WebRTCFileTransfer.swift")
        let rdpManager = try repositorySource("Sources/SkyBridgeCore/RemoteDesktopManager.swift")
        let remoteControlManager = try repositorySource("Sources/SkyBridgeCore/RemoteControl/RemoteControlManager.swift")
        let screenCaptureStreamer = try repositorySource("Sources/SkyBridgeCore/RemoteControl/ScreenCaptureKitStreamer.swift")
        let sshClient = try repositorySource("Sources/SkyBridgeCore/RemoteConnection/SSHClientImpl.swift")
        let sshSession = try repositorySource("Sources/SkyBridgeCore/RemoteConnection/SSHSession.swift")
        let vncClient = try repositorySource("Sources/SkyBridgeCore/RemoteConnection/VNCClientImpl.swift")
        let appRemoteView = try repositorySource("Sources/SkyBridgeCompassApp/RemoteDesktopView.swift")
        let nearFieldView = try repositorySource("Sources/SkyBridgeCompassApp/Views/NearFieldMirrorView.swift")

        XCTAssertTrue(settingsView.contains("displaySettings.targetFrameRate = videoSettingsManager.selectedFrameRate.rawValue"))
        XCTAssertTrue(settingsView.contains("videoFrameRate("))
        XCTAssertTrue(settingsView.contains("fromTargetFrameRate: displaySettings.targetFrameRate"))
        XCTAssertTrue(remoteSettings.contains("public mutating func enforceStrictTransportSecurity()"))
        XCTAssertTrue(remoteSettings.contains("userDefaults.set(true, forKey: \"\\(prefix)enableEncryption\")"))
        XCTAssertTrue(settingsView.contains("Text(\"Strict-PQC / TLS 1.3\")"))
        XCTAssertTrue(budget.contains("bandwidthLimitMbps: Double = 0"))
        XCTAssertTrue(budget.contains("enableAdaptiveQuality: Bool = true"))
        XCTAssertTrue(budget.contains("maxBufferedAmountOverrideBytes: UInt64? = nil"))
        XCTAssertTrue(crossNetwork.contains("networkSettings.boundedBandwidthLimitMbps"))
        XCTAssertTrue(crossNetwork.contains("networkSettings.maxBufferedAmountOverrideBytes"))
        XCTAssertTrue(crossNetwork.contains("networkSettings.boundedConnectionTimeoutSeconds"))
        XCTAssertTrue(crossNetwork.contains("remoteDesktopReconnectBackoffDelayMilliseconds(forAttempt:"))
        XCTAssertTrue(crossNetwork.contains("settings.networkSettings.enableNetworkStats"))
        XCTAssertTrue(crossNetwork.contains("udp_transport_disabled_by_settings"))
        XCTAssertTrue(crossNetwork.contains("compressionLevel: RemoteDesktopSettingsManager.shared.settings.networkSettings.boundedCompressionLevel"))
        XCTAssertTrue(webRTCFileTransfer.contains("interactionSettings.enableFileTransfer"))
        XCTAssertTrue(crossNetwork.contains("remote_desktop_file_transfer_disabled_by_settings"))
        XCTAssertTrue(remoteSettings.contains("public var boundedCompressionLevelPercent: Int"))
        XCTAssertTrue(remoteSettings.contains("public var boundedDoubleClickIntervalMilliseconds: Int"))
        XCTAssertTrue(remoteSettings.contains("public func reconnectBackoffDelayMilliseconds(forAttempt attempt: Int) -> Int"))
        XCTAssertTrue(rdpManager.contains("interactionSettings.enableTrackpadGestures"))
        XCTAssertTrue(rdpManager.contains("interactionSettings.scrollSensitivity"))
        XCTAssertTrue(rdpManager.contains("settings.mouseSensitivity"))
        XCTAssertTrue(rdpManager.contains("\"compressionLevel\": settings.displaySettings.boundedCompressionLevelPercent"))
        XCTAssertTrue(rdpManager.contains("\"connectionTimeout\": settings.networkSettings.boundedConnectionTimeoutSeconds * 1_000"))
        XCTAssertTrue(remoteControlManager.contains("boundedDoubleClickIntervalMilliseconds"))
        XCTAssertTrue(remoteControlManager.contains("videoCompressionLevel: settings.displaySettings.boundedCompressionLevelPercent"))
        XCTAssertTrue(screenCaptureStreamer.contains("settings.displaySettings.boundedCompressionLevelPercent"))
        XCTAssertTrue(sshClient.contains("connectionTimeout: TimeInterval(networkSettings.boundedConnectionTimeoutSeconds)"))
        XCTAssertTrue(sshClient.contains("timeoutPromise.fail(SSHClientImplError.timeout)"))
        XCTAssertTrue(sshSession.contains("boundedReconnectBackoffInitialMilliseconds"))
        XCTAssertTrue(vncClient.contains("VNCConnectionContinuationGate"))
        XCTAssertTrue(vncClient.contains("configuration.connectionTimeout"))
        XCTAssertTrue(nearFieldView.contains("RemoteDesktopSettingsManager.shared.settings.interactionSettings"))
        XCTAssertTrue(nearFieldView.contains("interactionSettings.enableContextMenu"))
        XCTAssertTrue(appRemoteView.contains("remoteDesktopScopeDescription"))
        XCTAssertTrue(appRemoteView.contains("Strict-PQC / TLS 1.3"))
        XCTAssertTrue(appRemoteView.contains("toggleRemoteDesktopFullScreen"))
        XCTAssertTrue(appRemoteView.contains("RemoteDesktopSettingsManager.shared.settings.$displaySettings"))
        XCTAssertTrue(appRemoteView.contains("targetWindow?.toggleFullScreen(nil)"))
    }

    private func repositorySource(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func sourceSlice(from startMarker: String, to endMarker: String, in source: String) throws -> String {
        guard let start = source.range(of: startMarker)?.lowerBound,
              let end = source.range(of: endMarker, range: start..<source.endIndex)?.lowerBound else {
            throw SourceSliceError(startMarker: startMarker, endMarker: endMarker)
        }
        return String(source[start..<end])
    }

    private struct SourceSliceError: Error, CustomStringConvertible {
        let startMarker: String
        let endMarker: String

        var description: String {
            "Source slice not found from '\(startMarker)' to '\(endMarker)'"
        }
    }
}
