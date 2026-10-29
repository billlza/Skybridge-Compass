import Foundation
import XCTest
import SkyBridgeProtocolCore

private typealias SignalingPolicy = CurrentPathSignalingWebSocketPolicy

final class CurrentPathSignalingPathEncodingTests: XCTestCase {
    func testPreservesExistingPercentEscapes() throws {
        for path in ["/signal/%41/%20", "/signal/%7e/%7E/%25", "/signal/%C3%A9", "/signal/%c3%a9", "/signal/%80/%ff"] {
            try assertExactPath(path)
        }
    }

    func testAllPrintableASCIIPathsArePreservedOrRejected() throws {
        let allowed = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~!$&'()*+,;=:@/"
        for value in UInt8(0x21)...UInt8(0x7E) {
            let character = String(UnicodeScalar(value))
            let path = "/signal/a" + character + "b"
            if allowed.contains(character) {
                try assertExactPath(path)
            } else {
                assertRejected(path)
            }
        }
    }

    func testRejectsRawWhitespaceControlsAndUnicode() {
        for scalar in [" ", "\t", "\n", "\r", "\u{0}", "\u{1F}", "\u{7F}", "\u{A0}", "租", "é", "🙂"] {
            assertRejected("/signal/a" + scalar + "b")
        }
    }

    func testRejectsMalformedPercentEscapes() {
        for path in ["/signal/%", "/signal/%2", "/signal/%GG", "/signal/%1G", "/signal/%G1", "/signal/%%20", "/signal/%🙂"] {
            assertRejected(path)
        }
    }

    func testRejectsEncodedControlsAndDelimiters() {
        let rejected = Array(UInt8(0)...UInt8(0x1F)) + [0x7F, 0x2E, 0x2F, 0x5C, 0x3F, 0x23]
        for value in rejected {
            assertRejected("/signal/" + String(format: "%%%02X", value))
            assertRejected("/signal/" + String(format: "%%%02x", value))
        }
    }

    func testRejectsUnsafePathStructure() {
        for path in [nil, "", "/", "signal/ws", "//signal/ws", "/signal//ws", "/signal/", "/./signal", "/signal/..", "/signal/./ws", "/signal/../ws", "/signal\\ws", "/signal?query=1", "/signal#fragment"] as [String?] {
            assertRejected(path)
        }
    }

    func testPreservesSingleLevelPercentEncoding() throws {
        for path in ["/signal/%252F", "/signal/%252e", "/signal/%253F", "/signal/%2520"] {
            try assertExactPath(path)
        }
    }

    func testPreservesNonDefaultPathsAcrossOrigins() throws {
        let origins = [
            ("https://Signal.Example:443", "wss://signal.example"),
            ("https://signal.example:8443", "wss://signal.example:8443"),
            ("http://localhost:8787", "ws://localhost:8787"),
            ("http://127.0.0.1:8787", "ws://127.0.0.1:8787"),
            ("http://[::1]:8787", "ws://[::1]:8787"),
            ("https://[2001:db8::1]:8443", "wss://[2001:db8::1]:8443")
        ]
        for (origin, expectedOrigin) in origins {
            try assertExactPath("/tenant/signaling/%41", origin: origin, expectedOrigin: expectedOrigin)
        }
    }

    func testRejectsInvalidOrigins() {
        for origin in ["http://signal.example", "ftp://localhost", "https://signal.example/path", "https://signal.example?x=1", "https://signal.example#fragment", "not-an-origin"] {
            XCTAssertNil(makeURL("/signal/%41", origin: origin), origin)
        }
    }

