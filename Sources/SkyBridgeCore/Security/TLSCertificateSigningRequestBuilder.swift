import Darwin
import Foundation
import Security

/// Builds PKCS#10 requests from an in-memory P-256 key without touching Keychain.
enum TLSCertificateSigningRequestBuilder {
    enum BuildError: Error, Equatable {
        case invalidPrivateKey
        case invalidSubject
        case invalidDNSName(String)
        case invalidIPAddress(String)
        case signingFailed
    }

    private static let extensionRequestOID = [1, 2, 840, 113_549, 1, 9, 14]
    private static let subjectAlternativeNameOID = [2, 5, 29, 17]

    static func buildDER(
        commonName: String,
        organization: String?,
        organizationalUnit: String?,
        sanDNS: [String],
        sanIP: [String],
        privateKey: SecKey
    ) throws -> Data {
        let x963: Data
        do {
            x963 = try TLSCertificateDER.p256PublicKeyX963Representation(
                for: privateKey
            )
        } catch {
            throw BuildError.invalidPrivateKey
        }

        let subject: Data
        do {
            subject = try TLSCertificateDER.distinguishedName(
                commonName: commonName,
                organization: organization,
                organizationalUnit: organizationalUnit
            )
        } catch {
            throw BuildError.invalidSubject
        }
        let certificationRequestInfo = TLSCertificateDER.sequence(
            TLSCertificateDER.integer(Data([0x00]))
                + subject
                + TLSCertificateDER.subjectPublicKeyInfoP256(x963)
                + (try attributes(dnsNames: sanDNS, ipAddresses: sanIP))
        )

        var signingError: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .ecdsaSignatureMessageX962SHA256,
            certificationRequestInfo as CFData,
            &signingError
        ) as Data? else {
            throw BuildError.signingFailed
        }
        return TLSCertificateDER.sequence(
            certificationRequestInfo
                + TLSCertificateDER.ecdsaWithSHA256AlgorithmIdentifier
                + TLSCertificateDER.bitString(signature, unusedBitCount: 0)
        )
    }

    private static func attributes(
        dnsNames: [String],
        ipAddresses: [String]
    ) throws -> Data {
        guard !dnsNames.isEmpty || !ipAddresses.isEmpty else {
            return TLSCertificateDER.contextSpecificConstructed(
                tagNumber: 0,
                content: Data()
            )
        }

        let names = try generalNames(
            dnsNames: dnsNames,
            ipAddresses: ipAddresses
        )
        let subjectAlternativeName = TLSCertificateDER.sequence(
            TLSCertificateDER.objectIdentifier(subjectAlternativeNameOID)
                + TLSCertificateDER.octetString(names)
        )
        let extensions = TLSCertificateDER.sequence(subjectAlternativeName)
        let extensionRequest = TLSCertificateDER.sequence(
            TLSCertificateDER.objectIdentifier(extensionRequestOID)
                + TLSCertificateDER.set(extensions)
        )
        // CertificationRequestInfo.attributes is [0] IMPLICIT SET OF Attribute.
        return TLSCertificateDER.contextSpecificConstructed(
            tagNumber: 0,
            content: extensionRequest
        )
    }

    private static func generalNames(
        dnsNames: [String],
        ipAddresses: [String]
    ) throws -> Data {
        var content = Data()
        for name in dnsNames {
            guard !name.isEmpty,
                  name.utf8.count <= 253,
                  name.unicodeScalars.allSatisfy({ scalar in
                      scalar.isASCII
                          && !CharacterSet.controlCharacters.contains(scalar)
                          && !CharacterSet.whitespacesAndNewlines.contains(scalar)
                  }) else {
                throw BuildError.invalidDNSName(name)
            }
            content.append(contextSpecificPrimitive(tagNumber: 2, Data(name.utf8)))
        }
        for address in ipAddresses {
            guard let encoded = encodedIPAddress(address) else {
                throw BuildError.invalidIPAddress(address)
            }
            content.append(contextSpecificPrimitive(tagNumber: 7, encoded))
        }
        return TLSCertificateDER.sequence(content)
    }

    private static func contextSpecificPrimitive(
        tagNumber: UInt8,
        _ content: Data
    ) -> Data {
        precondition(tagNumber <= 30)
        // Reuse the shared length encoder by wrapping once and replacing the tag.
        var encoded = TLSCertificateDER.octetString(content)
        encoded[encoded.startIndex] = 0x80 | tagNumber
        return encoded
    }

    private static func encodedIPAddress(_ value: String) -> Data? {
        var ipv4 = in_addr()
        if value.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            return withUnsafeBytes(of: ipv4) { Data($0) }
        }

        var ipv6 = in6_addr()
        if value.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 {
            return withUnsafeBytes(of: ipv6) { Data($0) }
        }
        return nil
    }
}
