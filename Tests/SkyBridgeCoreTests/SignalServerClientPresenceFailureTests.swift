import XCTest
@testable import SkyBridgeProtocolCore

/// 信令客户端错误 → `AccountPresenceFailure` 的映射（心跳/账号设备列表的退避与提示都依赖它）。
final class SignalServerClientPresenceFailureTests: XCTestCase {
    func testExtractsTheServerErrorCodeFromTheSanitizedSummary() {
        XCTAssertEqual(
            SignalServerClient.serverRejectedErrorCode(fromSanitizedDescription: #"{"bodyBytes":32,"error":"device_revoked"}"#),
            "device_revoked"
        )
        XCTAssertNil(SignalServerClient.serverRejectedErrorCode(fromSanitizedDescription: "<redacted-server-error-body> bytes=12"))
        XCTAssertNil(SignalServerClient.serverRejectedErrorCode(fromSanitizedDescription: #"{"bodyBytes":3,"error":"  "}"#))
    }

    func testMapsClientErrorsToTypedPresenceFailures() {
        XCTAssertEqual(
            SignalServerClient.presenceFailure(for: SignalServerClient.ClientError.serverRejected(403, #"{"bodyBytes":32,"error":"device_revoked"}"#)),
            .deviceNotActive(code: "device_revoked")
        )
        XCTAssertEqual(
            SignalServerClient.presenceFailure(for: SignalServerClient.ClientError.serverRejected(503, #"{"bodyBytes":40,"error":"registry_schema_outdated"}"#)),
            .registryUnavailable(code: "registry_schema_outdated")
        )
        XCTAssertEqual(
            SignalServerClient.presenceFailure(for: SignalServerClient.ClientError.serverRejected(401, "<redacted-server-error-body> bytes=0")),
            .notAuthenticated
        )
        XCTAssertEqual(
            SignalServerClient.presenceFailure(for: SignalServerClient.ClientError.serverRejected(429, "<redacted-server-error-body> bytes=0")),
            .rateLimited
        )
        XCTAssertEqual(
            SignalServerClient.presenceFailure(for: SignalServerClient.ClientError.serverRejected(502, "<redacted-server-error-body> bytes=0")),
            .serverRejected(status: 502, code: nil)
        )
        XCTAssertEqual(SignalServerClient.presenceFailure(for: SignalServerClient.ClientError.missingAuthentication), .notAuthenticated)
        XCTAssertEqual(SignalServerClient.presenceFailure(for: SignalServerClient.ClientError.malformedResponse("x")), .malformedResponse)
        XCTAssertEqual(SignalServerClient.presenceFailure(for: SignalServerClient.ClientError.requestTimedOut("/api/devices/list")), .transport)
        XCTAssertEqual(
            SignalServerClient.presenceFailure(for: AccountPresenceClientError.localIdentityUnavailable(underlying: "DeviceIdentityKeyError")),
            .localIdentityUnavailable
        )
        XCTAssertEqual(SignalServerClient.presenceFailure(for: URLError(.notConnectedToInternet)), .transport)
    }
}
