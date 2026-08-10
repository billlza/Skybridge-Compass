import XCTest
import SkyBridgeProtocolCore

final class ApplePeerConnectivityPolicyTests: XCTestCase {
    private let fingerprintA = String(repeating: "a", count: 64)
    private let fingerprintB = String(repeating: "b", count: 64)

    func testCanonicalServiceKindsHaveOneSharedSourceOfTruth() {
        XCTAssertEqual(
            ApplePeerConnectivityPolicy.ServiceKind(
                serviceType: BonjourInteropProtocolContract.controlServiceType
            ),
            .control
        )
        XCTAssertEqual(
            ApplePeerConnectivityPolicy.ServiceKind(
                serviceType: BonjourInteropProtocolContract.fileTransferServiceType
            ),
            .fileTransfer
        )
        XCTAssertEqual(
            ApplePeerConnectivityPolicy.ServiceKind(
                serviceType: BonjourInteropProtocolContract.remoteControlServiceType
            ),
            .remoteControl
        )
    }

    func testRouteIdentityNormalizesTypeAndDomainWithoutChangingInstanceName() throws {
        let route = try XCTUnwrap(
            ApplePeerConnectivityPolicy.BonjourRouteIdentity(
                name: "Bill’s iPad",
                type: " _SKYBRIDGE._TCP ",
                domain: "LOCAL"
            )
        )

        XCTAssertEqual(route.name, "Bill’s iPad")
        XCTAssertEqual(route.type, BonjourInteropProtocolContract.controlServiceType)
        XCTAssertEqual(route.domain, "local.")
    }

    func testStrongAuthorityMatchOutranksExactRouteMatch() throws {
        let exactRoute = try route(name: "Exact")
        let authorityRoute = try route(name: "Renamed")
        let target = ApplePeerConnectivityPolicy.DialTarget(
            deviceIds: ["ios-device-00000001"],
            protocolPublicKeyFingerprints: [fingerprintA],
            routes: [exactRoute]
        )
        let claims = [
            claim(
                route: exactRoute,
                deviceId: nil,
                fingerprint: nil
            ),
            claim(
                route: authorityRoute,
                deviceId: "ios-device-00000001",
                fingerprint: fingerprintA
            )
        ]

        XCTAssertEqual(
            ApplePeerConnectivityPolicy.orderedEligibleClaimIndices(
                target: target,
                claims: claims,
                requiredServiceKind: .control
            ),
            [1, 0]
        )
    }

    func testDeviceAuthorityNormalizesAliasPrefixAndCase() throws {
        let route = try route(name: "iPad Transfer Owner")
        let target = ApplePeerConnectivityPolicy.DialTarget(
            deviceIds: ["id:07cb9a6e-7492-4680-9dd7-f37dc8568891"],
            protocolPublicKeyFingerprints: [],
            routes: []
        )
        let claim = self.claim(
            route: route,
            deviceId: "07CB9A6E-7492-4680-9DD7-F37DC8568891",
            fingerprint: nil
        )

        XCTAssertEqual(
            target.deviceIds,
            ["07cb9a6e-7492-4680-9dd7-f37dc8568891"]
        )
        XCTAssertEqual(
            claim.authority.deviceId,
            "07cb9a6e-7492-4680-9dd7-f37dc8568891"
        )
        XCTAssertEqual(
            ApplePeerConnectivityPolicy.match(
                target: target,
                claim: claim,
                requiredServiceKind: .control
            ),
            .eligible(.strongAuthority)
        )
    }

    func testConflictingAuthorityCannotBorrowMatchingRouteName() throws {
        let route = try route(name: "Shared Name")
        let target = ApplePeerConnectivityPolicy.DialTarget(
            deviceIds: ["ios-device-00000001"],
            protocolPublicKeyFingerprints: [fingerprintA],
            routes: [route]
        )
        let conflicting = claim(
            route: route,
            deviceId: "other-device-0000001",
            fingerprint: fingerprintB
        )

        XCTAssertEqual(
            ApplePeerConnectivityPolicy.match(
                target: target,
                claim: conflicting,
                requiredServiceKind: .control
            ),
            .rejectedAuthorityConflict
        )
    }

