import XCTest

final class MacTrustedDeviceTrustActionsTests: XCTestCase {
    func testMacTrustedDeviceDetailSplitsRepairAndFullForgetSemantics() throws {
        let detailSource = try repositorySource("Sources/SkyBridgeCompassApp/Views/TrustedDeviceDetailView.swift")
        let discoverySource = try repositorySource("Sources/SkyBridgeCompassApp/Views/EnhancedDeviceDiscoveryView.swift")

        XCTAssertTrue(detailSource.contains("onRepairP2PTrust"))
        XCTAssertTrue(detailSource.contains("修复 P2P 信任"))
        XCTAssertTrue(detailSource.contains("Repair P2P Trust"))
        XCTAssertTrue(detailSource.contains("彻底忘记设备"))
        XCTAssertTrue(detailSource.contains("Forget Device"))
        XCTAssertFalse(detailSource.contains("Label(ui(chinese: \"移除信任\""))

        XCTAssertTrue(discoverySource.contains("PeerBootstrapTrustMaterialCleanup.repairP2PTrust(deviceIds: idsToRepair)"))
        XCTAssertTrue(discoverySource.contains("let idsToForget = Array(Set(idsToRevoke + [declaredDeviceId].compactMap { $0 }))"))
        XCTAssertTrue(discoverySource.contains("PeerBootstrapTrustMaterialCleanup.forgetDevice(deviceIds: idsToForget)"))

        let repairRange = try XCTUnwrap(discoverySource.range(of: "onRepairP2PTrust"))
        let repairCleanupRange = try XCTUnwrap(discoverySource.range(of: "PeerBootstrapTrustMaterialCleanup.repairP2PTrust"))
        let forgetRange = try XCTUnwrap(discoverySource.range(of: "onRemoveTrust"))
        let forgetCleanupRange = try XCTUnwrap(discoverySource.range(of: "PeerBootstrapTrustMaterialCleanup.forgetDevice"))

        XCTAssertLessThan(repairRange.lowerBound, repairCleanupRange.lowerBound)
        XCTAssertLessThan(forgetRange.lowerBound, forgetCleanupRange.lowerBound)
    }

