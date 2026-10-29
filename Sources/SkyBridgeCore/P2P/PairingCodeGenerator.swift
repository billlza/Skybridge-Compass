import Foundation
import CryptoKit

/// Generates the `skybridge-pair:v1` pairing code consumed by the Windows client's
/// `PairingMaterialClient` (windows/Skybridge.WinClient/Services/PairingMaterialClient.cs).
///
/// The code carries the device id, the device's public key as base64url, and the
/// 64-lowercase-hex SHA-256 fingerprint of that public key. The Windows side enforces the
/// invariant `SHA-256(base64url-decode(pubKey)) == pubKeyFP`, which holds here because
/// `DeviceIdentityKeyInfo.pubKeyFP` is the SHA-256 of `DeviceIdentityKeyInfo.publicKey`
/// (computed in `DeviceIdentityKeyManager.computePublicKeyFingerprint`).
///
/// This is the ONLY wired source of the real paired identity that the Win↔Mac WebRTC proof
/// binds, so both values MUST come from the device's own `DeviceIdentityKeyInfo` — never the
/// 16-hex uppercase discovery host-name fingerprint, and never the QR
/// `protocolPublicKeyFingerprint` (which hashes the *signing* key, a different key). Using
/// either of those would break the Windows `SHA-256(pubKey) == pubKeyFP` check.
public enum PairingCodeGenerator {
    /// The pairing-code scheme/version prefix the Windows parser expects.
    public static let scheme = "skybridge-pair:v1"

    /// Builds the pairing code from the device's identity-key material.
    public static func makePairCode(from info: DeviceIdentityKeyInfo, deviceName: String) -> String {
        makePairCode(
            deviceId: info.deviceId,
            publicKey: info.publicKey,
            pubKeyFP: info.pubKeyFP,
            deviceName: deviceName)
    }

    /// Builds the pairing code from raw fields. `pubKeyFP` MUST equal SHA-256(`publicKey`)
    /// in 64 lowercase hex, or the Windows parser rejects the code.
    public static func makePairCode(
        deviceId: String,
        publicKey: Data,
        pubKeyFP: String,
        deviceName: String
    ) -> String {
        let pubKey = base64url(publicKey)
        let name = uriEscape(deviceName)
        return "\(scheme);deviceId=\(deviceId);pubKey=\(pubKey);pubKeyFP=\(pubKeyFP);name=\(name);platform=macos"
    }

    /// URL-safe base64 with no padding (the Windows parser base64url-decodes `pubKey`).
    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Percent-encode a value so it can't collide with the `;` / `=` grammar
    /// (the Windows parser URI-unescapes values).
    static func uriEscape(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
