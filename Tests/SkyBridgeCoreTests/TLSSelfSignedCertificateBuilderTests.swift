import Security
import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, *)
final class TLSCertificateDERBuilderTests: XCTestCase {
    func testGeneratedLeafCertificateParsesWithExpectedIdentityAndExtensions() throws {
        let keychainLabel = "SkyBridge.der-builder-test.\(UUID().uuidString)"
        XCTAssertEqual(keychainCertificateStatus(label: keychainLabel), errSecItemNotFound)

        let privateKey = try makeEphemeralP256PrivateKey()
        let certificateDER = try TLSSelfSignedCertificateBuilder.buildCertificateDER(
            privateKey: privateKey,
            subject: .init(
                commonName: keychainLabel,
                organization: "SkyBridge",
                organizationalUnit: "Devices"
            ),
            serialNumber: Data([0x00, 0x80]),
            notBefore: Date(timeIntervalSince1970: 1_767_225_600),
            notAfter: Date(timeIntervalSince1970: 1_798_761_600)
        )

        guard let certificate = SecCertificateCreateWithData(nil, certificateDER as CFData) else {
            return XCTFail("The generated DER must be accepted by Security.framework")
        }
        let requestedOIDs = [
            kSecOIDCommonName,
            kSecOIDX509V1SubjectName,
            kSecOIDBasicConstraints,
            kSecOIDKeyUsage,
            kSecOIDExtendedKeyUsage,
            kSecOIDX509V1SerialNumber
        ] as CFArray
        guard let values = SecCertificateCopyValues(certificate, requestedOIDs, nil)
            as? [CFString: Any]
        else {
            return XCTFail("Security.framework must expose the requested X.509 fields")
        }

        XCTAssertEqual(arrayStringValue(for: kSecOIDCommonName, in: values), [keychainLabel])
        XCTAssertEqual(
            sectionStringValues(for: kSecOIDX509V1SubjectName, in: values),
            [
                "2.5.4.3": keychainLabel,
                "2.5.4.10": "SkyBridge",
                "2.5.4.11": "Devices"
            ]
        )
        XCTAssertEqual(
            sectionStringValues(for: kSecOIDBasicConstraints, in: values),
            ["Critical": "Yes", "Certificate Authority": "No"]
        )
        XCTAssertEqual(numberValue(for: kSecOIDKeyUsage, in: values)?.int32Value, Int32.min | 1)
        XCTAssertEqual(
            dataArrayValue(for: kSecOIDExtendedKeyUsage, in: values),
            [
                Data([0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x01]),
                Data([0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x02])
            ]
        )
        XCTAssertEqual(stringValue(for: kSecOIDX509V1SerialNumber, in: values), "128")

        let certificateElement = try DERElement.parseExactlyOne(certificateDER)
        XCTAssertEqual(certificateElement.tag, 0x30)
        let certificateFields = try certificateElement.children()
        XCTAssertEqual(certificateFields.count, 3)
        let tbsFields = try certificateFields[0].children()
        XCTAssertEqual(tbsFields.map(\.tag), [0xA0, 0x02, 0x30, 0x30, 0x30, 0x30, 0x30, 0xA3])
        XCTAssertEqual(tbsFields[1].content, Data([0x00, 0x80]))
        try assertNameEncoding(tbsFields[3], expectedValues: [keychainLabel, "SkyBridge", "Devices"])
        try assertNameEncoding(tbsFields[5], expectedValues: [keychainLabel, "SkyBridge", "Devices"])
        try assertExtensionsEncoding(tbsFields[7])
        XCTAssertEqual(keychainCertificateStatus(label: keychainLabel), errSecItemNotFound)
    }