    func testMacCloudDeviceConnectButtonsUseRealConnectionPaths() throws {
        let discoverySource = try repositorySource("Sources/SkyBridgeCompassApp/Views/EnhancedDeviceDiscoveryView.swift")
        let viewModelSource = try repositorySource("Sources/SkyBridgeCompassApp/ViewModels/CloudDeviceListViewModel.swift")
        let crossNetworkSource = try repositorySource("Sources/SkyBridgeCompassApp/Views/CrossNetworkConnectionView.swift")
        let unifiedSource = try repositorySource("Sources/SkyBridgeCore/DeviceDiscovery/UnifiedOnlineDeviceManager.swift")
        let coordinatorSource = try repositorySource("Sources/SkyBridgeCompassApp/Services/OnlineDeviceConnectionCoordinator.swift")
        let p2pDiscoverySource = try repositorySource("Sources/SkyBridgeCore/P2P/P2PDiscoveryService.swift")
        let appSource = try repositorySource("Sources/SkyBridgeCompassApp/SkyBridgeCompassApp.swift")
        let remoteSmokeScript = try repositorySource("Scripts/run_real_device_p2p_remote_smoke.sh")
        let iosP2PSmokeHarnessSource = try repositorySource("SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/App/Smoke/LocalP2PSmokeHarness.swift")
        let rustMacIpadGateSource = try repositorySource("rust/crates/skybridge-cli/src/p2p_remote_performance_evidence/mac_ipad_online.rs")
        let rustMacIpadTestsSource = try repositorySource("rust/crates/skybridge-cli/src/performance_tests/p2p_remote/mac_ipad_online.rs")
        let xcodeProjectSource = try repositorySource("SkyBridgeWidgets.xcodeproj/project.pbxproj")

        XCTAssertTrue(
            discoverySource.contains("connectToCloudDevice(device)"),
            "Cloud/iCloud rows in the main discovery UI must call the real connect path."
        )
        XCTAssertTrue(
            discoverySource.contains("connectToOnlineDevice(liveDevice)"),
            "When local Bonjour/P2P already sees the iPad, iCloud rows should prefer the direct local connect path."
        )
        XCTAssertTrue(
            discoverySource.contains("unifiedDeviceManager.resolvedOnlineDevice(for: device)"),
            "Mac UI should merge live local discovery into iCloud row reachability before showing an offline state."
        )
        XCTAssertTrue(
            viewModelSource.contains("OnlineDeviceConnectionCoordinator.connect(to: liveDevice)"),
            "The shared iCloud device view model must perform a real local P2P connect, not call the incomplete KVS offer path."
        )
        XCTAssertTrue(
            viewModelSource.contains("UnifiedOnlineDeviceManager.shared.hasResolvedConnectableControlRoute(for: liveDevice)"),
            "The shared iCloud device view model must reject heartbeat-only online rows that do not have a real local control route."
        )
        XCTAssertTrue(
            viewModelSource.contains("CloudDevicePresentationPolicy.visibleICloudDevices"),
            "The shared iCloud device view model must present a de-duplicated iCloud section instead of exposing raw KVS rows."
        )
        XCTAssertTrue(
            discoverySource.contains("deviceChainViewModel.authorizedDevices") &&
            crossNetworkSource.contains("deviceChainViewModel.authorizedDevices"),
            "Main and cross-network iCloud sections must render the de-duplicated presentation list."
        )
        XCTAssertFalse(
            viewModelSource.contains("liveDevice.connectionStatus != .offline || liveDevice.isConnectable"),
            "Cloud-device actions must not treat generic online state as proof that the Connect button can dial a real route."
        )
        XCTAssertTrue(
            coordinatorSource.contains("resolvedConnectableDiscoveredCandidates(for: device, limit: 6)") &&
            coordinatorSource.contains("P2PDiscoveryError.noConnectableEndpoint"),
            "Endpoint validation belongs in the shared coordinator so UI buttons can stay on their production behavior while fake endpoints still fail closed."
        )
        XCTAssertFalse(
            viewModelSource.contains("SkyBridgeLogger.discovery.info(\"Connecting to device:"),
            "A log-only iCloud connect button is a fake action and must not return."
        )
        XCTAssertFalse(
            viewModelSource.contains("CrossNetworkConnectionManager.shared.connectToCloudDevice"),
            "Cloud-device list actions must not wait on the iCloud offer/answer path until iOS has a responder."
        )
        XCTAssertTrue(
            crossNetworkSource.contains("unifiedDeviceManager.startDiscovery()"),
            "The cross-network window should start local discovery so live iPad presence can refresh stale iCloud rows."
        )
        XCTAssertTrue(
            crossNetworkSource.contains("OnlineDeviceConnectionCoordinator.connect(to: liveDevice)"),
            "CrossNetwork iCloud rows must prefer the same real Bonjour/P2P connection path as the main discovery UI."
        )
        XCTAssertTrue(
            discoverySource.contains("unifiedDeviceManager.hasResolvedConnectableControlRoute(for: liveDevice)") &&
            crossNetworkSource.contains("unifiedDeviceManager.hasResolvedConnectableControlRoute(for: liveDevice)"),
            "Cloud/iCloud connect entries must require the same resolved control route before delegating to the online-device connector."
        )
        XCTAssertFalse(
            crossNetworkSource.contains("liveDevice.connectionStatus != .offline || liveDevice.isConnectable"),
            "CrossNetwork iCloud rows must not use online status alone as connectability evidence."
        )
        XCTAssertFalse(
            crossNetworkSource.contains("deviceChainViewModel.connectToDeviceAsync(device)"),
            "CrossNetwork iCloud rows must not delegate back to the incomplete KVS offer/answer action."
        )
        XCTAssertTrue(
            crossNetworkSource.contains("connectingCloudDeviceId"),
            "The cross-network iCloud button must show an in-flight state instead of looking like a no-op."
        )
        XCTAssertTrue(
            crossNetworkSource.contains("deviceChainViewModel.errorMessage"),
            "The cross-network iCloud button must surface connection failures in the current UI."
        )
        XCTAssertTrue(
            discoverySource.contains("canConnect: unifiedDeviceManager.hasResolvedConnectableControlRoute(for: device)") &&
            discoverySource.contains("!device.isLocalDevice && effectiveConnectionStatus == .online && canConnect") &&
            crossNetworkSource.contains(".disabled(isConnecting)"),
            "Online-device Connect buttons must only be visible for rows with a resolved SkyBridge control route."
        )
        XCTAssertFalse(
            discoverySource.contains("canConnectCloudDevice(") ||
            discoverySource.contains(".disabled(!canConnectCloudDevice(device))") ||
            crossNetworkSource.contains("canConnectCloudDevice(") ||
            crossNetworkSource.contains(".disabled(isConnecting || !canConnect)"),
            "Cloud/iCloud rows must not introduce a separate fake connectability policy."
        )
        XCTAssertTrue(
            discoverySource.contains("OnlineDeviceConnectionCoordinator.connect(") &&
            !discoverySource.contains("MacOnlineDeviceSmokeEvidence.appendConnectButton") &&
            !discoverySource.contains("MacOnlineDeviceSmokeEvidence.appendOnlineRow"),
            "Online-device rows must keep production behavior; smoke-only click/row evidence belongs outside the visible view code."
        )
        XCTAssertFalse(
            crossNetworkSource.contains(".disabled(isConnecting || !device.isConnectable)"),
            "Cross-network iCloud rows must not change visible button enablement to satisfy smoke tests."
        )
        XCTAssertFalse(
            coordinatorSource.contains("MacOnlineDeviceSmokeEvidence"),
            "The production coordinator must not own smoke-only evidence formatting."
        )
        XCTAssertFalse(
            coordinatorSource.contains("mac-online-connect action=button targetFamily=ipad"),
            "The production coordinator must not pretend to be the UI click source; the Accessibility helper records the external button press."
        )
        XCTAssertFalse(
            coordinatorSource.contains("SKYBRIDGE_SMOKE_STATUS_FILE"),
            "The production coordinator must not subscribe to the generic smoke status channel."
        )
        XCTAssertFalse(
            coordinatorSource.contains("SKYBRIDGE_ONLINE_CONNECT_STATUS_FILE") ||
            coordinatorSource.contains("mac-online-connect-start") ||
            coordinatorSource.contains("mac-online-connect-result"),
            "The production coordinator must not write Mac online iPad artifact evidence; external Accessibility observation owns that proof."
        )
        XCTAssertTrue(
            rustMacIpadGateSource.contains("clickSource\", \"accessibility\"") &&
            rustMacIpadGateSource.contains("clickMechanism\", \"AXUIElementPerformAction\"") &&
            rustMacIpadGateSource.contains("is_external_ax_connected_result") &&
            rustMacIpadGateSource.contains("targetRowBound"),
            "The Rust artifact gate must require an external Accessibility click bound to the visible online row and an external connected-row observation."
        )
        XCTAssertTrue(
            rustMacIpadTestsSource.contains("mac-online-device-ui targetFamily=ipad") &&
            rustMacIpadTestsSource.contains("mac-online-connect-start targetFamily=ipad") &&
            rustMacIpadTestsSource.contains("mac-online-connect-result action=button targetFamily=ipad result=success") &&
            rustMacIpadTestsSource.contains("status=connected") &&
            rustMacIpadTestsSource.contains("identityKey=ipad-stable-1"),
            "Mac online/connect evidence must bind the visible row, click, connect start, and connected-row result to the same identity."
        )
        XCTAssertTrue(
            coordinatorSource.contains("P2PDiscoveryError.noConnectableEndpoint"),
            "Connect evidence must fail closed when no real endpoint candidate exists."
        )
        XCTAssertFalse(
            appSource.contains("MacOnlineIpadSmokeHarness") ||
            appSource.contains("SKYBRIDGE_UI_SMOKE_HARNESS") ||
            appSource.contains("macOnlineIpadSmokeHarness"),
            "Mac online iPad smoke must not hook the production app/root UI lifecycle."
        )
        XCTAssertTrue(
            discoverySource.contains("boot") &&
            discoverySource.contains("role=mac-online-ipad-client") &&
            discoverySource.contains("process=SkyBridgeCompassApp") &&
            discoverySource.contains("uiRole=root-container") &&
            discoverySource.contains("source=app") &&
            discoverySource.contains("pid=\\(ProcessInfo.processInfo.processIdentifier)"),
            "The dashboard/root-container boot evidence must be emitted by the real Mac app view task, not prewritten by the shell harness."
        )
        XCTAssertTrue(
            discoverySource.contains("@ObservedObject private var presenceService = ConnectionPresenceService.shared") &&
            discoverySource.contains("matchingPresenceConnection(for: device) == nil ? device.connectionStatus : .connected") &&
            discoverySource.contains("effectiveConnectionStatus(for: device).rawValue") &&
            discoverySource.contains("presenceService.activeConnections") &&
            discoverySource.contains("settingsManager.showConnectionStats || effectiveConnectionStatus == .connected") &&
            discoverySource.contains(".accessibilityValue(Text(statusText))") &&
            discoverySource.contains("onlineDeviceConnectionErrorMessage") &&
            discoverySource.contains("mac-online-connect-app") &&
            discoverySource.contains("evidenceSource=app-action") &&
            discoverySource.contains(".accessibilityAction") &&
            discoverySource.contains("onConnect()"),
            "Mac online rows must derive connected truth from ConnectionPresenceService, expose connected state even when optional stats are hidden, and surface app-side connection failures in the local-scan UI."
        )
        XCTAssertTrue(
            iosP2PSmokeHarnessSource.contains("SKYBRIDGE_SMOKE_PQC_REPORT_BASENAME") &&
            iosP2PSmokeHarnessSource.contains("exportLocalPQCIdentityIfNeeded") &&
            iosP2PSmokeHarnessSource.contains("P2PKEMIdentityKeyStore.shared.getOrCreateBootstrapPublicKeys()") &&
            iosP2PSmokeHarnessSource.contains("reportJSONBase64=\\(data.base64EncodedString())"),
            "The real-device iOS smoke must export the actual iPad KEM identity used to precondition the reverse Mac-to-iPad button test through an app-authored report."
        )
        XCTAssertFalse(
            iosP2PSmokeHarnessSource.contains("pqc-report-inline"),
            "The iOS smoke must not use legacy inline/reconstructed PQC report fallbacks."
        )
        XCTAssertFalse(
            remoteSmokeScript.contains("-DSKYBRIDGE_UI_SMOKE_HARNESS"),
            "Real-device smoke must not compile a special production UI lifecycle branch to make the online iPad row appear."
        )
        XCTAssertTrue(
            remoteSmokeScript.contains("copy_ios_app_cache_file()") &&
            remoteSmokeScript.contains("remote_path=\"Library/Caches/$remote_name\"") &&
            remoteSmokeScript.contains("run_with_hard_timeout \"$IOS_COPY_HARD_TIMEOUT_SECONDS\"") &&
            remoteSmokeScript.contains("--timeout \"$IOS_COPY_TIMEOUT_SECONDS\"") &&
            remoteSmokeScript.contains("--json-output \"$json_log\"") &&
            remoteSmokeScript.contains("--log-output \"$devicectl_log\"") &&
            remoteSmokeScript.contains("copy_ios_app_cache_file \"$IOS_PQC_REPORT_NAME\" \"$IOS_PQC_REPORT\" \"pqc-report\"") &&
            remoteSmokeScript.contains("ios-copy-pqc-report.log"),
            "Real-device smoke must copy the iOS PQC report from the app container with bounded devicectl diagnostics instead of silently treating a missing file as proof."
        )
        XCTAssertTrue(
            remoteSmokeScript.contains("materialize_ios_pqc_report_from_app_authored_status") &&
            remoteSmokeScript.contains("reportJSONBase64") &&
            remoteSmokeScript.contains("base64.b64decode(match.group(1), validate=True)") &&
            remoteSmokeScript.contains("iOS PQC report materialized from app-authored status"),
            "When CoreDevice file service is unavailable, the Mac online proof must consume the same iOS-authored PQC report from the live status stream instead of reconstructing keys in shell."
        )
        XCTAssertFalse(
            remoteSmokeScript.contains("subprocess.DEVNULL") ||
            remoteSmokeScript.contains("extract_ios_pqc_report_from_status") ||
            remoteSmokeScript.contains("pqc-report-inline"),
            "The Mac online iPad proof must not hide devicectl failures or reconstruct trusted KEM identity from status text."
        )
        XCTAssertTrue(
            remoteSmokeScript.contains("run_mac_online_ipad_button_smoke") &&
            remoteSmokeScript.contains("load_ios_pqc_report_for_mac_online") &&
            remoteSmokeScript.contains("start_macos_online_ipad_client") &&
            remoteSmokeScript.contains("find_macos_online_ipad_client_pid") &&
            remoteSmokeScript.contains("launch method=open-app-bundle pid=%s role=mac-online-ipad-client") &&
            remoteSmokeScript.contains("launch requested role=mac-online-ipad-client") &&
            remoteSmokeScript.contains("SKYBRIDGE_SMOKE_PQC_REPORT_BASENAME") &&
            remoteSmokeScript.contains("SKYBRIDGE_PQC_PEER_DEVICE_ID") &&
            remoteSmokeScript.contains("press_mac_online_ipad_connect_button") &&
            remoteSmokeScript.contains("observe_mac_online_ipad_connected_row") &&
            remoteSmokeScript.contains("run_stdin_command_with_hard_timeout 20 swift -") &&
            remoteSmokeScript.contains("subprocess.Popen(command, stdin=subprocess.PIPE)") &&
            remoteSmokeScript.contains("kAXIdentifierAttribute") &&
            remoteSmokeScript.contains("appendButtonClickEvidence") &&
            remoteSmokeScript.contains("clickSource=accessibility") &&
            remoteSmokeScript.contains("clickAssist=\\(didCenterClick ? \"CGEventCenterClick\" : \"none\")") &&
            remoteSmokeScript.contains("clickElementCenter") &&
            remoteSmokeScript.contains("CGEvent(mouseEventSource:") &&
            remoteSmokeScript.contains("targetRowBound=\\(targetRowBound ? 1 : 0)") &&
            remoteSmokeScript.contains("status=connected") &&
            remoteSmokeScript.contains("fail_if_forbidden_fallback_evidence") &&
            remoteSmokeScript.contains("MAC_ONLINE_RUNTIME_DIR=\"${TMPDIR:-/tmp}/skybridge-mac-online-${RUN_ID}\"") &&
            remoteSmokeScript.contains("MAC_ONLINE_STATUS_ARTIFACT=\"$ARTIFACT_DIR/mac-online-ipad.status.log\"") &&
            remoteSmokeScript.contains("MAC_ONLINE_STATUS=\"$MAC_ONLINE_RUNTIME_DIR/mac-online-ipad.status.log\"") &&
            remoteSmokeScript.contains("MAC_ONLINE_RUNTIME_APP_BUNDLE=\"$MAC_ONLINE_RUNTIME_DIR/SkyBridge Compass Pro.app\"") &&
            remoteSmokeScript.contains("ditto \"$MAC_ONLINE_PACKAGED_APP_BUNDLE\" \"$MAC_ONLINE_RUNTIME_APP_BUNDLE\"") &&
            remoteSmokeScript.contains("MAC_ONLINE_APP_BUNDLE=\"$MAC_ONLINE_RUNTIME_APP_BUNDLE\"") &&
            remoteSmokeScript.contains("canonical_macos_online_ipad_client_bin") &&
            remoteSmokeScript.contains("pwd -P") &&
            remoteSmokeScript.contains("cp -f \"$MAC_ONLINE_STATUS\" \"$MAC_ONLINE_STATUS_ARTIFACT\"") &&
            remoteSmokeScript.contains("SKYBRIDGE_SMOKE_STATUS_FILE=\"$MAC_ONLINE_STATUS\"") &&
            remoteSmokeScript.contains("SKYBRIDGE_TARGET_IPAD_IDENTITY=\"$IOS_PQC_DEVICE_ID\"") &&
            remoteSmokeScript.contains("No connected real iPad found") &&
            remoteSmokeScript.contains("validate_real_ipad_device_id") &&
            remoteSmokeScript.contains("Selected real-device target is not a connected iPad according to devicectl JSON") &&
            !remoteSmokeScript.contains("SKYBRIDGE_SMOKE_ALLOW_NON_IPAD_DEVICE") &&
            remoteSmokeScript.contains("require_remote_control_notice_identity_env") &&
            remoteSmokeScript.contains("SKYBRIDGE_SMOKE_LOCAL_ACCOUNT_DISPLAY_NAME") &&
            remoteSmokeScript.contains("SKYBRIDGE_SMOKE_LOCAL_NEBULA_ID") &&
            remoteSmokeScript.contains("wait_for_remote_control_notice_lifecycle") &&
            remoteSmokeScript.contains("remoteControlNoticeShown .*transport=p2p") &&
            remoteSmokeScript.contains("remoteControlNoticeActive .*transport=p2p") &&
            remoteSmokeScript.contains("terminate_ios_remote_smoke_app_for_notice_disconnect") &&
            remoteSmokeScript.contains("remoteControlNoticeDisconnected .*transport=p2p") &&
            remoteSmokeScript.contains("AXUIElementPerformAction") &&
            remoteSmokeScript.contains("source=OnlineDeviceCard"),
            "Real-device P2P remote smoke must launch the Mac UI client, press a real online-device Connect button, record click evidence from outside the app UI, and fail closed instead of silently choosing a non-iPad target."
        )
        XCTAssertFalse(
            remoteSmokeScript.contains("SKYBRIDGE_SMOKE_STATUS_FILE=\"$MAC_ONLINE_STATUS_ARTIFACT\""),
            "The packaged Mac app smoke must not ask LaunchServices-launched app code to open the Desktop artifact path; macOS Desktop privacy can block before boot evidence is emitted."
        )
        guard let macOnlineLaunchStart = remoteSmokeScript.range(of: "open_macos_online_ipad_app_bundle() {")?.lowerBound,
              let macOnlineLaunchEnd = remoteSmokeScript.range(of: "start_macos_online_ipad_client() {", range: macOnlineLaunchStart..<remoteSmokeScript.endIndex)?.lowerBound else {
            XCTFail("Expected mac-online LaunchServices helper in real-device smoke script.")
            return
        }
        let macOnlineLaunchBody = String(remoteSmokeScript[macOnlineLaunchStart..<macOnlineLaunchEnd])
        XCTAssertFalse(
            macOnlineLaunchBody.contains("SKYBRIDGE_PQC_PEER_XWING_PUBLIC_KEY_BASE64") ||
            macOnlineLaunchBody.contains("SKYBRIDGE_PQC_PEER_MLKEM768_PUBLIC_KEY_BASE64") ||
            macOnlineLaunchBody.contains("SKYBRIDGE_PQC_PEER_MLKEM768FS_PUBLIC_KEY_BASE64"),
            "Mac online UI client LaunchServices environment must stay short and limited to variables consumed by the Mac app; large KEM material belongs in the app-authored PQC report and AX/script proof path."
        )
        XCTAssertTrue(
            remoteSmokeScript.contains("let targetIdentityVariants = identityVariants(for: targetIdentity)") &&
            remoteSmokeScript.contains("let targetIdentifiers: Set<String>") &&
            remoteSmokeScript.contains("identityValueMatchesTarget(fieldValue(\"identityKey\", in: line))") &&
            remoteSmokeScript.contains("identityValueMatchesTarget(fieldValue(\"targetDeviceId\", in: line))") &&
            remoteSmokeScript.contains("identityValueMatchesTarget(fieldValue(\"p2pDeviceId\", in: line))") &&
            remoteSmokeScript.contains("let enabledOnlineDeviceRows = statusLines.filter") &&
            remoteSmokeScript.contains("if targetIdentity == nil, enabledOnlineDeviceRows.count == 1") &&
            remoteSmokeScript.contains("targetIdentity == nil || targetRowEvidenceLine != nil || !isSkyBridgeDeviceButton") &&
            remoteSmokeScript.contains("axMatch=(target-identifier|target-row-title)") &&
            remoteSmokeScript.contains("targetIdentity == nil && isSkyBridgeDeviceButton") &&
            remoteSmokeScript.contains("subtreeContainsTargetDevice(child) && subtreeContainsConnectButton(child)") &&
            remoteSmokeScript.contains("buttonIdentifier=\\(buttonIdentifier.isEmpty ? \"-\" : buttonIdentifier)"),
            "The external AX clicker must normalize raw/id: target identities and fail closed instead of title-clicking the first Connect button in a broad container."
        )
        XCTAssertFalse(
            remoteSmokeScript.contains("boot role=mac-online-ipad-client process=SkyBridgeCompassApp uiRole=external-accessibility"),
            "The shell harness must not prewrite dashboard boot evidence before the app actually runs."
        )
        XCTAssertFalse(
            remoteSmokeScript.contains("activateIgnoringOtherApps"),
            "The Accessibility button press helper must not emit macOS 14 deprecation warnings."
        )
        XCTAssertTrue(
            remoteSmokeScript.contains("O_APPEND") &&
            remoteSmokeScript.contains("O_NOFOLLOW") &&
            remoteSmokeScript.contains("fstat(fd, &metadata)") &&
            remoteSmokeScript.contains("(metadata.st_mode & S_IFMT) == S_IFREG"),
            "External AX smoke status writes must append atomically to a regular file without following symlinks."
        )
        XCTAssertFalse(
            remoteSmokeScript.contains("FileHandle(forWritingAtPath:") ||
            remoteSmokeScript.contains("seekToEnd()"),
            "External AX smoke status writes must not race by seeking to end before writing."
        )
        XCTAssertTrue(
            unifiedSource.contains("iCloudDiscovery.$discoveredDevices"),
            "UnifiedOnlineDeviceManager must subscribe to iCloud discovery updates instead of creating a half-wired manager."
        )
        XCTAssertTrue(
            unifiedSource.contains("self?.handleiCloudDevicesUpdate(devices)"),
            "iCloud heartbeat rows must flow into the unified online device list."
        )
        XCTAssertTrue(
            unifiedSource.contains("startDiscoveryPresenceRefreshTimer()"),
            "Bonjour discovery must refresh active results periodically so visible iPads do not expire to offline after 60 seconds."
        )
        XCTAssertTrue(
            unifiedSource.contains("device.sources.contains(.skybridgeCloud), timeSinceLastSeen < 120"),
            "KVS-backed iCloud presence must use a TTL compatible with its 30s heartbeat and 120s discovery timeout."
        )
        XCTAssertTrue(
            unifiedSource.contains("iCloudDeviceDiscoveryManager.shared"),
            "All Mac UI discovery paths must share one iCloud manager instead of splitting state across half-wired instances."
        )
        XCTAssertTrue(
            xcodeProjectSource.contains("OnlineDeviceConnectionCoordinator.swift in Sources"),
            "The packaged Mac app target must compile the shared connection coordinator, not only the SwiftPM test target."
        )
        XCTAssertTrue(
            xcodeProjectSource.contains("CloudDevicePresentationPolicy.swift in Sources"),
            "The packaged Mac app target must compile the shared iCloud presentation de-duplication policy."
        )
        let cloudPresentationSource = try repositorySource("Sources/SkyBridgeCompassApp/ViewModels/CloudDevicePresentationPolicy.swift")
        XCTAssertTrue(
            cloudPresentationSource.contains("resolvedOnlineDevice(for: device)") &&
            cloudPresentationSource.contains("manager.onlineDevices.contains") &&
            cloudPresentationSource.contains("return false") &&
            cloudPresentationSource.contains("presentationKey(for: device)") &&
            cloudPresentationSource.contains("device.stableIdentityDeviceId") &&
            cloudPresentationSource.contains("device.registrationFingerprint") &&
            cloudPresentationSource.contains("device.vendorDeviceId") &&
            cloudPresentationSource.contains("return \"identity:\\(stableIdentity)\""),
            "Raw iCloud rows that resolve to an already visible unified online row must be hidden, while raw iCloud duplicates collapse by strong identity before falling back to path-specific ids."
        )
        XCTAssertTrue(
            discoverySource.contains("smokeProtocolIdentity(for: device)") &&
            discoverySource.contains("targetDeviceId=\\(smokeFieldValue(protocolIdentity.authorityDeviceId ?? \"-\"))") &&
            discoverySource.contains("p2pDeviceId=\\(smokeFieldValue(protocolIdentity.protocolDeviceId ?? \"-\"))") &&
            discoverySource.contains("pubKeyFP=\\(smokeFieldValue(protocolIdentity.pubKeyFP ?? \"-\"))") &&
            discoverySource.contains("routeIdentifier=\\(smokeFieldValue(routeIdentifier))"),
            "Mac online iPad smoke row evidence must expose the authoritative trusted protocol identity separately from the visible presentation row identity."
        )
        XCTAssertTrue(
            coordinatorSource.contains("let liveDiscoveredCandidates = unifiedDeviceManager.resolvedConnectableDiscoveredCandidates(for: device, limit: 6)") &&
            coordinatorSource.contains("shouldPreferUSBRoute(for: device, candidates: liveDiscoveredCandidates)") &&
            coordinatorSource.contains("authoritativeProtocolDeviceId(for: device, unifiedDeviceManager: unifiedDeviceManager)") &&
            coordinatorSource.contains("authoritativeProtocolFingerprint(for: device, unifiedDeviceManager: unifiedDeviceManager)"),
            "The online-device coordinator must select USB preference from live resolved candidates and carry trusted protocol identity into fallback targets."
        )
        XCTAssertFalse(
            p2pDiscoverySource.contains("routePreference == .preferUSB || device.connectionTypes.contains(.usb)"),
            "P2P connect must not infer USB preference from a coalesced presentation row; the coordinator owns route preference after resolving live candidates."
        )
        XCTAssertTrue(
            p2pDiscoverySource.contains("isNonRoutableIPv4Endpoint") &&
            p2pDiscoverySource.contains("169.254.") &&
            unifiedSource.contains("shouldReplaceIPv4Address") &&
            unifiedSource.contains("shouldClearStaleIPv4Address") &&
            unifiedSource.contains("return false\n    }\n\n    private func normalizedMACAddress"),
            "Link-local IPv4 routes must be filtered at P2P dial time and replaced in the online-device truth source instead of remaining as fake connectable endpoints."
        )
        XCTAssertFalse(
            unifiedSource.contains("|| device.sources.contains(.skybridgeBonjour)\n            || device.sources.contains(.skybridgeP2P)") ||
            unifiedSource.contains("return device.connectionTypes.contains(.usb)"),
            "Source labels and USB presence alone must not make an OnlineDevice connectable without a resolved SkyBridge control route."
        )
        XCTAssertFalse(
            xcodeProjectSource.contains("MacOnlineIpadSmokeHarness.swift"),
            "Mac online iPad smoke must not be compiled into the packaged Mac app target."
        )
    }

