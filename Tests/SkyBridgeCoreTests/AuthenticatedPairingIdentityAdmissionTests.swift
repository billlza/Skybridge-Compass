import Foundation
import XCTest

@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
final class AuthenticatedPairingIdentityAdmissionTests: XCTestCase {
    func testSignedSOAAndExactProtocolAuthorityAdmitTheDeclaredDeviceID() throws {
        let deviceId = UUID().uuidString.lowercased()
        let publicKey = Data(repeating: 0x31, count: 1_952)
        let payload = makePayload(deviceId: deviceId, publicKey: publicKey)
        let authority = try makeAuthority(for: payload)
        let authenticatedSOAPeerId = PeerSessionArbiter.soaPeerId(from: deviceId)

        let admitted = AuthenticatedProtocolIdentityBinding.validatedPairingIdentityAuthority(
            payload: payload,
            authority: authority,
            authenticatedRemoteSOAPeerId: authenticatedSOAPeerId,
            sessionDeviceIds: ["id:\(deviceId)", "forged-alias"],
            operatorApprovalReceipt: nil
        )

        XCTAssertEqual(admitted?.declaredDeviceId, deviceId)
        XCTAssertEqual(admitted?.protocolPublicKey, publicKey)
        XCTAssertEqual(
            Set(admitted?.authorizedDeviceIds ?? []),
            Set([deviceId, "id:\(deviceId)"])
        )
        XCTAssertFalse(admitted?.authorizedDeviceIds.contains("forged-alias") == true)
    }

    func testForgedDeclaredDeviceIDIsRejectedBeforePersistenceAuthorization() throws {
        let authenticatedDeviceId = UUID().uuidString.lowercased()
        let forgedDeviceId = UUID().uuidString.lowercased()
        let publicKey = Data(repeating: 0x42, count: 1_952)
        let payload = makePayload(deviceId: forgedDeviceId, publicKey: publicKey)
        let authority = try makeAuthority(for: payload)

        let admitted = AuthenticatedProtocolIdentityBinding.validatedPairingIdentityAuthority(
            payload: payload,
            authority: authority,
            authenticatedRemoteSOAPeerId: PeerSessionArbiter.soaPeerId(from: authenticatedDeviceId),
            sessionDeviceIds: [authenticatedDeviceId],
            operatorApprovalReceipt: nil
        )

        XCTAssertNil(admitted)
    }

    func testMalformedDeclaredDeviceIDAndMissingHandshakeAuthorityFailClosed() async throws {
        let malformedDeviceId = "device\u{0000}id"
        let publicKey = Data(repeating: 0x43, count: 1_952)
        let payload = makePayload(deviceId: malformedDeviceId, publicKey: publicKey)
        let authority = try makeAuthority(for: payload)

        XCTAssertNil(
            AuthenticatedProtocolIdentityBinding.validatedPairingIdentityAuthority(
                payload: payload,
                authority: authority,
                authenticatedRemoteSOAPeerId: PeerSessionArbiter.soaPeerId(from: malformedDeviceId),
                sessionDeviceIds: [],
                operatorApprovalReceipt: nil
            )
        )
        let missingAuthority =
            await AuthenticatedProtocolIdentityBinding
            .validatedPairingIdentityAuthorityForPersistence(
                payload: makePayload(
                    deviceId: UUID().uuidString.lowercased(),
                    publicKey: publicKey
                ),
                authority: nil,
                authenticatedRemoteSOAPeerId: nil,
                sessionDeviceIds: []
            )
        XCTAssertNil(missingAuthority)
    }

