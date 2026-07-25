import Foundation
import XCTest

final class ReleaseTestSurfaceIsolationTests: XCTestCase {
    private struct HookExpectation {
        let relativePath: String
        let markers: [String]
    }

    func testMutableAndFaultInjectionHooksRequireAnExplicitTestBuild() throws {
        let expectations: [HookExpectation] = [
            .init(
                relativePath: "Sources/SkyBridgeCompassApp/LocalP2PFileTransferSmokeHarness.swift",
                markers: [
                    "final class LocalP2PFileTransferSmokeHarness",
                    "SKYBRIDGE_SMOKE_ROLE"
                ]
            ),
            .init(
                relativePath: "Sources/SkyBridgeCompassApp/SkyBridgeCompassApp.swift",
                markers: [
                    "MacOnlineIPadSmokeHarness",
                    "RemoteControlNoticePanelProbeHarness",
                    "LocalWebRTCSmokeHarness",
                    "SKYBRIDGE_SMOKE_ROLE"
                ]
            ),
            .init(
                relativePath: "Sources/SkyBridgeCompassApp/Views/EnhancedDeviceDiscoveryView.swift",
                markers: [
                    "SKYBRIDGE_SMOKE_ROLE",
                    "SKYBRIDGE_SMOKE_STATUS_FILE",
                    "MacSmokeStatusFailClosedWriter.append("
                ]
            ),
            .init(
                relativePath: "Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift",
                markers: [
                    "SKYBRIDGE_SMOKE_ROLE",
                    "SKYBRIDGE_SMOKE_FORCE_RELAY_ICE",
                    "SKYBRIDGE_SMOKE_SYNTHETIC_SCREEN",
                    "SKYBRIDGE_SMOKE_SYNTHETIC_OPUS_TONE",
                    "SKYBRIDGE_SMOKE_DELAY_HOST_PQC_REKEY_SECONDS"
                ]
            ),
            .init(
                relativePath: "Sources/SkyBridgeCore/RemoteConnection/WebRTC/WebRTCSession.swift",
                markers: ["SKYBRIDGE_SMOKE_FORCE_RELAY_ICE"]
            ),
            .init(
                relativePath: "Sources/SkyBridgeCore/RemoteConnection/WebRTC/CrossNetworkWebRTCDiagnostics.swift",
                markers: ["SKYBRIDGE_SMOKE_STATUS_FILE"]
            ),
            .init(
                relativePath: "Sources/SkyBridgeCore/RemoteConnection/WebRTC/WebRTCCGDisplayVideoEncoder.swift",
                markers: ["SKYBRIDGE_SMOKE_ROLE"]
            ),
            .init(
                relativePath: "Sources/SkyBridgeCore/RemoteControl/RemoteControlSmokeStatusWriter.swift",
                markers: [
                    "SKYBRIDGE_SMOKE_ROLE",
                    "SKYBRIDGE_SMOKE_STATUS_FILE"
                ]
            ),
            .init(
                relativePath: "Sources/SkyBridgeCore/P2P/HandshakeContext.swift",
                markers: ["SKYBRIDGE_SMOKE_ROLE"]
            ),
            .init(
                relativePath: "Sources/SkyBridgeCore/P2P/HandshakeDriver.swift",
                markers: ["SKYBRIDGE_SMOKE_ROLE"]
            ),
            .init(
                relativePath: "Sources/SkyBridgeCore/P2P/SignatureProvider.swift",
                markers: ["SKYBRIDGE_SMOKE_ROLE"]
            ),
            .init(
                relativePath: "Sources/SkyBridgeProtocolCore/P2P/HandshakeMessages.swift",
                markers: ["SKYBRIDGE_SMOKE_ROLE"]
            ),
            .init(
                relativePath: "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/App/Smoke/LocalP2PSmokeHarness.swift",
                markers: [
                    "final class LocalP2PSmokeHarness",
                    "SKYBRIDGE_SMOKE_ROLE"
                ]
            ),
            .init(
                relativePath: "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/App/Smoke/LocalWebRTCSmokeHarness.swift",
                markers: [
                    "final class LocalWebRTCSmokeHarness",
                    "SKYBRIDGE_SMOKE_ROLE"
                ]
            ),
            .init(
                relativePath: "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/App/Smoke/SmokeStatusReporter.swift",
                markers: ["SKYBRIDGE_SMOKE_ROLE"]
            ),
            .init(
                relativePath: "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/AuthenticationManager.swift",
                markers: [
                    "installSmokeRemoteDesktopSession(",
                    "validateSystemSmokeRemoteDesktopSession(",
                    "SKYBRIDGE_SMOKE_ROLE"
                ]
            ),
            .init(
                relativePath: "Sources/SkyBridgeAppleTransport/Connection/NativeWebSocketClient.swift",
                markers: ["internal static func testOnlyBuildParameters("]
            ),
            .init(
                relativePath: "Sources/SkyBridgeAppleTransport/RemoteConnection/WebRTC/WebSocketSignalingClient.swift",
                markers: [
                    "SKYBRIDGE_SIGNALING_TRANSPORT",
                    "SKYBRIDGE_SIGNALING_DISABLE_NATIVE_FALLBACK",
                    "internal func testOnlyReserveNextHandleId(",
                    "internal func testOnlyTransportAttemptLabels()",
                    "internal static func testOnlyNoProxyConnectionProxyDictionary()",
                    "internal static func testOnlyDefaultConnectionTimeoutSeconds()",
                    "internal func testOnlySeedCurrentHandle(",
                    "internal func testOnlyHandleText(",
                    "internal func testOnlyIsBound()",
                    "internal func testOnlyTerminalErrorCount()"
                ]
            ),
            .init(
                relativePath: "Sources/SkyBridgeCore/AuthenticationService.swift",
                markers: ["SKYBRIDGE_SMOKE_SKIP_AUTH_REFRESH"]
            ),
            .init(
                relativePath: "Sources/SkyBridgeCore/Connection/USBCConnectionManager.swift",
                markers: [
                    "XCTestConfigurationFilePath",
                    "XCTestBundlePath",
                    "XCTestSessionIdentifier",
                    "NSClassFromString(\"XCTestCase\")"
                ]
            ),
            .init(
                relativePath: "Sources/SkyBridgeCore/Device/BluetoothManager.swift",
                markers: [
                    "XCTestConfigurationFilePath",
                    "NSClassFromString(\"XCTestCase\")",
                    "NSClassFromString(\"XCTest\")"
                ]
            ),
            .init(
                relativePath: "Sources/SkyBridgeCore/Device/DevicePermissionManager.swift",
                markers: [
                    "XCTestConfigurationFilePath",
                    "NSClassFromString(\"XCTestCase\")",
                    "NSClassFromString(\"XCTest\")"
                ]
            ),
            .init(
                relativePath: "Sources/SkyBridgeCore/FileTransfer/FileTransferManager.swift",
                markers: ["XCTestConfigurationFilePath"]
            ),
            .init(
                relativePath: "Sources/SkyBridgeCore/DeviceDiscovery/UnifiedOnlineDeviceManager.swift",
                markers: [
                    "func replaceDevicesForTesting(",
                    "func replaceNetworkDiscoveredDevicesForTesting(",
                    "func reloadPersistedDevicesForTesting()",
                    "func recomputeDeviceStatusesForTesting()",
                    "struct SmokeDiscoveryDiagnostic",
                    "func smokeDiscoveryDiagnostics("
                ]
            ),
            .init(
                relativePath: "Sources/SkyBridgeCompassApp/Views/EnhancedDeviceDiscoveryView.swift",
                markers: ["unifiedDeviceManager.smokeDiscoveryDiagnostics("]
            ),
            .init(
                relativePath: "Sources/SkyBridgeCore/FileTransfer/LocalFileTransferHTTPServer.swift",
                markers: [
                    "typealias TestingStartHook",
                    "private static let testingDelay",
                    "private static let testingStartHookStorage",
                    "static var testingStartDelayNanos",
                    "static var testingStartHook",
                    "if let testingStartHook = Self.testingStartHook",
                    "let startDelay = Self.testingStartDelayNanos"
                ]
            ),
            .init(
                relativePath: "Sources/SkyBridgeCore/FileTransfer/FileTransferManager.swift",
                markers: [
                    "var configuredSpeedLimitBytesPerSecondForTesting",
                    "func testingAuthenticatedClassicTransferSourceCount()"
                ]
            ),
            .init(
                relativePath: "Sources/SkyBridgeCore/P2P/CryptoProviderFactory.swift",
                markers: [
                    "public struct MockCryptoEnvironment",
                    "public static func make(policy: SelectionPolicy = .preferPQC, environment: any CryptoEnvironment)",
                    "public static func detectCapability(environment: any CryptoEnvironment)",
                    "public static func makeInboundPQCResponderProvider(policy: SelectionPolicy, peerSupportedSuites: [CryptoSuite], environment: any CryptoEnvironment)",
                    "public static func makeOutboundPQCInitiatorProvider(policy: SelectionPolicy, peerAdvertisedSuites: [CryptoSuite], environment: any CryptoEnvironment)"
                ]
            ),
            .init(
                relativePath: "Sources/SkyBridgeCore/P2P/DiscoveryTransport.swift",
                markers: [
                    "public actor InMemoryDiscoveryTransport",
                    "private var shouldFail",
                    "func setShouldFail(",
                    "func simulateReceive("
                ]
            ),
            .init(
                relativePath: "Sources/SkyBridgeCore/P2P/HandshakeReplayCache.swift",
                markers: ["func clearForTesting()"]
            ),
            .init(
                relativePath: "Sources/SkyBridgeCore/P2P/P2PDiscoveryService.swift",
                markers: ["func testingReplaceAuthenticatedConnections("]
            ),
            .init(
                relativePath: "Sources/SkyBridgeCore/P2P/P2PModels.swift",
                markers: [
                    "func testingSetClassicTransferRemoteIdentity(",
                    "func testingSetHandshakePeerDeviceId(",
                    "func testingSetStatus("
                ]
            ),
            .init(
                relativePath: "Sources/SkyBridgeCore/P2P/P2PNetworkManager.swift",
                markers: ["public func addMockDevices()"]
            ),
            .init(
                relativePath: "Sources/SkyBridgeCore/P2P/PeerKEMBootstrapStore.swift",
                markers: ["func clearForTesting()"]
            ),
            .init(
                relativePath: "Sources/SkyBridgeCore/P2P/PeerProtocolIdentityBootstrapStore.swift",
                markers: [
                    "private var persistenceResultOverrideForTesting",
                    "if let persistenceResultOverrideForTesting",
                    "func clearForTesting()",
                    "func setPersistenceResultOverrideForTesting("
                ]
            ),
            .init(
                relativePath: "Sources/SkyBridgeCore/P2P/ProtocolIdentityBindingTransactionStore.swift",
                markers: ["func clearForTesting()", "func countForTesting("]
            ),
            .init(
                relativePath: "Sources/SkyBridgeCore/P2P/SecureBytes.swift",
                markers: [
                    "private static let wipingFunctionStorage",
                    "public static var wipingFunction",
                    "public final class SecureBytesWipeTracker"
                ]
            ),
            .init(
                relativePath: "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Core/CoreTypes.swift",
                markers: [
                    "private static let wipingFunctionStorage",
                    "public static var wipingFunction"
                ]
            ),
            .init(
                relativePath: "Sources/SkyBridgeCore/P2P/SignedKEMRefreshRequestAdmissionGate.swift",
                markers: ["func clearForTesting()"]
            ),
            .init(
                relativePath: "Sources/SkyBridgeCore/P2P/TrustSyncService.swift",
                markers: [
                    "usesInMemoryPersistenceForTesting",
                    "func removeRecordsForTesting("
                ]
            ),
            .init(
                relativePath: "Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift",
                markers: [
                    "func testingSeedSignalingState(",
                    "func testingSetReadiness(",
                    "func testingCurrentSignalingHandle()",
                    "func testingCanPerformSignalingOperation("
                ]
            ),
            .init(
                relativePath: "Sources/SkyBridgeCore/RemoteConnection/WebRTC/CrossNetworkWebRTCDiagnostics.swift",
                markers: ["func flushForTesting()", "func pendingSnapshotForTesting()"]
            ),
            .init(
                relativePath: "Sources/SkyBridgeCore/RemoteConnection/WebRTC/CrossNetworkWebRTCSignalingPolicy.swift",
                markers: ["static func selectWebRTCInboundResponder(peerSupportedSuites: [CryptoSuite], policy: HandshakePolicy, environment: any CryptoEnvironment)"]
            ),
            .init(
                relativePath: "Sources/SkyBridgeCore/RemoteControl/RemoteControlManager.swift",
                markers: [
                    "struct RemoteControlManagerRoleSnapshot",
                    "func testingRegisterRole(",
                    "func testingRemoveRole(",
                    "func testingSetViewingRenderPipelineMode(",
                    "func testingSeedBeingControlledResources(",
                    "var testingRoleSnapshot"
                ]
            ),
            .init(
                relativePath: "Sources/SkyBridgeCore/RemoteControl/RemoteControlSecurityNotice.swift",
                markers: ["var disconnectHandlerCountForTesting"]
            ),
            .init(
                relativePath: "Sources/SkyBridgeCore/Performance/PerformanceTestSuite.swift",
                markers: ["public final class PerformanceTestSuite", "public struct TestResults"]
            ),
            .init(
                relativePath: "Sources/SkyBridgeCore/Performance/PerformanceTestView.swift",
                markers: ["public struct PerformanceTestView"]
            ),
            .init(
                relativePath: "Sources/SkyBridgeCore/Protocol/PQCProtocolAdapter.swift",
                markers: ["public init(provider: PQCProvider?"]
            ),
            .init(
                relativePath: "Sources/SkyBridgeCore/Security/AuthTokenValidator.swift",
                markers: ["static func generateTestToken(", "static func generateTestUUID()"]
            ),
            .init(
                relativePath: "Sources/SkyBridgeCore/Security/BatchScanLimiter.swift",
                markers: ["static func createForTesting("]
            ),
            .init(
                relativePath: "Sources/SkyBridgeCore/Security/LimitedJSONDecoder.swift",
                markers: ["static func createForTesting("]
            ),
            .init(
                relativePath: "Sources/SkyBridgeCore/Security/PairingTrustApprovalService.swift",
                markers: [
                    "ProtocolIdentityPinOperationForTesting",
                    "protocolIdentityPinResultOverrideForTesting",
                    "protocolIdentityPinOperationForTesting",
                    "policySaveResultOverrideForTesting",
                    "func pendingWaiterCountForTesting("
                ]
            ),
            .init(
                relativePath: "Sources/SkyBridgeCore/Security/P2PHandshakeManager.swift",
                markers: ["public func initiate(deviceId:"]
            ),
            .init(
                relativePath: "Sources/SkyBridgeCore/Security/P2PSecurityManager.swift",
                markers: ["public func establishSessionKey(with deviceId:"]
            ),
            .init(
                relativePath: "Sources/SkyBridgeCore/Security/ConnectionRateLimiter.swift",
                markers: ["internal init(limits: SecurityLimits, connectionId: String, tokenBucket: TokenBucketLimiter)"]
            ),
            .init(
                relativePath: "Sources/SkyBridgeCore/Security/FileScanService.swift",
                markers: ["func isExecutingOnBackgroundThread()"]
            ),
            .init(
                relativePath: "Sources/SkyBridgeCore/Security/PAKERateLimiterMemory.swift",
                markers: ["var currentWritesCount"]
            ),
            .init(
                relativePath: "Sources/SkyBridgeCore/Security/PatternMatcher.swift",
                markers: ["func resetVersion()"]
            ),
            .init(
                relativePath: "Sources/SkyBridgeCore/Security/RegexMatchingExecutor.swift",
                markers: [
                    "private init(limits: SecurityLimits, useXPCIsolation: Bool)",
                    "static func createForTesting("
                ]
            ),
            .init(
                relativePath: "Sources/SkyBridgeCore/Security/RegexValidator.swift",
                markers: ["static func createForTesting(", "func reset()"]
            ),
            .init(
                relativePath: "Sources/SkyBridgeCore/Security/ScanHistoryStore.swift",
                markers: [
                    "detailsDirectoryOverride",
                    "simulateDetailsDirectoryResolutionFailure",
                    "userDefaultsSuiteName",
                    "internal func reset() async",
                    "internal func setEntries(",
                    "internal func setSummaries(",
                    "internal func getDetailsDirectory()",
                    "static func createForTesting("
                ]
            ),
            .init(
                relativePath: "Sources/SkyBridgeCore/Security/SecurityEventEmitter.swift",
                markers: ["static func createForTesting(", "func resetForTesting()"]
            ),
            .init(
                relativePath: "Sources/SkyBridgeCore/Security/SecurityEventCollector.swift",
                markers: ["public actor SecurityEventCollector"]
            ),
            .init(
                relativePath: "Sources/SkyBridgeCore/Security/SignatureDBKeyManager.swift",
                markers: ["static func createTestDatabase()", "static func verifyForTesting("]
            ),
            .init(
                relativePath: "Sources/SkyBridgeCore/Security/SymlinkResolver.swift",
                markers: ["static func createForTesting("]
            ),
            .init(
                relativePath: "Sources/SkyBridgeCore/SystemMetricsService.swift",
                markers: ["var notificationObserverCountForTesting"]
            ),
            .init(
                relativePath: "Sources/SkyBridgeCore/Services/NebulaPublicClientOAuth.swift",
                markers: [
                    "configurationOverride",
                    "func overrideConfiguration(",
                    "func clearConfigurationOverride()"
                ]
            ),
            .init(
                relativePath: "Sources/SkyBridgeCore/Utilities/DeprecationTracker.swift",
                markers: ["self.isEnabled = true", "public func reset()", "static func createForTesting()"]
            ),
            .init(
                relativePath: "Sources/SkyBridgeUI/Security/PairingTrustApprovalWindowController.swift",
                markers: ["var presentedRequestIDForTesting", "func closePresentedWindowForTesting()"]
            ),
            .init(
                relativePath: "Sources/SkyBridgeUI/Security/RemoteControlSecurityNoticePanelController.swift",
                markers: ["var isStartedForTesting", "var hasPanelForTesting"]
            ),
            .init(
                relativePath: "Sources/SkyBridgeUI/MenuBar/MenuBarPopoverView.swift",
                markers: ["static let buttonIdentifiers"]
            ),
            .init(
                relativePath: "Sources/SkyBridgeCore/Weather/WeatherDataService.swift",
                markers: ["func setSimulatedWeather(", "func getSimulatedHazeWeatherParameters()"]
            ),
            .init(
                relativePath: "Sources/SkyBridgeCore/Weather/HazeDebugTest.swift",
                markers: ["public struct HazeDebugTestView"]
            )
        ]

        for expectation in expectations {
            let source = try repositorySource(expectation.relativePath)
            let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let stacks = conditionalStacks(for: lines)

            for marker in expectation.markers {
                let matchingLines = lines.indices.filter { lines[$0].contains(marker) }
                XCTAssertFalse(
                    matchingLines.isEmpty,
                    "Missing expected test hook marker '\(marker)' in \(expectation.relativePath)"
                )
                for lineIndex in matchingLines {
                    XCTAssertTrue(
                        hasExplicitTestGate(stacks[lineIndex]),
                        "Test hook '\(marker)' must be inside #if DEBUG || SKYBRIDGE_TESTING "
                            + "in \(expectation.relativePath):\(lineIndex + 1)"
                    )
                }
            }
        }
    }

