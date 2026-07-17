import Foundation
import Security
import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, *)
final class CAServiceManagerTests: XCTestCase {
    func testEndpointRequiresCredentialFreeHTTPSURL() throws {
        XCTAssertEqual(
            try CAServiceManager.validatedEndpoint(
                XCTUnwrap(URL(string: "https://ca.example.test/v1/csr?tenant=one"))
            ).absoluteString,
            "https://ca.example.test/v1/csr?tenant=one"
        )

        for rawURL in [
            "http://ca.example.test/v1/csr",
            "https://user:secret@ca.example.test/v1/csr",
            "https://ca.example.test/v1/csr#fragment",
            "file:///tmp/ca"
        ] {
            XCTAssertThrowsError(
                try CAServiceManager.validatedEndpoint(
                    XCTUnwrap(URL(string: rawURL))
                )
            ) { error in
                XCTAssertEqual(error as? CAServiceError, .invalidHTTPSEndpoint)
            }
        }
    }

    func testRequestIdRejectsAliasesControlsAndUnboundedValues() throws {
        XCTAssertEqual(
            try CAServiceManager.validatedRequestId("request-123"),
            "request-123"
        )

        for invalid in [
            "",
            " request-123",
            "request-123\n",
            "request\u{0000}123",
            String(repeating: "x", count: 513)
        ] {
            XCTAssertThrowsError(
                try CAServiceManager.validatedRequestId(invalid)
            ) { error in
                XCTAssertEqual(error as? CAServiceError, .invalidRequestId)
            }
        }
    }

    func testCSRRequiresOneBoundedPEMEnvelope() throws {
        let valid = """
        -----BEGIN CERTIFICATE REQUEST-----
        MAA=
        -----END CERTIFICATE REQUEST-----
        """
        XCTAssertEqual(
            try CAServiceManager.validatedCSRData(valid),
            Data(valid.utf8)
        )
        XCTAssertNoThrow(
            try CAServiceManager.validatedCSRData(
                valid.replacingOccurrences(of: "\n", with: "\r\n")
            )
        )

        for invalid in [
            "",
            "MAA=",
            valid + "junk",
            valid.replacingOccurrences(of: "MAA=", with: "not-base64!"),
            valid.replacingOccurrences(of: "\n", with: "\r")
        ] {
            XCTAssertThrowsError(
                try CAServiceManager.validatedCSRData(invalid)
            ) { error in
                XCTAssertEqual(error as? CAServiceError, .invalidCSR)
            }
        }
    }

    func testPollingResponseUsesExplicitPendingOrCertificateContract() throws {
        let pending = try CAServiceManager.parsePollingResponse("pending")
        XCTAssertFalse(pending.issued)
        XCTAssertNil(pending.pem)

        for invalid in [
            "",
            "pending\n",
            "not issued",
            "-----BEGIN CERTIFICATE-----\ninvalid\n-----END CERTIFICATE-----"
        ] {
            XCTAssertThrowsError(
                try CAServiceManager.parsePollingResponse(invalid)
            ) { error in
                XCTAssertEqual(error as? CAServiceError, .invalidResponseBody)
            }
        }
    }

    func testPollingResponseAcceptsOneParseableCertificatePEM() throws {
        let privateKey = try makeEphemeralP256PrivateKey()
        let certificateDER = try TLSSelfSignedCertificateBuilder
            .buildCertificateDER(
                privateKey: privateKey,
                subject: .init(
                    commonName: "ca-response-test",
                    organization: "SkyBridge",
                    organizationalUnit: "Tests"
                ),
                serialNumber: Data([0x01]),
                notBefore: Date(timeIntervalSince1970: 1_767_225_600),
                notAfter: Date(timeIntervalSince1970: 1_798_761_600)
            )
        let pem = "-----BEGIN CERTIFICATE-----\n"
            + certificateDER.base64EncodedString(
                options: [.lineLength64Characters]
            )
            + "\n-----END CERTIFICATE-----\n"

        let result = try CAServiceManager.parsePollingResponse(pem)
        XCTAssertTrue(result.issued)
        XCTAssertEqual(result.pem, pem)

        let crlfPEM = pem.replacingOccurrences(of: "\n", with: "\r\n")
        let crlfResult = try CAServiceManager.parsePollingResponse(crlfPEM)
        XCTAssertTrue(crlfResult.issued)
        XCTAssertEqual(crlfResult.pem, crlfPEM)
    }

    private func makeEphemeralP256PrivateKey() throws -> SecKey {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: false
            ]
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(
            attributes as CFDictionary,
            &error
        ) else {
            throw error!.takeRetainedValue()
        }
        return key
    }
}
