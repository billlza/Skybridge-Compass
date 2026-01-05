// Tests/Negative/LegacyVerifierHasNoSign.swift
// 此文件必须编译失败：LegacySignatureVerifier 没有 sign 方法
//
// Requirements: 3.3, 11.1, 11.2
//
// 预期错误：LegacySignatureVerifier 没有 sign 方法

import Foundation

// 模拟类型定义
protocol LegacySignatureVerifier {
 // 只有 verify，没有 sign
    func verify(_ data: Data, signature: Data, publicKey: Data) async throws -> Bool
}

struct P256LegacyVerifier: LegacySignatureVerifier {
    func verify(_ data: Data, signature: Data, publicKey: Data) async throws -> Bool {
        return true
    }
}

struct SigningKeyHandle {
    let privateKeyData: Data
}

func testLegacyVerifierCannotSign() async throws {
    let verifier = P256LegacyVerifier()
    let data = Data()
    let key = SigningKeyHandle(privateKeyData: Data())
 // 这行应该编译失败：LegacySignatureVerifier 没有 sign 方法
    let _ = try await verifier.sign(data, key: key)
}
