import Foundation
import Network
import SkyBridgeProtocolCore
import XCTest
@testable import SkyBridgeCompass_iOS

@MainActor
final class IOSLanConnectionTargetTests: XCTestCase {
    private let deviceID = "9A770257-EE43-4D15-9031-D39B7A4AE045"
    private let fingerprint = String(repeating: "a", count: 64)

    private func info(deviceID: String? = nil, platform: String = "macos", host: String = "192.168.1.60",
                      port: UInt16 = 51044, fingerprint: String? = nil) throws -> LanDirectConnectionInfo {
        try .init(host: host, port: port, deviceId: deviceID ?? self.deviceID,
            protocolFingerprint: fingerprint ?? self.fingerprint, deviceName: "Nearby computer", platform: platform)
    }

    func testNativeRouteUsesTheWholeScannedPairAndKeepsOrdinaryDiscoveryUnchanged() throws {
        let value = try info()
        let target = try IOSLanConnectionTarget(LanDirectConnectionInfoCodec.decode(LanDirectConnectionInfoCodec.encode(value)))
        guard case .hostPort(let host, let port) = target.endpoint else { return XCTFail("Not a direct route") }
        XCTAssertEqual(String(describing: host), value.host)
        XCTAssertEqual(port.rawValue, value.port)
        XCTAssertTrue(target.matchesDeviceID(target.key), "Native identity normalization must preserve the SOA binding")
        XCTAssertTrue(P2PConnectionEndpointPolicy.connectionEndpointCandidates(
            for: target.device, liveBonjourControlEndpoints: []).isEmpty,
            "A descriptor alone must not create a direct route")
    }

    func testScanDoesNotAssertTrustPublicKeyOrAuthenticatedCapabilities() throws {
        let target = try IOSLanConnectionTarget(info())
        XCTAssertFalse(target.device.isTrusted)
        XCTAssertFalse(target.device.isConnected)
        XCTAssertNil(target.device.publicKey)
        XCTAssertTrue(target.device.capabilities.isEmpty)
        XCTAssertTrue(target.device.advertisedCapabilities.isEmpty)
        XCTAssertTrue(target.device.portMap.isEmpty)
        XCTAssertNil(target.device.bonjourServiceName)
    }

    func testNativeManagerRequiresExplicitTargetAndRejectsAnIdentitySubstitution() throws {
        let manager = P2PConnectionManager.instance
        let target = try IOSLanConnectionTarget(info())
        XCTAssertTrue(manager.testConnectionEndpointDescriptions(for: target.device).isEmpty)
        XCTAssertEqual(manager.testDirectLANEndpointDescriptions(for: target.device, target: target),
                       [target.endpoint.debugDescription])
        let other = try IOSLanConnectionTarget(info(deviceID: UUID().uuidString))
        XCTAssertTrue(manager.testDirectLANEndpointDescriptions(for: other.device, target: target).isEmpty)
    }

    func testCandidateMustMatchBothSelectedIdentityAndFingerprint() throws {
        let target = try IOSLanConnectionTarget(info())
        try target.requireCandidate(deviceID: deviceID, fingerprint: fingerprint)
        XCTAssertThrowsError(try target.requireCandidate(deviceID: UUID().uuidString, fingerprint: fingerprint)) {
            XCTAssertEqual($0 as? IOSLanConnectionError, .identityMismatch)
        }
        XCTAssertThrowsError(try target.requireCandidate(deviceID: deviceID, fingerprint: String(repeating: "b", count: 64))) {
            XCTAssertEqual($0 as? IOSLanConnectionError, .identityMismatch)
        }
    }

    func testCompletedHandshakeMustBindExactFingerprintAndSignedSOATarget() throws {
        let target = try IOSLanConnectionTarget(info())
        let authority = AuthenticatedRemoteAuthority(protocolSigningAlgorithm: "Ed25519",
            protocolPublicKeyFingerprint: fingerprint, protocolPublicKeyBytes: Data(repeating: 1, count: 32))
        try target.requireAuthenticatedBinding(.init(authority: authority,
            authenticatedRemoteSOAPeerId: PeerSessionArbiter.soaPeerId(from: deviceID)))
        for peer in [nil, PeerSessionArbiter.soaPeerId(from: UUID().uuidString)] as [Data?] {
            XCTAssertThrowsError(try target.requireAuthenticatedBinding(.init(authority: authority,
                authenticatedRemoteSOAPeerId: peer))) {
                XCTAssertEqual($0 as? IOSLanConnectionError, .identityMismatch)
            }
        }
        let other = AuthenticatedRemoteAuthority(protocolSigningAlgorithm: "Ed25519",
            protocolPublicKeyFingerprint: String(repeating: "b", count: 64), protocolPublicKeyBytes: Data(repeating: 2, count: 32))
        XCTAssertThrowsError(try target.requireAuthenticatedBinding(.init(authority: other,
            authenticatedRemoteSOAPeerId: PeerSessionArbiter.soaPeerId(from: deviceID))))
    }