    /// The release binary surface gate in `Scripts/check_macos_release_readiness.sh`
    /// rejects any symbol matching `*SmokeStatusWriter` in the shipping binary.
    /// `RemoteControlSmokeStatusWriter.append(_:)` is allowed to keep an ungated
    /// declaration only because its entire body sits behind the test gate, so a
    /// Release build erases it at every call site. Any other member carrying
    /// executable code outside that gate emits a forbidden symbol and fails the
    /// gate, which is exactly how `fieldValue(_:)` used to leak into the DMG.
    func testSmokeStatusWriterKeepsEveryMemberButItsNoOpEntryPointBehindTheTestGate() throws {
        let relativePath = "Sources/SkyBridgeCore/RemoteControl/RemoteControlSmokeStatusWriter.swift"
        let source = try repositorySource(relativePath)
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let stacks = conditionalStacks(for: lines)

        // Stored properties leak a forbidden symbol just as readily as functions
        // do, so the scan covers nested types and static storage, not only `func`.
        let memberDeclarationMarkers = ["func ", "static let ", "static var ", "class ", "struct ", "enum "]

        for lineIndex in lines.indices {
            let trimmed = lines[lineIndex].trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("//") else { continue }
            guard memberDeclarationMarkers.contains(where: { trimmed.contains($0) }) else { continue }
            // The type declaration itself must stay ungated so the 148 ungated
            // call sites across SkyBridgeCore keep compiling in Release.
            if trimmed.hasPrefix("enum RemoteControlSmokeStatusWriter") { continue }
            if trimmed.hasPrefix("static func append(") { continue }
            XCTAssertTrue(
                hasExplicitTestGate(stacks[lineIndex]),
                "\(relativePath):\(lineIndex + 1) declares a member outside "
                    + "#if DEBUG || SKYBRIDGE_TESTING. Every member except the no-op "
                    + "append(_:) entry point must stay gated, otherwise the Release "
                    + "binary carries a forbidden *SmokeStatusWriter symbol."
            )
        }

        XCTAssertFalse(
            source.contains("func fieldValue("),
            "Structured-evidence field sanitizing belongs to the production "
                + "DiagnosticFieldSanitizer, not to a smoke-named type that must not "
                + "appear in the release binary symbol table."
        )
    }

