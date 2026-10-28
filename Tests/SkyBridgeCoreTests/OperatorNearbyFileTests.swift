import XCTest
import SkyBridgeProtocolCore
@testable import SkyBridgeCore

final class OperatorNearbyFileTests: XCTestCase {
    private let peer = "90900821-DA07-4D71-916C-6A158731A6B8"

    func testUSBInspectionFailuresRetainTheirRealBoundary() async throws {
        for failure in [USBPeerDiscoveryError.invalidRequest, .invalidResponse, .signatureInvalid, .rateLimited] {
            let router = CrossnetControlRouter(runtime: runtime(inspectUSB: { _ in throw failure }))
            let data = await router.handleLine(try line(method: "crossnet.usb.inspect", params: [
                "udid": "00008140-000E788401C0801C"
            ]))
            let response = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let error = try XCTUnwrap(response["error"] as? [String: String])
            XCTAssertEqual(error["code"], "session_mutation_rejected")
            XCTAssertTrue(error["message"]?.contains("usb_inspection_\(failure.rawValue)") == true)
            XCTAssertFalse(error["message"]?.contains("encode") == true)
        }
    }

    func testCompletedBytesWithoutReceiptCannotBecomeSuccess() throws {
        let request = try fileRequest()
        let missingReceipt = OperatorFileTransferEvent(
            request: request, transferID: UUID().uuidString, status: .completed,
            bytesTransferred: 100, totalBytes: 100, sha256: String(repeating: "a", count: 64)
        )
        XCTAssertThrowsError(try missingReceipt.validated())
        let receipt = OperatorFileTransferEvent(
            request: request, transferID: UUID().uuidString, status: .completed,
            bytesTransferred: 100, totalBytes: 100, sha256: String(repeating: "a", count: 64), receiptVerified: true
        )
        XCTAssertTrue(try receipt.validated().success)
        XCTAssertFalse(receipt.automatic_retry_allowed)
    }

    func testReceiptStillRequiresExactSizeAndHash() throws {
        for (bytes, hash) in [(99, String(repeating: "a", count: 64)), (100, "invalid")] {
            let event = OperatorFileTransferEvent(
                request: try fileRequest(), transferID: UUID().uuidString, status: .completed,
                bytesTransferred: Int64(bytes), totalBytes: 100, sha256: hash, receiptVerified: true
            )
            XCTAssertThrowsError(try event.validated())
        }
    }

    func testRequestRejectsRelativePathsAndUnboundedWaits() {
        for (path, timeout) in [("relative.bin", 30), ("/tmp/file.bin", 0), ("/tmp/file.bin", 3601)] {
            XCTAssertThrowsError(try OperatorFileSendRequest(operationID: "op", params: .init([
                "device_ref": .string(peer), "path": .string(path), "timeout_seconds": .int(timeout)
            ])))
        }
    }

    func testTrustRecoveryRequiresExplicitApprovalAndExactPreview() throws {
        let valid: [String: CrossnetControlJSONValue] = [
            "udid": .string("00008140-000E788401C0801C"), "peer_id": .string(peer),
            "expected_fingerprint": .string(String(repeating: "b", count: 64)),
            "snapshot_sha256": .string(String(repeating: "a", count: 64)),
            "recovery_id": .string(UUID().uuidString), "approve_mirror_retirement": .bool(true)
        ]
        XCTAssertNoThrow(try OperatorTrustRecoveryRequest(params: .init(valid)))
        for key in ["approve_mirror_retirement", "snapshot_sha256", "recovery_id", "peer_id"] {
            var missing = valid
            missing.removeValue(forKey: key)
            XCTAssertThrowsError(try OperatorTrustRecoveryRequest(params: .init(missing)))
        }
        var denied = valid
        denied["approve_mirror_retirement"] = .bool(false)
        XCTAssertThrowsError(try OperatorTrustRecoveryRequest(params: .init(denied)))
    }