    func testDashboardDiscoveryRowsKeepProductionUIAndUseRealClickPath() throws {
        let rowSource = try repositorySource("Sources/SkyBridgeCompassApp/Dashboard/Components/EnhancedDeviceRow.swift")
        let dashboardSource = try repositorySource("Sources/SkyBridgeCompassApp/DashboardViewModel.swift")
        let dashboardViewSource = try repositorySource("Sources/SkyBridgeCompassApp/Dashboard/DashboardView.swift")
        let dashboardContentSource = try repositorySource("Sources/SkyBridgeCompassApp/Dashboard/Sections/DashboardContentView.swift")
        let dashboardPanelSource = try repositorySource("Sources/SkyBridgeCompassApp/Dashboard/Sections/DeviceDiscoveryPanelView.swift")
        let discoverySource = try repositorySource("Sources/SkyBridgeCompassApp/Views/EnhancedDeviceDiscoveryView.swift")
        let unifiedSource = try repositorySource("Sources/SkyBridgeCore/DeviceDiscovery/UnifiedOnlineDeviceManager.swift")
        let optimizedDiscoverySource = try repositorySource("Sources/SkyBridgeCore/DeviceDiscovery/DeviceDiscoveryManagerOptimized.swift")
        let remoteSmokeScript = try repositorySource("Scripts/run_real_device_p2p_remote_smoke.sh")

        XCTAssertTrue(
            rowSource.contains("(device.ipv4 != nil || device.ipv6 != nil) ? .green : .red") &&
            rowSource.contains("Button(action: onConnect)"),
            "Dashboard row visuals and controls must stay on the production implementation."
        )
        XCTAssertFalse(
            rowSource.contains("isMacOnlineIpadSmoke") ||
            rowSource.contains("MacOnlineDeviceSmokeEvidence") ||
            rowSource.contains(".disabled(!canConnect)") ||
            rowSource.contains(".opacity(canConnect") ||
            rowSource.contains(".accessibilityIdentifier(\"mac-online-connect-button-") ||
            rowSource.contains("UnifiedOnlineDeviceManager.shared.resolvedOnlineDevice(for: device)"),
            "Dashboard rows must not embed smoke-only visual state, button disabling, accessibility hooks, or canonical-device lookups."
        )
        XCTAssertFalse(
            rowSource.contains("@ObservedObject private var unifiedDeviceManager"),
            "Production Dashboard rows must not subscribe to smoke-only online state changes."
        )
        XCTAssertTrue(
            dashboardPanelSource.contains("await appModel.connect(to: device)"),
            "Dashboard row clicks must use the real discovered-device connection path."
        )
        XCTAssertFalse(
            dashboardPanelSource.contains("guard isMacOnlineIpadSmoke else") ||
            dashboardPanelSource.contains("resolvedOnlineDevice(for: device)") ||
            dashboardPanelSource.contains("await appModel.connect(to: onlineDevice)"),
            "Dashboard row clicks must not switch to a smoke-only canonical-device shortcut."
        )
        XCTAssertFalse(
            dashboardContentSource.contains("isMacOnlineIpadSmoke"),
            "Dashboard layout must not move production panels around for smoke tests."
        )
        XCTAssertFalse(
            dashboardSource.contains("MacOnlineDeviceSmokeEvidence.appendConnectButton"),
            "DashboardViewModel must not emit button-click smoke evidence because it is not the button source."
        )
        XCTAssertTrue(
            dashboardSource.contains("await connect(to: discoveredDevice)"),
            "DashboardViewModel online-device compatibility entry point must stay on the existing discovered-device connection path."
        )
        XCTAssertFalse(
            dashboardSource.contains("OnlineDeviceConnectionCoordinator.connect(to: onlineDevice)") ||
            dashboardSource.contains("canConnectOnlineDevice(_ device: OnlineDevice)"),
            "DashboardViewModel must not be repurposed as the online-card smoke button path."
        )
        XCTAssertTrue(
            discoverySource.contains("OnlineDeviceConnectionCoordinator.connect("),
            "Online-device card clicks must call the real coordinator."
        )
        XCTAssertFalse(
            discoverySource.contains("MacOnlineDeviceSmokeEvidence.appendConnectButton"),
            "Online-device cards must not emit fake smoke click evidence."
        )
        XCTAssertTrue(
            discoverySource.contains("skybridge-online-device-connect-button-"),
            "The real online-device connect button must remain addressable by accessibility for external smoke clicks."
        )
        XCTAssertTrue(
            discoverySource.contains("let buttonIdentity = canonicalAccessibilityIdentity(for: effectiveAccessibilityIdentity)") &&
            discoverySource.contains("accessibilityIdentity: resolvedPresentationIdentityKey(for: device)") &&
            discoverySource.contains("skybridge-online-device-connect-button-") &&
            discoverySource.contains("UUID(uuidString: normalized)"),
            "Online-device connect button accessibility identifier must use the resolved live protocol identity and canonical stable-id token so the external AX smoke does not split the same iPad by stale aliases, UUID case, or id: prefix."
        )
        XCTAssertFalse(
            discoverySource.contains(".accessibilityValue(buttonIdentity)"),
            "Online-device accessibility values must not expose raw stable identities to users; raw matching belongs in accessibilityIdentifier only."
        )
        XCTAssertTrue(
            remoteSmokeScript.contains("variants.insert(\"id:\\(trimmed)\")"),
            "The external AX clicker must match already-packaged buttons that expose id:UUID while the smoke target comes from a bare PQC UUID."
        )
        XCTAssertFalse(
            dashboardViewSource.contains("appendDashboardOnlineRowSmokeEvidence") ||
            dashboardViewSource.contains("MacOnlineDeviceSmokeEvidence") ||
            dashboardViewSource.contains("SKYBRIDGE_SMOKE_ROLE") ||
            dashboardViewSource.contains("appModel.$onlineDevices") ||
            dashboardViewSource.contains("filteredDevices = mapOnlineToDiscovered(onlineDevices)"),
            "DashboardView must not embed smoke-only environment checks, evidence writers, or online-card refresh behavior."
        )
        XCTAssertFalse(
            dashboardPanelSource.contains("deviceId: stableDeviceIdentifier(for: od)") ||
            dashboardPanelSource.contains("pubKeyFP: publicKeyFingerprint(for: od)") ||
            dashboardViewSource.contains("deviceId: stableDeviceIdentifier(for: od)") ||
            dashboardViewSource.contains("pubKeyFP: publicKeyFingerprint(for: od)") ||
            dashboardSource.contains("actualOnlineDevices = onlineCount + crossNetworkPeerContribution") ||
            dashboardSource.contains("UnifiedOnlineDeviceManager.shared.resolvedOnlineDevice(for: lhs)") ||
            dashboardSource.contains("requiresStrongDashboardDedupeIdentity(device, existing)"),
            "Dashboard production mapping, counts, and de-dupe must not be changed to satisfy the Mac online iPad smoke."
        )
        XCTAssertFalse(
            discoverySource.contains("resolvedIsOnline: resolvedIsOnline"),
            "Enhanced discovery iCloud rows must not change visible online status just to satisfy the Mac online iPad smoke."
        )
        XCTAssertTrue(
            discoverySource.contains("trustedRecordsForUI.map(\\.displayRecord)"),
            "Recent/trusted grouping must stay on the production display-record grouping path for the Mac online iPad smoke."
        )
        XCTAssertTrue(
            discoverySource.contains("private var connectedOnlineDevicesNonLocal") &&
            discoverySource.contains("private var activeOnlineDevicesNonLocal") &&
            discoverySource.contains("presentationDedupeOnlineDevices(") &&
            discoverySource.contains("shouldCoalesceAppleMobilePresentation(") &&
            discoverySource.contains("appleMobileStrongPresentationTokens(") &&
            discoverySource.contains("appleMobileCanonicalBonjourRouteToken(") &&
            discoverySource.contains("$0.connectionStatus == .offline") &&
            discoverySource.contains("private var displayedTrustedRecordsForUI") &&
            discoverySource.contains("hasVisibleOnlineRepresentation(for: group)"),
            "Enhanced discovery must keep connected, recent, trusted, and online sections mutually exclusive so one physical iPad is not rendered multiple times."
        )
        XCTAssertFalse(
            discoverySource.contains("appleMobilePresentationNamesRepresentSameDevice("),
            "Apple mobile presentation coalescing must not merge devices by name-only substring; it must require trust, stable identity, or Bonjour route anchors."
        )
        XCTAssertFalse(
            discoverySource.contains("normalizedSmokeToken(serviceName)"),
            "Apple mobile Bonjour route coalescing must keep service instance punctuation and domain; smoke-token compression can merge different devices."
        )
        XCTAssertTrue(
            discoverySource.contains("skybridge-online-device-row-") &&
            discoverySource.contains(".accessibilityElement(children: .contain)") &&
            discoverySource.contains(".accessibilityHint(Text(device.name))"),
            "Online-device rows must expose a real AX container and the real connect button must remain discoverable by external Accessibility."
        )
        XCTAssertTrue(
            discoverySource.contains("private func macOnlineIPadSmokeVisibleRows()") &&
            discoverySource.contains("surface=\\(surface)") &&
            discoverySource.contains("for device in connectedOnlineDevicesNonLocal") &&
            discoverySource.contains("for device in groupedRecentlyConnectedDevices") &&
            discoverySource.contains("for device in filteredOnlineDevicesNonLocal"),
            "Mac online iPad smoke evidence must describe actual visible OnlineDeviceCard surfaces, not the raw unified device map."
        )
        XCTAssertTrue(
            unifiedSource.contains("online-state sourceMerge source=discovered-device") &&
            unifiedSource.contains("online-state sourceMerge source=cloud-device") &&
            unifiedSource.contains("resolved=none status=offline score=0"),
            "Unified online resolver must log discovery/iCloud-to-online merge reasons for inconsistent status debugging."
        )
        XCTAssertTrue(
            optimizedDiscoverySource.contains("routeIdentifiers: [bonjourID].compactMap { $0 }") &&
            optimizedDiscoverySource.contains("merged.mergeRouteIdentifiers(device.routeIdentifiers)") &&
            unifiedSource.contains("device.routeIdentifiers") &&
            unifiedSource.contains("Self.routeIdentifiers(from: device.uniqueIdentifier)") &&
            unifiedSource.contains("routeIdentifiers: []") &&
            unifiedSource.contains("isConnectable: false"),
            "Discovery-to-online state must preserve real Bonjour route aliases separately from stable identity and must not mark iCloud heartbeat-only rows as connectable."
        )
    }

