import Foundation

@available(macOS 14.0, iOS 17.0, *)
enum WebRTCAuthenticatedRouteBindingPolicy {
    struct Context: Sendable, Equatable {
        let localDeviceId: String
        let localProtocolPublicKeyFingerprint: String
        let expectedRemoteAuthority: CurrentPathRemoteAuthority?
        let sessionBinding: WebRTCAppSecureSessionBindingDescriptor
        let now: Date
    }

    struct FileTransferRoute: Sendable, Equatable {
        let peerId: String
        let deviceName: String
        let displayAddress: String
        let transferAddress: String
        let transferPort: Int
    }

    enum Decision: Sendable, Equatable {
        case fileTransfer(FileTransferRoute)
        case verifiedButUnsupported(kind: String)
        case rejected(reason: String)
    }

    static func evaluate(
        _ payload: AppMessage.AuthenticatedRouteBindingPayload,
        context: Context
    ) -> Decision {
        guard payload.version == AppMessage.AuthenticatedRouteBindingPayload.currentVersion else {
            return .rejected(reason: "unsupported_version")
        }
        guard payload.endpointProvenance == CrossNetworkWebRTCLocalAppMessageFactory.routeBindingEndpointProvenance else {
            return .rejected(reason: "unsupported_endpoint_provenance")
        }
        guard payload.sentAt <= payload.expiresAt else {
            return .rejected(reason: "invalid_time_window")
        }
        guard payload.expiresAt > context.now else {
            return .rejected(reason: "expired")
        }
        guard let expectedRemoteAuthority = context.expectedRemoteAuthority else {
            return .rejected(reason: "missing_expected_remote_authority")
        }
        guard let localDeviceId = normalizedRequiredToken(context.localDeviceId) else {
            return .rejected(reason: "missing_local_device_id")
        }
        guard let localFingerprint = normalizedFingerprint(context.localProtocolPublicKeyFingerprint) else {
            return .rejected(reason: "missing_local_protocol_fingerprint")
        }
        guard let remoteDeviceId = normalizedRequiredToken(expectedRemoteAuthority.deviceId),
              let remoteFingerprint = normalizedFingerprint(expectedRemoteAuthority.protocolPublicKeyFingerprint) else {
            return .rejected(reason: "missing_remote_authority_identity")
        }
        guard normalizedRequiredToken(payload.localDeviceId) == remoteDeviceId else {
            return .rejected(reason: "route_authority_device_mismatch")
        }
        guard normalizedRequiredToken(payload.remoteDeviceId) == localDeviceId else {
            return .rejected(reason: "route_recipient_device_mismatch")
        }
        guard normalizedFingerprint(payload.routeAuthorityProtocolPublicKeyFingerprint) == remoteFingerprint else {
            return .rejected(reason: "route_authority_fingerprint_mismatch")
        }
        guard normalizedFingerprint(payload.remoteProtocolPublicKeyFingerprint) == localFingerprint else {
            return .rejected(reason: "route_recipient_fingerprint_mismatch")
        }
        guard payload.sessionHashHex == context.sessionBinding.sessionHashHex,
              payload.transcriptPrefixHex == context.sessionBinding.transcriptPrefixHex else {
            return .rejected(reason: "session_binding_mismatch")
        }
        guard (1...65535).contains(Int(payload.port)) else {
            return .rejected(reason: "invalid_port")
        }
        guard let hostName = normalizedHost(payload.hostName),
              !payload.instanceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .rejected(reason: "invalid_endpoint")
        }

        if payload.kind == "fileTransfer",
           [
               BonjourInteropContract.fileTransferServiceType,
               BonjourInteropContract.legacyFileTransferServiceType
           ].contains(payload.serviceType) {
            let peerName = normalizedRequiredToken(expectedRemoteAuthority.deviceName)
                ?? normalizedRequiredToken(payload.localDeviceId)
                ?? "Remote Device"
            return .fileTransfer(.init(
                peerId: remoteDeviceId,
                deviceName: peerName,
                displayAddress: hostName,
                transferAddress: hostName,
                transferPort: Int(payload.port)
            ))
        }
        if payload.kind == "remoteDesktop",
           [
               BonjourInteropContract.remoteControlServiceType,
               BonjourInteropContract.legacyRemoteControlServiceType
           ].contains(payload.serviceType) {
            return .verifiedButUnsupported(kind: "remoteDesktop")
        }
        return .rejected(reason: "unsupported_route_kind_or_service")
    }

    private static func normalizedRequiredToken(_ raw: String?) -> String? {
        let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    private static func normalizedFingerprint(_ raw: String?) -> String? {
        guard let value = normalizedRequiredToken(raw)?.lowercased(),
              value.count == 64,
              value.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) }) else {
            return nil
        }
        return value
    }

    private static func normalizedHost(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.count <= 253,
              value.rangeOfCharacter(from: .controlCharacters) == nil,
              !value.contains("/"),
              !value.contains("\\") else {
            return nil
        }
        return value.hasSuffix(".") ? String(value.dropLast()) : value
    }
}
