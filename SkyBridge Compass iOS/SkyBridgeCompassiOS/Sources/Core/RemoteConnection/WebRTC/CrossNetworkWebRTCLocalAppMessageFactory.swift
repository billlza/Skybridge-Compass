import Foundation
import Security
import enum SkyBridgeProtocolCore.BonjourInteropProtocolContract

@available(iOS 17.0, *)
enum CrossNetworkWebRTCLocalAppMessageFactoryError: Error, LocalizedError, Equatable {
    case invalidLocalDeviceId
    case invalidRemoteDeviceId
    case invalidLocalProtocolFingerprint
    case invalidRemoteProtocolFingerprint
    case randomNonceUnavailable(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidLocalDeviceId:
            return "invalid local device id"
        case .invalidRemoteDeviceId:
            return "invalid remote device id"
        case .invalidLocalProtocolFingerprint:
            return "invalid local protocol public key fingerprint"
        case .invalidRemoteProtocolFingerprint:
            return "invalid remote protocol public key fingerprint"
        case .randomNonceUnavailable(let status):
            return "secure random nonce unavailable status=\(status)"
        }
    }
}

@available(iOS 17.0, *)
enum CrossNetworkWebRTCLocalAppMessageFactory {
    static let routeBindingEndpointProvenance = "resolved-dns-sd-endpoint"
    static let fileTransferServiceType = BonjourInteropProtocolContract.fileTransferServiceType
    static let fileTransferRouteKind = "fileTransfer"

    static func authenticatedFileTransferRouteBindingMessages(
        keys: SessionKeys,
        localDeviceId rawLocalDeviceId: String,
        remoteAuthority: CurrentPathRemoteAuthorityCompat,
        localRouteAuthorityProtocolPublicKeyFingerprint rawLocalFingerprint: String,
        sentAt: Date = Date(),
        ttl: TimeInterval = 120
    ) throws -> [AppMessage] {
        let localDeviceId = rawLocalDeviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !localDeviceId.isEmpty else {
            throw CrossNetworkWebRTCLocalAppMessageFactoryError.invalidLocalDeviceId
        }

        let remoteDeviceId = remoteAuthority.deviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remoteDeviceId.isEmpty else {
            throw CrossNetworkWebRTCLocalAppMessageFactoryError.invalidRemoteDeviceId
        }

        let localFingerprint = rawLocalFingerprint
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard isCanonicalLowerHexFingerprint(localFingerprint) else {
            throw CrossNetworkWebRTCLocalAppMessageFactoryError.invalidLocalProtocolFingerprint
        }

        let remoteFingerprint = remoteAuthority.protocolPublicKeyFingerprint
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard isCanonicalLowerHexFingerprint(remoteFingerprint) else {
            throw CrossNetworkWebRTCLocalAppMessageFactoryError.invalidRemoteProtocolFingerprint
        }

        let descriptor = CrossNetworkWebRTCControlChannelCodec.sessionBindingDescriptor(for: keys)
        return [
            .authenticatedRouteBinding(.init(
                kind: fileTransferRouteKind,
                serviceType: fileTransferServiceType,
                instanceName: "\(localRouteBindingInstanceName()).\(fileTransferServiceType).local",
                hostName: localRouteBindingHostName(),
                port: FileTransferConstants.defaultPort,
                endpointProvenance: routeBindingEndpointProvenance,
                localDeviceId: localDeviceId,
                remoteDeviceId: remoteDeviceId,
                routeAuthorityProtocolPublicKeyFingerprint: localFingerprint,
                remoteProtocolPublicKeyFingerprint: remoteFingerprint,
                sessionHashHex: descriptor.sessionHashHex,
                transcriptPrefixHex: descriptor.transcriptPrefixHex,
                sentAt: sentAt,
                expiresAt: sentAt.addingTimeInterval(ttl),
                nonce: try secureRouteBindingNonce()
            ))
        ]
    }

    static func isCanonicalLowerHexFingerprint(_ value: String) -> Bool {
        guard value.count == 64 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            (48...57).contains(scalar.value) || (97...102).contains(scalar.value)
        }
    }

    private static func localRouteBindingInstanceName() -> String {
        let name = ProcessInfo.processInfo.hostName
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "SkyBridge iOS" : trimmed
    }

    private static func localRouteBindingHostName() -> String {
        let raw = ProcessInfo.processInfo.hostName.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = raw.isEmpty ? localRouteBindingInstanceName() : raw
        let withoutTrailingDot = base.hasSuffix(".") ? String(base.dropLast()) : base
        return withoutTrailingDot.contains(".") ? withoutTrailingDot : "\(withoutTrailingDot).local"
    }

    private static func secureRouteBindingNonce() throws -> Data {
        var nonce = Data(count: 16)
        let status = nonce.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, buffer.count, baseAddress)
        }
        guard status == errSecSuccess else {
            throw CrossNetworkWebRTCLocalAppMessageFactoryError.randomNonceUnavailable(status)
        }
        return nonce
    }
}
