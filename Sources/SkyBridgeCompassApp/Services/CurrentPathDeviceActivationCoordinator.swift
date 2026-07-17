import Foundation
import OSLog
import SkyBridgeCore
import SkyBridgeProtocolCore

private enum CurrentPathActivationError: LocalizedError {
    case identityNotProvisioned(String)

    var errorDescription: String? {
        switch self {
        case .identityNotProvisioned(let component):
            return "本机 current-path 身份未就绪：缺少\(component)"
        }
    }
}

@MainActor
final class CurrentPathDeviceActivationCoordinator {
    static let shared = CurrentPathDeviceActivationCoordinator()

    private let logger = Logger(subsystem: "com.skybridge.SkyBridgeCompassApp", category: "CurrentPathActivation")
    private var lastSuccessfulSyncKey: String?
    private var activeSyncKey: String?

    private init() {}

    func syncIfNeeded(session: AuthSession?) async {
        guard let session,
              !session.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              session.accessToken != "guest_token" else {
            lastSuccessfulSyncKey = nil
            activeSyncKey = nil
            return
        }

        let binding: ProtocolIdentityBinding
        do {
            binding = try await Self.currentPathLocalBinding()
        } catch {
            logger.error("❌ current-path activation skipped: local binding unavailable: \(error.localizedDescription, privacy: .public)")
            return
        }

        let accessToken: String
        do {
            accessToken = try await AuthenticationService.shared.validAccessToken(forceRefresh: false)
                ?? session.accessToken
        } catch {
            logger.error("❌ current-path activation skipped: token refresh failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        let tenantID = Self.deriveTenantIdentifier(accessToken: accessToken)
        guard !tenantID.isEmpty else {
            logger.error("❌ current-path activation skipped: tenant id missing")
            return
        }

        let syncKey = [
            tenantID,
            session.userIdentifier,
            binding.deviceId,
            binding.protocolPublicKeyFingerprint
        ].joined(separator: "|")
        if lastSuccessfulSyncKey == syncKey || activeSyncKey == syncKey {
            return
        }

        activeSyncKey = syncKey
        defer {
            if activeSyncKey == syncKey {
                activeSyncKey = nil
            }
        }

        let clientVersion = Self.resolvedClientVersion()
        let protocolVersion = Self.resolvedProtocolVersion()
        let client = SignalServerClient(
            bearerTokenProvider: { accessToken },
            tenantIDProvider: { tenantID },
            clientVersionProvider: { clientVersion },
            protocolVersionProvider: { protocolVersion }
        )

        do {
            let registered = try await client.registerCurrentDevice(
                binding: binding,
                deviceName: Host.current().localizedName ?? "Mac"
            )
            lastSuccessfulSyncKey = syncKey
            logger.info(
                "✅ current-path device activated: device=\(registered.deviceId, privacy: .public) status=\(registered.status, privacy: .public)"
            )
        } catch {
            logger.error("❌ current-path activation failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func currentPathLocalBinding() async throws -> ProtocolIdentityBinding {
        let algorithm: ProtocolSigningAlgorithm = .ed25519
        let deviceID = try await DeviceIdentityKeyManager.shared.getDeviceId()
        guard !deviceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CurrentPathActivationError.identityNotProvisioned("deviceId")
        }
        let publicKey = try await DeviceIdentityKeyManager.shared.getProtocolSigningPublicKey(for: algorithm)
        guard !publicKey.isEmpty else {
            throw CurrentPathActivationError.identityNotProvisioned("协议签名公钥")
        }
        return try ProtocolIdentityBinding(
            deviceId: deviceID,
            protocolSigningAlgorithm: algorithm,
            protocolPublicKeyBytes: publicKey
        )
    }

    private static func deriveTenantIdentifier(accessToken: String?) -> String {
        let explicit = ProcessInfo.processInfo.environment["SKYBRIDGE_TENANT_ID"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !explicit.isEmpty { return explicit }
        guard let accessToken, !accessToken.isEmpty else { return "" }
        guard let payload = accessToken.split(separator: ".").dropFirst().first else { return "" }
        var base64 = payload.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }
        guard let data = Data(base64Encoded: base64),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ""
        }
        let appMetadata = object["app_metadata"] as? [String: Any]
        let userMetadata = object["user_metadata"] as? [String: Any]
        let candidates: [Any?] = [
            appMetadata?["tenant_id"],
            appMetadata?["tenantId"],
            appMetadata?["org_id"],
            appMetadata?["workspace_id"],
            userMetadata?["tenant_id"],
            userMetadata?["tenantId"],
            userMetadata?["org_id"],
            userMetadata?["workspace_id"],
            object["tenant_id"],
            object["tenantId"],
            object["sub"]
        ]
        for candidate in candidates {
            let value = String(describing: candidate ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty, value != "nil" {
                return value
            }
        }
        return ""
    }

    private static func resolvedClientVersion() -> String {
        if let value = ProcessInfo.processInfo.environment["SKYBRIDGE_CLIENT_VERSION"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return value
        }
        if let value = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return "0.0.0"
    }

    private static func resolvedProtocolVersion() -> String {
        if let value = ProcessInfo.processInfo.environment["SKYBRIDGE_PROTOCOL_VERSION"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return value
        }
        return "1"
    }
}
