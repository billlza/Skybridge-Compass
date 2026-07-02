//
// QPeriaptKEMProvider.swift
// SkyBridgeCore
//
// Q-Periapt ContextBound hybrid KEM provider (ML-KEM-768 + X25519).
//
// This is an ADDITIVE, feature-flagged provider. It conforms to the same
// `KEMProvider` protocol as the existing X25519 / ML-KEM-768 / X-Wing providers
// and is only ever instantiated when the Q-Periapt beta is enabled
// (`SettingsManager.preferQPeriaptBeta` UserDefaults key, or the
// `SB_ENABLE_QPERIAPT` environment variable). When the flag is OFF, nothing in
// the existing crypto path references this type, so behavior is unchanged.
//
// The implementation bridges to the vendored `q-periapt-ffi` static library
// (Sources/Vendor/qperiapt.xcframework) via the C wrapper target `CQPeriapt`
// (mirrors how liboqs is consumed through OQSRAII; keeps the xcframework from
// shipping a second include/module.modulemap). The whole file is guarded by
// `#if canImport(CQPeriapt)` so the package still compiles if the xcframework
// is absent.
//
// Wire/blob layout (the privateKey blob is the provider's OWN representation and
// is never placed on the wire):
//   publicKey  = pk_pq(1184) ‖ pk_trad(32)
//   privateKey = sk_pq(2400) ‖ sk_trad(32) ‖ pk_pq(1184) ‖ pk_trad(32)
//   encapsulated = ct_pq(1088) ‖ ct_trad(32)
//   sharedSecret = secret(32)
//

import Foundation
import SkyBridgeProtocolCore

#if canImport(CQPeriapt)
import CQPeriapt
#if canImport(Security)
import Security
#endif

/// Q-Periapt ContextBound 混合 KEM Provider (ML-KEM-768 + X25519)。
///
/// 仅在 q-periapt beta 开关开启时使用；与现有 provider 完全隔离、可加性新增。
@available(macOS 14.0, iOS 17.0, *)
public struct QPeriaptKEMProvider: KEMProvider, Sendable {

    // MARK: - Constants (mirror q_periapt.h)

    /// `profile = 2`: context-bound combiner.
    private static let profileContextBound: UInt8 = 2 // Q_PERIAPT_PROFILE_CONTEXT_BOUND
    private static let mlkem768SKLen = 2400           // Q_PERIAPT_MLKEM768_SK_LEN
    private static let mlkem768PKLen = 1184           // Q_PERIAPT_MLKEM768_PK_LEN
    private static let mlkem768CTLen = 1088           // Q_PERIAPT_MLKEM768_CT_LEN
    private static let x25519Len = 32                 // Q_PERIAPT_X25519_LEN
    private static let secretLen = 32                 // Q_PERIAPT_SECRET_LEN
    private static let okStatus: Int32 = 0            // Q_PERIAPT_OK

    private static let mlkemSeedLen = 64              // q_periapt_mlkem768_keypair seed length
    private static let policyVersion: UInt32 = 1

    /// suite_id 字节串（ASCII）。
    private static let suiteID: [UInt8] = Array("ML-KEM-768+X25519".utf8)
    /// context 字节串（ASCII），ContextBound profile 下绑定。
    private static let context: [UInt8] = Array("skybridge-qperiapt/v1".utf8)

    // MARK: - KEMProvider

    public var algorithmName: String { P2PCryptoAlgorithm.qperiaptContextBound.rawValue }
    public var isPQC: Bool { true }

    public init() {}

    // MARK: - Key Generation