    func testQRCodeCannotCreateOrExpandExistingPins() throws {
        let target = try IOSLanConnectionTarget(info())
        XCTAssertTrue(try target.constrainedPins([]).isEmpty)
        let other = String(repeating: "b", count: 64)
        XCTAssertThrowsError(try target.constrainedPins([other])) {
            XCTAssertEqual($0 as? IOSLanConnectionError, .identityMismatch)
        }
        XCTAssertEqual(try target.constrainedPins([fingerprint, other]), [fingerprint])
    }

    func testEndpointAliasesAndUnsupportedPlatformsCannotBecomeSelectedDesktopIdentities() throws {
        for id in ["host:192.168.1.60", "bonjour:Computer@local."] {
            XCTAssertThrowsError(try IOSLanConnectionTarget(info(deviceID: id))) {
                XCTAssertEqual($0 as? IOSLanConnectionError, .invalidDevice)
            }
        }
        for platform in ["android", "ios", "linux"] {
            XCTAssertThrowsError(try IOSLanConnectionTarget(info(platform: platform))) {
                XCTAssertEqual($0 as? IOSLanConnectionError, .unsupportedPlatform)
            }
        }
        XCTAssertEqual(try IOSLanConnectionTarget(info(platform: "windows")).device.platform, .windows)
    }

    func testRouteDigestChangesWithAnySelectedEndpointOrIdentityField() throws {
        let target = try IOSLanConnectionTarget(info())
        let alternatives = try [info(host: "192.168.1.61"), info(port: 51045), info(deviceID: UUID().uuidString),
                                info(fingerprint: String(repeating: "b", count: 64))]
        for value in alternatives { XCTAssertNotEqual(try IOSLanConnectionTarget(value).endpointDigest, target.endpointDigest) }
    }

    func testScannerRoutesLANAndExistingShortCodesWithoutTrustEffects() throws {
        let value = try info()
        XCTAssertEqual(try IOSScannedConnectionRoute.decode(LanDirectConnectionInfoCodec.encode(value)),
                       .lan(try IOSLanConnectionTarget(value)))
        XCTAssertEqual(try IOSScannedConnectionRoute.decode("skybridge://code/AB23CD45"), .connectionCode("AB23CD45"))
        for text in ["skybridge://lan/v2/invalid", "skybridge://lan/v1/invalid", "https://example.com", "skybridge://pair/old", "skybridge://code/AB12CD34"] {
            XCTAssertThrowsError(try IOSScannedConnectionRoute.decode(text))
        }
    }

