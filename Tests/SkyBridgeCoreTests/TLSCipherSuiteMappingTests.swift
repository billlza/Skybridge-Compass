import XCTest
@testable import SkyBridgeCore
import Security

/// 中文注释：TLS 套件映射测试
/// 覆盖 tls_ciphersuite_t 与 SSLCipherSuite 两种类型，验证常见 TLS 1.3 名称与未知值处理。
final class TLSCipherSuiteMappingTests: XCTestCase {
 /// 中文注释：验证 tls_ciphersuite_t 到字符串的映射
    func testTLSCipherSuiteMapping_tlsType() throws {
 // 构造 TLS 1.3 常见套件的原始值
        let aes128 = unsafeBitCast(UInt16(0x1301), to: tls_ciphersuite_t.self)
        let aes256 = unsafeBitCast(UInt16(0x1302), to: tls_ciphersuite_t.self)
        let chacha = unsafeBitCast(UInt16(0x1303), to: tls_ciphersuite_t.self)
        let unknown = unsafeBitCast(UInt16(0x1304), to: tls_ciphersuite_t.self)

 // 断言映射结果
        XCTAssertEqual(DeviceDiscoveryManagerOptimized.TLSHandshakeDetails.string(from: aes128), "TLS_AES_128_GCM_SHA256")
        XCTAssertEqual(DeviceDiscoveryManagerOptimized.TLSHandshakeDetails.string(from: aes256), "TLS_AES_256_GCM_SHA384")
        XCTAssertEqual(DeviceDiscoveryManagerOptimized.TLSHandshakeDetails.string(from: chacha), "TLS_CHACHA20_POLY1305_SHA256")
        XCTAssertTrue(DeviceDiscoveryManagerOptimized.TLSHandshakeDetails.string(from: unknown).contains("未知套件(0x1304)"))
    }

 /// 中文注释：验证 SSLCipherSuite 到字符串的映射（兼容旧常量类型）
    func testTLSCipherSuiteMapping_sslType() throws {
        let aes128: SSLCipherSuite = 0x1301
        let aes256: SSLCipherSuite = 0x1302
        let chacha: SSLCipherSuite = 0x1303
        let unknown: SSLCipherSuite = 0x1304

        XCTAssertEqual(DeviceDiscoveryManagerOptimized.TLSHandshakeDetails.string(from: aes128), "TLS_AES_128_GCM_SHA256")
        XCTAssertEqual(DeviceDiscoveryManagerOptimized.TLSHandshakeDetails.string(from: aes256), "TLS_AES_256_GCM_SHA384")
        XCTAssertEqual(DeviceDiscoveryManagerOptimized.TLSHandshakeDetails.string(from: chacha), "TLS_CHACHA20_POLY1305_SHA256")
        XCTAssertTrue(DeviceDiscoveryManagerOptimized.TLSHandshakeDetails.string(from: unknown).contains("未知套件(0x1304)"))
    }

 /// 中文注释：验证协议版本映射（TLS 1.3、TLS 1.2、DTLS 1.2 与未知）
    func testTLSProtocolVersionMapping() throws {
        XCTAssertEqual(DeviceDiscoveryManagerOptimized.TLSHandshakeDetails.string(from: .TLSv13), "TLS 1.3")
        XCTAssertEqual(DeviceDiscoveryManagerOptimized.TLSHandshakeDetails.string(from: .TLSv12), "TLS 1.2")
        XCTAssertEqual(DeviceDiscoveryManagerOptimized.TLSHandshakeDetails.string(from: .DTLSv12), "DTLS 1.2")
 // 构造未知版本（使用未定义枚举值）
        let unknownVersion = unsafeBitCast(UInt16(0xFFFF), to: tls_protocol_version_t.self)
        XCTAssertEqual(DeviceDiscoveryManagerOptimized.TLSHandshakeDetails.string(from: unknownVersion), "未知版本")
    }

 /// 中文注释：验证降级兼容路径（TLS 1.2 + 未映射套件应返回可读未知描述）
    func testTLSDowngradeCompatibility() throws {
 // 常见 TLS 1.2 套件（例如 0xC02F 对应 ECDHE_RSA_WITH_AES_128_GCM_SHA256），当前实现未映射应标记未知
        let tls12Cipher = unsafeBitCast(UInt16(0xC02F), to: tls_ciphersuite_t.self)
        let versionString = DeviceDiscoveryManagerOptimized.TLSHandshakeDetails.string(from: .TLSv12)
        let cipherString = DeviceDiscoveryManagerOptimized.TLSHandshakeDetails.string(from: tls12Cipher)
        XCTAssertEqual(versionString, "TLS 1.2")
        XCTAssertTrue(cipherString.contains("未知套件(0xC02F)"))

 // 兼容旧常量类型 SSLCipherSuite 的未知值
        let sslCipher: SSLCipherSuite = 0xC030
        let sslCipherString = DeviceDiscoveryManagerOptimized.TLSHandshakeDetails.string(from: sslCipher)
        XCTAssertTrue(sslCipherString.contains("未知套件(0xC030)"))
    }
}