    public func generateKeyPair() async throws -> (publicKey: Data, privateKey: Data) {
        // ML-KEM-768 keypair (deterministic from a 64-byte seed).
        var mlkemSeed = try Self.randomBytes(count: Self.mlkemSeedLen)
        defer { Self.wipe(&mlkemSeed) }

        var skPQ = [UInt8](repeating: 0, count: Self.mlkem768SKLen)
        var pkPQ = [UInt8](repeating: 0, count: Self.mlkem768PKLen)

        let pqStatus = mlkemSeed.withUnsafeBufferPointer { seedPtr in
            skPQ.withUnsafeMutableBufferPointer { skPtr in
                pkPQ.withUnsafeMutableBufferPointer { pkPtr in
                    q_periapt_mlkem768_keypair(
                        seedPtr.baseAddress, UInt(seedPtr.count),
                        skPtr.baseAddress, UInt(skPtr.count),
                        pkPtr.baseAddress, UInt(pkPtr.count)
                    )
                }
            }
        }
        guard pqStatus == Self.okStatus else {
            Self.wipe(&skPQ)
            throw CryptoProviderError.keyGenerationFailed("q_periapt_mlkem768_keypair failed (\(pqStatus))")
        }

        // X25519 keypair (deterministic from a 32-byte scalar).
        var x25519Secret = try Self.randomBytes(count: Self.x25519Len)
        defer { Self.wipe(&x25519Secret) }

        var skTrad = [UInt8](repeating: 0, count: Self.x25519Len)
        var pkTrad = [UInt8](repeating: 0, count: Self.x25519Len)

        let tradStatus = x25519Secret.withUnsafeBufferPointer { secretPtr in
            skTrad.withUnsafeMutableBufferPointer { skPtr in
                pkTrad.withUnsafeMutableBufferPointer { pkPtr in
                    q_periapt_x25519_keypair(
                        secretPtr.baseAddress, UInt(secretPtr.count),
                        skPtr.baseAddress, UInt(skPtr.count),
                        pkPtr.baseAddress, UInt(pkPtr.count)
                    )
                }
            }
        }
        guard tradStatus == Self.okStatus else {
            Self.wipe(&skPQ)
            Self.wipe(&skTrad)
            throw CryptoProviderError.keyGenerationFailed("q_periapt_x25519_keypair failed (\(tradStatus))")
        }

        // publicKey = pk_pq ‖ pk_trad
        var publicKey = Data()
        publicKey.append(contentsOf: pkPQ)
        publicKey.append(contentsOf: pkTrad)

        // privateKey = sk_pq ‖ sk_trad ‖ pk_pq ‖ pk_trad
        var privateKey = Data()
        privateKey.append(contentsOf: skPQ)
        privateKey.append(contentsOf: skTrad)
        privateKey.append(contentsOf: pkPQ)
        privateKey.append(contentsOf: pkTrad)

        Self.wipe(&skPQ)
        Self.wipe(&skTrad)

        return (publicKey, privateKey)
    }

    // MARK: - Encapsulation

