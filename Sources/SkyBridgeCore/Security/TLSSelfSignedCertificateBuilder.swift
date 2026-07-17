import Foundation
import Security

/// Shared, side-effect-free DER primitives for local TLS certificates and CSRs.
enum TLSCertificateDER {
    enum EncodingError: Error, Equatable {
        case invalidP256PrivateKey
        case invalidDistinguishedName
    }

    static let ecdsaWithSHA256AlgorithmIdentifier = sequence(
        objectIdentifier([1, 2, 840, 10_045, 4, 3, 2])
    )

    static func distinguishedName(
        commonName: String,
        organization: String?,
        organizationalUnit: String?
    ) throws -> Data {
        guard isValidDirectoryString(commonName, maximumUTF8Length: 512),
              organization.map({
                  isValidDirectoryString($0, maximumUTF8Length: 128)
              }) ?? true,
              organizationalUnit.map({
                  isValidDirectoryString($0, maximumUTF8Length: 128)
              }) ?? true else {
            throw EncodingError.invalidDistinguishedName
        }
        var relativeDistinguishedNames = relativeDistinguishedName(
            oid: [2, 5, 4, 3],
            value: commonName
        )
        if let organization {
            relativeDistinguishedNames.append(
                relativeDistinguishedName(
                    oid: [2, 5, 4, 10],
                    value: organization
                )
            )
        }
        if let organizationalUnit {
            relativeDistinguishedNames.append(
                relativeDistinguishedName(
                    oid: [2, 5, 4, 11],
                    value: organizationalUnit
                )
            )
        }
        return sequence(relativeDistinguishedNames)
    }

    static func subjectPublicKeyInfoP256(_ x963Representation: Data) -> Data {
        sequence(
            sequence(
                objectIdentifier([1, 2, 840, 10_045, 2, 1])
                    + objectIdentifier([1, 2, 840, 10_045, 3, 1, 7])
            )
                + bitString(x963Representation, unusedBitCount: 0)
        )
    }

    static func p256PublicKeyX963Representation(
        for privateKey: SecKey
    ) throws -> Data {
        guard let attributes = SecKeyCopyAttributes(privateKey) as? [CFString: Any],
              let keyType = attributes[kSecAttrKeyType] as? String,
              keyType == (kSecAttrKeyTypeECSECPrimeRandom as String),
              let keySize = attributes[kSecAttrKeySizeInBits] as? Int,
              keySize == 256,
              let keyClass = attributes[kSecAttrKeyClass] as? String,
              keyClass == (kSecAttrKeyClassPrivate as String),
              let publicKey = SecKeyCopyPublicKey(privateKey),
              let x963 = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?,
              x963.count == 65,
              x963.first == 0x04
        else {
            throw EncodingError.invalidP256PrivateKey
        }
        return x963
    }

    static func sequence(_ content: Data) -> Data {
        tagged(0x30, content)
    }

    static func set(_ content: Data) -> Data {
        tagged(0x31, content)
    }

    static func integer(_ content: Data) -> Data {
        tagged(0x02, content)
    }

    static func boolean(_ value: Bool) -> Data {
        tagged(0x01, Data([value ? 0xFF : 0x00]))
    }

    static func bitString(_ bytes: Data, unusedBitCount: UInt8) -> Data {
        precondition(unusedBitCount <= 7)
        var content = Data([unusedBitCount])
        content.append(bytes)
        return tagged(0x03, content)
    }

    static func octetString(_ bytes: Data) -> Data {
        tagged(0x04, bytes)
    }

    static func utf8String(_ value: String) -> Data {
        tagged(0x0C, Data(value.utf8))
    }

    static func generalizedTime(_ date: Date) -> Data {
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents(in: .gmt, from: date)
        let encoded = String(
            format: "%04d%02d%02d%02d%02d%02dZ",
            components.year ?? 1970,
            components.month ?? 1,
            components.day ?? 1,
            components.hour ?? 0,
            components.minute ?? 0,
            components.second ?? 0
        )
        return tagged(0x18, Data(encoded.utf8))
    }

