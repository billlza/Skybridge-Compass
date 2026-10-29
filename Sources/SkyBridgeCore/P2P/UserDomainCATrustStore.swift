//
// UserDomainCATrustStore.swift
// SkyBridgeCore
//
// Enterprise Optional Feature:
// - Store a pinned "User Domain CA" public key (P-256, DER-encoded SecKey)
// - Used to verify certificates with signerType = .userDomainSigned
//
// Security note:
// - If no CA is configured, user-domain-signed certificates MUST be rejected (safe default).
//

import Foundation
#if canImport(Security)
import Security
#endif

@available(macOS 14.0, iOS 17.0, *)
public enum UserDomainCATrustStore {
    private static let service = "com.skybridge.p2p.userDomainCA"
    private static let account = "userDomainCA.p256.der"
    
    /// Store/update the domain CA public key (P-256 public key, DER/X9.63 accepted by SecKeyCreateWithData).
    public static func setCAPublicKeyDER(_ der: Data) throws {
        #if canImport(Security)
        // Basic sanity check: can we construct a SecKey from it as P-256 public?
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic
        ]
        var error: Unmanaged<CFError>?
        guard SecKeyCreateWithData(der as CFData, attributes as CFDictionary, &error) != nil else {
            throw CertificateError.verificationFailed("Invalid domain CA public key (P-256) DER")
        }
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        
        var add = query
        add[kSecValueData as String] = der
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw CertificateError.verificationFailed("Failed to store domain CA key (status=\(status))")
        }
        #else
        throw CertificateError.verificationFailed("Security framework unavailable; cannot store domain CA key")
        #endif
    }
    
    /// Remove the configured domain CA key.
    public static func clearCAKey() {
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        #endif
    }
    
    /// Load the configured domain CA key, if any.
    public static func getCAPublicKeyDER() -> Data? {
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return (result as? Data)
        #else
        return nil
        #endif
    }
}


