import Foundation
import XCTest
import enum SkyBridgeProtocolCore.ClassicTransferApprovalError
@testable import SkyBridgeCompass_iOS

final class FileTransferErrorFormatterTests: XCTestCase {
    func testEveryKnownApprovalFailureUsesItsSpecificLocalizationKey() {
        let cases: [(ClassicTransferApprovalError, String)] = [
            (.refused(.denied), "fileTransfer.error.approvalDenied"),
            (.refused(.unavailable), "fileTransfer.error.receiverUnavailable"),
            (.capabilityEvidenceUnavailable, "fileTransfer.error.capabilitiesNotReady"),
            (.invalidSessionBinding, "fileTransfer.error.sessionNotReady"),
            (.unsupportedProtocol, "fileTransfer.error.approvalProtocolUnsupported"),
            (.invalidResponse, "fileTransfer.error.approvalResponseInvalid"),
            (.requestMismatch, "fileTransfer.error.approvalRequestMismatch"),
            (.authenticationFailed, "fileTransfer.error.approvalAuthenticationFailed"),
        ]
        for (error, key) in cases {
            var requestedKeys: [String] = []
            let message = FileTransferErrorFormatter.localizedMessage(for: error) {
                requestedKeys.append($0)
                return "localized: \($0)"
            }
            XCTAssertEqual(requestedKeys, [key])
            XCTAssertEqual(message, "localized: \(key)")
        }
    }

    func testUnknownErrorsKeepOriginalDetailsWithoutLocalizationOrTruncation() {
        let detail = String(repeating: "original detail ", count: 20)
        let error = NSError(domain: "FileProvider", code: 27,
            userInfo: [NSLocalizedDescriptionKey: detail])
        let message = FileTransferErrorFormatter.localizedMessage(for: error) { _ in
            XCTFail("Unknown errors must preserve their existing explanation")
            return "replacement"
        }
        XCTAssertEqual(message, error.localizedDescription)
    }

    func testNSErrorCodeZeroIsNotGuessedToBeARefusal() {
        let error = NSError(domain: "SkyBridgeProtocolCore.ClassicTransferApprovalError", code: 0,
            userInfo: [NSLocalizedDescriptionKey: "Original untyped error"])
        XCTAssertEqual(FileTransferErrorFormatter.localizedMessage(for: error), error.localizedDescription)
    }
}
