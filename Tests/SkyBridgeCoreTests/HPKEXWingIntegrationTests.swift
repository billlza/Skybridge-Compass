import XCTest
#if canImport(CryptoKit)
import CryptoKit

final class HPKEXWingIntegrationTests: XCTestCase {
    func testXWingSealOpen() throws {
        if #available(macOS 26.0, *) {
            let info = Data("SkyBridgeHPKE".utf8)
            let suite = HPKE.Ciphersuite.XWingMLKEM768X25519_SHA256_AES_GCM_256
            let recipientPriv = try XWingMLKEM768X25519.PrivateKey.generate()
            let recipientPub = recipientPriv.publicKey
            var sender = try HPKE.Sender(recipientKey: recipientPub, ciphersuite: suite, info: info)
            let plaintext = Data("hello-pqc".utf8)
            let aad = Data("meta".utf8)
            let ciphertext = try sender.seal(plaintext, authenticating: aad)
            let encapsulated = sender.encapsulatedKey
            var recipient = try HPKE.Recipient(privateKey: recipientPriv, ciphersuite: suite, info: info, encapsulatedKey: encapsulated)
            let opened = try recipient.open(ciphertext, authenticating: aad)
            XCTAssertEqual(opened, plaintext)
        } else {
            throw XCTSkip("HPKE available on macOS 26.0+")
        }
    }
}
#else
final class HPKEXWingIntegrationTests: XCTestCase {
    func testSkip() throws { throw XCTSkip("CryptoKit unavailable") }
}
#endif
