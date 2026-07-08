import Foundation
import Security

struct CrossNetworkWebRTCLocalAuthenticatedRouteBindingRoute: Sendable, Equatable {
    let kind: String
    let serviceType: String
    let instanceName: String
    let hostName: String
    let port: UInt16
}

enum CrossNetworkWebRTCLocalAppMessageFactoryError: Error, LocalizedError, Equatable {
    case missingRequiredToken(String)
    case invalidProtocolFingerprint(String)

    var errorDescription: String? {
        switch self {
        case .missingRequiredToken(let label):
            return "\(label) must not be empty"
        case .invalidProtocolFingerprint(let label):
            return "\(label) must be 64 lowercase hex characters"
        }
    }
}

struct CrossNetworkWebRTCLocalDeviceDescriptor: Sendable, Equatable {
    let deviceName: String?
    let modelName: String?
    let platform: String
    let osVersion: String

    static func current(
        osVersion: String = ProcessInfo.processInfo.operatingSystemVersionString
    ) -> CrossNetworkWebRTCLocalDeviceDescriptor {
        let snapshot = LocalDevicePresentation.current(osVersion: osVersion)
        return CrossNetworkWebRTCLocalDeviceDescriptor(
            deviceName: snapshot.deviceName,
            modelName: snapshot.modelName,
            platform: snapshot.platformName,
            osVersion: snapshot.osVersion
        )
    }
}

enum CrossNetworkWebRTCLocalAppMessageFactory {
    static let routeBindingEndpointProvenance = "resolved-dns-sd-endpoint"

    static func heartbeatMessage(
        deviceId: String,
        remoteVideoFormats: [String],
        accountDisplayName: String? = nil,
        nebulaId: String? = nil,
        sentAt: Date = Date(),
        descriptor: CrossNetworkWebRTCLocalDeviceDescriptor = .current()
    ) -> AppMessage {
        AppMessage.heartbeat(.init(
            sentAt: sentAt,
            deviceId: deviceId,
            deviceName: descriptor.deviceName,
            modelName: descriptor.modelName,
            platform: descriptor.platform,
            osVersion: descriptor.osVersion,
            chip: nil,
            accountDisplayName: accountDisplayName,
            nebulaId: nebulaId,
            remoteVideoFormats: remoteVideoFormats
        ))
    }

    static func pairingIdentityExchangePayload(
        deviceId: String,
        kemPublicKeys: [KEMPublicKeyInfo],
        protocolIdentityPublicKeys: [AppMessage.ProtocolIdentityPublicKeyInfo]?,
        remoteVideoFormats: [String],
        accountDisplayName: String? = nil,
        nebulaId: String? = nil,
        sentAt: Date = Date(),
        descriptor: CrossNetworkWebRTCLocalDeviceDescriptor = .current()
    ) -> AppMessage.PairingIdentityExchangePayload {
        AppMessage.PairingIdentityExchangePayload(
            deviceId: deviceId,
            kemPublicKeys: kemPublicKeys,
            protocolIdentityPublicKeys: protocolIdentityPublicKeys,
            deviceName: descriptor.deviceName,
            modelName: descriptor.modelName,
            platform: descriptor.platform,
            osVersion: descriptor.osVersion,
            chip: nil,
            accountDisplayName: accountDisplayName,
            nebulaId: nebulaId,
            remoteVideoFormats: remoteVideoFormats,
            sentAt: sentAt
        )
    }

