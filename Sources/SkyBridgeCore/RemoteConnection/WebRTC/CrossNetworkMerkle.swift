import Foundation
import CryptoKit

enum CrossNetworkMerkle {
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
                next.append(sha256(left + right))
                i += 2
            }
            level = next
        }
        return level.first
    }

    static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }
}


