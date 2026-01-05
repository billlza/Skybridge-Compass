// Tests/Negative/P256AsProtocolSignatureProvider.swift
// 此文件必须编译失败：P256SePoPProvider 不能当 any ProtocolSignatureProvider
//
// Requirements: 1.1, 1.2, 3.4, 3.5
//
// 预期错误：类型不匹配，P256SePoPProvider 不 conform ProtocolSignatureProvider

import Foundation

// 模拟类型定义（实际类型在 SkyBridgeCore 中）
protocol ProtocolSignatureProvider {
    var signatureAlgorithm: ProtocolSigningAlgorithm { get }
}

enum ProtocolSigningAlgorithm {
    case ed25519
    case mlDSA65
}

// P256SePoPProvider 不 conform ProtocolSignatureProvider
struct P256SePoPProvider {
 // 只有 SePoPSignatureProvider 的方法，没有 signatureAlgorithm
}

func testP256CannotBeProtocolProvider() {
    let p256Provider = P256SePoPProvider()
 // 这行应该编译失败：P256SePoPProvider 不 conform ProtocolSignatureProvider
    let _: any ProtocolSignatureProvider = p256Provider
}
