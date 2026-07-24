import XCTest
@testable import SkyBridgeCameraKit

final class EndpointTests: XCTestCase {
    func testAcceptsOnlyRFC1918IPv4AndULAIPv6Literals() throws {
        let accepted = [
            "rtsp://10.0.0.1/live",
            "rtsp://172.16.0.1/live",
            "rtsp://172.31.255.254/live",
            "rtsps://192.168.1.20:7441/stream?profile=main",
            "rtsp://[fc00::1]/live",
            "rtsps://[fdff:1234::abcd]:7441/live",
        ]
        for value in accepted {
            XCTAssertNoThrow(try RTSPEndpoint(value), value)
        }

        let secure = try RTSPEndpoint("rtsps://192.168.1.20/live")
        XCTAssertTrue(secure.isSecure)
        XCTAssertEqual(secure.port, 322)
        XCTAssertEqual(String(describing: secure), "RTSPEndpoint(<redacted>)")
    }

    func testRejectsNamesAndEveryNonPrivateAddressClass() {
        let rejected = [
            "rtsp://camera.local/live",
            "rtsp://camera.example/live",
            "rtsp://127.0.0.1/live",
            "rtsp://0.0.0.0/live",
            "rtsp://8.8.8.8/live",
            "rtsp://100.64.0.1/live",
            "rtsp://169.254.1.1/live",
            "rtsp://224.0.0.1/live",
            "rtsp://[::]/live",
            "rtsp://[::1]/live",
            "rtsp://[fe80::1]/live",
            "rtsp://[ff02::1]/live",
            "rtsp://[2001:db8::1]/live",
            "rtsp://[fe80::1%25en0]/live",
            "rtsp://%31%39%32.168.1.1/live",
            "rtsp://%0d%0a192.168.1.1/live",
            "rtsp://192.168.1.2:/live",
        ]
        for value in rejected {
            XCTAssertThrowsError(try RTSPEndpoint(value), value)
        }
    }

    func testRejectsCredentialsFragmentsAndUnsupportedSchemes() {
        XCTAssertThrowsError(try RTSPEndpoint("rtsp://user:secret@192.168.1.2/live")) {
            XCTAssertEqual($0 as? SkyBridgeCameraError, .credentialsInURLForbidden)
        }
        XCTAssertThrowsError(try RTSPEndpoint("rtsp://192.168.1.2/live#fragment"))
        XCTAssertThrowsError(try RTSPEndpoint("https://192.168.1.2/live"))

        let oversized = "rtsp://192.168.1.2/" + String(repeating: "a", count: 2_048)
        XCTAssertThrowsError(try RTSPEndpoint(oversized))
        XCTAssertThrowsError(try RTSPEndpoint(
            url: URL(string: "rtsp://192.168.1.2/live\u{7F}")!
        ))
    }

    func testSameOriginPolicyRejectsSchemeHostAndPortChanges() throws {
        let endpoint = try RTSPEndpoint("rtsp://192.168.1.2:8554/live/")
        XCTAssertNoThrow(try endpoint.validateSameOrigin(
            XCTUnwrap(URL(string: "rtsp://192.168.1.2:8554/live/track1"))
        ))
        XCTAssertThrowsError(try endpoint.validateSameOrigin(
            XCTUnwrap(URL(string: "rtsps://192.168.1.2:8554/live/track1"))
        ))
        XCTAssertThrowsError(try endpoint.validateSameOrigin(
            XCTUnwrap(URL(string: "rtsp://192.168.1.3:8554/live/track1"))
        ))
        XCTAssertThrowsError(try endpoint.validateSameOrigin(
            XCTUnwrap(URL(string: "rtsp://192.168.1.2:8555/live/track1"))
        ))
    }

    func testCredentialDescriptionsAreRedactedAndColonIsRejected() throws {
        let credentials = try RTSPCredentials(username: "viewer", password: "secret")
        XCTAssertEqual(String(describing: credentials), "RTSPCredentials(<redacted>)")
        XCTAssertEqual(String(reflecting: credentials), "RTSPCredentials(<redacted>)")
        XCTAssertThrowsError(try RTSPCredentials(username: "bad:name", password: "secret"))
        XCTAssertThrowsError(try RTSPCredentials(
            username: "viewer\r\nInjected",
            password: "secret"
        ))
        XCTAssertThrowsError(try RTSPCredentials(
            username: "viewer",
            password: "secret\r\nInjected"
        ))
    }
}