    public func encapsulate(publicKey: Data) async throws -> (sharedSecret: Data, encapsulated: Data) {
        let expectedPKLen = Self.mlkem768PKLen + Self.x25519Len
        guard publicKey.count == expectedPKLen else {
            throw CryptoProviderError.invalidKeyFormat
        }

        let pkPQ = [UInt8](publicKey.prefix(Self.mlkem768PKLen))
        let pkTrad = [UInt8](publicKey.suffix(Self.x25519Len))

        var randPQ = try Self.randomBytes(count: Self.x25519Len)   // ML-KEM encaps coins (32 bytes)
        var randTrad = try Self.randomBytes(count: Self.x25519Len) // X25519 ephemeral scalar (32 bytes)
        defer {
            Self.wipe(&randPQ)
            Self.wipe(&randTrad)
        }

        var ctPQ = [UInt8](repeating: 0, count: Self.mlkem768CTLen)
        var ctTrad = [UInt8](repeating: 0, count: Self.x25519Len)
        var secret = [UInt8](repeating: 0, count: Self.secretLen)

        let status = Self.suiteID.withUnsafeBufferPointer { suitePtr in
            Self.context.withUnsafeBufferPointer { ctxPtr in
                pkPQ.withUnsafeBufferPointer { pkPQPtr in
                    pkTrad.withUnsafeBufferPointer { pkTradPtr in
                        randPQ.withUnsafeBufferPointer { randPQPtr in
                            randTrad.withUnsafeBufferPointer { randTradPtr in
                                ctPQ.withUnsafeMutableBufferPointer { ctPQPtr in
                                    ctTrad.withUnsafeMutableBufferPointer { ctTradPtr in
                                        secret.withUnsafeMutableBufferPointer { secretPtr in
                                            q_periapt_hybrid_encapsulate(
                                                Self.profileContextBound,
                                                suitePtr.baseAddress, UInt(suitePtr.count),
                                                Self.policyVersion,
                                                pkPQPtr.baseAddress, UInt(pkPQPtr.count),
                                                pkTradPtr.baseAddress, UInt(pkTradPtr.count),
                                                ctxPtr.baseAddress, UInt(ctxPtr.count),
                                                randPQPtr.baseAddress, UInt(randPQPtr.count),
                                                randTradPtr.baseAddress, UInt(randTradPtr.count),
                                                ctPQPtr.baseAddress, UInt(ctPQPtr.count),
                                                ctTradPtr.baseAddress, UInt(ctTradPtr.count),
                                                secretPtr.baseAddress, UInt(secretPtr.count)
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        guard status == Self.okStatus else {
            Self.wipe(&secret)
            throw CryptoProviderError.encapsulationFailed("q_periapt_hybrid_encapsulate failed (\(status))")
        }

        // encapsulated = ct_pq ‖ ct_trad
        var encapsulated = Data()
        encapsulated.append(contentsOf: ctPQ)
        encapsulated.append(contentsOf: ctTrad)

        let sharedSecret = Data(secret)
        Self.wipe(&secret)

        return (sharedSecret, encapsulated)
    }

    // MARK: - Decapsulation

    public func decapsulate(encapsulated: Data, privateKey: Data) async throws -> Data {
        let expectedSKLen = Self.mlkem768SKLen + Self.x25519Len + Self.mlkem768PKLen + Self.x25519Len
        guard privateKey.count == expectedSKLen else {
            throw CryptoProviderError.invalidKeyFormat
        }
        let expectedCTLen = Self.mlkem768CTLen + Self.x25519Len
        guard encapsulated.count == expectedCTLen else {
            throw CryptoProviderError.invalidKeyFormat
        }

        // Split privateKey = sk_pq ‖ sk_trad ‖ pk_pq ‖ pk_trad
        var offset = privateKey.startIndex
        let skPQ = [UInt8](privateKey[offset ..< privateKey.index(offset, offsetBy: Self.mlkem768SKLen)])
        offset = privateKey.index(offset, offsetBy: Self.mlkem768SKLen)
        let skTrad = [UInt8](privateKey[offset ..< privateKey.index(offset, offsetBy: Self.x25519Len)])
        offset = privateKey.index(offset, offsetBy: Self.x25519Len)
        let pkPQ = [UInt8](privateKey[offset ..< privateKey.index(offset, offsetBy: Self.mlkem768PKLen)])
        offset = privateKey.index(offset, offsetBy: Self.mlkem768PKLen)
        let pkTrad = [UInt8](privateKey[offset ..< privateKey.index(offset, offsetBy: Self.x25519Len)])

        // Split encapsulated = ct_pq ‖ ct_trad
        let ctPQ = [UInt8](encapsulated.prefix(Self.mlkem768CTLen))
        let ctTrad = [UInt8](encapsulated.suffix(Self.x25519Len))

        var secret = [UInt8](repeating: 0, count: Self.secretLen)

        let status = Self.suiteID.withUnsafeBufferPointer { suitePtr in
            Self.context.withUnsafeBufferPointer { ctxPtr in
                skPQ.withUnsafeBufferPointer { skPQPtr in
                    ctPQ.withUnsafeBufferPointer { ctPQPtr in
                        pkPQ.withUnsafeBufferPointer { pkPQPtr in
                            skTrad.withUnsafeBufferPointer { skTradPtr in
                                ctTrad.withUnsafeBufferPointer { ctTradPtr in
                                    pkTrad.withUnsafeBufferPointer { pkTradPtr in
                                        secret.withUnsafeMutableBufferPointer { secretPtr in
                                            q_periapt_hybrid_decapsulate(
                                                Self.profileContextBound,
                                                suitePtr.baseAddress, UInt(suitePtr.count),
                                                Self.policyVersion,
                                                skPQPtr.baseAddress, UInt(skPQPtr.count),
                                                ctPQPtr.baseAddress, UInt(ctPQPtr.count),
                                                pkPQPtr.baseAddress, UInt(pkPQPtr.count),
                                                skTradPtr.baseAddress, UInt(skTradPtr.count),
                                                ctTradPtr.baseAddress, UInt(ctTradPtr.count),
                                                pkTradPtr.baseAddress, UInt(pkTradPtr.count),
                                                ctxPtr.baseAddress, UInt(ctxPtr.count),
                                                secretPtr.baseAddress, UInt(secretPtr.count)
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        guard status == Self.okStatus else {
            Self.wipe(&secret)
            throw CryptoProviderError.decapsulationFailed("q_periapt_hybrid_decapsulate failed (\(status))")
        }

        let sharedSecret = Data(secret)
        Self.wipe(&secret)
        return sharedSecret
    }

    // MARK: - Helpers

    /// 使用系统 CSPRNG 生成随机字节。
    private static func randomBytes(count: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        #if canImport(Security)
        let status = bytes.withUnsafeMutableBufferPointer { ptr -> Int32 in
            SecRandomCopyBytes(kSecRandomDefault, ptr.count, ptr.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw CryptoProviderError.keyGenerationFailed("SecRandomCopyBytes failed (\(status))")
        }
        #else
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: UInt8.min ... UInt8.max)
        }
        #endif
        return bytes
    }

    /// 最佳努力擦除敏感缓冲区。
    private static func wipe(_ buffer: inout [UInt8]) {
        for index in buffer.indices {
            buffer[index] = 0
        }
    }
}
#endif
