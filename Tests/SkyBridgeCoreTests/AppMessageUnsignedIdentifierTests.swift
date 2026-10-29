import Foundation
import XCTest
@testable import SkyBridgeCore

final class AppMessageUnsignedIdentifierTests: XCTestCase {
    func testPingAndPongUseExactUnsigned64JSONNumbers() throws {
        let values: [UInt64] = [0, 9_007_199_254_740_993, UInt64(Int64.max),
                                UInt64(Int64.max) + 1, UInt64.max]
        for kind in ["ping", "pong"] {
            for id in values {
                let message: AppMessage = kind == "ping" ? .ping(.init(id: id)) : .pong(.init(id: id))
                let wire = try JSONEncoder().encode(message)
                XCTAssertEqual(String(decoding: wire, as: UTF8.self), "{\"\(kind)\":{\"id\":\(id)}}")
                XCTAssertEqual(try JSONDecoder().decode(AppMessage.self, from: wire), message)
            }
        }
    }

    func testIdentifiersOutsideUnsigned64RangeAreRejected() {
        for kind in ["ping", "pong"] {
            for value in ["-1", "18446744073709551616", "1.5"] {
                let wire = Data("{\"\(kind)\":{\"id\":\(value)}}".utf8)
                XCTAssertThrowsError(try JSONDecoder().decode(AppMessage.self, from: wire))
            }
        }
    }
}
