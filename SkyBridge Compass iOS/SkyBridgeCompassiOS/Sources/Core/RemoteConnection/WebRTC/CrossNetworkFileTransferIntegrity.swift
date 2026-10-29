import Foundation
import CryptoKit

/// Minimal SHA-256 helper used by WebRTC chunking and integrity checks.
@available(iOS 17.0, *)
enum CrossNetworkCryptoCompat {
    static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }
}

/// Deterministic SHA-256 Merkle tree helper for chunk root computation.
@available(iOS 17.0, *)
enum CrossNetworkMerkleCompat {
    /// Deterministic SHA-256 Merkle root:
    /// - Leaves are per-chunk SHA-256 digests (32B), ordered by chunkIndex.
    /// - Parent = SHA256(left || right)
    /// - Odd count: duplicate last.
    static func root(leaves: [Data]) -> Data? {
        guard !leaves.isEmpty else { return nil }
        guard leaves.allSatisfy({ $0.count == 32 }) else { return nil }

        var level = leaves
        while level.count > 1 {
            var next: [Data] = []
            next.reserveCapacity((level.count + 1) / 2)
            var i = 0
            while i < level.count {
                let left = level[i]
                let right = (i + 1 < level.count) ? level[i + 1] : left
                next.append(CrossNetworkCryptoCompat.sha256(left + right))
                i += 2
            }
            level = next
        }
        return level.first
    }
}

/// Auth helper for Merkle root verification (HMAC over deterministic preimage).
@available(iOS 17.0, *)
enum CrossNetworkMerkleAuthCompat {
    static let signatureAlgV1 = "hmac-sha256-session-v1"

    // Must match Android MerkleRootAuthV1.preimage.
    static func preimage(transferId: String, merkleRoot: Data, fileSha256: Data?) -> Data {
        var out = Data()
        out.append(Data("SkyBridge-MerkleRoot|v1|".utf8))

        let tid = transferId.data(using: .utf8) ?? Data()
        out.append(u16le(tid.count))
        out.append(tid)

        out.append(u16le(merkleRoot.count))
        out.append(merkleRoot)

        let f = fileSha256 ?? Data()
        out.append(u16le(f.count))
        out.append(f)
        return out
    }

    static func hmacSha256(key: Data, data: Data) -> Data {
        let k = SymmetricKey(data: key)
        let mac = HMAC<SHA256>.authenticationCode(for: data, using: k)
        return Data(mac)
    }

    private static func u16le(_ v: Int) -> Data {
        var x = UInt16(max(0, min(65535, v))).littleEndian
        return Data(bytes: &x, count: 2)
    }
}

@available(iOS 17.0, *)
enum CrossNetworkFileTransferIntegrityFailure: String, Error, Equatable {
    case chunkHashMismatch = "chunk hash mismatch"
    case missingIntegrityProof = "missing integrity proof"
    case merkleRootMismatch = "merkle root mismatch"
    case unknownMerkleSignatureAlgorithm = "unknown merkle sig alg"
    case merkleSignatureMismatch = "merkle signature mismatch"
}

@available(iOS 17.0, *)
enum CrossNetworkFileTransferIntegrityValidator {
    static func verifiedChunkHash(
        data: Data,
        expectedChunkSha256: Data?
    ) -> Result<Data, CrossNetworkFileTransferIntegrityFailure> {
        let actualHash = CrossNetworkCryptoCompat.sha256(data)
        guard let expectedChunkSha256 else {
            return .success(actualHash)
        }
        guard actualHash == expectedChunkSha256 else {
            return .failure(.chunkHashMismatch)
        }
        return .success(actualHash)
    }

    static func requiredProofFailure(
        fileSha256: Data?,
        merkleRoot: Data?,
        merkleRootSignature: Data?,
        merkleRootSignatureAlg: String?
    ) -> CrossNetworkFileTransferIntegrityFailure? {
        if fileSha256 != nil {
            return nil
        }
        guard merkleRoot != nil,
              merkleRootSignature != nil,
              merkleRootSignatureAlg == CrossNetworkMerkleAuthCompat.signatureAlgV1 else {
            return .missingIntegrityProof
        }
        return nil
    }

    static func hasRequiredProof(
        fileSha256: Data?,
        merkleRoot: Data?,
        merkleRootSignature: Data?,
        merkleRootSignatureAlg: String?
    ) -> Bool {
        requiredProofFailure(
            fileSha256: fileSha256,
            merkleRoot: merkleRoot,
            merkleRootSignature: merkleRootSignature,
            merkleRootSignatureAlg: merkleRootSignatureAlg
        ) == nil
    }

    static func validateMerkleProof(
        transferId: String,
        totalChunks: Int,
        chunkHashes: [Int: Data],
        expectedMerkleRoot: Data?,
        merkleRootSignature: Data?,
        merkleRootSignatureAlg: String?,
        expectedFileSha256: Data?,
        receiveKey: Data
    ) -> CrossNetworkFileTransferIntegrityFailure? {
        guard let expectedMerkleRoot else {
            return nil
        }

        let leaves = (0..<totalChunks).compactMap { chunkHashes[$0] }
        guard leaves.count == totalChunks,
              CrossNetworkMerkleCompat.root(leaves: leaves) == expectedMerkleRoot else {
            return .merkleRootMismatch
        }

        guard let merkleRootSignature else {
            return nil
        }
        guard merkleRootSignatureAlg == CrossNetworkMerkleAuthCompat.signatureAlgV1 else {
            return .unknownMerkleSignatureAlgorithm
        }

        let preimage = CrossNetworkMerkleAuthCompat.preimage(
            transferId: transferId,
            merkleRoot: expectedMerkleRoot,
            fileSha256: expectedFileSha256
        )
        let expectedSignature = CrossNetworkMerkleAuthCompat.hmacSha256(key: receiveKey, data: preimage)
        return merkleRootSignature == expectedSignature ? nil : .merkleSignatureMismatch
    }
}