    func testCancelledDirectEntryDoesNotStartPairingOrPublishConnection() async throws {
        let manager = P2PConnectionManager.instance
        let value = try info(deviceID: UUID().uuidString)
        let pending = manager.testOnlyPendingPairingDecisionWaiterCount
        let task = Task { @MainActor in try await manager.connect(direct: value) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled connection must not succeed") }
        catch is CancellationError { }
        XCTAssertNil(manager.getNegotiatedSuite(for: value.deviceId))
        XCTAssertEqual(manager.testOnlyPendingPairingDecisionWaiterCount, pending)
    }

    func testCancelledNewConnectionRetiresItsNativeSession() async throws {
        let manager = P2PConnectionManager.instance
        let peer = UUID().uuidString
        defer { manager.testSimulateTerminalCleanup(runtimePeerId: peer) }
        try manager.testInstallAuthenticatedSession(.x25519Ed25519, for: peer)
        let cancel = try manager.testCaptureDirectLANCancellation(for: peer, createdConnection: true)
        await cancel()
        XCTAssertNil(manager.getNegotiatedSuite(for: peer))
    }

    func testCancelledReusedConnectionPreservesExistingNativeSession() async throws {
        let manager = P2PConnectionManager.instance
        let peer = UUID().uuidString
        defer { manager.testSimulateTerminalCleanup(runtimePeerId: peer) }
        try manager.testInstallAuthenticatedSession(.x25519Ed25519, for: peer)
        let cancel = try manager.testCaptureDirectLANCancellation(for: peer, createdConnection: false)
        await cancel()
        XCTAssertEqual(manager.getNegotiatedSuite(for: peer), .x25519Ed25519)
    }

    func testSelectedEntryReusesFinishedBoundInboundRuntimeAlias() async throws {
        // Match the existing manager fixture: initialize only the owned simulator's
        // local self-identity; the synthetic peer keys below do not run a handshake.
        try await SkyBridgeiOSCore.shared.initialize(policy: .classicOnly)
        let manager = P2PConnectionManager.instance
        let stable = UUID().uuidString
        let runtime = "host:127.0.0.1:59401"
        defer { manager.testSimulateTerminalCleanup(runtimePeerId: runtime) }
        try manager.testInstallAuthenticatedSession(.x25519Ed25519, for: runtime)
        try manager.testInstallSelectedSessionBinding(.init(authority: .init(
            protocolSigningAlgorithm: "Ed25519", protocolPublicKeyFingerprint: fingerprint,
            protocolPublicKeyBytes: Data(repeating: 1, count: 32)),
            authenticatedRemoteSOAPeerId: PeerSessionArbiter.soaPeerId(from: stable)), for: runtime)
        manager.testPromotePeerPresentationIdentity(runtimePeerId: runtime, declaredDeviceId: stable)
        XCTAssertEqual(manager.testResolveRuntimePeerId(forAnyPeerId: stable), runtime)
        let retireOriginalOwner = try manager.testCaptureDirectLANCancellation(for: runtime, createdConnection: true)
        let connected = try await manager.connect(direct: info(deviceID: stable))
        XCTAssertTrue(DeviceDetailSessionIdentity.matches(deviceID: stable, sessionDeviceID: connected.id))
        XCTAssertEqual(manager.getNegotiatedSuite(for: stable), .x25519Ed25519)
        await retireOriginalOwner()
        XCTAssertNil(manager.getNegotiatedSuite(for: stable), "The selected entry must preserve the original socket generation and session")
    }

    func testSelectedEntryCannotReuseAnAliasWithWrongFinishedIdentity() async throws {
        try await SkyBridgeiOSCore.shared.initialize(policy: .classicOnly)
        let manager = P2PConnectionManager.instance
        for wrongFingerprint in [false, true] {
            let stable = UUID().uuidString
            let runtime = "host:127.0.0.1:59402"
            defer { manager.testSimulateTerminalCleanup(runtimePeerId: runtime) }
            try manager.testInstallAuthenticatedSession(.x25519Ed25519, for: runtime)
            try manager.testInstallSelectedSessionBinding(.init(authority: .init(
                protocolSigningAlgorithm: "Ed25519",
                protocolPublicKeyFingerprint: wrongFingerprint ? String(repeating: "b", count: 64) : fingerprint,
                protocolPublicKeyBytes: Data(repeating: 1, count: 32)),
                authenticatedRemoteSOAPeerId: PeerSessionArbiter.soaPeerId(from: wrongFingerprint ? stable : UUID().uuidString)),
                for: runtime)
            manager.testPromotePeerPresentationIdentity(runtimePeerId: runtime, declaredDeviceId: stable)
            do { _ = try await manager.connect(direct: info(deviceID: stable)); XCTFail("An alias must not grant authority") }
            catch { XCTAssertEqual(error as? IOSLanConnectionError, .identityMismatch) }
            XCTAssertEqual(manager.getNegotiatedSuite(for: runtime), .x25519Ed25519,
                "A rejected selection must not retire the existing owner")
        }
    }

    func testSelectedEntryCannotReuseAliasWithoutCurrentSessionAuthority() async throws {
        try await SkyBridgeiOSCore.shared.initialize(policy: .classicOnly)
        let manager = P2PConnectionManager.instance
        let stable = UUID().uuidString
        let runtime = "host:127.0.0.1:59403"
        defer { manager.testSimulateTerminalCleanup(runtimePeerId: runtime) }
        try manager.testInstallAuthenticatedSession(.x25519Ed25519, for: runtime)
        manager.testPromotePeerPresentationIdentity(runtimePeerId: runtime, declaredDeviceId: stable)
        do { _ = try await manager.connect(direct: info(deviceID: stable)); XCTFail("Transport keys alone are not peer authority") }
        catch { XCTAssertEqual(error as? IOSLanConnectionError, .identityMismatch) }
        XCTAssertEqual(manager.getNegotiatedSuite(for: runtime), .x25519Ed25519)
    }

    func testSelectedEntryCannotDialUsingAnUnauthenticatedRuntimeAlias() async throws {
        try await SkyBridgeiOSCore.shared.initialize(policy: .classicOnly)
        let manager = P2PConnectionManager.instance
        let stable = UUID().uuidString
        let runtime = "host:127.0.0.1:59404"
        defer { manager.testSimulateTerminalCleanup(runtimePeerId: runtime) }
        manager.installTestPeerRuntimeState(runtimePeerId: runtime)
        manager.testPromotePeerPresentationIdentity(runtimePeerId: runtime, declaredDeviceId: stable)
        let pending = manager.testOnlyPendingPairingDecisionWaiterCount
        do { _ = try await manager.connect(direct: info(deviceID: stable)); XCTFail("An unowned alias must not start a new dial") }
        catch { XCTAssertEqual(error as? IOSLanConnectionError, .identityMismatch) }
        XCTAssertNil(manager.getNegotiatedSuite(for: runtime))
        XCTAssertEqual(manager.testOnlyPendingPairingDecisionWaiterCount, pending)
    }

    func testLateCancellationCannotRetireReplacementNativeSession() async throws {
        let manager = P2PConnectionManager.instance
        let peer = UUID().uuidString
        defer { manager.testSimulateTerminalCleanup(runtimePeerId: peer) }
        try manager.testInstallAuthenticatedSession(.x25519Ed25519, for: peer)
        let cancel = try manager.testCaptureDirectLANCancellation(for: peer, createdConnection: true)
        try manager.testInstallAuthenticatedSession(.x25519Ed25519, for: peer)
        await cancel()
        XCTAssertEqual(manager.getNegotiatedSuite(for: peer), .x25519Ed25519)
    }

    func testLateCancellationCannotRetireRekeyedSessionOnTheSameSocket() async throws {
        let manager = P2PConnectionManager.instance
        let peer = UUID().uuidString
        defer { manager.testSimulateTerminalCleanup(runtimePeerId: peer) }
        try manager.testInstallAuthenticatedSession(.x25519Ed25519, for: peer)
        let cancel = try manager.testCaptureDirectLANCancellation(for: peer, createdConnection: true)
        try manager.testReplaceSessionOnCurrentTransport(for: peer)
        await cancel()
        XCTAssertEqual(manager.getNegotiatedSuite(for: peer), .x25519Ed25519)
    }

    private func record(id: String? = nil, fingerprint: String? = nil, algorithm: String = "Ed25519",
                        status: String = "active", caller: Bool = false, name: String = "Computer",
                        route: AccountDeviceLANRoute? = nil) -> AccountDeviceRecord {
        .init(deviceId: id ?? deviceID, deviceName: name, status: status,
            protocolSigningAlgorithm: algorithm, protocolPublicKeyFingerprint: fingerprint ?? self.fingerprint,
            platformRawValue: "macos", deviceModel: nil, osVersion: nil, appVersion: nil,
            lanAddresses: ["192.168.1.60"], publicAddress: nil, capabilities: [],
            registeredAtEpochMilliseconds: nil, lastSeenAtEpochMilliseconds: nil,
            presenceUpdatedAtEpochMilliseconds: nil, online: true, isCaller: caller, lanControlRoute: route)
    }

    private func snapshot(_ records: [AccountDeviceRecord], scope: String? = "test-account-scope",
                          callerStatus: String = "active") -> AccountDeviceListSnapshot {
        let caller = record(id: "15C69BDD-C58F-482D-9426-421C5A727869", status: callerStatus, caller: true)
        return .init(generatedAtEpochMilliseconds: 1_000, callerDeviceId: caller.deviceId, truncated: false,
            devices: [caller] + records, accountScope: scope)
    }

    private func accountSelection(_ record: AccountDeviceRecord? = nil) throws -> IOSAccountConnectionSelection {
        let target = record ?? self.record()
        return try .init(record: target, snapshot: snapshot([target]), isAuthenticated: true, callerRemoved: false, authenticationGeneration: 1)
    }

    func testAccountSelectionRequiresActiveCallerTargetAndLocallyBoundScope() throws {
        let target = record()
        for state in [snapshot([target], scope: nil), snapshot([target], scope: ""),
                      snapshot([target], callerStatus: "frozen"), snapshot([]), snapshot([record(status: "pending")]),
                      snapshot([record(status: "frozen")])] {
            XCTAssertThrowsError(try IOSAccountConnectionSelection(record: target, snapshot: state,
                isAuthenticated: true, callerRemoved: false, authenticationGeneration: 1))
        }
        for (authenticated, removed) in [(false, false), (true, true)] {
            XCTAssertThrowsError(try IOSAccountConnectionSelection(record: target, snapshot: snapshot([target]),
                isAuthenticated: authenticated, callerRemoved: removed, authenticationGeneration: 1))
        }
        let caller = try XCTUnwrap(snapshot([target]).devices.first)
        XCTAssertThrowsError(try IOSAccountConnectionSelection(record: caller, snapshot: snapshot([target]),
            isAuthenticated: true, callerRemoved: false, authenticationGeneration: 1))
    }

    func testAccountSelectionRejectsChangedAccountRemovalAndIdentityRotation() throws {
        let selection = try accountSelection()
        for state in [snapshot([record()], scope: "new-login"), snapshot([]),
                      snapshot([record(fingerprint: String(repeating: "b", count: 64))]),
                      snapshot([record(algorithm: "ML-DSA-65")]), snapshot([record(status: "frozen")])] {
            XCTAssertThrowsError(try selection.requireCurrent(snapshot: state, isAuthenticated: true, callerRemoved: false, authenticationGeneration: 1))
        }
        XCTAssertThrowsError(try selection.requireCurrent(snapshot: nil, isAuthenticated: false, callerRemoved: false, authenticationGeneration: 1))
        XCTAssertThrowsError(try selection.requireCurrent(snapshot: snapshot([record()]), isAuthenticated: true,
            callerRemoved: false, authenticationGeneration: 2), "Signing back into the same account must retire the old selection")
    }

    func testAccountRefreshMetadataAndOnlineExpiryDoNotInvalidateStableSelection() throws {
        let selection = try accountSelection()
        let refreshed = snapshot([record(name: "Updated display name")]).markingAllOffline()
        try selection.requireCurrent(snapshot: refreshed, isAuthenticated: true, callerRemoved: false, authenticationGeneration: 1)
    }

    func testAccountDiscoveryRequiresStableIdentityAndMatchingAdvertisedFingerprint() throws {
        let selection = try accountSelection()
        let target = try IOSLanConnectionTarget(info()).device
        try selection.requireDiscovery(target, fingerprint: fingerprint.uppercased())
        for fp in [nil, "", String(repeating: "b", count: 64)] as [String?] {
            XCTAssertThrowsError(try selection.requireDiscovery(target, fingerprint: fp))
        }
        let sameNameOtherDevice = try IOSLanConnectionTarget(info(deviceID: UUID().uuidString)).device
        XCTAssertThrowsError(try selection.requireDiscovery(sameNameOtherDevice, fingerprint: fingerprint))
    }

    func testAccountCandidateAndFinishedMustMatchSelectedSigningAlgorithm() throws {
        let target = IOSSelectedConnectionTarget.account(try accountSelection())
        try target.requireCandidate(deviceID: deviceID, fingerprint: fingerprint, signingAlgorithm: "Ed25519")
        XCTAssertThrowsError(try target.requireCandidate(deviceID: deviceID, fingerprint: fingerprint, signingAlgorithm: "ML-DSA-65"))
        for algorithm in ["Ed25519", "ML-DSA-65"] {
            let binding = AuthenticatedHandshakePeerBinding(authority: .init(protocolSigningAlgorithm: algorithm,
                protocolPublicKeyFingerprint: fingerprint, protocolPublicKeyBytes: Data(repeating: 1, count: 32)),
                authenticatedRemoteSOAPeerId: PeerSessionArbiter.soaPeerId(from: deviceID))
            if algorithm == "Ed25519" { try target.requireAuthenticatedBinding(binding) }
            else { XCTAssertThrowsError(try target.requireAuthenticatedBinding(binding)) }
        }
    }

    func testAccountSelectionCannotGrantPinsOrUseRosterAddressesAsControlEndpoints() throws {
        let target = IOSSelectedConnectionTarget.account(try accountSelection())
        XCTAssertNil(target.directLAN)
        XCTAssertTrue(try target.constrainedPins([]).isEmpty)
        XCTAssertThrowsError(try target.constrainedPins([String(repeating: "b", count: 64)]))
        let device = try IOSLanConnectionTarget(info()).device
        XCTAssertTrue(P2PConnectionManager.instance.testSelectedEndpointDescriptions(for: device, target: target).isEmpty)
    }

    func testAccountEndpointUsesAndWithdrawsTheExistingLiveBonjourRoute() throws {
        let discovery = DeviceDiscoveryManager.instance
        let prior = discovery.debugCaptureState()
        defer { discovery.debugRestoreState(prior) }
        let record = self.record(id: UUID().uuidString)
        let target = IOSSelectedConnectionTarget.account(try accountSelection(record))
        let device = DiscoveredDevice(id: "id:\(record.deviceId.lowercased())", name: "Account control route",
            bonjourServiceName: "Account control route", modelName: "Mac", platform: .macOS, osVersion: "",
            ipAddress: "192.168.1.60", bonjourServiceType: DiscoveryServiceType.skybridge.rawValue,
            bonjourServiceDomain: "local.", services: [DiscoveryServiceType.skybridge.rawValue],
            portMap: [DiscoveryServiceType.skybridge.rawValue: 51044])
        let manager = P2PConnectionManager.instance
        XCTAssertTrue(manager.testSelectedEndpointDescriptions(for: device, target: target).isEmpty)
        _ = discovery.debugReplaceAdvertisementSnapshot(device, endpointKey: "account-control-endpoint", serviceType: .skybridge)
        let routes = manager.testSelectedEndpointDescriptions(for: device, target: target)
        XCTAssertFalse(routes.isEmpty)
        XCTAssertTrue(routes.allSatisfy { $0.contains(DiscoveryServiceType.skybridge.rawValue) })
        discovery.debugRestoreState(prior)
        XCTAssertTrue(manager.testSelectedEndpointDescriptions(for: device, target: target).isEmpty)
    }

    func testMalformedAccountIdentityNeverBecomesAConnectionConstraint() throws {
        for target in [record(id: "host:192.168.1.60"), record(fingerprint: "invalid"),
                       record(fingerprint: String(repeating: "z", count: 64)), record(algorithm: "unknown")] {
            XCTAssertThrowsError(try accountSelection(target))
        }
    }

    func testCancelledAccountEntryDoesNotStartPairingOrPublishConnection() async throws {
        let manager = P2PConnectionManager.instance
        let selection = try accountSelection(record(id: UUID().uuidString))
        let device = try IOSLanConnectionTarget(info(deviceID: selection.record.deviceId)).device
        let pending = manager.testOnlyPendingPairingDecisionWaiterCount
        let task = Task { @MainActor in try await manager.connect(account: selection, to: device) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled selection must not connect") }
        catch is CancellationError { }
        XCTAssertNil(manager.getNegotiatedSuite(for: device.id))
        XCTAssertEqual(manager.testOnlyPendingPairingDecisionWaiterCount, pending)
    }

    func testDeviceActionsMatchOnlyTheSelectedStrongSessionIdentity() {
        XCTAssertTrue(DeviceDetailSessionIdentity.matches(deviceID: deviceID, sessionDeviceID: "id:\(deviceID.lowercased())"))
        for other in [nil, "", UUID().uuidString, "host:192.168.1.60", "bonjour:Computer@local."] as [String?] {
            XCTAssertFalse(DeviceDetailSessionIdentity.matches(deviceID: deviceID, sessionDeviceID: other))
        }
        XCTAssertFalse(DeviceDetailSessionIdentity.matches(deviceID: "host:192.168.1.60", sessionDeviceID: "host:192.168.1.60"))
    }
}


extension IOSLanConnectionTargetTests {
    private func route(port: UInt16 = 51173, addresses: [String] = ["192.168.1.60", "10.0.0.5"],
                       expiresAt: Int64 = 91_000) throws -> AccountDeviceLANRoute {
        try .init(addresses: addresses, port: port, expiresAt: expiresAt)
    }

    func testAccountRouteConnectsWithoutBonjourAndOffersAllReportedInterfaces() throws {
        let now = ContinuousClock.now
        let row = record(route: try route())
        let state = snapshot([row]).observingRoutes(requestStartedAt: now, now: now)
        let account = try accountSelection(row)
        let selected = try IOSAccountLANRouteSelection(account: account, snapshot: state, now: now)
        let target = IOSSelectedConnectionTarget.accountLAN(selected)
        let manager = P2PConnectionManager.instance
        XCTAssertEqual(manager.testSelectedEndpointDescriptions(for: selected.primary.device, target: target),
                       selected.targets.map { $0.endpoint.debugDescription })
        XCTAssertEqual(selected.targets.count, 2)
        XCTAssertTrue(manager.testConnectionEndpointDescriptions(for: selected.primary.device).isEmpty)
        XCTAssertFalse(selected.primary.device.isTrusted)
        XCTAssertNil(selected.primary.device.publicKey)
        XCTAssertTrue(selected.primary.device.capabilities.isEmpty)
        try target.requireCandidate(deviceID: deviceID, fingerprint: fingerprint, signingAlgorithm: "Ed25519")
        XCTAssertThrowsError(try target.requireCandidate(deviceID: deviceID, fingerprint: fingerprint, signingAlgorithm: "ML-DSA-65"))
        XCTAssertThrowsError(try target.requireCandidate(deviceID: deviceID, fingerprint: String(repeating: "b", count: 64), signingAlgorithm: "Ed25519"))
        XCTAssertThrowsError(try target.requireCandidate(deviceID: UUID().uuidString, fingerprint: fingerprint, signingAlgorithm: "Ed25519"))
    }

    func testAccountRouteCannotUseUnobservedOrExpiredResponse() throws {
        let now = ContinuousClock.now
        let row = record(route: try route())
        let account = try accountSelection(row)
        XCTAssertThrowsError(try IOSAccountLANRouteSelection(account: account, snapshot: snapshot([row]), now: now))
        let state = snapshot([row]).observingRoutes(requestStartedAt: now, now: now)
        XCTAssertThrowsError(try IOSAccountLANRouteSelection(account: account, snapshot: state, now: now.advanced(by: .seconds(90))))
        XCTAssertThrowsError(try IOSAccountLANRouteSelection(account: account, snapshot: state.markingAllOffline(), now: now))
    }

    func testAccountRouteRechecksCurrentPortIdentityOwnerAndAuthenticationGeneration() throws {
        let now = ContinuousClock.now
        let row = record(route: try route())
        func observed(_ value: AccountDeviceListSnapshot) -> AccountDeviceListSnapshot {
            value.observingRoutes(requestStartedAt: now, now: now)
        }
        let state = observed(snapshot([row]))
        let selected = try IOSAccountLANRouteSelection(account: accountSelection(row), snapshot: state, now: now)
        let replacements = [snapshot([record(route: try route(port: 51164))]),
            snapshot([record(route: try route(addresses: ["10.0.0.6"]))]),
            snapshot([record(fingerprint: String(repeating: "b", count: 64), route: try route())]),
            snapshot([record(algorithm: "ML-DSA-65", route: try route())]), snapshot([record()]),
            snapshot([row], scope: "other-account"), snapshot([row], callerStatus: "pending")]
        for replacement in replacements {
            XCTAssertThrowsError(try selected.requireCurrent(snapshot: observed(replacement), isAuthenticated: true,
                callerRemoved: false, authenticationGeneration: 1, now: now))
        }
        XCTAssertThrowsError(try selected.requireCurrent(snapshot: state, isAuthenticated: true,
            callerRemoved: false, authenticationGeneration: 2, now: now))
        XCTAssertThrowsError(try selected.requireCurrent(snapshot: state, isAuthenticated: false,
            callerRemoved: false, authenticationGeneration: 1, now: now))
        let refreshed = snapshot([record(route: try route(expiresAt: 121_000))])
            .observingRoutes(requestStartedAt: now.advanced(by: .seconds(30)), now: now.advanced(by: .seconds(30)))
        try selected.requireCurrent(snapshot: refreshed, isAuthenticated: true, callerRemoved: false,
            authenticationGeneration: 1, now: now.advanced(by: .seconds(40)))
        XCTAssertThrowsError(try selected.requireCurrent(snapshot: refreshed, isAuthenticated: true, callerRemoved: false,
            authenticationGeneration: 1, now: now.advanced(by: .seconds(91))), "A refresh cannot extend an in-flight dial indefinitely")
    }
}