    func testSerialNumberUsesMinimalPositiveDERIntegerEncoding() throws {
        let privateKey = try makeEphemeralP256PrivateKey()
        let subject = TLSSelfSignedCertificateBuilder.Subject(
            commonName: "serial-boundary",
            organization: "SkyBridge",
            organizationalUnit: "Devices"
        )
        let notBefore = Date(timeIntervalSince1970: 1_767_225_600)
        let notAfter = Date(timeIntervalSince1970: 1_798_761_600)

        for (magnitude, expectedContent) in [
            (Data([0x00, 0x00, 0x01]), Data([0x01])),
            (Data([0x7F]), Data([0x7F])),
            (Data([0x80]), Data([0x00, 0x80])),
            (
                Data([0x7F] + Array(repeating: 0xFF, count: 19)),
                Data([0x7F] + Array(repeating: 0xFF, count: 19))
            )
        ] {
            let der = try TLSSelfSignedCertificateBuilder.buildCertificateDER(
                privateKey: privateKey,
                subject: subject,
                serialNumber: magnitude,
                notBefore: notBefore,
                notAfter: notAfter
            )
            let certificate = try DERElement.parseExactlyOne(der)
            let serial = try certificate.children()[0].children()[1]
            XCTAssertEqual(serial.tag, 0x02)
            XCTAssertEqual(serial.content, expectedContent)
        }

        XCTAssertThrowsError(
            try TLSSelfSignedCertificateBuilder.buildCertificateDER(
                privateKey: privateKey,
                subject: subject,
                serialNumber: Data([0x00]),
                notBefore: notBefore,
                notAfter: notAfter
            )
        ) { error in
            XCTAssertEqual(error as? TLSSelfSignedCertificateBuilder.BuildError, .invalidSerialNumber)
        }
        XCTAssertThrowsError(
            try TLSSelfSignedCertificateBuilder.buildCertificateDER(
                privateKey: privateKey,
                subject: subject,
                serialNumber: Data(repeating: 0x80, count: 20),
                notBefore: notBefore,
                notAfter: notAfter
            )
        ) { error in
            XCTAssertEqual(error as? TLSSelfSignedCertificateBuilder.BuildError, .serialNumberTooLong)
        }
    }

