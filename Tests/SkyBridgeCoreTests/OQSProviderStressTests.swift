import XCTest
@testable import SkyBridgeCore

final class OQSProviderStressTests: XCTestCase {
    func testSignVerifyStress() async throws {
        #if canImport(OQSRAII)
        let provider = OQSProvider()
        let peer = "stress-peer"
        let message = Data(repeating: 0xAB, count: 1024)
        for _ in 0..<100 {
            let sig = try await provider.sign(data: message, peerId: peer, algorithm: "ML-DSA-65")
            let ok = await provider.verify(data: message, signature: sig, peerId: peer, algorithm: "ML-DSA-65")
            XCTAssertTrue(ok)
        }
        #else
        throw XCTSkip("OQSRAII not available")
        #endif
    }
    func testKEMEncapDecapStress() async throws {
        #if canImport(OQSRAII)
        let provider = OQSProvider()
        let peer = "stress-peer-kem"
        for _ in 0..<100 {
            let r = try await provider.kemEncapsulate(peerId: peer, kemVariant: "ML-KEM-768")
            let ss = try await provider.kemDecapsulate(peerId: peer, encapsulated: r.encapsulated, kemVariant: "ML-KEM-768")
            XCTAssertEqual(r.sharedSecret, ss)
        }
        #else
        throw XCTSkip("OQSRAII not available")
        #endif
    }
    func testConcurrentOperations() async throws {
        #if canImport(OQSRAII)
        let provider = OQSProvider()
        let peer = "stress-concurrent"
        let message = Data(repeating: 0xCD, count: 2048)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<32 {
                group.addTask {
                    let id = peer + "-\(i)"
                    let sig = try await provider.sign(data: message, peerId: id, algorithm: "ML-DSA-65")
                    let ok = await provider.verify(data: message, signature: sig, peerId: id, algorithm: "ML-DSA-65")
                    XCTAssertTrue(ok)
                }
            }
            try await group.waitForAll()
        }
        #else
        throw XCTSkip("OQSRAII not available")
        #endif
    }
}
