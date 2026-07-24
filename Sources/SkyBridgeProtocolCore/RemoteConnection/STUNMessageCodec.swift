import Foundation

/// One RFC 8489 binding request and the transaction identifier that must be
/// matched by its response.
public struct STUNBindingRequest: Sendable, Equatable {
    public let payload: Data
    public let transactionID: Data

    public init(payload: Data, transactionID: Data) {
        self.payload = Data(payload)
        self.transactionID = Data(transactionID)
    }
}

public struct STUNMappedAddress: Sendable, Equatable {
    public let address: String
    public let port: UInt16

    public init(address: String, port: UInt16) {
        self.address = address
        self.port = port
    }
}

public enum STUNMessageCodecError: Error, LocalizedError, Sendable, Equatable {
    case invalidTransactionIDLength(actual: Int)
    case datagramTooShort(actual: Int)
    case invalidMessageType(actual: UInt16)
    case invalidDeclaredLength(declared: Int, actualBody: Int)
    case invalidMagicCookie
    case transactionIDMismatch
    case truncatedAttributeHeader
    case truncatedAttributeValue(type: UInt16)
    case invalidAddressAttribute(type: UInt16)
    case unsupportedAddressFamily(UInt8)
    case missingMappedAddress

    public var errorDescription: String? {
        switch self {
        case .invalidTransactionIDLength(let actual):
            return "STUN transaction ID must be 12 bytes; received \(actual)."
        case .datagramTooShort(let actual):
            return "STUN datagram is shorter than its 20-byte header (\(actual) bytes)."
        case .invalidMessageType(let actual):
            return String(format: "Unexpected STUN message type 0x%04X.", actual)
        case .invalidDeclaredLength(let declared, let actualBody):
            return "STUN body length mismatch: declared \(declared), received \(actualBody)."
        case .invalidMagicCookie:
            return "STUN magic cookie mismatch."
        case .transactionIDMismatch:
            return "STUN response transaction ID does not match the request."
        case .truncatedAttributeHeader:
            return "STUN attribute header is truncated."
        case .truncatedAttributeValue(let type):
            return String(format: "STUN attribute 0x%04X is truncated.", type)
        case .invalidAddressAttribute(let type):
            return String(format: "STUN address attribute 0x%04X is malformed.", type)
        case .unsupportedAddressFamily(let family):
            return String(format: "Unsupported STUN address family 0x%02X.", family)
        case .missingMappedAddress:
            return "STUN response contains no supported mapped address."
        }
    }
}

/// Strict, Foundation-only STUN wire codec shared by macOS and iOS.
public enum STUNMessageCodec {
    public static let magicCookie = Data([0x21, 0x12, 0xA4, 0x42])

    private static let bindingRequestType: UInt16 = 0x0001
    private static let bindingSuccessType: UInt16 = 0x0101
    private static let mappedAddressType: UInt16 = 0x0001
    private static let xorMappedAddressType: UInt16 = 0x0020
    private static let headerLength = 20
    private static let transactionIDLength = 12

    public static func makeBindingRequest() -> STUNBindingRequest {
        var generator = SystemRandomNumberGenerator()
        let transactionID = Data((0..<transactionIDLength).map { _ in
            UInt8.random(in: UInt8.min...UInt8.max, using: &generator)
        })
        return makeValidatedBindingRequest(transactionID: transactionID)
    }

    public static func makeBindingRequest(
        transactionID: Data
    ) throws(STUNMessageCodecError) -> STUNBindingRequest {
        guard transactionID.count == transactionIDLength else {
            throw STUNMessageCodecError.invalidTransactionIDLength(actual: transactionID.count)
        }
        return makeValidatedBindingRequest(transactionID: Data(transactionID))
    }