    func testMatchingDeviceIdCannotOverrideConflictingFingerprint() throws {
        let route = try route(name: "Conflicting Fingerprint")
        let target = ApplePeerConnectivityPolicy.DialTarget(
            deviceIds: ["ios-device-00000001"],
            protocolPublicKeyFingerprints: [fingerprintA],
            routes: []
        )
        let conflicting = claim(
            route: route,
            deviceId: "ios-device-00000001",
            fingerprint: fingerprintB
        )

        XCTAssertEqual(
            ApplePeerConnectivityPolicy.match(
                target: target,
                claim: conflicting,
                requiredServiceKind: .control
            ),
            .rejectedAuthorityConflict
        )
    }

    func testMatchingFingerprintCannotOverrideConflictingDeviceId() throws {
        let route = try route(name: "Conflicting Device ID")
        let target = ApplePeerConnectivityPolicy.DialTarget(
            deviceIds: ["ios-device-00000001"],
            protocolPublicKeyFingerprints: [fingerprintA],
            routes: []
        )
        let conflicting = claim(
            route: route,
            deviceId: "other-device-0000001",
            fingerprint: fingerprintA
        )

        XCTAssertEqual(
            ApplePeerConnectivityPolicy.match(
                target: target,
                claim: conflicting,
                requiredServiceKind: .control
            ),
            .rejectedAuthorityConflict
        )
    }

    func testPersistedMetadataIsNeverDialEligible() throws {
        let route = try route(name: "Persisted")
        let target = ApplePeerConnectivityPolicy.DialTarget(
            deviceIds: [],
            protocolPublicKeyFingerprints: [],
            routes: [route]
        )
        let claim = ApplePeerConnectivityPolicy.RouteClaim(
            route: route,
            authority: .init(
                deviceId: nil,
                protocolPublicKeyFingerprint: nil,
                platform: nil
            ),
            provenance: .persistedMetadata
        )

        XCTAssertEqual(
            ApplePeerConnectivityPolicy.match(
                target: target,
                claim: claim,
                requiredServiceKind: .control
            ),
            .rejectedUnprovenRoute
        )
    }

    func testRemoteControlMediaRouteAcceptsBoundInfrastructureLinkLocalEvidence() {
        let evidence = ApplePeerConnectivityPolicy.RemoteControlRouteEvidence(
            provenance: .liveBrowser,
            requestedServiceType: BonjourInteropProtocolContract.remoteControlServiceType,
            requestedInterfaceName: "en0",
            requestedInterfaceClass: .infrastructure,
            pathUsesRequestedInterfaceType: true,
            resolvedAddressClass: .linkLocalIPv6,
            resolvedInterfaceScope: "en0"
        )

        XCTAssertNil(
            ApplePeerConnectivityPolicy.remoteControlRouteRejectionReason(for: evidence)
        )
        XCTAssertTrue(
            ApplePeerConnectivityPolicy.remoteControlInterfaceScopeMatches(evidence)
        )
    }