    static func explicit(tagNumber: UInt8, content: Data) -> Data {
        contextSpecificConstructed(tagNumber: tagNumber, content: content)
    }

    static func contextSpecificConstructed(
        tagNumber: UInt8,
        content: Data
    ) -> Data {
        precondition(tagNumber <= 30)
        return tagged(0xA0 | tagNumber, content)
    }

    static func objectIdentifier(_ arcs: [Int]) -> Data {
        precondition(arcs.count >= 2)
        precondition((0...2).contains(arcs[0]))
        precondition(arcs[0] == 2 || (0...39).contains(arcs[1]))
        precondition(arcs.allSatisfy { $0 >= 0 })

        var content = Data(base128(arcs[0] * 40 + arcs[1]))
        for arc in arcs.dropFirst(2) {
            content.append(contentsOf: base128(arc))
        }
        return tagged(0x06, content)
    }

    private static func relativeDistinguishedName(
        oid: [Int],
        value: String
    ) -> Data {
        set(sequence(objectIdentifier(oid) + utf8String(value)))
    }

    private static func isValidDirectoryString(
        _ value: String,
        maximumUTF8Length: Int
    ) -> Bool {
        value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && !value.isEmpty
            && value.utf8.count <= maximumUTF8Length
            && value.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0)
            }
    }

    private static func base128(_ value: Int) -> [UInt8] {
        var remaining = value
        var bytes = [UInt8(remaining & 0x7F)]
        remaining >>= 7
        while remaining > 0 {
            bytes.insert(UInt8(remaining & 0x7F) | 0x80, at: 0)
            remaining >>= 7
        }
        return bytes
    }

    private static func tagged(_ tag: UInt8, _ content: Data) -> Data {
        var encoded = Data([tag])
        encoded.append(length(content.count))
        encoded.append(content)
        return encoded
    }

    private static func length(_ count: Int) -> Data {
        precondition(count >= 0)
        if count < 0x80 {
            return Data([UInt8(count)])
        }

        var value = count
        var bytes = [UInt8]()
        while value > 0 {
            bytes.insert(UInt8(value & 0xFF), at: 0)
            value >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }
}

/// Builds the DER bytes for the local TLS leaf certificate without touching Keychain.
///
/// Persistence is deliberately owned by `CertificateManager`; keeping DER construction
/// pure lets callers validate the certificate before beginning a Keychain transaction.
enum TLSSelfSignedCertificateBuilder {
    struct Subject: Equatable, Sendable {
        let commonName: String
        let organization: String
        let organizationalUnit: String
    }

    enum BuildError: Error, Equatable {
        case invalidPrivateKey
        case invalidSubject
        case invalidSerialNumber
        case serialNumberTooLong
        case invalidValidityRange
        case signingFailed
    }

    private static let basicConstraintsOID = [2, 5, 29, 19]
    private static let keyUsageOID = [2, 5, 29, 15]
    private static let extendedKeyUsageOID = [2, 5, 29, 37]
    private static let serverAuthOID = [1, 3, 6, 1, 5, 5, 7, 3, 1]
    private static let clientAuthOID = [1, 3, 6, 1, 5, 5, 7, 3, 2]

