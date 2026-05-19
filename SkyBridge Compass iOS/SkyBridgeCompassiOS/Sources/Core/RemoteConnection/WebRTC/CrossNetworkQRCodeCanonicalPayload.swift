import Foundation

@available(iOS 17.0, *)
extension DynamicQRCodeData {
    var canonicalSignaturePayload: Data {
        var data = Data()

        func appendUInt16(_ value: UInt16) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }

        func appendUInt32(_ value: UInt32) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }

        func appendInt64(_ value: Int64) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }

        func appendString(_ value: String) {
            let bytes = Data(value.precomposedStringWithCanonicalMapping.utf8)
            appendUInt32(UInt32(bytes.count))
            data.append(bytes)
        }

        func appendData(_ value: Data) {
            appendUInt32(UInt32(value.count))
            data.append(value)
        }

        appendUInt16(UInt16(max(0, version)))
        appendString(sessionID)
        appendString(qrBootstrapToken)
        appendInt64(Int64(expiresAt.timeIntervalSince1970 * 1000))
        appendString(canonicalSignalingServerOrigin)
        appendString(deviceID)
        appendString(deviceName)
        appendString(deviceType)
        appendString(osVersion)
        appendUInt32(UInt32(normalizedCapabilities.count))
        for capability in normalizedCapabilities {
            appendString(capability)
        }
        appendString(protocolSigningAlgorithm.rawValue)
        appendData(protocolPublicKeyBytes)
        appendString(protocolPublicKeyFingerprint)
        appendUInt32(UInt32(normalizedKEMPublicKeys.count))
        for key in normalizedKEMPublicKeys {
            appendUInt16(key.suiteWireId)
            appendData(key.publicKey)
        }
        appendInt64(signatureTimestampMs)
        return data
    }
}
