import Foundation
import OQSRAII

@available(macOS 14.0, *)
public enum OQSRAIISample {
 /// 示例 - ML-DSA-65 生成密钥对、签名与验签
    public static func demoMLDSA65() -> Bool {
        let pkLen = oqs_raii_mldsa65_public_key_length()
        let skLen = oqs_raii_mldsa65_secret_key_length()
        let sigMax = oqs_raii_mldsa65_signature_length()

        var pub = [UInt8](repeating: 0, count: Int(pkLen))
        var sec = [UInt8](repeating: 0, count: Int(skLen))
        var sig = [UInt8](repeating: 0, count: Int(sigMax))
        var sigLen: Int = 0

        guard oqs_raii_mldsa65_keypair(&pub, pkLen, &sec, skLen) == OQSRAII_SUCCESS else { return false }
        let msg = Array("SkyBridge-RAII-DSA".utf8)
        guard oqs_raii_mldsa65_sign(msg, msg.count, sec, skLen, &sig, &sigLen) == OQSRAII_SUCCESS else { return false }
        return oqs_raii_mldsa65_verify(msg, msg.count, sig, sigLen, pub, pkLen)
    }

 /// 示例 - ML-KEM-768 封装与解封装（共享密钥一致性）
    public static func demoMLKEM768() -> Bool {
        let pkLen = oqs_raii_mlkem768_public_key_length()
        let skLen = oqs_raii_mlkem768_secret_key_length()
        let ctLen = oqs_raii_mlkem768_ciphertext_length()
        let ssLen = oqs_raii_mlkem768_shared_secret_length()

        var pub = [UInt8](repeating: 0, count: Int(pkLen))
        var sec = [UInt8](repeating: 0, count: Int(skLen))
        var ct  = [UInt8](repeating: 0, count: Int(ctLen))
        var ss1 = [UInt8](repeating: 0, count: Int(ssLen))
        var ss2 = [UInt8](repeating: 0, count: Int(ssLen))

        guard oqs_raii_mlkem768_keypair(&pub, pkLen, &sec, skLen) == OQSRAII_SUCCESS else { return false }
        guard oqs_raii_mlkem768_encaps(pub, pkLen, &ct, ctLen, &ss1, ssLen) == OQSRAII_SUCCESS else { return false }
        guard oqs_raii_mlkem768_decaps(ct, ctLen, sec, skLen, &ss2, ssLen) == OQSRAII_SUCCESS else { return false }
        return ss1 == ss2
    }
}