    func testWrongAlgorithmOrPublicKeyIsRejectedEvenWhenDeviceIDMatchesSOA() throws {
        let deviceId = UUID().uuidString.lowercased()
        let expectedPublicKey = Data(repeating: 0x53, count: 1_952)
        let expectedPayload = makePayload(deviceId: deviceId, publicKey: expectedPublicKey)
        let authority = try makeAuthority(for: expectedPayload)
        let authenticatedSOAPeerId = PeerSessionArbiter.soaPeerId(from: deviceId)

        let fingerprintOnlyAuthority = AuthenticatedRemoteAuthority(
            protocolSigningAlgorithm: authority.protocolSigningAlgorithm,
            protocolPublicKeyFingerprint: authority.protocolPublicKeyFingerprint
        )
        XCTAssertNil(
            AuthenticatedProtocolIdentityBinding.validatedPairingIdentityAuthority(
                payload: expectedPayload,
                authority: fingerprintOnlyAuthority,
                authenticatedRemoteSOAPeerId: authenticatedSOAPeerId,
                sessionDeviceIds: [deviceId],
                operatorApprovalReceipt: nil
            ),
            "A current SOA handshake must bind the exact raw protocol key, not only its advertised fingerprint."
        )

        let wrongKeyPayload = makePayload(
            deviceId: deviceId,
            publicKey: Data(repeating: 0x54, count: 1_952)
        )
        XCTAssertNil(
            AuthenticatedProtocolIdentityBinding.validatedPairingIdentityAuthority(
                payload: wrongKeyPayload,
                authority: authority,
                authenticatedRemoteSOAPeerId: authenticatedSOAPeerId,
                sessionDeviceIds: [deviceId],
                operatorApprovalReceipt: nil
            )
        )

        let wrongAlgorithmPayload = makePayload(
            deviceId: deviceId,
            algorithm: .ed25519,
            publicKey: Data(repeating: 0x55, count: 32)
        )
        XCTAssertNil(
            AuthenticatedProtocolIdentityBinding.validatedPairingIdentityAuthority(
                payload: wrongAlgorithmPayload,
                authority: authority,
                authenticatedRemoteSOAPeerId: authenticatedSOAPeerId,
                sessionDeviceIds: [deviceId],
                operatorApprovalReceipt: nil
            )
        )
    }

    func testExactPIBOperatorApprovalCanAuthorizeAHandshakeWithoutSOA() throws {
        let deviceId = UUID().uuidString.lowercased()
        let publicKey = Data(repeating: 0x64, count: 1_952)
        let payload = makePayload(deviceId: deviceId, publicKey: publicKey)
        let authority = try makeAuthority(for: payload)
        let receipt = PIBOperatorApprovalReceipt(
            declaredDeviceId: deviceId,
            binding: ProtocolIdentityBindingV2(
                algorithm: .mlDSA65,
                publicKey: publicKey,
                fingerprint: authority.protocolPublicKeyFingerprint,
                source: .pib1OperatorApproval,
                generation: 1
            )
        )

        XCTAssertNil(
            AuthenticatedProtocolIdentityBinding.validatedPairingIdentityAuthority(
                payload: payload,
                authority: authority,
                authenticatedRemoteSOAPeerId: nil,
                sessionDeviceIds: [],
                operatorApprovalReceipt: nil
            ),
            "A no-SOA handshake must never persist a payload without an exact operator receipt."
        )

        let admitted = AuthenticatedProtocolIdentityBinding.validatedPairingIdentityAuthority(
            payload: payload,
            authority: authority,
            authenticatedRemoteSOAPeerId: nil,
            sessionDeviceIds: ["bonjour:untrusted@local."],
            operatorApprovalReceipt: receipt
        )

        XCTAssertEqual(admitted?.authorizedDeviceIds, [deviceId])

        let aliasReceipt = PIBOperatorApprovalReceipt(
            declaredDeviceId: "id:\(deviceId)",
            binding: receipt.binding
        )
        XCTAssertNil(
            AuthenticatedProtocolIdentityBinding.validatedPairingIdentityAuthority(
                payload: payload,
                authority: authority,
                authenticatedRemoteSOAPeerId: nil,
                sessionDeviceIds: [],
                operatorApprovalReceipt: aliasReceipt
            ),
            "A PIB approval for an alias must not inherit authority from a potentially poisoned alias set."
        )

        let nonOperatorReceipt = PIBOperatorApprovalReceipt(
            declaredDeviceId: deviceId,
            binding: ProtocolIdentityBindingV2(
                algorithm: .mlDSA65,
                publicKey: publicKey,
                fingerprint: authority.protocolPublicKeyFingerprint,
                source: .authenticatedHandshake,
                generation: 1
            )
        )
        XCTAssertNil(
            AuthenticatedProtocolIdentityBinding.validatedPairingIdentityAuthority(
                payload: payload,
                authority: authority,
                authenticatedRemoteSOAPeerId: nil,
                sessionDeviceIds: [],
                operatorApprovalReceipt: nonOperatorReceipt
            )
        )
    }