    public static func parseBindingResponse(
        _ input: Data,
        expectedTransactionID: Data
    ) throws(STUNMessageCodecError) -> STUNMappedAddress {
        guard expectedTransactionID.count == transactionIDLength else {
            throw STUNMessageCodecError.invalidTransactionIDLength(
                actual: expectedTransactionID.count
            )
        }

        // STUN datagrams are at most 65,555 bytes. Rebase possible Data slices
        // once before applying protocol-relative offsets.
        let data = Data(input)
        guard data.count >= headerLength else {
            throw STUNMessageCodecError.datagramTooShort(actual: data.count)
        }

        let messageType = uint16(data[0], data[1])
        guard messageType == bindingSuccessType else {
            throw STUNMessageCodecError.invalidMessageType(actual: messageType)
        }

        let declaredBodyLength = Int(uint16(data[2], data[3]))
        let actualBodyLength = data.count - headerLength
        guard declaredBodyLength.isMultiple(of: 4),
              declaredBodyLength == actualBodyLength else {
            throw STUNMessageCodecError.invalidDeclaredLength(
                declared: declaredBodyLength,
                actualBody: actualBodyLength
            )
        }
        guard Data(data[4..<8]) == magicCookie else {
            throw STUNMessageCodecError.invalidMagicCookie
        }
        guard constantTimeEquals(Data(data[8..<20]), expectedTransactionID) else {
            throw STUNMessageCodecError.transactionIDMismatch
        }

        var offset = headerLength
        let bodyEnd = data.count
        var mappedAddress: STUNMappedAddress?
        var xorMappedAddress: STUNMappedAddress?

        while offset < bodyEnd {
            guard offset <= bodyEnd - 4 else {
                throw STUNMessageCodecError.truncatedAttributeHeader
            }
            let attributeType = uint16(data[offset], data[offset + 1])
            let attributeLength = Int(uint16(data[offset + 2], data[offset + 3]))
            let valueStart = offset + 4
            let paddedLength = (attributeLength + 3) & ~3
            guard attributeLength <= bodyEnd - valueStart,
                  paddedLength <= bodyEnd - valueStart else {
                throw STUNMessageCodecError.truncatedAttributeValue(type: attributeType)
            }

            if attributeType == mappedAddressType || attributeType == xorMappedAddressType {
                guard attributeLength >= 4 else {
                    throw STUNMessageCodecError.invalidAddressAttribute(type: attributeType)
                }
                let reserved = data[valueStart]
                let family = data[valueStart + 1]
                guard reserved == 0 else {
                    throw STUNMessageCodecError.invalidAddressAttribute(type: attributeType)
                }

                switch family {
                case 0x01:
                    guard attributeLength == 8 else {
                        throw STUNMessageCodecError.invalidAddressAttribute(type: attributeType)
                    }
                    var port = uint16(data[valueStart + 2], data[valueStart + 3])
                    var addressBytes = Array(data[(valueStart + 4)..<(valueStart + 8)])
                    if attributeType == xorMappedAddressType {
                        port ^= 0x2112
                        for index in addressBytes.indices {
                            addressBytes[index] ^= magicCookie[index]
                        }
                    }
                    let parsed = STUNMappedAddress(
                        address: addressBytes.map(String.init).joined(separator: "."),
                        port: port
                    )
                    if attributeType == xorMappedAddressType {
                        xorMappedAddress = parsed
                    } else {
                        mappedAddress = parsed
                    }
                case 0x02:
                    guard attributeLength == 20 else {
                        throw STUNMessageCodecError.invalidAddressAttribute(type: attributeType)
                    }
                    // The current public result is IPv4 text. A valid IPv6
                    // attribute is ignored so a later IPv4 mapping can win.
                default:
                    throw STUNMessageCodecError.unsupportedAddressFamily(family)
                }
            }

            offset = valueStart + paddedLength
        }

        guard let result = xorMappedAddress ?? mappedAddress else {
            throw STUNMessageCodecError.missingMappedAddress
        }
        return result
    }

    private static func makeValidatedBindingRequest(transactionID: Data) -> STUNBindingRequest {
        var payload = Data()
        appendUInt16(bindingRequestType, to: &payload)
        appendUInt16(0, to: &payload)
        payload.append(magicCookie)
        payload.append(transactionID)
        return STUNBindingRequest(payload: payload, transactionID: transactionID)
    }

    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value >> 8))
        data.append(UInt8(value & 0xFF))
    }

    private static func uint16(_ high: UInt8, _ low: UInt8) -> UInt16 {
        UInt16(high) << 8 | UInt16(low)
    }

    private static func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) {
            difference |= left ^ right
        }
        return difference == 0
    }
}
