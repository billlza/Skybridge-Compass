import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
final class P2PDiscoveryBootstrapControlTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let protocolPublicKey = Data(repeating: 0x33, count: 1184)
    private var fingerprint: String {
        ProtocolIdentityPublicKeys(
            protocolPublicKey: protocolPublicKey,
            protocolAlgorithm: .mlDSA65
        ).authoritativeFingerprint
    }

    func testKEMRefreshRequestMapsSuccessToSignedRefreshAndServedStatus() async throws {
        let request = kemRefreshRequest()
        let response = await P2PDiscoveryService.makeBootstrapControlResponse(
            for: .kemRefreshRequest(request),
            makeSignedKEMRefreshPayload: { request in
                self.signedKEMRefreshPayload(for: request)
            },
            makeSignedProtocolIdentityBindingPayload: { _ in
                throw Self.testError("unexpected PIB-1 path")
            }
        )

        let controlResponse = try XCTUnwrap(response)
        guard case .signedKEMRefreshServed = controlResponse.kind else {
            return XCTFail("Expected SKR-1 served response")
        }
        guard case .signedKEMRefresh(let payload) = controlResponse.message else {
            return XCTFail("Expected signedKEMRefresh message")
        }
        XCTAssertEqual(payload.requestHashHex, request.canonicalRequestHashHex)
        XCTAssertEqual(payload.requestNonce, request.nonce)
        XCTAssertEqual(payload.policyAllowClassicFallback, false)
        XCTAssertEqual(payload.routeScope, "lan")
        XCTAssertFalse(payload.signature.isEmpty)
        XCTAssertTrue(controlResponse.statusLine.contains("SKR-1 signed LAN KEM refresh served"))
        XCTAssertTrue(controlResponse.statusLine.contains("wireId=0x0001"))
        XCTAssertTrue(controlResponse.statusLine.contains("responderLatencyMs="))
        XCTAssertFalse(controlResponse.statusLine.contains(request.requesterDeviceId))
        XCTAssertFalse(controlResponse.statusLine.contains(request.targetDeviceId))
        XCTAssertFalse(controlResponse.statusLine.contains(payload.keyId))
        XCTAssertTrue(controlResponse.statusLine.contains("requester=<redacted>"))
        XCTAssertTrue(controlResponse.statusLine.contains("target=<redacted>"))
        XCTAssertTrue(controlResponse.statusLine.contains("keyId=<redacted>"))
        XCTAssertFalse(controlResponse.isFailure)
    }

    func testKEMRefreshRequestMapsGeneratorFailureToDiagnosticFailure() async throws {
        let request = kemRefreshRequest(requestedSuiteWireIds: [0x0000])
        let response = await P2PDiscoveryService.makeBootstrapControlResponse(
            for: .kemRefreshRequest(request),
            makeSignedKEMRefreshPayload: { _ in
                throw Self.testError("SKR-1 rejected unknown suite wireId=0x0000")
            },
            makeSignedProtocolIdentityBindingPayload: { _ in
                throw Self.testError("unexpected PIB-1 path")
            }
        )

        let controlResponse = try XCTUnwrap(response)
        guard case .signedKEMRefreshRejected = controlResponse.kind else {
            return XCTFail("Expected SKR-1 rejected response")
        }
        guard case .kemRefreshFailure(let failure) = controlResponse.message else {
            return XCTFail("Expected diagnostic kemRefreshFailure")
        }
        XCTAssertEqual(failure.stage, "kem_refresh")
        XCTAssertEqual(failure.reasonCode, "unknown_suite")
        XCTAssertEqual(failure.requestHashHex, request.canonicalRequestHashHex)
        XCTAssertTrue(controlResponse.statusLine.contains("lifecycle=request>rejected"))
        XCTAssertTrue(controlResponse.statusLine.contains("responderLatencyMs="))
        XCTAssertFalse(controlResponse.statusLine.contains(request.requesterDeviceId))
        XCTAssertFalse(controlResponse.statusLine.contains(request.targetDeviceId))
        XCTAssertFalse(controlResponse.statusLine.contains("SKR-1 rejected unknown suite"))
        XCTAssertTrue(controlResponse.statusLine.contains("requester=<redacted>"))
        XCTAssertTrue(controlResponse.statusLine.contains("target=<redacted>"))
        XCTAssertTrue(controlResponse.statusLine.contains("reason=<redacted>"))
        XCTAssertTrue(controlResponse.isFailure)
    }

    func testKEMRefreshRequestResponderRejectsStrictPolicyFailuresAsDiagnosticOnly() async throws {
        let cases: [(name: String, request: AppMessage.KEMRefreshRequestPayload, reasonCode: String)] = [
            (
                "policy hash mismatch",
                kemRefreshRequest(policyHashHex: String(repeating: "0", count: 64), sentAt: Date()),
                "policy_hash_mismatch"
            ),
            (
                "missing requested suite",
                kemRefreshRequest(requestedSuiteWireIds: [], sentAt: Date()),
                "missing_requested_suite"
            ),
            (
                "unknown suite",
                kemRefreshRequest(requestedSuiteWireIds: [0x0000], sentAt: Date()),
                "unknown_suite"
            ),
            (
                "classic suite",
                kemRefreshRequest(requestedSuiteWireIds: [CryptoSuite.x25519Ed25519.wireId], sentAt: Date()),
                "classic_suite_rejected"
            ),
            (
                "invalid target identity",
                kemRefreshRequest(targetProtocolIdentityFingerprint: "not-a-fingerprint", sentAt: Date()),
                "invalid_target_protocol_identity"
            )
        ]

        for entry in cases {
            let response = await P2PDiscoveryService.makeBootstrapControlResponse(for: .kemRefreshRequest(entry.request))
            let controlResponse = try XCTUnwrap(response, entry.name)
            guard case .signedKEMRefreshRejected = controlResponse.kind else {
                return XCTFail("Expected \(entry.name) to reject SKR-1 before any success path")
            }
            guard case .kemRefreshFailure(let failure) = controlResponse.message else {
                return XCTFail("Expected \(entry.name) to return diagnostic kemRefreshFailure")
            }

            XCTAssertTrue(controlResponse.isFailure, entry.name)
            XCTAssertEqual(failure.stage, "kem_refresh", entry.name)
            XCTAssertEqual(failure.reasonCode, entry.reasonCode, entry.name)
            XCTAssertEqual(failure.requestHashHex, entry.request.canonicalRequestHashHex, entry.name)
            XCTAssertTrue(controlResponse.statusLine.contains("lifecycle=request>rejected"), entry.name)
            XCTAssertFalse(controlResponse.statusLine.contains("served"), entry.name)
        }
    }

    func testKEMRefreshRequestResponderReportsPinnedTargetReplayAndRateLimitFailures() async throws {
        let store = PeerProtocolIdentityBootstrapStore.shared
        await store.clearForTesting()
        await SignedKEMRefreshRequestAdmissionGate.shared.clearForTesting()
        await store.upsert(deviceIds: ["id:ios-1"], fingerprints: [fingerprint])

        let mismatchedTarget = String(repeating: "a", count: 64)
        let first = kemRefreshRequest(
            targetProtocolIdentityFingerprint: mismatchedTarget,
            sentAt: Date()
        )
        try await assertKEMRefreshRejected(
            first,
            reasonCode: "pinned_protocol_identity_mismatch_requires_oob"
        )

        try await assertKEMRefreshRejected(
            first,
            reasonCode: "request_replay_detected"
        )

        await SignedKEMRefreshRequestAdmissionGate.shared.clearForTesting()
        for index in 0..<10 {
            let request = kemRefreshRequest(
                targetProtocolIdentityFingerprint: mismatchedTarget,
                nonce: Data(repeating: UInt8(index + 1), count: 24),
                sentAt: Date()
            )
            try await assertKEMRefreshRejected(
                request,
                reasonCode: "pinned_protocol_identity_mismatch_requires_oob",
                "attempt \(index)"
            )
        }

        let rateLimited = kemRefreshRequest(
            targetProtocolIdentityFingerprint: mismatchedTarget,
            nonce: Data(repeating: 0x7f, count: 24),
            sentAt: Date()
        )
        try await assertKEMRefreshRejected(
            rateLimited,
            reasonCode: "requester_rate_limited"
        )

        await store.clearForTesting()
        await SignedKEMRefreshRequestAdmissionGate.shared.clearForTesting()
    }

    func testProtocolIdentityBindingRequestMapsSuccessToSignedBindingAndServedStatus() async throws {
        let request = protocolIdentityBindingRequest()
        let response = await P2PDiscoveryService.makeBootstrapControlResponse(
            for: .protocolIdentityBindingRequest(request),
            makeSignedKEMRefreshPayload: { _ in
                throw Self.testError("unexpected SKR-1 path")
            },
            makeSignedProtocolIdentityBindingPayload: { request in
                self.signedProtocolIdentityBindingPayload(for: request)
            }
        )

        let controlResponse = try XCTUnwrap(response)
        guard case .protocolIdentityBindingServed = controlResponse.kind else {
            return XCTFail("Expected PIB-1 served response")
        }
        guard case .signedProtocolIdentityBinding(let payload) = controlResponse.message else {
            return XCTFail("Expected signedProtocolIdentityBinding message")
        }
        XCTAssertEqual(controlResponse.protocolIdentityBindingRequest, request)
        XCTAssertEqual(controlResponse.protocolIdentityBindingPayload, payload)
        XCTAssertEqual(payload.requestHashHex, request.canonicalRequestHashHex)
        XCTAssertEqual(payload.policyAllowClassicFallback, false)
        XCTAssertEqual(payload.routeScope, "lan")
        XCTAssertEqual(controlResponse.protocolIdentityBindingCode?.count, 6)
        XCTAssertTrue(controlResponse.statusLine.contains("PIB-1 protocol identity binding served"))
        XCTAssertFalse(controlResponse.isFailure)
    }

    func testProtocolIdentityBindingRequestMapsGeneratorFailureToDiagnosticFailure() async throws {
        let request = protocolIdentityBindingRequest()
        let response = await P2PDiscoveryService.makeBootstrapControlResponse(
            for: .protocolIdentityBindingRequest(request),
            makeSignedKEMRefreshPayload: { _ in
                throw Self.testError("unexpected SKR-1 path")
            },
            makeSignedProtocolIdentityBindingPayload: { _ in
                throw Self.testError("policy mismatch")
            }
        )

        let controlResponse = try XCTUnwrap(response)
        guard case .protocolIdentityBindingRejected = controlResponse.kind else {
            return XCTFail("Expected PIB-1 rejected response")
        }
        guard case .kemRefreshFailure(let failure) = controlResponse.message else {
            return XCTFail("Expected diagnostic kemRefreshFailure")
        }
        XCTAssertEqual(failure.stage, "identity_binding")
        XCTAssertEqual(failure.reasonCode, "policy_mismatch")
        XCTAssertEqual(failure.requestHashHex, request.canonicalRequestHashHex)
        XCTAssertTrue(controlResponse.statusLine.contains("lifecycle=identity-oob>rejected"))
        XCTAssertTrue(controlResponse.isFailure)
    }

    func testNonBootstrapControlMessageDoesNotProduceResponse() async {
        let response = await P2PDiscoveryService.makeBootstrapControlResponse(for: .ping(.init(id: 7)))
        XCTAssertNil(response)
    }

    private func kemRefreshRequest(
        requestedSuiteWireIds: [UInt16] = [CryptoSuite.xwingMLDSA.wireId],
        policyHashHex: String? = nil,
        targetProtocolIdentityFingerprint: String? = nil,
        nonce: Data? = nil,
        sentAt: Date? = nil
    ) -> AppMessage.KEMRefreshRequestPayload {
        AppMessage.KEMRefreshRequestPayload(
            requesterDeviceId: "id:ios-1",
            targetDeviceId: "id:mac-1",
            requesterProtocolIdentityFingerprint: fingerprint,
            targetProtocolIdentityFingerprint: targetProtocolIdentityFingerprint ?? fingerprint,
            requestedSuiteWireIds: requestedSuiteWireIds,
            policyHashHex: policyHashHex,
            bonjourEndpointDigest: String(repeating: "c", count: 64),
            nonce: nonce ?? Data(repeating: 0x44, count: 24),
            sentAt: sentAt ?? now
        )
    }

    private func assertKEMRefreshRejected(
        _ request: AppMessage.KEMRefreshRequestPayload,
        reasonCode: String,
        _ message: String = ""
    ) async throws {
        let response = await P2PDiscoveryService.makeBootstrapControlResponse(for: .kemRefreshRequest(request))
        let controlResponse = try XCTUnwrap(response, message)
        guard case .signedKEMRefreshRejected = controlResponse.kind else {
            return XCTFail("Expected SKR-1 rejection \(message)")
        }
        guard case .kemRefreshFailure(let failure) = controlResponse.message else {
            return XCTFail("Expected diagnostic kemRefreshFailure \(message)")
        }

        XCTAssertTrue(controlResponse.isFailure, message)
        XCTAssertEqual(failure.stage, "kem_refresh", message)
        XCTAssertEqual(failure.reasonCode, reasonCode, message)
        XCTAssertEqual(failure.requestHashHex, request.canonicalRequestHashHex, message)
        XCTAssertTrue(controlResponse.statusLine.contains("lifecycle=request>rejected"), message)
        XCTAssertFalse(controlResponse.statusLine.contains("lifecycle=request>served"), message)
    }

    private func signedKEMRefreshPayload(
        for request: AppMessage.KEMRefreshRequestPayload
    ) -> AppMessage.SignedKEMRefreshPayload {
        AppMessage.SignedKEMRefreshPayload(
            deviceId: "id:mac-1",
            aliases: ["id:mac-1", "bonjour:mac@local."],
            protocolSigningAlgorithm: ProtocolSigningAlgorithm.mlDSA65.rawValue,
            protocolIdentityPublicKey: protocolPublicKey,
            protocolIdentityFingerprint: fingerprint,
            kemPublicKeys: [
                KEMPublicKeyInfo(
                    suiteWireId: CryptoSuite.xwingMLDSA.wireId,
                    publicKey: Data(repeating: 0x55, count: 1216)
                )
            ],
            keyId: "skr1-test",
            generation: 9,
            sentAt: now,
            expiresAt: now.addingTimeInterval(300),
            requestNonce: request.nonce,
            requestHashHex: request.canonicalRequestHashHex,
            policyAllowClassicFallback: false,
            routeScope: "lan",
            bonjourEndpointDigest: request.bonjourEndpointDigest,
            signature: Data(repeating: 0x99, count: 64)
        )
    }

    private func protocolIdentityBindingRequest() -> AppMessage.ProtocolIdentityBindingRequestPayload {
        AppMessage.ProtocolIdentityBindingRequestPayload(
            requesterDeviceId: "id:ios-1",
            targetDeviceId: "id:mac-1",
            requestedProtocolSigningAlgorithms: [
                ProtocolSigningAlgorithm.mlDSA65.rawValue,
                ProtocolSigningAlgorithm.ed25519.rawValue
            ],
            bonjourEndpointDigest: String(repeating: "c", count: 64),
            nonce: Data(repeating: 0x66, count: 24),
            sentAt: now
        )
    }

    private func signedProtocolIdentityBindingPayload(
        for request: AppMessage.ProtocolIdentityBindingRequestPayload
    ) -> AppMessage.SignedProtocolIdentityBindingPayload {
        AppMessage.SignedProtocolIdentityBindingPayload(
            deviceId: "id:mac-1",
            aliases: ["id:mac-1", "bonjour:mac@local."],
            protocolSigningAlgorithm: ProtocolSigningAlgorithm.mlDSA65.rawValue,
            protocolIdentityPublicKey: protocolPublicKey,
            protocolIdentityFingerprint: fingerprint,
            deviceName: "MacBook",
            sentAt: now,
            expiresAt: now.addingTimeInterval(300),
            requestNonce: request.nonce,
            requestHashHex: request.canonicalRequestHashHex,
            policyAllowClassicFallback: false,
            routeScope: "lan",
            bonjourEndpointDigest: request.bonjourEndpointDigest,
            signature: Data(repeating: 0x77, count: 64)
        )
    }

    private static func testError(_ reason: String) -> NSError {
        NSError(
            domain: "SkyBridge.Tests.BootstrapControl",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: reason]
        )
    }
}
