import XCTest
@testable import SkyBridgeProtocolCore
@testable import SkyBridgeCore

@MainActor
final class USBPeerDiscoveryTests: XCTestCase {
    private func identity() -> HandshakeManagementIdentity {
        let key = Data(repeating: 7, count: 1952)
        return .init(deviceID: UUID().uuidString.lowercased(), algorithm: "ML-DSA-65", publicKey: key,
                     fingerprint: ProtocolIdentityBinding.computeFingerprint(algorithm: .mlDSA65, publicKeyBytes: key))
    }
    // Deterministic signing isolates transcript/freshness logic. Real ML-DSA
    // verification is a separate native-device acceptance requirement.
    nonisolated private static func sign(_ data: Data) -> Data { Data(HandshakeConfigurationWire.hash(data).utf8) }

    func testSignedProbeBindsEveryPublicFieldAndRequestWithoutGrantingTrust() async throws {
        let request = try USBPeerDiscoveryRequest(), identity = identity()
        let responder = USBPeerDiscoveryResponder()
        let response = try await responder.respond(to: request, name: "Test phone", platform: "ios",
            identity: { identity }, sign: { Self.sign($0) })
        try await response.validate(for: request, verify: { Self.sign($0) == $1 && $2 == identity })
        let wire = try JSONEncoder().encode(AppMessage.usbPeerDiscoveryResponse(response))
        XCTAssertEqual(try AppMessage.decodeWireMessage(from: wire), .usbPeerDiscoveryResponse(response))
        let tampered = USBPeerDiscoveryResponse(request: request, identity: identity, name: "Other phone", platform: "ios", signature: response.signature)
        do { try await tampered.validate(for: request, verify: { Self.sign($0) == $1 && $2 == identity }); XCTFail("changed presentation was accepted") }
        catch let error as USBPeerDiscoveryError { XCTAssertEqual(error, .signatureInvalid) }
        let anotherRequest = try USBPeerDiscoveryRequest()
        do { try await response.validate(for: anotherRequest, verify: { _, _, _ in true }); XCTFail("another nonce was accepted") }
        catch let error as USBPeerDiscoveryError { XCTAssertEqual(error, .invalidResponse) }
    }

    func testProbeReplayAndSigningBudgetAreBounded() async throws {
        let request = try USBPeerDiscoveryRequest(), identity = identity(), responder = USBPeerDiscoveryResponder()
        var signs = 0
        _ = try await responder.respond(to: request, name: "Test", platform: "ios", identity: { identity }, sign: { signs += 1; return Self.sign($0) })
        do { _ = try await responder.respond(to: request, name: "Test", platform: "ios", identity: { identity }, sign: { signs += 1; return Self.sign($0) }); XCTFail("replay was signed") }
        catch let error as USBPeerDiscoveryError { XCTAssertEqual(error, .rateLimited) }
        XCTAssertEqual(signs, 1)
    }

    func testStaleSheetDecisionCannotAuthorizeReplacementRequest() async throws {
        let approval = HandshakeConfigurationApproval(), peer = identity()
        let firstID = UUID(), nextID = UUID()
        let first = Task { @MainActor in await approval.decide(peer, profile: .qperiapt, requestID: firstID) }
        defer { first.cancel() }
        let firstDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while approval.pending == nil && ContinuousClock.now < firstDeadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(try XCTUnwrap(approval.pending).id, firstID)
        approval.resolve(firstID, decision: .reject)
        _ = await first.value
        let next = Task { @MainActor in await approval.decide(peer, profile: .xwing, requestID: nextID) }
        defer { next.cancel() }
        let nextDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while approval.pending == nil && ContinuousClock.now < nextDeadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(try XCTUnwrap(approval.pending).id, nextID)
        approval.resolve(firstID, decision: .alwaysAllow)
        XCTAssertEqual(approval.pending?.id, nextID)
        approval.resolve(nextID, decision: .reject)
        let result = await next.value
        XCTAssertEqual(result, .reject)
    }

    func testInvalidTimestampsDoNotTrapAndExpiredRequestsFail() throws {
        XCTAssertThrowsError(try USBPeerDiscoveryRequest(now: Date(timeIntervalSince1970: .infinity)))
        let request = try USBPeerDiscoveryRequest(now: Date().addingTimeInterval(-31))
        XCTAssertThrowsError(try request.validate())
        let request2 = try USBPeerDiscoveryRequest(now: Date().addingTimeInterval(10))
        XCTAssertThrowsError(try request2.validate())
    }

    func testLocalApprovalRejectsMalformedCodesAndStaleDecisions() throws {
        XCTAssertEqual(OperatorLocalApprovals.code("123 456"), "123456")
        XCTAssertNil(OperatorLocalApprovals.code("123456x"))
        XCTAssertNil(OperatorLocalApprovals.code("12345"))
        let request = try OperatorLocalApprovalRequest(action: .decide, params: .init([
            "approval_id": .string(UUID().uuidString), "decision": .string("always_allow"),
            "verification_code": .string("123456")
        ]))
        XCTAssertThrowsError(try OperatorLocalApprovals.execute(request))
    }
}
