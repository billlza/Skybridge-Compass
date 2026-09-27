import XCTest
import CryptoKit
@testable import SkyBridgeCompass_iOS
@available(iOS 17.0, *)
final class SignedQPeriaptRefreshTests: XCTestCase {
    private struct Vector: Decodable {
        let request: AppMessage.KEMRefreshRequestPayload
        let response: AppMessage.SignedKEMRefreshPayload
        let requestHashHex: String
        let responseHashHex: String
    }

    private func vector() throws -> Vector {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "skr2-golden", withExtension: "json"))
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

    private func changing(_ payload: AppMessage.SignedKEMRefreshPayload, field: String, value: Any) throws -> AppMessage.SignedKEMRefreshPayload {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any])
        object[field] = value
        return try JSONDecoder().decode(AppMessage.SignedKEMRefreshPayload.self, from: JSONSerialization.data(withJSONObject: object))
    }
}
