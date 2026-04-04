import XCTest
@testable import SkyBridgeCore
import SkyBridgeProtocolCore

final class HandshakeCryptoPolicyResolverTests: XCTestCase {
    func testResolverKeepsDefaultPolicyForPurePQC() {
        let policy = HandshakeCryptoPolicyResolver.policy(for: [.mlkem768MLDSA65])

        XCTAssertEqual(policy, .default)
    }

    func testResolverEnablesHybridWhenOnlyHybridSuitesAreOffered() {
        let policy = HandshakeCryptoPolicyResolver.policy(for: [.xwingMLDSA])

        XCTAssertEqual(policy.minimumSecurityTier, .hybridPreferred)
        XCTAssertTrue(policy.allowExperimentalHybrid)
        XCTAssertTrue(policy.advertiseHybrid)
        XCTAssertTrue(policy.requireHybridIfAvailable)
    }

    func testResolverAllowsHybridWithoutForcingItWhenPurePQCAlsoExists() {
        let policy = HandshakeCryptoPolicyResolver.policy(for: [.xwingMLDSA, .mlkem768MLDSA65])

        XCTAssertEqual(policy.minimumSecurityTier, .pqcPreferred)
        XCTAssertTrue(policy.allowExperimentalHybrid)
        XCTAssertTrue(policy.advertiseHybrid)
        XCTAssertFalse(policy.requireHybridIfAvailable)
    }
}