    func testPreservesHeaderCredentialsAndUppercaseShard() throws {
        let url = try XCTUnwrap(makeURL("/signal/%41"))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.queryItems, [
            URLQueryItem(name: "shard", value: "SESSION-MIXED"),
            URLQueryItem(name: "cv", value: "1.2.3"),
            URLQueryItem(name: "pv", value: "2")
        ])
        XCTAssertFalse(url.absoluteString.contains("token-value"))
        let headers = try XCTUnwrap(SignalingPolicy.webSocketHeaders(
            sessionID: "session-Mixed", sessionToken: "token-value", clientVersion: "1.2.3", protocolVersion: "2", credentialTransport: .headers
        ))
        XCTAssertEqual(headers[SignalingPolicy.sessionIDHeader], "SESSION-MIXED")
        XCTAssertEqual(headers[SignalingPolicy.sessionTokenHeader], "token-value")
    }

    func testPreservesExplicitQueryCredentialMode() throws {
        let url = try XCTUnwrap(SignalingPolicy.webSocketURL(
            signalingServerOrigin: "https://signal.example", wsPath: "/signal/%41", sessionID: "session-Mixed", sessionToken: "token-value", clientVersion: "1.2.3", protocolVersion: "2", credentialTransport: .queryToken
        ))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.percentEncodedPath, "/signal/%41")
        XCTAssertEqual(components.queryItems?.last, URLQueryItem(name: "st", value: "token-value"))
        let headers = try XCTUnwrap(SignalingPolicy.webSocketHeaders(
            sessionID: "session-Mixed", sessionToken: "token-value", clientVersion: "1.2.3", protocolVersion: "2", credentialTransport: .queryToken
        ))
        XCTAssertNil(headers[SignalingPolicy.sessionIDHeader])
        XCTAssertNil(headers[SignalingPolicy.sessionTokenHeader])
        XCTAssertEqual(headers[SignalingPolicy.clientVersionHeader], "1.2.3")
        XCTAssertEqual(headers[SignalingPolicy.protocolVersionHeader], "2")
    }

    func testPreservesLengthAndOuterTrimBoundaries() throws {
        let maximum = "/" + String(repeating: "a", count: SignalingPolicy.maxWebSocketPathLength - 1)
        try assertExactPath(maximum)
        assertRejected(maximum + "a")
        let url = try XCTUnwrap(makeURL(" \t/tenant/%41 \n"))
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath, "/tenant/%41")
    }

    func testRejectsInvalidCredentials() {
        let cases = [
            ("", "token", "1", "2"),
            ("room", "", "1", "2"),
            ("room", "token,other", "1", "2"),
            ("room", "to\rken", "1", "2"),
            (String(repeating: "x", count: SignalingPolicy.maxSessionIDLength + 1), "token", "1", "2"),
            ("room", String(repeating: "x", count: SignalingPolicy.maxSessionTokenLength + 1), "1", "2"),
            ("room", "token", String(repeating: "x", count: SignalingPolicy.maxVersionLength + 1), "2")
        ]
        for (sessionID, token, version, protocolVersion) in cases {
            XCTAssertNil(SignalingPolicy.webSocketURL(
                signalingServerOrigin: "https://signal.example", wsPath: "/signal/%41", sessionID: sessionID, sessionToken: token, clientVersion: version, protocolVersion: protocolVersion, credentialTransport: .headers
            ))
            XCTAssertNil(SignalingPolicy.webSocketHeaders(
                sessionID: sessionID, sessionToken: token, clientVersion: version, protocolVersion: protocolVersion, credentialTransport: .headers
            ))
        }
    }

    func testPercentEncodedByteMatrix() throws {
        let forbidden = Set(Array(UInt8(0)...UInt8(0x1F)) + [0x7F, 0x2E, 0x2F, 0x5C, 0x3F, 0x23])
        for value in UInt8.min...UInt8.max {
            let path = "/signal/" + String(format: "%%%02X", value)
            if forbidden.contains(value) {
                assertRejected(path)
            } else {
                try assertExactPath(path)
            }
        }
    }

    private func makeURL(_ path: String?, origin: String = "https://signal.example") -> URL? {
        SignalingPolicy.webSocketURL(
            signalingServerOrigin: origin, wsPath: path, sessionID: "session-Mixed", sessionToken: "token-value", clientVersion: "1.2.3", protocolVersion: "2", credentialTransport: .headers
        )
    }

    private func assertExactPath(_ path: String, origin: String = "https://signal.example", expectedOrigin: String = "wss://signal.example", file: StaticString = #filePath, line: UInt = #line) throws {
        let url = try XCTUnwrap(makeURL(path, origin: origin), path, file: file, line: line)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false), file: file, line: line)
        XCTAssertEqual(components.percentEncodedPath, path, file: file, line: line)
        XCTAssertTrue(url.absoluteString.hasPrefix(expectedOrigin + path + "?"), url.absoluteString, file: file, line: line)
        XCTAssertNil(components.fragment, file: file, line: line)
    }

    private func assertRejected(_ path: String?, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try SignalingPolicy.validatedWebSocketPath(path), file: file, line: line) { failure in
            XCTAssertEqual(failure as? SignalingPolicy.PolicyError, .invalidWebSocketPath, file: file, line: line)
        }
        XCTAssertNil(makeURL(path), file: file, line: line)
    }
}
