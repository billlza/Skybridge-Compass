import XCTest
import CryptoKit
@testable import SkyBridgeCore
@available(macOS 14.0, iOS 17.0, *)
final class SignedQPeriaptRefreshTests: XCTestCase {
    private struct Vector: Decodable {
        let request: AppMessage.KEMRefreshRequestPayload
        let response: AppMessage.SignedKEMRefreshPayload
        let requestHashHex: String
        let responseHashHex: String
    }

    private func vector() throws -> Vector {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "skr2-golden", withExtension: "json"))
        return try JSONDecoder().decode(Vector.self, from: Data(contentsOf: url))
    }

    func testAndroidQOnlyRequestAndSignedResponseHaveIdenticalCanonicalBytes() throws {
        let vector = try vector()
        XCTAssertEqual(vector.request.version, 2)
        XCTAssertEqual(try vector.request.validatedStrictResponderSuites(now: vector.request.sentAt).map(\.wireId), [0x0012])
        XCTAssertEqual(vector.request.canonicalRequestHashHex, vector.requestHashHex)
        let payload = try vector.response.validatedForStrictPQCImport(
            request: vector.request, now: vector.request.sentAt,
            pinnedProtocolFingerprints: [vector.response.protocolIdentityFingerprint]
        )
        XCTAssertEqual(payload.kemPublicKeys.map(\.suiteWireId), [0x0012])
        XCTAssertEqual(payload.platform, "macOS")
        XCTAssertEqual(payload.osVersion, "macOS 26.5")
        XCTAssertEqual(SHA256.hash(data: payload.signaturePreimage).map { String(format: "%02x", $0) }.joined(), vector.responseHashHex)
        let wire = try JSONEncoder().encode(AppMessage.signedKEMRefresh(payload))
        XCTAssertEqual(try AppMessage.decodeWireMessage(from: wire), .signedKEMRefresh(payload))
    }

    func testIndependentAndroidMlDsa65SignatureVerifiesAndPlatformTamperingFails() async throws {
        let vector = try vector()
        let provider = ProtocolSignatureProviderSelector.select(for: .mlDSA65)
        let original = try await provider.verify(
            vector.response.signaturePreimage, signature: vector.response.signature,
            publicKey: vector.response.protocolIdentityPublicKey
        )
        XCTAssertTrue(original)
        let tampered = try changing(vector.response, field: "osVersion", value: "macOS 26.6")
        // This OS is still eligible, so only the cryptographic signature distinguishes it.
        _ = try tampered.validatedForStrictPQCImport(
            request: vector.request, now: vector.request.sentAt,
            pinnedProtocolFingerprints: [vector.response.protocolIdentityFingerprint]
        )
        let tamperedSignatureValid = try await provider.verify(
            tampered.signaturePreimage, signature: tampered.signature,
            publicKey: tampered.protocolIdentityPublicKey
        )
        XCTAssertFalse(tamperedSignatureValid)
    }

    func testQVersionDowngradeMissingPlatformAndMixedSuitesFailAdmission() throws {
        let vector = try vector()
        for (field, value): (String, Any) in [
            ("version", 1), ("version", 3), ("platform", NSNull()),
            ("osVersion", NSNull()), ("osVersion", "macOS 25.0"),
            ("policyAllowClassicFallback", true)
        ] {
            let changed = try changing(vector.response, field: field, value: value)
            XCTAssertThrowsError(try changed.validatedForStrictPQCImport(
                request: vector.request, now: vector.request.sentAt,
                pinnedProtocolFingerprints: [vector.response.protocolIdentityFingerprint]
            ), "accepted invalid Q field \(field)")
        }
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(vector.request)) as? [String: Any])
        object["requestedSuiteWireIds"] = [0x0012, 0x0001]
        let mixed = try JSONDecoder().decode(AppMessage.KEMRefreshRequestPayload.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertThrowsError(try mixed.validatedStrictResponderSuites(now: vector.request.sentAt))
    }

    func testQProfileRejectsInvalidKeyLengthBeforeSignatureImport() throws {
        let vector = try vector()
        let malformed = try changing(vector.response, field: "kemPublicKeys", value: [[
            "suiteWireId": 0x0012, "publicKey": Data(repeating: 0x55, count: 1184).base64EncodedString()
        ]])
        XCTAssertThrowsError(try malformed.validatedForStrictPQCImport(
            request: vector.request, now: vector.request.sentAt,
            pinnedProtocolFingerprints: [vector.response.protocolIdentityFingerprint]
        )) { error in
            XCTAssertEqual(error as? AppMessage.KEMRefreshValidationError,
                .invalidKEMPublicKeyLength(wireId: 0x0012, expected: 1216, actual: 1184))
        }
    }

    func testVerifiedQImportSurvivesRestartAndRejectsMissingVersion() async throws {
        let (request, response) = try await freshSignedResponse()
        let suiteName = "signed-q-refresh-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let store = PeerKEMBootstrapStore(defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName)))
        try await store.upsertSignedKEMRefresh(deviceIds: [response.deviceId], payload: response,
            request: request, pinnedProtocolFingerprints: [response.protocolIdentityFingerprint], minimumGeneration: nil)
        let restarted = PeerKEMBootstrapStore(defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName)))
        let keys = await restarted.signedRefreshKEMPublicKeys(forCandidates: [response.deviceId], pinnedProtocolFingerprints: [response.protocolIdentityFingerprint])
        XCTAssertEqual(keys[0x0012], response.kemPublicKeys.first?.publicKey)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let key = "com.skybridge.p2p.bootstrap_kem_store.v1"
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(defaults.data(forKey: key))) as? [String: Any])
        var entries = try XCTUnwrap(object["entries"] as? [String: [String: Any]])
        for id in entries.keys { entries[id]?.removeValue(forKey: "signedRefreshVersion") }
        object["entries"] = entries
        defaults.set(try JSONSerialization.data(withJSONObject: object), forKey: key)
        let withoutSignedVersion = PeerKEMBootstrapStore(defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName)))
        let rejected = await withoutSignedVersion.signedRefreshKEMPublicKeys(forCandidates: [response.deviceId], pinnedProtocolFingerprints: [response.protocolIdentityFingerprint])
        XCTAssertNil(rejected[0x0012])
    }

    func testImportNeverReturnsSuccessWhenPreferenceWriteIsLost() async throws {
        let (request, response) = try await freshSignedResponse()
        let defaults = try XCTUnwrap(RejectingWritesDefaults(suiteName: "signed-q-rejected-\(UUID().uuidString)"))
        let store = PeerKEMBootstrapStore(defaults: defaults)
        do {
            try await store.upsertSignedKEMRefresh(deviceIds: [response.deviceId], payload: response,
                request: request, pinnedProtocolFingerprints: [response.protocolIdentityFingerprint], minimumGeneration: nil)
            XCTFail("lost signed KEM write was reported as success")
        } catch let error as PeerKEMBootstrapStore.SignedRefreshImportError {
            XCTAssertEqual(error, .persistenceVerificationFailed)
        }
        let keys = await store.signedRefreshKEMPublicKeys(forCandidates: [response.deviceId], pinnedProtocolFingerprints: [response.protocolIdentityFingerprint])
        XCTAssertTrue(keys.isEmpty)
    }

    private func freshSignedResponse() async throws -> (AppMessage.KEMRefreshRequestPayload, AppMessage.SignedKEMRefreshPayload) {
        let context = try DeviceIdentityKeychainTestContext()
        defer { try? context.reset() }
        let identity = try await context.manager.getProtocolSigningIdentity(for: .mlDSA65, protection: .softwareKeychain)
        let fingerprint = ProtocolIdentityPublicKeys(protocolPublicKey: identity.publicKey, protocolAlgorithm: .mlDSA65).authoritativeFingerprint
        let request = AppMessage.KEMRefreshRequestPayload(version: 2, requesterDeviceId: "id:android-1",
            targetDeviceId: "id:mac-1", requesterProtocolIdentityFingerprint: fingerprint,
            targetProtocolIdentityFingerprint: fingerprint, requestedSuiteWireIds: [0x0012], nonce: Data(repeating: 0x44, count: 24))
        let now = Date()
        let unsigned = AppMessage.SignedKEMRefreshPayload(version: 2, deviceId: "id:mac-1",
            protocolSigningAlgorithm: "ML-DSA-65", protocolIdentityPublicKey: identity.publicKey,
            protocolIdentityFingerprint: fingerprint, kemPublicKeys: try vector().response.kemPublicKeys,
            keyId: "q-bootstrap-key", generation: 7, sentAt: now, expiresAt: now.addingTimeInterval(300),
            requestNonce: request.nonce, requestHashHex: request.canonicalRequestHashHex,
            platform: "macOS", osVersion: "macOS 26.5", signature: Data())
        let signature = try await ProtocolSignatureProviderSelector.select(for: .mlDSA65).sign(unsigned.signaturePreimage, key: identity.keyHandle)
        return (request, try changing(unsigned, field: "signature", value: signature.base64EncodedString()))
    }

    // This actor-owned fixture drops writes; it is never shared across isolation domains.
    private final class RejectingWritesDefaults: UserDefaults {
        override func set(_ value: Any?, forKey defaultName: String) {}
    }

    private func changing(_ payload: AppMessage.SignedKEMRefreshPayload, field: String, value: Any) throws -> AppMessage.SignedKEMRefreshPayload {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any])
        object[field] = value
        return try JSONDecoder().decode(AppMessage.SignedKEMRefreshPayload.self, from: JSONSerialization.data(withJSONObject: object))
    }
}