    func testUSBConnectCannotReportNetworkOrUnverifiedIdentityAsSuccess() async throws {
        let expected = String(repeating: "b", count: 64)
        for (carrier, pqc, fingerprint, accepted) in [
            ("network", true, expected, false), ("usb", false, expected, false),
            ("usb", true, String(repeating: "c", count: 64), false), ("usb", true, expected, true)
        ] {
            let router = CrossnetControlRouter(runtime: runtime(connectUSB: { _ in
                OperatorNearbyConnectResult(deviceRef: UUID().uuidString, authenticated: true,
                    transport: carrier, negotiatedSuite: "X-Wing", peerFingerprint: fingerprint, pqc: pqc)
            }))
            let data = await router.handleLine(try line(method: "crossnet.usb.connect", params: [
                "udid": "00008140-000E788401C0801C", "peer_id": peer, "expected_fingerprint": expected
            ]))
            let response = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(response["ok"] as? Bool, accepted)
        }
    }

    func testUSBDeviceSelectionRequiresPhysicalRouteAndExactTarget() async throws {
        let selected = peer
        for (route, target, pqc, accepted) in [
            ("usb", selected, true, true), ("network", selected, true, false),
            ("usb", UUID().uuidString, true, false), ("usb", selected, false, false)
        ] {
            let router = CrossnetControlRouter(runtime: runtime(connectUSBDevice: { request in
                XCTAssertEqual(request.deviceRef, selected)
                XCTAssertEqual(request.udid, "00008140-000E788401C0801C")
                return OperatorNearbyConnectResult(deviceRef: target, authenticated: true,
                    transport: route, negotiatedSuite: "X-Wing",
                    peerFingerprint: String(repeating: "b", count: 64), pqc: pqc)
            }))
            let data = await router.handleLine(try line(method: "crossnet.usb.connect_device", params: [
                "udid": "00008140-000E788401C0801C", "device_ref": selected
            ]))
            let response = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(response["ok"] as? Bool, accepted)
        }
        for params: [String: CrossnetControlJSONValue] in [
            ["device_ref": .string(selected)],
            ["device_ref": .string(selected), "udid": .string("network")],
            ["device_ref": .string("device-name"), "udid": .string("00008140-000E788401C0801C")]
        ] {
            XCTAssertThrowsError(try OperatorUSBDeviceConnectRequest(params: .init(params)))
        }
    }

    func testUnwiredAndUnauthenticatedFileOperationsFailBeforeStreaming() async throws {
        for (authenticated, code) in [(false, "auth_required"), (true, "method_not_enabled")] {
            let router = CrossnetControlRouter(runtime: runtime(authenticated: authenticated))
            let outcome = await router.handleLineStreaming(try line(method: "crossnet.file.send", params: [
                "device_ref": peer, "path": "/tmp/file.bin", "timeout_seconds": 30
            ]))
            guard case .response(let data) = outcome else { return XCTFail("unauthorized stream") }
            let response = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual((response["error"] as? [String: String])?["code"], code)
        }
    }

    func testStreamRejectsAnEventFromAnotherOperation() async throws {
        let wrongRequest = try fileRequest(operationID: "another")
        let router = CrossnetControlRouter(runtime: runtime(sendFile: { _ in
            AsyncStream { continuation in
                continuation.yield(OperatorFileTransferEvent(request: wrongRequest, status: .preparing))
                continuation.finish()
            }
        }))
        let outcome = await router.handleLineStreaming(try line(method: "crossnet.file.send", params: [
            "device_ref": peer, "path": "/tmp/file.bin", "timeout_seconds": 30
        ]))
        guard case .stream(_, let events) = outcome else { return XCTFail("expected a stream") }
        var iterator = events.makeAsyncIterator()
        let next = await iterator.next()
        let data = try XCTUnwrap(next)
        let event = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(event["ok"] as? Bool, false)
        XCTAssertNotNil(event["error"])
    }

    func testNearbyCannotClaimUnverifiedAuthentication() async throws {
        let router = CrossnetControlRouter(runtime: runtime(connect: { ref in
            OperatorNearbyConnectResult(deviceRef: ref, authenticated: false)
        }))
        let data = await router.handleLine(try line(method: "crossnet.connect_nearby", params: ["device_ref": peer]))
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(response["ok"] as? Bool, false)
    }

    func testPeerSuiteMismatchReturnsAnActionableClosedCode() async throws {
        let router = CrossnetControlRouter(runtime: runtime(connect: { _ in
            throw P2PDiscoveryError.peerPQCSuiteUnavailable
        }))
        let data = await router.handleLine(try line(method: "crossnet.connect_nearby", params: ["device_ref": peer]))
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let error = try XCTUnwrap(response["error"] as? [String: String])
        XCTAssertEqual(error["code"], "peer_pqc_suite_unavailable")
        XCTAssertTrue(error["message"]?.contains("suite settings") == true)
        XCTAssertTrue(P2PDiscoveryError.peerPQCSuiteUnavailable.preventsCandidateFallback)
    }

