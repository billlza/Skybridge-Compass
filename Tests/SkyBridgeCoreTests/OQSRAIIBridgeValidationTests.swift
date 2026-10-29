import XCTest

#if canImport(OQSRAII)
import OQSRAII
#endif

final class OQSRAIIBridgeValidationTests: XCTestCase {
    func testMLDSAKeypairRejectsUndersizedBuffers() throws {
        #if canImport(OQSRAII)
        let pkLen = oqs_raii_mldsa65_public_key_length()
        let skLen = oqs_raii_mldsa65_secret_key_length()
        XCTAssertGreaterThan(pkLen, 1)
        XCTAssertGreaterThan(skLen, 0)

        var pk = [UInt8](repeating: 0, count: Int(pkLen - 1))
        var sk = [UInt8](repeating: 0, count: Int(skLen))
        let rc = oqs_raii_mldsa65_keypair(&pk, pkLen - 1, &sk, skLen)
        XCTAssertEqual(rc, OQSRAII_FAIL)
        #else
        throw XCTSkip("OQSRAII not available")
        #endif
    }

    func testMLDSASignRejectsInsufficientSignatureCapacity() throws {
        #if canImport(OQSRAII)
        let pkLen = oqs_raii_mldsa65_public_key_length()
        let skLen = oqs_raii_mldsa65_secret_key_length()
        let sigMaxLen = oqs_raii_mldsa65_signature_length()
        XCTAssertGreaterThan(sigMaxLen, 0)

        var pk = [UInt8](repeating: 0, count: Int(pkLen))
        var sk = [UInt8](repeating: 0, count: Int(skLen))
        XCTAssertEqual(oqs_raii_mldsa65_keypair(&pk, pkLen, &sk, skLen), OQSRAII_SUCCESS)

        var msg = [UInt8](repeating: 0x42, count: 64)
        var sig = [UInt8](repeating: 0, count: Int(sigMaxLen))
        var requestedLen = sigMaxLen - 1

        let rc = oqs_raii_mldsa65_sign(
            &msg, msg.count,
            &sk, skLen,
            &sig, &requestedLen
        )

        XCTAssertEqual(rc, OQSRAII_FAIL)
        XCTAssertEqual(requestedLen, 0)
        #else
        throw XCTSkip("OQSRAII not available")
        #endif
    }

    func testMLKEMKeypairRejectsUndersizedBuffers() throws {
        #if canImport(OQSRAII)
        let pkLen = oqs_raii_mlkem768_public_key_length()
        let skLen = oqs_raii_mlkem768_secret_key_length()
        XCTAssertGreaterThan(pkLen, 1)
        XCTAssertGreaterThan(skLen, 0)

        var pk = [UInt8](repeating: 0, count: Int(pkLen - 1))
        var sk = [UInt8](repeating: 0, count: Int(skLen))
        let rc = oqs_raii_mlkem768_keypair(&pk, pkLen - 1, &sk, skLen)
        XCTAssertEqual(rc, OQSRAII_FAIL)
        #else
        throw XCTSkip("OQSRAII not available")
        #endif
    }

    func testMLKEMEncapsRejectsUndersizedOutputBuffers() throws {
        #if canImport(OQSRAII)
        let pkLen = oqs_raii_mlkem768_public_key_length()
        let skLen = oqs_raii_mlkem768_secret_key_length()
        let ctLen = oqs_raii_mlkem768_ciphertext_length()
        let ssLen = oqs_raii_mlkem768_shared_secret_length()
        XCTAssertGreaterThan(ctLen, 1)
        XCTAssertGreaterThan(ssLen, 0)

        var pk = [UInt8](repeating: 0, count: Int(pkLen))
        var sk = [UInt8](repeating: 0, count: Int(skLen))
        XCTAssertEqual(oqs_raii_mlkem768_keypair(&pk, pkLen, &sk, skLen), OQSRAII_SUCCESS)

        var ct = [UInt8](repeating: 0, count: Int(ctLen - 1))
        var ss = [UInt8](repeating: 0, count: Int(ssLen))
        let rc = oqs_raii_mlkem768_encaps(&pk, pkLen, &ct, ctLen - 1, &ss, ssLen)
        XCTAssertEqual(rc, OQSRAII_FAIL)
        #else
        throw XCTSkip("OQSRAII not available")
        #endif
    }
}