    /// Counterpart to the invariant above: the extracted sanitizer is production log
    /// hygiene and must compile into Release builds, so it must carry no test gate.
    func testDiagnosticFieldSanitizerIsUngatedProductionCode() throws {
        let relativePath = "Sources/SkyBridgeCore/Diagnostics/DiagnosticFieldSanitizer.swift"
        let source = try repositorySource(relativePath)
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let stacks = conditionalStacks(for: lines)

        XCTAssertTrue(source.contains("enum DiagnosticFieldSanitizer"))
        XCTAssertTrue(source.contains("static func fieldValue(_ raw: String?) -> String"))

        let declarationIndex = try XCTUnwrap(
            lines.firstIndex { $0.contains("static func fieldValue(") },
            "\(relativePath) must declare fieldValue(_:)"
        )
        XCTAssertTrue(
            stacks[declarationIndex].isEmpty,
            "\(relativePath):\(declarationIndex + 1) must not sit inside any conditional "
                + "compilation block. Release builds have to keep the sanitizer, because the "
                + "ungated call sites that interpolate it still compile."
        )
    }

    func testSecurityEventEmitterHasOneCompleteTestResetAndNoPartialResetSurface() throws {
        let source = try repositorySource("Sources/SkyBridgeCore/Security/SecurityEventEmitter.swift")

        XCTAssertEqual(source.components(separatedBy: "func resetForTesting()").count - 1, 1)
        XCTAssertFalse(source.contains("func clearQueue()"))
        XCTAssertFalse(source.contains("func clearSubscribers()"))
        XCTAssertTrue(source.contains("Self.hasSubscribersFlag.store(false, ordering: .relaxed)"))
    }

