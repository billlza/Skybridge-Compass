import Foundation
import CryptoKit

enum CrossNetworkMerkleAuth {
    static let signatureAlgV1 = "hmac-sha256-session-v1"

    // Must match Android MerkleRootAuthV1.preimage
    static func preimage(transferId: String, merkleRoot: Data, fileSha256: Data?) -> Data {
        var out = Data()
        out.append("SkyBridge-MerkleRoot|v1|".data(using: .utf8)!)

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