    func testSharedICloudPresenceIsWiredForMacPackageAndIOSRuntime() throws {
        let macDev = try repositorySource("Sources/SkyBridgeCompassApp/SkyBridgeCompassApp.entitlements")
        let macPackaging = try repositorySource("Sources/SkyBridgeCompassApp/SkyBridgeCompassApp.packaging.entitlements")
        let macNativePackaging = try repositorySource("Sources/SkyBridgeCompassApp/SkyBridgeCompassApp.native.packaging.entitlements")
        let iosDebug = try repositorySource("SkyBridge Compass iOS/SkyBridgeCompass-iOSDebug.entitlements")
        let iosRelease = try repositorySource("SkyBridge Compass iOS/SkyBridgeCompass-iOSRelease.entitlements")
        let iosAppSource = try repositorySource("SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/App/SkyBridgeCompassApp.swift")
        let iosPresenceSource = try repositorySource("SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/CloudKitSyncManager.swift")
        let macICloudSource = try repositorySource("Sources/SkyBridgeCore/iCloud/iCloudDeviceDiscoveryManager.swift")
        let signingHelperSource = try repositorySource("Scripts/signing_entitlements_helpers.sh")

        for entitlements in [macDev, macPackaging, macNativePackaging, iosDebug, iosRelease] {
            XCTAssertTrue(entitlements.contains("iCloud.com.skybridge.compass"))
            XCTAssertTrue(entitlements.contains("com.apple.developer.ubiquity-kvstore-identifier"))
            XCTAssertTrue(entitlements.contains("$(TeamIdentifierPrefix)com.skybridge.compass"))
        }
        for entitlements in [macDev, macPackaging, macNativePackaging] {
            XCTAssertTrue(
                entitlements.contains("<key>com.apple.application-identifier</key>") &&
                entitlements.contains("$(AppIdentifierPrefix)com.skybridge.compass.pro"),
                "Mac iCloud/App Group packaging entitlements must carry the profile-backed application identifier used by iCloud Drive and KVS at runtime."
            )
        }

        XCTAssertTrue(signingHelperSource.contains("skybridge_expand_build_setting_entitlements"))
        XCTAssertTrue(signingHelperSource.contains("ApplicationIdentifierPrefix"))
        XCTAssertTrue(signingHelperSource.contains("$(TeamIdentifierPrefix)"))
        XCTAssertTrue(signingHelperSource.contains("\"com.apple.application-identifier\""))

        XCTAssertTrue(iosAppSource.contains("ICloudDevicePresenceService.shared.start()"))
        XCTAssertTrue(iosAppSource.contains("ICloudDevicePresenceService.shared.refreshNow()"))
        XCTAssertTrue(iosAppSource.contains("if !shouldSkipInteractiveStartup {\n                ICloudDevicePresenceService.shared.refreshNow()\n            }"))
        XCTAssertTrue(iosPresenceSource.contains("private let deviceKeyPrefix = \"skybridge.device.\""))
        XCTAssertTrue(iosPresenceSource.contains("NSUbiquitousKeyValueStore.default"))
        XCTAssertTrue(iosPresenceSource.contains("\"remote_desktop\", \"file_transfer\", \"clipboard\""))
        XCTAssertTrue(macICloudSource.contains("继续使用 iCloud KV Store 做设备在线心跳"))
        XCTAssertTrue(
            iosPresenceSource.contains("isAdvertisableRoutableIPv4") &&
            iosPresenceSource.contains("!value.hasPrefix(\"169.254.\")") &&
            macICloudSource.contains("isAdvertisableRoutableIPv4") &&
            macICloudSource.contains("!value.hasPrefix(\"169.254.\")"),
            "iOS and Mac iCloud KVS presence must not publish link-local IPv4 addresses as cross-device dial targets."
        )
        XCTAssertFalse(
            macICloudSource.contains("iCloud 容器不可用：请检查 iCloud Drive"),
            "iCloud KVS device presence must not be blocked by the optional iCloud Documents container."
        )
    }