    func testPKCS10CSRUsesCanonicalNameAndSubjectAlternativeNames() throws {
        let privateKey = try makeEphemeralP256PrivateKey()
        let csrDER = try TLSCertificateSigningRequestBuilder.buildDER(
            commonName: "csr-device",
            organization: "SkyBridge",
            organizationalUnit: "Devices",
            sanDNS: ["csr-device.local"],
            sanIP: ["192.0.2.10", "2001:db8::1"],
            privateKey: privateKey
        )

        let request = try DERElement.parseExactlyOne(csrDER)
        XCTAssertEqual(request.tag, 0x30)
        let requestFields = try request.children()
        XCTAssertEqual(requestFields.map(\.tag), [0x30, 0x30, 0x03])
        let requestInfo = requestFields[0]
        let requestInfoFields = try requestInfo.children()
        XCTAssertEqual(requestInfoFields.map(\.tag), [0x02, 0x30, 0x30, 0xA0])
        XCTAssertEqual(requestInfoFields[0].content, Data([0x00]))
        try assertNameEncoding(
            requestInfoFields[1],
            expectedValues: ["csr-device", "SkyBridge", "Devices"]
        )

        let attributes = try requestInfoFields[3].children()
        XCTAssertEqual(attributes.count, 1)
        let extensionRequestFields = try attributes[0].children()
        XCTAssertEqual(extensionRequestFields.map(\.tag), [0x06, 0x31])
        XCTAssertEqual(
            extensionRequestFields[0].content,
            Data([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x09, 0x0E])
        )
        let extensionSets = try extensionRequestFields[1].children()
        XCTAssertEqual(extensionSets.count, 1)
        let extensions = try extensionSets[0].children()
        XCTAssertEqual(extensions.count, 1)
        let subjectAlternativeNameFields = try extensions[0].children()
        XCTAssertEqual(subjectAlternativeNameFields.map(\.tag), [0x06, 0x04])
        XCTAssertEqual(
            subjectAlternativeNameFields[0].content,
            Data([0x55, 0x1D, 0x11])
        )
        let generalNames = try DERElement.parseExactlyOne(
            subjectAlternativeNameFields[1].content
        ).children()
        XCTAssertEqual(generalNames.map(\.tag), [0x82, 0x87, 0x87])
        XCTAssertEqual(
            String(data: generalNames[0].content, encoding: .ascii),
            "csr-device.local"
        )
        XCTAssertEqual(generalNames[1].content, Data([192, 0, 2, 10]))
        XCTAssertEqual(
            generalNames[2].content,
            Data(
                [0x20, 0x01, 0x0D, 0xB8]
                    + Array(repeating: 0, count: 11)
                    + [0x01]
            )
        )

        XCTAssertEqual(requestFields[2].content.first, 0)
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            return XCTFail("The ephemeral key must expose its public key")
        }
        XCTAssertTrue(
            SecKeyVerifySignature(
                publicKey,
                .ecdsaSignatureMessageX962SHA256,
                requestInfo.encoded as CFData,
                Data(requestFields[2].content.dropFirst()) as CFData,
                nil
            )
        )
    }

    func testPKCS10CSRWithoutSANUsesEmptyAttributesAndRejectsInvalidIP() throws {
        let privateKey = try makeEphemeralP256PrivateKey()
        let csrDER = try TLSCertificateSigningRequestBuilder.buildDER(
            commonName: "csr-no-san",
            organization: nil,
            organizationalUnit: nil,
            sanDNS: [],
            sanIP: [],
            privateKey: privateKey
        )
        let request = try DERElement.parseExactlyOne(csrDER)
        let attributes = try request.children()[0].children()[3]
        XCTAssertEqual(attributes.tag, 0xA0)
        XCTAssertTrue(attributes.content.isEmpty)

        XCTAssertThrowsError(
            try TLSCertificateSigningRequestBuilder.buildDER(
                commonName: "csr-invalid-ip",
                organization: nil,
                organizationalUnit: nil,
                sanDNS: [],
                sanIP: ["not-an-ip-address"],
                privateKey: privateKey
            )
        ) { error in
            XCTAssertEqual(
                error as? TLSCertificateSigningRequestBuilder.BuildError,
                .invalidIPAddress("not-an-ip-address")
            )
        }
    }

    private func makeEphemeralP256PrivateKey() throws -> SecKey {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: false
            ]
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw error!.takeRetainedValue()
        }
        return key
    }

    private func keychainCertificateStatus(label: String) -> OSStatus {
        SecItemCopyMatching([
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: label,
            kSecMatchLimit as String: kSecMatchLimitOne
        ] as CFDictionary, nil)
    }

    private func arrayStringValue(
        for oid: CFString,
        in values: [CFString: Any]
    ) -> [String]? {
        guard let property = values[oid] as? [CFString: Any] else {
            return nil
        }
        return property[kSecPropertyKeyValue] as? [String]
    }

    private func stringValue(
        for oid: CFString,
        in values: [CFString: Any]
    ) -> String? {
        guard let property = values[oid] as? [CFString: Any] else {
            return nil
        }
        return property[kSecPropertyKeyValue] as? String
    }

    private func numberValue(
        for oid: CFString,
        in values: [CFString: Any]
    ) -> NSNumber? {
        guard let property = values[oid] as? [CFString: Any] else {
            return nil
        }
        return property[kSecPropertyKeyValue] as? NSNumber
    }

    private func dataArrayValue(
        for oid: CFString,
        in values: [CFString: Any]
    ) -> [Data]? {
        guard let property = values[oid] as? [CFString: Any] else {
            return nil
        }
        return property[kSecPropertyKeyValue] as? [Data]
    }

    private func sectionStringValues(
        for oid: CFString,
        in values: [CFString: Any]
    ) -> [String: String]? {
        guard let property = values[oid] as? [CFString: Any],
              let entries = property[kSecPropertyKeyValue] as? [[CFString: Any]]
        else {
            return nil
        }
        var result = [String: String]()
        for entry in entries {
            guard let label = entry[kSecPropertyKeyLabel] as? String,
                  let value = entry[kSecPropertyKeyValue] as? String
            else {
                return nil
            }
            result[label] = value
        }
        return result
    }

    private func assertNameEncoding(
        _ name: DERElement,
        expectedValues: [String]
    ) throws {
        XCTAssertEqual(name.tag, 0x30, "Name must have exactly one outer SEQUENCE")
        let relativeDistinguishedNames = try name.children()
        XCTAssertEqual(relativeDistinguishedNames.map(\.tag), [0x31, 0x31, 0x31])
        XCTAssertEqual(relativeDistinguishedNames.count, expectedValues.count)
        for (rdn, expectedValue) in zip(relativeDistinguishedNames, expectedValues) {
            let attributes = try rdn.children()
            XCTAssertEqual(attributes.count, 1, "Each RDN must contain exactly one attribute")
            let attributeFields = try attributes[0].children()
            XCTAssertEqual(attributeFields.count, 2)
            XCTAssertEqual(attributeFields[1].tag, 0x0C)
            XCTAssertEqual(String(data: attributeFields[1].content, encoding: .utf8), expectedValue)
        }
    }

    private func assertExtensionsEncoding(_ explicitExtensions: DERElement) throws {
        XCTAssertEqual(explicitExtensions.tag, 0xA3, "Extensions must be [3] EXPLICIT")
        let explicitContent = try explicitExtensions.children()
        XCTAssertEqual(explicitContent.count, 1)
        XCTAssertEqual(explicitContent[0].tag, 0x30)
        let extensions = try explicitContent[0].children()
        XCTAssertEqual(extensions.count, 3)

        let keyUsageFields = try extensions[1].children()
        XCTAssertEqual(keyUsageFields[0].content, Data([0x55, 0x1D, 0x0F]))
        XCTAssertEqual(keyUsageFields[1].tag, 0x01)
        XCTAssertEqual(keyUsageFields[1].content, Data([0xFF]))
        XCTAssertEqual(keyUsageFields[2].tag, 0x04)
        let namedBitList = try DERElement.parseExactlyOne(keyUsageFields[2].content)
        XCTAssertEqual(namedBitList.tag, 0x03)
        XCTAssertEqual(namedBitList.content, Data([0x07, 0x80]))
    }
}

