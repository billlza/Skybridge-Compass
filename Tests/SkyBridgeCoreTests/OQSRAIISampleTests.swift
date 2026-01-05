import XCTest
import OQSRAII

final class OQSRAIISampleTests: XCTestCase {
    func testMLDSA65KeypairSignVerify() throws {
 // 中文注释：准备缓冲区（根据长度接口获取）
        let pkLen = oqs_raii_mldsa65_public_key_length()
        let skLen = oqs_raii_mldsa65_secret_key_length()
        let sigMax = oqs_raii_mldsa65_signature_length()

        var pub = [UInt8](repeating: 0, count: Int(pkLen))
        var sec = [UInt8](repeating: 0, count: Int(skLen))
        var sig = [UInt8](repeating: 0, count: Int(sigMax))
        var sigLen: Int = 0

 // 中文注释：生成密钥对
        XCTAssertEqual(oqs_raii_mldsa65_keypair(&pub, pkLen, &sec, skLen), OQSRAII_SUCCESS)

 // 中文注释：消息内容
        let msg = Array("你好，SkyBridge".utf8)

 // 中文注释：签名
        XCTAssertEqual(oqs_raii_mldsa65_sign(msg, msg.count, sec, skLen, &sig, &sigLen), OQSRAII_SUCCESS)

 // 中文注释：验签
        let ok = oqs_raii_mldsa65_verify(msg, msg.count, sig, sigLen, pub, pkLen)
        XCTAssertTrue(ok)
    }

    func testMLKEM768EncapsDecaps() throws {
 // 中文注释：准备缓冲区（根据长度接口获取）
        let pkLen = oqs_raii_mlkem768_public_key_length()
        let skLen = oqs_raii_mlkem768_secret_key_length()
        let ctLen = oqs_raii_mlkem768_ciphertext_length()
        let ssLen = oqs_raii_mlkem768_shared_secret_length()

        var pub = [UInt8](repeating: 0, count: Int(pkLen))
        var sec = [UInt8](repeating: 0, count: Int(skLen))
        var ct  = [UInt8](repeating: 0, count: Int(ctLen))
        var ss1 = [UInt8](repeating: 0, count: Int(ssLen))
        var ss2 = [UInt8](repeating: 0, count: Int(ssLen))

 // 中文注释：生成密钥对
        XCTAssertEqual(oqs_raii_mlkem768_keypair(&pub, pkLen, &sec, skLen), OQSRAII_SUCCESS)

 // 中文注释：封装（使用公钥生成密文与共享密钥）
        XCTAssertEqual(oqs_raii_mlkem768_encaps(pub, pkLen, &ct, ctLen, &ss1, ssLen), OQSRAII_SUCCESS)

 // 中文注释：解封装（使用私钥从密文恢复共享密钥）
        XCTAssertEqual(oqs_raii_mlkem768_decaps(ct, ctLen, sec, skLen, &ss2, ssLen), OQSRAII_SUCCESS)

 // 中文注释：共享密钥一致性校验
        XCTAssertEqual(ss1, ss2)
    }
}