    func testRemoteControlMediaRouteRejectsPeerToPeerAndMismatchedEvidence() {
        XCTAssertFalse(ApplePeerConnectivityPolicy.remoteControlMediaAllowsPeerToPeer)
        XCTAssertFalse(
            ApplePeerConnectivityPolicy.remoteControlMediaIncludesPeerToPeer(
                for: .peerToPeer
            )
        )

        let peerToPeer = ApplePeerConnectivityPolicy.RemoteControlRouteEvidence(
            provenance: .liveBrowser,
            requestedServiceType: BonjourInteropProtocolContract.remoteControlServiceType,
            requestedInterfaceName: "awdl0",
            requestedInterfaceClass: .peerToPeer,
            pathUsesRequestedInterfaceType: true,
            resolvedAddressClass: .linkLocalIPv6,
            resolvedInterfaceScope: "awdl0"
        )
        XCTAssertEqual(
            ApplePeerConnectivityPolicy.remoteControlRouteRejectionReason(for: peerToPeer),
            .peerToPeerMediaRouteDisallowed
        )

        let wrongScope = ApplePeerConnectivityPolicy.RemoteControlRouteEvidence(
            provenance: .liveBrowser,
            requestedServiceType: BonjourInteropProtocolContract.remoteControlServiceType,
            requestedInterfaceName: "en0",
            requestedInterfaceClass: .infrastructure,
            pathUsesRequestedInterfaceType: true,
            resolvedAddressClass: .linkLocalIPv6,
            resolvedInterfaceScope: "awdl0"
        )
        XCTAssertEqual(
            ApplePeerConnectivityPolicy.remoteControlRouteRejectionReason(for: wrongScope),
            .resolvedScopeMismatch
        )

        let persisted = ApplePeerConnectivityPolicy.RemoteControlRouteEvidence(
            provenance: .persistedMetadata,
            requestedServiceType: BonjourInteropProtocolContract.remoteControlServiceType,
            requestedInterfaceName: "en0",
            requestedInterfaceClass: .infrastructure,
            pathUsesRequestedInterfaceType: true,
            resolvedAddressClass: .routable,
            resolvedInterfaceScope: nil
        )
        XCTAssertEqual(
            ApplePeerConnectivityPolicy.remoteControlRouteRejectionReason(for: persisted),
            .untrustedProvenance
        )
    }

    func testRemoteControlMediaInterfaceBindingSelectsExactInfrastructureScope() {
        let evidence = ApplePeerConnectivityPolicy.RemoteControlMediaInterfaceBindingEvidence(
            advertisedHostRelation: .unspecified,
            authenticatedAddressClass: .linkLocalIPv6,
            authenticatedInterfaceScope: "en0",
            candidates: [
                .init(
                    name: "en1",
                    index: 8,
                    interfaceClass: .infrastructure,
                    pathUsesInterfaceType: true
                ),
                .init(
                    name: "en0",
                    index: 7,
                    interfaceClass: .infrastructure,
                    pathUsesInterfaceType: true
                )
            ]
        )

        XCTAssertEqual(
            ApplePeerConnectivityPolicy.remoteControlMediaInterfaceBindingDecision(
                for: evidence
            ),
            .use(interfaceName: "en0", interfaceIndex: 7)
        )
    }

    func testRemoteControlMediaInterfaceBindingRejectsUnsafeOrAmbiguousRoutes() {
        let baseCandidate = ApplePeerConnectivityPolicy.RemoteControlMediaInterfaceCandidate(
            name: "en0",
            index: 7,
            interfaceClass: .infrastructure,
            pathUsesInterfaceType: true
        )

        XCTAssertEqual(
            ApplePeerConnectivityPolicy.remoteControlMediaInterfaceBindingDecision(
                for: .init(
                    advertisedHostRelation: .mismatch,
                    authenticatedAddressClass: .routable,
                    authenticatedInterfaceScope: nil,
                    candidates: [baseCandidate]
                )
            ),
            .reject(.advertisedHostMismatch)
        )
        XCTAssertEqual(
            ApplePeerConnectivityPolicy.remoteControlMediaInterfaceBindingDecision(
                for: .init(
                    advertisedHostRelation: .exactAuthenticatedHost,
                    authenticatedAddressClass: .linkLocalIPv6,
                    authenticatedInterfaceScope: nil,
                    candidates: [baseCandidate]
                )
            ),
            .reject(.missingInterfaceScope)
        )
        XCTAssertEqual(
            ApplePeerConnectivityPolicy.remoteControlMediaInterfaceBindingDecision(
                for: .init(
                    advertisedHostRelation: .unspecified,
                    authenticatedAddressClass: .linkLocalIPv6,
                    authenticatedInterfaceScope: "awdl0",
                    candidates: [
                        .init(
                            name: "awdl0",
                            index: 11,
                            interfaceClass: .peerToPeer,
                            pathUsesInterfaceType: true
                        )
                    ]
                )
            ),
            .reject(.peerToPeerForbidden)
        )
        XCTAssertEqual(
            ApplePeerConnectivityPolicy.remoteControlMediaInterfaceBindingDecision(
                for: .init(
                    advertisedHostRelation: .unspecified,
                    authenticatedAddressClass: .routable,
                    authenticatedInterfaceScope: nil,
                    candidates: [
                        baseCandidate,
                        .init(
                            name: "en1",
                            index: 8,
                            interfaceClass: .infrastructure,
                            pathUsesInterfaceType: true
                        )
                    ]
                )
            ),
            .reject(.ambiguousInterface)
        )
    }