    func testMissingPhysicalUSBDeviceHasAnActionableError() async throws {
        let router = CrossnetControlRouter(runtime: runtime(connectUSB: { _ in
            throw P2PDiscoveryError.preflightFailure(
                USBMultiplexError.deviceUnavailable,
                refreshFailure: P2PDiscoveryError.strictPQCTrustPreflightFailed("missing pinned identity")
            )
        }))
        let data = await router.handleLine(try line(method: "crossnet.usb.connect", params: [
            "udid": "00008140-000E788401C0801C", "peer_id": peer,
            "expected_fingerprint": String(repeating: "b", count: 64)
        ]))
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(response["ok"] as? Bool, false)
        let error = try XCTUnwrap(response["error"] as? [String: String])
        XCTAssertEqual(error["code"], "usb_device_unavailable")
        XCTAssertTrue(error["message"]?.contains("no network fallback") == true)
    }

    func testNonTransportPreflightFailureRemainsATrustRejection() {
        let source = NSError(domain: "protocol-validation", code: 17)
        let error = P2PDiscoveryError.preflightFailure(source, refreshFailure: nil)
        guard case .strictPQCTrustPreflightFailed = error as? P2PDiscoveryError else {
            return XCTFail("protocol failures must retain their trust-preflight classification")
        }
    }

    func testNearbyRuntimeRejectionsAreNotMisreportedAsEncodingFailures() async throws {
        for reason in ["nearby_trust_preflight_failed", "nearby_identity_conflict"] {
            let router = CrossnetControlRouter(runtime: runtime(connect: { _ in
                if reason == "nearby_trust_preflight_failed" {
                    throw P2PDiscoveryError.strictPQCTrustPreflightFailed("private peer details")
                }
                throw P2PDiscoveryError.targetAuthorityConflict
            }))
            let data = await router.handleLine(try line(method: "crossnet.connect_nearby", params: ["device_ref": peer]))
            let response = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let failure = try XCTUnwrap(response["error"] as? [String: String])
            XCTAssertEqual(failure["code"], "session_mutation_rejected")
            XCTAssertTrue(failure["message"]?.contains(reason) == true)
            XCTAssertFalse(failure["message"]?.contains("private peer details") == true)
            XCTAssertFalse(failure["message"]?.contains("encode") == true)
        }
    }

    private func fileRequest(operationID: String = "op") throws -> OperatorFileSendRequest {
        try OperatorFileSendRequest(operationID: operationID, params: .init([
            "device_ref": .string(peer), "path": .string("/tmp/file.bin"), "timeout_seconds": .int(30)
        ]))
    }

    private func line(method: String, params: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["v": 1, "id": "op", "method": method, "params": params])
    }

    private func runtime(
        authenticated: Bool = true,
        connect: (@Sendable (String) async throws -> OperatorNearbyConnectResult)? = nil,
        connectUSB: (@Sendable (OperatorUSBConnectRequest) async throws -> OperatorNearbyConnectResult)? = nil,
        connectUSBDevice: (@Sendable (OperatorUSBDeviceConnectRequest) async throws -> OperatorNearbyConnectResult)? = nil,
        inspectUSB: (@Sendable (String) async throws -> USBPeerInspection)? = nil,
        sendFile: (@Sendable (OperatorFileSendRequest) async throws -> AsyncStream<OperatorFileTransferEvent>)? = nil
    ) -> CrossnetControlRuntime {
        CrossnetControlRuntime(
            hello: { CrossnetControlHelloResult(engineVersion: "test", authLoaded: authenticated, tenantBound: authenticated) },
            status: { CrossnetControlStatusResult(connectionStatus: "idle", readiness: "idle", sessionPresent: false,
                sessionRef: nil, suite: nil, signalingHealth: nil, authLoaded: authenticated, tenantBound: authenticated) },
            settingsSnapshot: { CrossnetControlSettingsSnapshotResult(settings: []) },
            connectNearby: connect, sendFile: sendFile, inspectUSB: inspectUSB, connectUSB: connectUSB, connectUSBDevice: connectUSBDevice
        )
    }
}
