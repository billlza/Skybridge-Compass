import Foundation
import SkyBridgeProtocolCore
import XCTest

final class CrossNetworkFileTransferWireEncoderTests: XCTestCase {
    func testErrorMessageEncodingIsCanonicalAndDeterministic() throws {
        let message = CrossNetworkFileTransferMessage(
            op: .error,
            transferId: "01234567-89AB-CDEF-0123-456789ABCDEF",
            message: "path/segment"
        )
        let expected = Data(
            #"{"message":"path/segment","op":"error","transferId":"01234567-89AB-CDEF-0123-456789ABCDEF","version":1}"#.utf8
        )

        let first = try CrossNetworkFileTransferWireEncoder.encode(message)

        XCTAssertEqual(first, expected)
        XCTAssertFalse(String(decoding: first, as: UTF8.self).contains(#"\/"#))
        for _ in 0..<32 {
            XCTAssertEqual(
                try CrossNetworkFileTransferWireEncoder.encode(message),
                first
            )
        }
    }

    func testStrictDecoderAcceptsLegacyKeyOrderAndEscapedSlashes() throws {
        let transferID = "01234567-89AB-CDEF-0123-456789ABCDEF"
        let legacy = Data(
            #"{"transferId":"01234567-89AB-CDEF-0123-456789ABCDEF","message":"path\/segment","version":1,"op":"error"}"#.utf8
        )

        let decoded = try CrossNetworkFileTransferWireDecoder.decode(legacy)

        XCTAssertEqual(decoded.version, 1)
        XCTAssertEqual(decoded.op, .error)
        XCTAssertEqual(decoded.transferId, transferID)
        XCTAssertEqual(decoded.message, "path/segment")
    }
}

final class CrossNetworkFileTransferShippingCodecContractTests: XCTestCase {
    func testMacShippingSendPathsUseCanonicalWireEncoder() throws {
        let outbound = try repositorySource(
            "Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager+WebRTCFileTransfer.swift"
        )
        let manager = try repositorySource(
            "Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift"
        )

        XCTAssertEqual(
            occurrenceCount(
                of: "let plain = try CrossNetworkFileTransferWireEncoder.encode(message)",
                in: outbound
            ),
            1
        )
        XCTAssertFalse(outbound.contains("let plain = try JSONEncoder().encode(message)"))
        XCTAssertEqual(
            occurrenceCount(
                of: "let outPlain = try CrossNetworkFileTransferWireEncoder.encode(response)",
                in: manager
            ),
            2
        )
        XCTAssertFalse(manager.contains("let outPlain = try JSONEncoder().encode(response)"))
    }

    private func repositorySource(_ relativePath: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func occurrenceCount(of needle: String, in source: String) -> Int {
        source.components(separatedBy: needle).count - 1
    }
}