    func testSecureBytesExportsOnlyOwnedDataAndUsesImmutableReleaseWipingHooks() throws {
        let paths = [
            "Sources/SkyBridgeCore/P2P/SecureBytes.swift",
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Core/CoreTypes.swift"
        ]

        for path in paths {
            let source = try repositorySource(path)
            XCTAssertTrue(source.contains("public func copyData() -> Data"), path)
            XCTAssertFalse(source.contains("noCopyData"), path)
            XCTAssertTrue(source.contains("internal static let wipingFunction"), path)
        }
    }

    func testSignalingTransportPolicyInitializerIsNotInTheProductionSurface() throws {
        let relativePath = "Sources/SkyBridgeAppleTransport/RemoteConnection/WebRTC/WebSocketSignalingClient.swift"
        let source = try repositorySource(relativePath)
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let stacks = conditionalStacks(for: lines)
        var injectableInitializers: [Int] = []

        var lineIndex = 0
        while lineIndex < lines.count {
            let trimmed = lines[lineIndex].trimmingCharacters(in: .whitespaces)
            guard trimmed == "init(" else {
                lineIndex += 1
                continue
            }

            let start = lineIndex
            var declaration = lines[lineIndex]
            while lineIndex + 1 < lines.count, !lines[lineIndex].contains(") {") {
                lineIndex += 1
                declaration += "\n" + lines[lineIndex]
            }
            if declaration.contains("selectionPolicy: BackendSelectionPolicy"),
               declaration.contains("nativeFallbackEnabled: Bool") {
                injectableInitializers.append(start)
            }
            lineIndex += 1
        }

        XCTAssertEqual(injectableInitializers.count, 1, "Expected one explicit signaling fault-injection initializer")
        for initializerLine in injectableInitializers {
            XCTAssertTrue(
                hasExplicitTestGate(stacks[initializerLine]),
                "The signaling transport policy initializer must not compile into a production Release build"
            )
        }
        XCTAssertTrue(source.contains("private struct TransportConfiguration"))
        XCTAssertTrue(source.contains("private init("))
    }

    private func conditionalStacks(for lines: [String]) -> [[String]] {
        var stack: [String] = []
        var result: [[String]] = []
        result.reserveCapacity(lines.count)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#if ") {
                stack.append(String(trimmed.dropFirst(4)))
            } else if trimmed.hasPrefix("#elseif ") {
                if !stack.isEmpty {
                    stack[stack.count - 1] = String(trimmed.dropFirst(8))
                }
            } else if trimmed == "#else" {
                if !stack.isEmpty {
                    stack[stack.count - 1] = "else(\(stack[stack.count - 1]))"
                }
            } else if trimmed == "#endif" {
                if !stack.isEmpty {
                    stack.removeLast()
                }
            }
            result.append(stack)
        }
        return result
    }

    private func hasExplicitTestGate(_ stack: [String]) -> Bool {
        stack.contains { condition in
            condition.filter { !$0.isWhitespace && $0 != "(" && $0 != ")" }
                == "DEBUG||SKYBRIDGE_TESTING"
        }
    }

    private func repositorySource(_ relativePath: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
