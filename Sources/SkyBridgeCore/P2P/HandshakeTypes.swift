//
// HandshakeTypes.swift
// SkyBridgeCore
//
// Runtime-bound handshake types that intentionally remain in SkyBridgeCore.
// Pure handshake models live in SkyBridgeProtocolCore.
//

import Foundation
import SkyBridgeProtocolCore
#if canImport(Security)
import Security
#endif

// MARK: - SigningCallback Protocol

/// 签名回调协议
///
/// 用于支持 Secure Enclave 或其他硬件安全模块中的密钥签名。
/// 实现此协议可以让 HandshakeDriver 使用硬件保护的密钥进行签名，
/// 而无需将私钥暴露到内存中。
public protocol SigningCallback: Sendable {
    func sign(data: Data) async throws -> Data
}

// MARK: - SigningKeyHandle

/// Signing key handle for secure storage (Keychain/Secure Enclave) or raw key data.
public enum SigningKeyHandle: @unchecked Sendable {
    case softwareKey(Data)
    #if canImport(Security)
    case secureEnclaveRef(SecKey)
    #endif
    case callback(any SigningCallback)
}

/// 握手身份密钥（协议签名 + 可选 Secure Enclave PoP）
public struct HandshakeIdentityKeys: Sendable {
    public let classicPublicKey: Data?
    public let classicKeyHandle: SigningKeyHandle?
    public let pqcPublicKey: Data?
    public let pqcKeyHandle: SigningKeyHandle?
    public let secureEnclavePublicKey: Data?

    public init(
        classicPublicKey: Data? = nil,
        classicKeyHandle: SigningKeyHandle? = nil,
        pqcPublicKey: Data? = nil,
        pqcKeyHandle: SigningKeyHandle? = nil,
        secureEnclavePublicKey: Data? = nil
    ) {
        self.classicPublicKey = classicPublicKey
        self.classicKeyHandle = classicKeyHandle
        self.pqcPublicKey = pqcPublicKey
        self.pqcKeyHandle = pqcKeyHandle
        self.secureEnclavePublicKey = secureEnclavePublicKey
    }
}