    func testCurrentPathAdmissionUsesActualHandshakeKeyAndExpectedStableDeviceID() throws {
        let deviceId = UUID().uuidString.lowercased()
        let expectedPayload = makePayload(
            deviceId: deviceId,
            publicKey: Data(repeating: 0x71, count: 1_952)
        )
        let expectedAuthority = try makeAuthority(for: expectedPayload)

        let admitted = AuthenticatedProtocolIdentityBinding
            .validatedCurrentPathPairingIdentityAuthority(
                payload: expectedPayload,
                authenticatedAuthority: expectedAuthority,
                expectedStableDeviceId: deviceId
            )
        XCTAssertEqual(admitted?.authorizedDeviceIds, [deviceId])
        XCTAssertEqual(admitted?.protocolPublicKey, expectedAuthority.protocolPublicKey)

        let differentHandshakePayload = makePayload(
            deviceId: deviceId,
            publicKey: Data(repeating: 0x72, count: 1_952)
        )
        let differentHandshakeAuthority = try makeAuthority(for: differentHandshakePayload)
        XCTAssertNil(
            AuthenticatedProtocolIdentityBinding
                .validatedCurrentPathPairingIdentityAuthority(
                    payload: expectedPayload,
                    authenticatedAuthority: differentHandshakeAuthority,
                    expectedStableDeviceId: deviceId
                ),
            "An expected key advertised in the payload cannot replace the key actually authenticated by the handshake."
        )

        XCTAssertNil(
            AuthenticatedProtocolIdentityBinding
                .validatedCurrentPathPairingIdentityAuthority(
                    payload: expectedPayload,
                    authenticatedAuthority: expectedAuthority,
                    expectedStableDeviceId: UUID().uuidString.lowercased()
                )
        )
    }

    func testCrossNetworkPairingAndHeartbeatMutateOnlyValidatedIdentity() throws {
        let source = try repositorySource(
            "Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift"
        )
        let pairing = try sourceSlice(
            source,
            from: "case .pairingIdentityExchange(let rawPayload):",
            until: "case .heartbeat(let payload):"
        )
        let admission = try XCTUnwrap(
            pairing.range(of: ".validatedCurrentPathPairingIdentityAuthority(")
        )
        for marker in [
            "updateCrossNetworkRemoteMetadata(",
            ".commitAuthorityAndKEM("
        ] {
            let mutation = try XCTUnwrap(pairing.range(of: marker))
            XCTAssertLessThan(admission.lowerBound, mutation.lowerBound)
        }
        XCTAssertTrue(pairing.contains("deviceIds: validatedAuthority.authorizedDeviceIds"))
        XCTAssertTrue(pairing.contains("authority: pairingAuthorityLease"))
        XCTAssertTrue(pairing.contains("PairingIdentityExchangeCommitCoordinator.isCurrent("))
        XCTAssertFalse(pairing.contains("PeerKEMBootstrapStore.shared.upsert("))
        XCTAssertFalse(pairing.contains("recordCurrentPathProtocolFingerprints("))
        XCTAssertFalse(pairing.contains("deviceId: payload.deviceId"))

        let heartbeat = try sourceSlice(
            source,
            from: "case .heartbeat(let payload):",
            until: "case .ping(let payload):"
        )
        XCTAssertTrue(heartbeat.contains("authenticatedCrossNetworkDeviceId("))
        XCTAssertFalse(heartbeat.contains("deviceId: payload.deviceId"))
        XCTAssertFalse(heartbeat.contains("authenticatedDeviceId: payload.deviceId"))
    }

