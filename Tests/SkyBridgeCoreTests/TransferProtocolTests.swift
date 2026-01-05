import XCTest
#if canImport(CryptoKit)
import CryptoKit
#endif

final class TransferProtocolTests: XCTestCase {
    func testLengthPrefixedFrameEncodingDecoding() throws {
        let payload = Data("hello".utf8)
        var length = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(payload)
        let lenData = frame.prefix(4)
        let decodedLen = lenData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        XCTAssertEqual(decodedLen, 5)
        let body = frame.suffix(from: 4)
        XCTAssertEqual(String(data: body, encoding: .utf8), "hello")
    }
    func testSHA256HashConsistency() throws {
        #if canImport(CryptoKit)
        let data = Data([1,2,3,4,5])
        let hash = SHA256.hash(data: data)
        let hex = hash.compactMap { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hex.count, 64)
        #endif
    }
}