    func testLegacyP2PConnectionViewDoesNotExposePlanningOnlyConnectionCodeButton() throws {
        let p2pSource = try repositorySource("Sources/SkyBridgeCore/UI/P2PConnectionView.swift")

        XCTAssertFalse(p2pSource.contains("showConnectionCode"))
        XCTAssertFalse(p2pSource.contains("功能规划"))
        XCTAssertFalse(p2pSource.contains("连接码功能将支持"))
    }

    func testMacAppAvoidsVolatileAutosaveDefaultsAndPerFrameDateStateWrites() throws {
        let appSource = try repositorySource("Sources/SkyBridgeCompassApp/SkyBridgeCompassApp.swift")
        let animatedBackgrounds = try [
            "Sources/SkyBridgeCompassApp/ClassicBackgroundV2.swift",
            "Sources/SkyBridgeCompassApp/StarryBackground.swift",
            "Sources/SkyBridgeCompassApp/DeepSpaceBackground.swift",
            "Sources/SkyBridgeCompassApp/AuroraBackground.swift",
            "Sources/SkyBridgeCompassApp/AuroraBackgroundV2.swift"
        ].map(repositorySource)

        XCTAssertTrue(
            appSource.contains("WindowGroup(localizationManager.localizedString(\"app.name\"), id: \"main\")"),
            "The main Mac window needs a stable id so AppKit does not persist frame keys based on volatile SwiftUI type names."
        )
        XCTAssertTrue(appSource.contains("pruneVolatileSwiftUIAutosaveDefaults()"))
        XCTAssertTrue(appSource.contains("\"NSWindow Frame SwiftUI\""))
        XCTAssertTrue(appSource.contains("\"NSSplitView Subview Frames SwiftUI\""))
        XCTAssertTrue(appSource.contains("(unknown context at $"))

        for source in animatedBackgrounds {
            XCTAssertFalse(
                source.contains(".onChange(of: timeline.date"),
                "TimelineView-backed backgrounds should derive animation time from timeline.date without mutating SwiftUI state every frame."
            )
            XCTAssertFalse(
                source.contains("time += delta"),
                "Per-frame @State accumulation in animated backgrounds can trigger SwiftUI multiple-updates-per-frame warnings."
            )
            XCTAssertTrue(
                source.contains("timeIntervalSince(Self.animationEpoch)") || source.contains("let phase = timeline.date.timeIntervalSince(Self.animationEpoch)"),
                "Animated backgrounds should render from a stable timeline epoch."
            )
        }
    }

    private func repositorySource(_ relativePath: String) throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repoRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
