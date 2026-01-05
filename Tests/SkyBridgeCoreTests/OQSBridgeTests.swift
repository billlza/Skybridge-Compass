import XCTest
@testable import SkyBridgeCore

#if canImport(liboqs)
final class OQSBridgeTests: XCTestCase {
    func testMLDSA65SignVerify() async throws {
        let peer = "test-peer"
        let msg = Data("hello-oqs".utf8)
        let sig = try await OQSBridge.sign(msg, peerId: peer, algorithm: .mldsa65)
        let ok = await OQSBridge.verify(msg, signature: sig, peerId: peer, algorithm: .mldsa65)
        XCTAssertTrue(ok)
    }
    func testMLKEM768EncDec() async throws {
        let peer = "test-peer"
        let r = try await OQSBridge.kemEncapsulate(peerId: peer, algorithm: .mlkem768)
        let ss = try await OQSBridge.kemDecapsulate(r.encapsulated, peerId: peer, algorithm: .mlkem768)
        XCTAssertEqual(r.shared.count, ss.count)
    }
}
#endif