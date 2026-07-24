import Foundation

/// Self-describing sealed-box wire format used by the handshake/control plane.
///
/// This is protocol data, not an Apple-only runtime concern, so the parser and
/// serializer live in `SkyBridgeProtocolCore`.
public struct HPKESealedBox: Sendable {
    public let encapsulatedKey: Data
    public let nonce: Data
    public let ciphertext: Data
    public let tag: Data

    private static let magic: [UInt8] = [0x48, 0x50, 0x4B, 0x45]
    private static let headerSize = 17
    private static let maxEncLen = 4096
    private static let expectedNonceLen = 12
    private static let expectedTagLen = 16
    private static let maxCtLenHandshake = 64 * 1024
    private static let maxCtLenPostAuth = 256 * 1024

    public init(encapsulatedKey: Data, nonce: Data, ciphertext: Data, tag: Data) {
        self.encapsulatedKey = encapsulatedKey
        self.nonce = nonce
        self.ciphertext = ciphertext
        self.tag = tag
    }

    public init(combined: Data, isHandshake: Bool = true) throws {
        // The sealed box is bounded (64 KiB during handshake, 256 KiB after
        // authentication). Normalize a possible Data slice once so the wire
        // offsets below are valid collection indices.
        let combined = Data(combined)
        guard combined.count >= Self.headerSize else {
            throw CryptoProviderError.invalidSealedBox("Data too short for header")
        }
        guard combined.prefix(4).elementsEqual(Self.magic) else {
            throw CryptoProviderError.invalidMagic
        }

        let version = combined[4]
        guard version == 1 || version == 2 else {
            throw CryptoProviderError.unsupportedVersion(version)
        }

        let encLen = Int(combined[9]) | (Int(combined[10]) << 8)
        let nonceLen = Int(combined[11])
        let tagLen = Int(combined[12])
        let ctLen = Int(combined[13]) | (Int(combined[14]) << 8)
            | (Int(combined[15]) << 16) | (Int(combined[16]) << 24)

        guard encLen <= Self.maxEncLen else {
            throw CryptoProviderError.lengthExceeded("encLen", encLen, Self.maxEncLen)
        }
        if version == 1 {
            guard nonceLen == Self.expectedNonceLen else {
                throw CryptoProviderError.invalidNonceLength(nonceLen)
            }
            guard tagLen == Self.expectedTagLen else {
                throw CryptoProviderError.invalidTagLength(tagLen)
            }
        } else {
            // v2 is the native-HPKE form: nonce/tag are carried inside its
            // ciphertext and therefore both outer fields must be absent.
            // A v2 header with v1 lengths is an encoding alias and must not be
            // accepted then normalized to v1 in a signed transcript.
            guard nonceLen == 0 else {
                throw CryptoProviderError.invalidNonceLength(nonceLen)
            }
            guard tagLen == 0 else {
                throw CryptoProviderError.invalidTagLength(tagLen)
            }
        }

        let maxCtLen = isHandshake ? Self.maxCtLenHandshake : Self.maxCtLenPostAuth
        guard ctLen <= maxCtLen else {
            throw CryptoProviderError.lengthExceeded("ctLen", ctLen, maxCtLen)
        }

        var expectedTotal = Self.headerSize
        let (sum1, overflow1) = expectedTotal.addingReportingOverflow(encLen)
        let (sum2, overflow2) = sum1.addingReportingOverflow(nonceLen)
        let (sum3, overflow3) = sum2.addingReportingOverflow(ctLen)
        let (sum4, overflow4) = sum3.addingReportingOverflow(tagLen)

        guard !overflow1 && !overflow2 && !overflow3 && !overflow4 else {
            throw CryptoProviderError.lengthOverflow
        }
        expectedTotal = sum4

        guard combined.count == expectedTotal else {
            throw CryptoProviderError.lengthMismatch(expected: expectedTotal, actual: combined.count)
        }

        var offset = Self.headerSize
        self.encapsulatedKey = Data(combined[offset..<(offset + encLen)])
        offset += encLen
        self.nonce = Data(combined[offset..<(offset + nonceLen)])
        offset += nonceLen
        self.ciphertext = Data(combined[offset..<(offset + ctLen)])
        offset += ctLen
        self.tag = Data(combined[offset..<(offset + tagLen)])
    }

    public var combined: Data {
        var out = Data()
        out.append(encapsulatedKey)
        out.append(nonce)
        out.append(ciphertext)
        out.append(tag)
        return out
    }

    public func combinedWithHeader(suite: CryptoSuite) -> Data {
        var out = Data()
        out.append(contentsOf: Self.magic)
        let version: UInt8 = (nonce.count == Self.expectedNonceLen && tag.count == Self.expectedTagLen) ? 1 : 2
        out.append(version)
        out.append(UInt8(suite.wireId & 0xFF))
        out.append(UInt8(suite.wireId >> 8))
        out.append(contentsOf: [0, 0])
        out.append(UInt8(encapsulatedKey.count & 0xFF))
        out.append(UInt8(encapsulatedKey.count >> 8))
        out.append(UInt8(nonce.count & 0xFF))
        out.append(UInt8(tag.count & 0xFF))
        out.append(UInt8(ciphertext.count & 0xFF))
        out.append(UInt8((ciphertext.count >> 8) & 0xFF))
        out.append(UInt8((ciphertext.count >> 16) & 0xFF))
        out.append(UInt8((ciphertext.count >> 24) & 0xFF))
        out.append(encapsulatedKey)
        out.append(nonce)
        out.append(ciphertext)
        out.append(tag)
        return out
    }
}