    func testRemoteControlInterfaceClassificationIsSharedAcrossAdapters() {
        XCTAssertEqual(
            ApplePeerConnectivityPolicy.remoteControlInterfaceClass(
                interfaceName: "en0",
                isWiFi: true,
                isWiredEthernet: false
            ),
            .infrastructure
        )
        XCTAssertEqual(
            ApplePeerConnectivityPolicy.remoteControlInterfaceClass(
                interfaceName: "awdl0",
                isWiFi: true,
                isWiredEthernet: false
            ),
            .peerToPeer
        )
        XCTAssertEqual(
            ApplePeerConnectivityPolicy.remoteControlInterfaceClass(
                interfaceName: "utun9",
                isWiFi: false,
                isWiredEthernet: false
            ),
            .unsupported
        )
    }

    func testConnectionFailureClassificationIsStableAcrossAdapters() {
        XCTAssertEqual(
            ApplePeerConnectivityPolicy.connectionFailureCode(
                event: .timedOut,
                pathReason: .localNetworkDenied,
                errorDescriptions: []
            ),
            .localNetworkPermissionDenied
        )
        XCTAssertEqual(
            ApplePeerConnectivityPolicy.connectionFailureCode(
                event: .failed,
                pathReason: nil,
                errorDescriptions: ["Local network prohibited by privacy settings"]
            ),
            .localNetworkPermissionDenied
        )
        XCTAssertEqual(
            ApplePeerConnectivityPolicy.connectionFailureCode(
                event: .timedOut,
                pathReason: .wifiDenied,
                errorDescriptions: []
            ),
            .transportTimedOut
        )
    }

    func testApplePeersRequireCurrentBonjourRouteEvidence() {
        XCTAssertTrue(
            ApplePeerConnectivityPolicy.requiresLiveBonjourRoute(platform: .macOS)
        )
        XCTAssertTrue(
            ApplePeerConnectivityPolicy.requiresLiveBonjourRoute(platform: .iOS)
        )
        XCTAssertTrue(
            ApplePeerConnectivityPolicy.requiresLiveBonjourRoute(platform: .iPadOS)
        )
        XCTAssertFalse(
            ApplePeerConnectivityPolicy.requiresLiveBonjourRoute(platform: .windows)
        )
    }