    static func localAuthenticatedRouteBindingRoutes(
        endpointSnapshot: ServiceEndpointSnapshot,
        serviceName: String = Host.current().localizedName ?? "Mac",
        hostName: String = ProcessInfo.processInfo.hostName
    ) -> [CrossNetworkWebRTCLocalAuthenticatedRouteBindingRoute] {
        let normalizedServiceName = normalizedNonEmptyToken(serviceName) ?? "Mac"
        let normalizedHostName = normalizedBonjourHostName(hostName, fallbackServiceName: normalizedServiceName)
        var routes: [CrossNetworkWebRTCLocalAuthenticatedRouteBindingRoute] = []
        if let port = endpointSnapshot.fileTransferPort, port > 0 {
            routes.append(.init(
                kind: "fileTransfer",
                serviceType: "_skybridge-transfer._tcp",
                instanceName: "\(normalizedServiceName)._skybridge-transfer._tcp.local",
                hostName: normalizedHostName,
                port: port
            ))
        }
        if let port = endpointSnapshot.remoteControlPort, port > 0 {
            routes.append(.init(
                kind: "remoteDesktop",
                serviceType: "_skybridge-remote._tcp",
                instanceName: "\(normalizedServiceName)._skybridge-remote._tcp.local",
                hostName: normalizedHostName,
                port: port
            ))
        }
        return routes
    }

    static func authenticatedRouteBindingMessages(
        routes: [CrossNetworkWebRTCLocalAuthenticatedRouteBindingRoute],
        localDeviceId: String,
        remoteDeviceId: String,
        localProtocolPublicKeyFingerprint: String,
        remoteProtocolPublicKeyFingerprint: String,
        sessionBinding: WebRTCAppSecureSessionBindingDescriptor,
        sentAt: Date = Date(),
        ttl: TimeInterval = 120
    ) throws -> [AppMessage] {
        let localDeviceId = try normalizedRequiredToken(localDeviceId, label: "local route-binding device id")
        let remoteDeviceId = try normalizedRequiredToken(remoteDeviceId, label: "remote route-binding device id")
        let localFingerprint = try normalizedProtocolFingerprint(
            localProtocolPublicKeyFingerprint,
            label: "local route-binding protocol fingerprint"
        )
        let remoteFingerprint = try normalizedProtocolFingerprint(
            remoteProtocolPublicKeyFingerprint,
            label: "remote route-binding protocol fingerprint"
        )
        guard !routes.isEmpty else { return [] }
        let expiresAt = sentAt.addingTimeInterval(ttl)
        return try routes.map { route in
            AppMessage.authenticatedRouteBinding(.init(
                kind: route.kind,
                serviceType: route.serviceType,
                instanceName: route.instanceName,
                hostName: route.hostName,
                port: route.port,
                endpointProvenance: routeBindingEndpointProvenance,
                localDeviceId: localDeviceId,
                remoteDeviceId: remoteDeviceId,
                routeAuthorityProtocolPublicKeyFingerprint: localFingerprint,
                remoteProtocolPublicKeyFingerprint: remoteFingerprint,
                sessionHashHex: sessionBinding.sessionHashHex,
                transcriptPrefixHex: sessionBinding.transcriptPrefixHex,
                sentAt: sentAt,
                expiresAt: expiresAt,
                nonce: try secureNonce()
            ))
        }
    }

    private static func normalizedRequiredToken(_ raw: String, label: String) throws -> String {
        guard let value = normalizedNonEmptyToken(raw) else {
            throw CrossNetworkWebRTCLocalAppMessageFactoryError.missingRequiredToken(label)
        }
        return value
    }

    private static func normalizedNonEmptyToken(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func normalizedProtocolFingerprint(_ raw: String, label: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count == 64, value.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) }) else {
            throw CrossNetworkWebRTCLocalAppMessageFactoryError.invalidProtocolFingerprint(label)
        }
        return value
    }

    private static func normalizedBonjourHostName(
        _ raw: String,
        fallbackServiceName: String
    ) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.isEmpty ? fallbackServiceName : trimmed
        if candidate.hasSuffix(".") {
            return String(candidate.dropLast())
        }
        return candidate.contains(".") ? candidate : "\(candidate).local"
    }

    private static func secureNonce() throws -> Data {
        var nonce = Data(count: 16)
        let status = nonce.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw NSError(
                domain: "CrossNetworkWebRTCLocalAppMessageFactory",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "failed to generate authenticated route-binding nonce"]
            )
        }
        return nonce
    }
}
