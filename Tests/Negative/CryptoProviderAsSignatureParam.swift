// Tests/Negative/CryptoProviderAsSignatureParam.swift
// 此文件必须编译失败：CryptoProvider 不能传给签名参数
//
// Requirements: 3.4, 3.5
//
// 预期错误：类型不匹配，CryptoProvider 不能赋值给 ProtocolSignatureProvider

import Foundation

// 模拟类型定义
protocol CryptoProvider {
    func encapsulate() async throws
}

protocol ProtocolSignatureProvider {
    var signatureAlgorithm: ProtocolSigningAlgorithm { get }
}

enum ProtocolSigningAlgorithm {
    case ed25519
    case mlDSA65
}

struct ClassicCryptoProvider: CryptoProvider {
    func encapsulate() async throws {}
}

struct HandshakeDriver {
    init(protocolSignatureProvider: any ProtocolSignatureProvider) {}
}

func testCryptoProviderCannotBeSignatureProvider() {
    let cryptoProvider = ClassicCryptoProvider()
 // 这行应该编译失败：CryptoProvider 不能传给 ProtocolSignatureProvider 参数
    let _ = HandshakeDriver(protocolSignatureProvider: cryptoProvider)
}