    func testAllFourPairingHandlersRejectBeforeAnyPersistenceSite() throws {
        let outboundSource = try repositorySource(
            "Sources/SkyBridgeCore/P2P/P2PModels.swift"
        )
        try assertAdmissionPrecedesPersistence(
            in: outboundSource,
            handlerStart: "private func handlePairingIdentityExchange(",
            handlerEnd: "internal static func isBootstrapControlMessage",
            closeCall: "disconnect()",
            persistenceMarkers: [
                "recordRemoteControlSecurityIdentity(",
                ".commitAuthorityAndKEM(",
            ]
        )

        let inboundSource = try repositorySource(
            "Sources/SkyBridgeCore/P2P/P2PDiscoveryService.swift"
        )
        try assertAdmissionPrecedesPersistence(
            in: inboundSource,
            handlerStart: "case .pairingIdentityExchange(let payload):",
            handlerEnd: "case .ping(let payload):",
            closeCall: "connection.cancel()",
            persistenceMarkers: [
                "recordRemoteControlSecurityIdentity(",
                ".commitAuthorityAndKEM(",
            ]
        )

        let legacySource = try repositorySource(
            "Sources/SkyBridgeCore/DeviceDiscovery/DeviceDiscoveryManager.swift"
        )
        try assertAdmissionPrecedesPersistence(
            in: legacySource,
            handlerStart: "case .pairingIdentityExchange(let payload):",
            handlerEnd: "case .ping(let payload):",
            closeCall: "connection.cancel()",
            persistenceMarkers: [
                "recordRemoteControlSecurityIdentity(",
                ".commitAuthorityAndKEM(",
            ]
        )

        let optimizedSource = try repositorySource(
            "Sources/SkyBridgeCore/DeviceDiscovery/DeviceDiscoveryManagerOptimized.swift"
        )
        try assertAdmissionPrecedesPersistence(
            in: optimizedSource,
            handlerStart: "case .pairingIdentityExchange(let payload):",
            handlerEnd: "case .ping(let payload):",
            closeCall: "connection.cancel()",
            persistenceMarkers: [
                ".commitAuthorityAndKEM(",
            ]
        )

        for source in [outboundSource, inboundSource, legacySource, optimizedSource] {
            XCTAssertEqual(
                occurrenceCount(
                    of: ".validatedPairingIdentityAuthorityForPersistence(",
                    in: source
                ),
                1,
                "Every pairing path must consume the single shared SOA/PIB admission boundary."
            )
            XCTAssertFalse(source.contains("?? authority.protocolPublicKey"))
            XCTAssertFalse(source.contains("sealed.combined ?? Data()"))
            XCTAssertTrue(
                source.contains("AuthenticatedAppPayloadCryptoError.combinedCiphertextUnavailable")
            )
            XCTAssertTrue(source.contains("validatedAuthority.declaredDeviceId"))
            XCTAssertTrue(source.contains("validatedAuthority.authorizedDeviceIds"))
        }
        let coordinatorSource = try repositorySource(
            "Sources/SkyBridgeCore/P2P/PairingIdentityExchangeCommitCoordinator.swift"
        )
        XCTAssertTrue(coordinatorSource.contains("authority.protocolSigningAlgorithm"))
        XCTAssertTrue(coordinatorSource.contains("authority.protocolPublicKeyFingerprint"))
        XCTAssertTrue(
            coordinatorSource.contains("AuthenticatedProtocolIdentityBinding.matchingPublicKey(")
        )
        for managerSource in [legacySource, optimizedSource] {
            XCTAssertFalse(managerSource.contains("if let msg = try? JSONDecoder().decode"))
            XCTAssertTrue(
                managerSource.contains("let msg = try AppMessage.decodeWireMessage(from: plaintext)")
            )
            XCTAssertTrue(
                managerSource.contains("authenticated app frame failed validation; closing session")
            )
        }
    }