private struct DERElement {
    let tag: UInt8
    let content: Data
    let encoded: Data

    static func parseExactlyOne(_ encoded: Data) throws -> Self {
        var reader = DERReader(data: encoded)
        let element = try reader.readElement()
        guard reader.isAtEnd else {
            throw DERTestError.trailingData
        }
        return element
    }

    func children() throws -> [Self] {
        var reader = DERReader(data: content)
        var elements = [Self]()
        while !reader.isAtEnd {
            elements.append(try reader.readElement())
        }
        return elements
    }
}

private struct DERReader {
    let data: Data
    private(set) var offset = 0

    var isAtEnd: Bool {
        offset == data.count
    }

    mutating func readElement() throws -> DERElement {
        let elementStart = offset
        let tag = try readByte()
        let firstLengthByte = try readByte()
        let contentLength: Int
        if firstLengthByte & 0x80 == 0 {
            contentLength = Int(firstLengthByte)
        } else {
            let byteCount = Int(firstLengthByte & 0x7F)
            guard byteCount > 0, byteCount <= MemoryLayout<Int>.size else {
                throw DERTestError.invalidLength
            }
            var length = 0
            for _ in 0..<byteCount {
                length = (length << 8) | Int(try readByte())
            }
            contentLength = length
        }
        guard contentLength <= data.count - offset else {
            throw DERTestError.truncated
        }
        let end = offset + contentLength
        let content = data.subdata(in: offset..<end)
        offset = end
        return DERElement(
            tag: tag,
            content: content,
            encoded: data.subdata(in: elementStart..<end)
        )
    }

    private mutating func readByte() throws -> UInt8 {
        guard offset < data.count else {
            throw DERTestError.truncated
        }
        defer { offset += 1 }
        return data[data.startIndex + offset]
    }
}

private enum DERTestError: Error {
    case invalidLength
    case trailingData
    case truncated
}
