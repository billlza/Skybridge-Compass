import XCTest
@testable import SkyBridgeCameraKit

final class AuthenticationTests: XCTestCase {
    func testSelectsSHA256DigestOverMD5AndBasic() throws {
        let selection = try RTSPAuthentication.selectChallenge(
            from: [
                "Basic realm=\"camera\"",
                "Digest realm=\"camera\", nonce=\"old\", algorithm=MD5, qop=\"auth\"",
                "Digest realm=\"camera\", nonce=\"new\", algorithm=SHA-256, qop=\"auth,auth-int\"",
            ],
            isSecureTransport: true
        )
        guard case let .digest(challenge) = selection else {
            return XCTFail("expected Digest")
        }
        XCTAssertEqual(challenge.algorithm, .sha256)
        XCTAssertEqual(challenge.nonce, "new")
        XCTAssertFalse(challenge.isStale)
    }

    func testBasicIsRejectedWithoutTLSAtSelectionAndContextBoundaries() throws {
        XCTAssertThrowsError(try RTSPAuthentication.selectChallenge(
            from: ["Basic realm=\"camera\""],
            isSecureTransport: false
        )) {
            XCTAssertEqual($0 as? SkyBridgeCameraError, .basicAuthenticationRequiresTLS)
        }

        let credentials = try RTSPCredentials(username: "viewer", password: "secret")
        XCTAssertThrowsError(try RTSPAuthenticationContext(
            selection: .basic,
            credentials: credentials,
            secureTransport: false
        )) {
            XCTAssertEqual($0 as? SkyBridgeCameraError, .basicAuthenticationRequiresTLS)
        }
    }

    func testRFC2617MD5DigestVectorAndNonceCount() throws {
        let credentials = try RTSPCredentials(username: "Mufasa", password: "Circle Of Life")
        let challenge = RTSPDigestChallenge(
            realm: "testrealm@host.com",
            nonce: "dcd98b7102dd2f0e8b11d0f600bfb0c093",
            algorithm: .md5,
            opaque: "5ccc069c403ebaf9f0171e9517f40e41"
        )
        var context = try RTSPAuthenticationContext(
            selection: .digest(challenge),
            credentials: credentials,
            secureTransport: false
        )
        let first = try context.authorizationHeader(
            method: "GET",
            uri: "/dir/index.html",
            cnonce: "0a4f113b"
        )
        XCTAssertTrue(first.contains("response=\"6629fae49393a05397450978507c4ef1\""))
        XCTAssertTrue(first.contains("nc=00000001"))
        let second = try context.authorizationHeader(
            method: "GET",
            uri: "/dir/index.html",
            cnonce: "0a4f113b"
        )
        XCTAssertTrue(second.contains("nc=00000002"))
    }

    func testDigestRejectsUnsupportedQOPAndHeaderInjection() throws {
        XCTAssertThrowsError(try RTSPAuthentication.selectChallenge(
            from: ["Digest realm=\"r\", nonce=\"n\", algorithm=MD5, qop=\"auth-int\""],
            isSecureTransport: true
        ))
        XCTAssertThrowsError(try RTSPAuthentication.selectChallenge(
            from: [
                "Digest realm=\"r\", nonce=\"n\", algorithm=SHA-512, qop=\"auth\"",
                "Basic realm=\"camera\"",
            ],
            isSecureTransport: true
        ))

        let credentials = try RTSPCredentials(username: "viewer", password: "secret")
        var context = try RTSPAuthenticationContext(
            selection: .digest(.init(realm: "r", nonce: "n", algorithm: .sha256)),
            credentials: credentials,
            secureTransport: false
        )
        XCTAssertThrowsError(try context.authorizationHeader(
            method: "DESCRIBE",
            uri: "rtsp://192.168.1.2/live\r\nInjected: yes",
            cnonce: "abc123"
        ))
    }

    func testDigestStaleRefreshUsesNewNonceOpaqueAndResetsNonceCount() throws {
        let credentials = try RTSPCredentials(username: "viewer", password: "secret")
        var context = try RTSPAuthenticationContext(
            selection: .digest(.init(
                realm: "camera",
                nonce: "old-nonce",
                algorithm: .sha256,
                opaque: "old-opaque"
            )),
            credentials: credentials,
            secureTransport: false
        )
        let oldAuthorization = try context.authorizationHeader(
            method: "OPTIONS",
            uri: "rtsp://192.168.1.2/live",
            cnonce: "abc123"
        )
        XCTAssertTrue(oldAuthorization.contains("nonce=\"old-nonce\""))
        XCTAssertTrue(oldAuthorization.contains("nc=00000001"))

        XCTAssertTrue(try context.refreshIfStale(from: [
            "Digest realm=\"camera\", nonce=\"new-nonce\", algorithm=SHA-256, "
                + "qop=\"auth\", stale=TRUE, opaque=\"new-opaque\"",
        ]))
        let refreshedAuthorization = try context.authorizationHeader(
            method: "OPTIONS",
            uri: "rtsp://192.168.1.2/live",
            cnonce: "def456"
        )
        XCTAssertTrue(refreshedAuthorization.contains("nonce=\"new-nonce\""))
        XCTAssertTrue(refreshedAuthorization.contains("opaque=\"new-opaque\""))
        XCTAssertTrue(refreshedAuthorization.contains("nc=00000001"))
    }

    func testDigestStaleRefreshRejectsMissingPermissionAndSecurityBoundaryChanges() throws {
        let credentials = try RTSPCredentials(username: "viewer", password: "secret")

        func makeContext() throws -> RTSPAuthenticationContext {
            try RTSPAuthenticationContext(
                selection: .digest(.init(
                    realm: "camera",
                    nonce: "old-nonce",
                    algorithm: .sha256
                )),
                credentials: credentials,
                secureTransport: false
            )
        }

        var notStale = try makeContext()
        XCTAssertFalse(try notStale.refreshIfStale(from: [
            "Digest realm=\"camera\", nonce=\"new-nonce\", algorithm=SHA-256, qop=\"auth\"",
        ]))

        var reusedNonce = try makeContext()
        XCTAssertThrowsError(try reusedNonce.refreshIfStale(from: [
            "Digest realm=\"camera\", nonce=\"old-nonce\", algorithm=SHA-256, "
                + "qop=\"auth\", stale=true",
        ])) { error in
            guard let cameraError = error as? SkyBridgeCameraError,
                  case .unsupportedAuthentication = cameraError else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        var changedRealm = try makeContext()
        XCTAssertThrowsError(try changedRealm.refreshIfStale(from: [
            "Digest realm=\"other\", nonce=\"new-nonce\", algorithm=SHA-256, "
                + "qop=\"auth\", stale=true",
        ])) { error in
            guard let cameraError = error as? SkyBridgeCameraError,
                  case .unsupportedAuthentication = cameraError else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        var downgradedAlgorithm = try makeContext()
        XCTAssertThrowsError(try downgradedAlgorithm.refreshIfStale(from: [
            "Basic realm=\"camera\", "
                + "Digest realm=\"camera\", nonce=\"new-nonce\", algorithm=MD5, "
                + "qop=\"auth\", stale=true",
        ])) { error in
            guard let cameraError = error as? SkyBridgeCameraError,
                  case .unsupportedAuthentication = cameraError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }
}