    private func makePayload(
        deviceId: String,
        algorithm: ProtocolSigningAlgorithm = .mlDSA65,
        publicKey: Data
    ) -> AppMessage.PairingIdentityExchangePayload {
        AppMessage.PairingIdentityExchangePayload(
            deviceId: deviceId,
            kemPublicKeys: [
                KEMPublicKeyInfo(
                    suiteWireId: CryptoSuite.xwingMLDSA.wireId,
                    publicKey: Data(repeating: 0xA5, count: 1_216)
                )
            ],
            protocolIdentityPublicKeys: [
                .init(
                    protocolSigningAlgorithm: algorithm.rawValue,
                    publicKey: publicKey
                )
            ]
        )
    }

    private func makeAuthority(
        for payload: AppMessage.PairingIdentityExchangePayload
    ) throws -> AuthenticatedRemoteAuthority {
        let identity = try XCTUnwrap(payload.protocolIdentityPublicKeys?.first)
        return AuthenticatedRemoteAuthority(
            protocolSigningAlgorithm: try XCTUnwrap(
                ProtocolSigningAlgorithm(rawValue: identity.protocolSigningAlgorithm)
            ),
            protocolPublicKeyFingerprint: try XCTUnwrap(identity.authoritativeFingerprint),
            protocolPublicKey: identity.publicKey
        )
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

    private func sourceSlice(
        _ source: String,
        from startMarker: String,
        until endMarker: String
    ) throws -> String {
        let start = try XCTUnwrap(source.range(of: startMarker))
        let end = try XCTUnwrap(
            source.range(of: endMarker, range: start.upperBound..<source.endIndex)
        )
        return String(source[start.lowerBound..<end.lowerBound])
    }

    private func assertAdmissionPrecedesPersistence(
        in source: String,
        handlerStart: String,
        handlerEnd: String,
        closeCall: String,
        persistenceMarkers: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let handler = try sourceSlice(source, from: handlerStart, until: handlerEnd)
        let admission = try XCTUnwrap(
            handler.range(
                of: "guard let validatedAuthority = await validatedPairingIdentityAuthority"
            ),
            file: file,
            line: line
        )

        var firstPersistenceIndex = handler.endIndex
        for marker in persistenceMarkers {
            let persistence = try XCTUnwrap(
                handler.range(
                    of: marker,
                    range: admission.upperBound..<handler.endIndex
                ),
                "Missing expected persistence marker: \(marker)",
                file: file,
                line: line
            )
            XCTAssertLessThan(
                admission.lowerBound,
                persistence.lowerBound,
                file: file,
                line: line
            )
            if persistence.lowerBound < firstPersistenceIndex {
                firstPersistenceIndex = persistence.lowerBound
            }
        }

        let prePersistence = String(handler[..<firstPersistenceIndex])
        XCTAssertGreaterThanOrEqual(
            occurrenceCount(of: closeCall, in: prePersistence),
            2,
            "Both malformed payloads and failed identity admission must close the session.",
            file: file,
            line: line
        )
        XCTAssertGreaterThanOrEqual(
            occurrenceCount(of: "return", in: prePersistence),
            2,
            "Pairing admission failures must exit the handler rather than fall through.",
            file: file,
            line: line
        )
        XCTAssertFalse(handler.contains("deviceIds: [payload.deviceId"), file: file, line: line)
        XCTAssertFalse(handler.contains("currentDeviceId: payload.deviceId"), file: file, line: line)
    }

    private func occurrenceCount(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }
}