    /// Returns a non-zero 128-bit serial-number magnitude suitable for `buildCertificateDER`.
    static func randomSerialNumber() throws -> Data {
        var bytes = Data(count: 16)
        let status = bytes.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return errSecParam
            }
            return SecRandomCopyBytes(kSecRandomDefault, buffer.count, baseAddress)
        }
        guard status == errSecSuccess else {
            throw BuildError.invalidSerialNumber
        }
        if bytes.allSatisfy({ $0 == 0 }) {
            bytes[bytes.index(before: bytes.endIndex)] = 1
        }
        return bytes
    }

    /// Creates a self-signed v3 leaf certificate using ECDSA P-256 with SHA-256.
    ///
    /// `serialNumber` is an unsigned magnitude. The builder canonicalizes it to a
    /// positive, minimally encoded DER INTEGER and enforces RFC 5280's 20-octet limit.
    static func buildCertificateDER(
        privateKey: SecKey,
        subject: Subject,
        serialNumber: Data,
        notBefore: Date,
        notAfter: Date
    ) throws -> Data {
        guard notBefore < notAfter else {
            throw BuildError.invalidValidityRange
        }
        let x963: Data
        do {
            x963 = try TLSCertificateDER.p256PublicKeyX963Representation(
                for: privateKey
            )
        } catch {
            throw BuildError.invalidPrivateKey
        }

        let serialInteger = try positiveInteger(serialNumber)
        let signatureAlgorithm = TLSCertificateDER.ecdsaWithSHA256AlgorithmIdentifier
        let name: Data
        do {
            name = try TLSCertificateDER.distinguishedName(
                commonName: subject.commonName,
                organization: subject.organization,
                organizationalUnit: subject.organizationalUnit
            )
        } catch {
            throw BuildError.invalidSubject
        }
        let validity = TLSCertificateDER.sequence(
            TLSCertificateDER.generalizedTime(notBefore)
                + TLSCertificateDER.generalizedTime(notAfter)
        )
        let subjectPublicKeyInfo = TLSCertificateDER.subjectPublicKeyInfoP256(x963)
        let extensions = TLSCertificateDER.explicit(
            tagNumber: 3,
            content: certificateExtensions()
        )
        let tbsCertificate = TLSCertificateDER.sequence(
            TLSCertificateDER.explicit(
                tagNumber: 0,
                content: TLSCertificateDER.integer(Data([0x02]))
            )
                + serialInteger
                + signatureAlgorithm
                + name
                + validity
                + name
                + subjectPublicKeyInfo
                + extensions
        )

        var signingError: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .ecdsaSignatureMessageX962SHA256,
            tbsCertificate as CFData,
            &signingError
        ) as Data? else {
            throw BuildError.signingFailed
        }

        return TLSCertificateDER.sequence(
            tbsCertificate
                + signatureAlgorithm
                + TLSCertificateDER.bitString(signature, unusedBitCount: 0)
        )
    }

    private static func positiveInteger(_ unsignedMagnitude: Data) throws -> Data {
        let magnitude = unsignedMagnitude.drop(while: { $0 == 0 })
        guard !magnitude.isEmpty else {
            throw BuildError.invalidSerialNumber
        }

        var content = Data(magnitude)
        if let first = content.first, first & 0x80 != 0 {
            content.insert(0, at: content.startIndex)
        }
        guard content.count <= 20 else {
            throw BuildError.serialNumberTooLong
        }
        return TLSCertificateDER.integer(content)
    }

    private static func certificateExtensions() -> Data {
        // BasicConstraints with the default cA=FALSE is encoded as an empty sequence.
        let basicConstraints = certificateExtension(
            oid: basicConstraintsOID,
            critical: true,
            value: TLSCertificateDER.sequence(Data())
        )
        // digitalSignature is bit zero of the NamedBitList, so seven trailing bits are unused.
        let keyUsage = certificateExtension(
            oid: keyUsageOID,
            critical: true,
            value: TLSCertificateDER.bitString(
                Data([0x80]),
                unusedBitCount: 7
            )
        )
        let extendedKeyUsage = certificateExtension(
            oid: extendedKeyUsageOID,
            critical: false,
            value: TLSCertificateDER.sequence(
                TLSCertificateDER.objectIdentifier(serverAuthOID)
                    + TLSCertificateDER.objectIdentifier(clientAuthOID)
            )
        )
        return TLSCertificateDER.sequence(
            basicConstraints + keyUsage + extendedKeyUsage
        )
    }

    private static func certificateExtension(
        oid: [Int],
        critical: Bool,
        value: Data
    ) -> Data {
        let criticalField = critical
            ? TLSCertificateDER.boolean(true)
            : Data()
        return TLSCertificateDER.sequence(
            TLSCertificateDER.objectIdentifier(oid)
                + criticalField
                + TLSCertificateDER.octetString(value)
        )
    }
}