    func testMacAndIOSAdaptersDelegateToTheSharedPolicy() throws {
        let macBonjourPolicy = try repositorySource(
            "Sources/SkyBridgeCore/P2P/P2PDiscoveryBonjourPolicy.swift"
        )
        let macP2P = try repositorySource(
            "Sources/SkyBridgeCore/P2P/P2PDiscoveryService.swift"
        )
        let sharedPermission = try repositorySource(
            "Sources/SkyBridgeAppleTransport/Network/NetworkFrameworkLocalNetworkPermissionClassifier.swift"
        )
        let macPermissionAdapter = try repositorySource(
            "Sources/SkyBridgeCore/Network/NetworkFrameworkLocalNetworkPermissionClassifier.swift"
        )
        let iosEndpointPolicy = try repositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionEndpointPolicy.swift"
        )
        let iosConnectionManager = try repositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift"
        )
        let iosP2PError = try repositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Core/P2P/P2PError.swift"
        )
        let macP2PError = try repositorySource(
            "Sources/SkyBridgeCore/P2P/P2PDiscoveryModels.swift"
        )
        let iosDiscovery = try repositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/DeviceDiscoveryManager.swift"
        )
        let iosRemoteControlRoutePolicy = try repositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Core/RemoteConnection/RemoteDesktop/RemoteDesktopLANRoutePolicy.swift"
        )
        let macRemoteControlServer = try repositorySource(
            "Sources/SkyBridgeCore/RemoteControl/RemoteControlServer.swift"
        )

        XCTAssertTrue(macBonjourPolicy.contains("ApplePeerConnectivityPolicy.DialTarget"))
        XCTAssertTrue(macP2P.contains("ApplePeerConnectivityPolicy.match("))
        XCTAssertTrue(
            sharedPermission.contains("ApplePeerConnectivityPolicy.isLocalNetworkPermissionDenied(")
        )
        XCTAssertTrue(
            macPermissionAdapter.contains(
                "SkyBridgeAppleTransport.NetworkFrameworkLocalNetworkPermissionClassifier"
            )
        )
        XCTAssertTrue(iosEndpointPolicy.contains("ApplePeerConnectivityPolicy.orderedEligibleClaimIndices("))
        XCTAssertTrue(
            iosConnectionManager.contains("ApplePeerConnectivityPolicy")
                && iosConnectionManager.contains(".connectionFailureCode(")
        )
        XCTAssertTrue(iosP2PError.contains("case noLiveControlRoute"))
        XCTAssertTrue(macP2PError.contains("case noLiveControlRoute"))
        XCTAssertTrue(
            iosRemoteControlRoutePolicy.contains(
                "ApplePeerConnectivityPolicy.remoteControlRouteRejectionReason(for: evidence)"
            )
        )
        XCTAssertTrue(
            macRemoteControlServer.contains(
                "ApplePeerConnectivityPolicy.remoteControlMediaAllowsPeerToPeer"
            )
        )
        XCTAssertFalse(
            macP2P.contains("interface: nil"),
            "macOS must not reconstruct a Bonjour endpoint without its live browser route ownership."
        )
        for duplicatedLiteral in [
            "case skybridge = \"_skybridge._tcp\"",
            "case skybridgeTransfer = \"_skybridge-xfer._tcp\"",
            "case skybridgeRemote = \"_skybridge-rd._tcp\""
        ] {
            XCTAssertFalse(
                iosDiscovery.contains(duplicatedLiteral),
                "iOS service constants must come from SkyBridgeProtocolCore: \(duplicatedLiteral)"
            )
        }
    }

    private func route(
        name: String
    ) throws -> ApplePeerConnectivityPolicy.BonjourRouteIdentity {
        try XCTUnwrap(
            ApplePeerConnectivityPolicy.BonjourRouteIdentity(
                name: name,
                type: BonjourInteropProtocolContract.controlServiceType,
                domain: "local."
            )
        )
    }

    private func claim(
        route: ApplePeerConnectivityPolicy.BonjourRouteIdentity,
        deviceId: String?,
        fingerprint: String?
    ) -> ApplePeerConnectivityPolicy.RouteClaim {
        ApplePeerConnectivityPolicy.RouteClaim(
            route: route,
            authority: .init(
                deviceId: deviceId,
                protocolPublicKeyFingerprint: fingerprint,
                platform: .iPadOS
            ),
            provenance: .liveBrowser
        )
    }

    private func repositorySource(_ relativePath: String) throws -> String {
        try String(
            contentsOf: URL(
                fileURLWithPath: FileManager.default.currentDirectoryPath
            ).appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
