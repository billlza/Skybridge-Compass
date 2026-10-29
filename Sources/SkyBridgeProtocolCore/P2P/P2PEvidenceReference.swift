import CryptoKit
import Foundation

/// A non-secret, privacy-preserving correlation reference for P2P evidence.
///
/// These references do not authenticate protocol messages. Authentication is
/// still provided by the protocol signatures and transcript validation. The
/// references only let private smoke evidence prove that two events belong to
/// the same already-authenticated operation without logging raw UUIDs or full
/// canonical hashes.
public enum P2PEvidenceReference {
    private static let domainSeparator = "SkyBridge-P2P-Evidence-Reference-V1"

    public static func transaction(_ transactionID: UUID) -> String {
        make(kind: "transaction", canonicalValue: transactionID.uuidString.lowercased())
    }

    public static func recovery(_ recoveryID: UUID) -> String {
        make(kind: "recovery", canonicalValue: recoveryID.uuidString.lowercased())
    }

    public static func session(_ sessionID: String) -> String? {
        let canonical = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !canonical.isEmpty, canonical.utf8.count <= 1_024 else { return nil }
        return make(kind: "session", canonicalValue: canonical)
    }

    /// Correlates one exact authenticated handshake incarnation. A session ID
    /// alone is insufficient evidence when a caller can explicitly reuse an
    /// identifier across reconnects, so the authenticated transcript is part
    /// of the evidence reference as well.
    public static func sessionIncarnation(
        sessionID: String,
        transcriptHash: Data
    ) -> String? {
        let canonicalSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !canonicalSessionID.isEmpty,
              canonicalSessionID.utf8.count <= 1_024,
              transcriptHash.count == 32 else {
            return nil
        }
        let transcriptHex = transcriptHash.map { String(format: "%02x", $0) }.joined()
        return make(
            kind: "session-incarnation",
            canonicalValue: "\(canonicalSessionID)\n\(transcriptHex)"
        )
    }

    public static func requestHash(_ requestHashHex: String) -> String? {
        guard let canonical = canonicalSHA256Hex(requestHashHex) else { return nil }
        return make(kind: "request-hash", canonicalValue: canonical)
    }

    public static func payloadHash(_ payloadHashHex: String) -> String? {
        guard let canonical = canonicalSHA256Hex(payloadHashHex) else { return nil }
        return make(kind: "payload-hash", canonicalValue: canonical)
    }

    public static func isValid(_ reference: String) -> Bool {
        let canonical = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canonical.utf8.count == 36, canonical.hasPrefix("ev1:") else {
            return false
        }
        return canonical.dropFirst(4).unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 48 && scalar.value <= 57)
                || (scalar.value >= 97 && scalar.value <= 102)
        }
    }

    private static func make(kind: String, canonicalValue: String) -> String {
        let material = "\(domainSeparator)\n\(kind)\n\(canonicalValue)"
        let digest = SHA256.hash(data: Data(material.utf8))
        return "ev1:" + digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private static func canonicalSHA256Hex(_ value: String) -> String? {
        let canonical = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard canonical.utf8.count == 64,
              canonical.unicodeScalars.allSatisfy({ scalar in
                  (scalar.value >= 48 && scalar.value <= 57)
                      || (scalar.value >= 97 && scalar.value <= 102)
              }) else {
            return nil
        }
        return canonical
    }
}
