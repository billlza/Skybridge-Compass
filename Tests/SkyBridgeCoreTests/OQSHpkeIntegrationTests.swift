import XCTest
@testable import SkyBridgeCore

final class OQSHpkeIntegrationTests: XCTestCase {
    func testHpkeSealOpenWithAADAndToken() async throws {
        let fixture = try await AuthenticatedHPKETestFixture.make()
        let peer = fixture.peerId
        let plaintext = Data("Hello HPKE".utf8)
        let aad = Data("SkyBridgeHPKE-AAD".utf8)

        let sealed = try await fixture.sender.hpkeSeal(
            recipientPeerId: peer,
            plaintext: plaintext,
            associatedData: aad
        )

        let opened = try await fixture.recipient.hpkeOpen(
            recipientPeerId: peer,
            ciphertext: sealed.ciphertext,
            encapsulatedKey: sealed.encapsulatedKey,
            associatedData: aad
        )
        XCTAssertEqual(opened, plaintext)

        let claims = ["peer": peer, "ts": String(Date().timeIntervalSince1970)]
        let payload = try JSONSerialization.data(withJSONObject: claims, options: [])
        let sig = try await fixture.sender.sign(data: payload, peerId: peer, algorithm: "ML-DSA-65")
        _ = try await authenticateLocalSigningKeyForTesting(
            signer: fixture.sender,
            verifier: fixture.recipient,
            peerId: peer
        )
        let ok = await fixture.recipient.verify(
            data: payload,
            signature: sig,
            peerId: peer,
            algorithm: "ML-DSA-65"
        )
        XCTAssertTrue(ok)

        let badAAD = Data("SkyBridgeHPKE-AAD-Mismatch".utf8)
        do {
            _ = try await fixture.recipient.hpkeOpen(
                recipientPeerId: peer,
                ciphertext: sealed.ciphertext,
                encapsulatedKey: sealed.encapsulatedKey,
                associatedData: badAAD
            )
            XCTFail("不同AAD不应成功解封装")
        } catch {
            XCTAssertFalse((error as NSError).localizedDescription.isEmpty)
            XCTAssertFalse(isMissingAuthenticatedXWingKeyError(error))
        }
    }

    func testHpkeMismatchAADFails() async throws {
        let fixture = try await AuthenticatedHPKETestFixture.make()
        let peer = fixture.peerId
        let pt = Data("HPKE-AAD-Mismatch".utf8)
        let aad1 = Data("AAD-1".utf8)
        let aad2 = Data("AAD-2".utf8)
        let sealed = try await fixture.sender.hpkeSeal(
            recipientPeerId: peer,
            plaintext: pt,
            associatedData: aad1
        )
        let control = try await fixture.recipient.hpkeOpen(
            recipientPeerId: peer,
            ciphertext: sealed.ciphertext,
            encapsulatedKey: sealed.encapsulatedKey,
            associatedData: aad1
        )
        XCTAssertEqual(control, pt)
        do {
            _ = try await fixture.recipient.hpkeOpen(
                recipientPeerId: peer,
                ciphertext: sealed.ciphertext,
                encapsulatedKey: sealed.encapsulatedKey,
                associatedData: aad2
            )
            XCTFail("不同AAD不应成功解密")
        } catch {
            XCTAssertFalse((error as NSError).localizedDescription.isEmpty)
            XCTAssertFalse(isMissingAuthenticatedXWingKeyError(error))
        }
    }


    func testHpkeTamperedEncapsulatedKeyFails() async throws {
        let fixture = try await AuthenticatedHPKETestFixture.make()
        let peer = fixture.peerId
        let pt = Data("HPKE-Tamper-EncKey".utf8)
        let aad = Data("AAD".utf8)
        let sealed = try await fixture.sender.hpkeSeal(
            recipientPeerId: peer,
            plaintext: pt,
            associatedData: aad
        )
        XCTAssertFalse(sealed.encapsulatedKey.isEmpty)
        let control = try await fixture.recipient.hpkeOpen(
            recipientPeerId: peer,
            ciphertext: sealed.ciphertext,
            encapsulatedKey: sealed.encapsulatedKey,
            associatedData: aad
        )
        XCTAssertEqual(control, pt)
        var tamperedEncapsulatedKey = sealed.encapsulatedKey
        tamperedEncapsulatedKey[0] ^= 0xAA
        do {
            _ = try await fixture.recipient.hpkeOpen(
                recipientPeerId: peer,
                ciphertext: sealed.ciphertext,
                encapsulatedKey: tamperedEncapsulatedKey,
                associatedData: aad
            )
            XCTFail("篡改封装密钥不应成功解密")
        } catch {
            XCTAssertFalse((error as NSError).localizedDescription.isEmpty)
            XCTAssertFalse(isMissingAuthenticatedXWingKeyError(error))
        }
    }

    func testHpkeEmptyAndLongAAD() async throws {
        let fixture = try await AuthenticatedHPKETestFixture.make()
        let peer = fixture.peerId
        let pt = Data("HPKE-AAD-length".utf8)
        let emptyAAD = Data()
        let longAAD = Data(repeating: 0x42, count: 4096)
        let sealed1 = try await fixture.sender.hpkeSeal(
            recipientPeerId: peer,
            plaintext: pt,
            associatedData: emptyAAD
        )
        let opened1 = try await fixture.recipient.hpkeOpen(
            recipientPeerId: peer,
            ciphertext: sealed1.ciphertext,
            encapsulatedKey: sealed1.encapsulatedKey,
            associatedData: emptyAAD
        )
        XCTAssertEqual(opened1, pt)
        let sealed2 = try await fixture.sender.hpkeSeal(
            recipientPeerId: peer,
            plaintext: pt,
            associatedData: longAAD
        )
        let opened2 = try await fixture.recipient.hpkeOpen(
            recipientPeerId: peer,
            ciphertext: sealed2.ciphertext,
            encapsulatedKey: sealed2.encapsulatedKey,
            associatedData: longAAD
        )
        XCTAssertEqual(opened2, pt)
    }
}
