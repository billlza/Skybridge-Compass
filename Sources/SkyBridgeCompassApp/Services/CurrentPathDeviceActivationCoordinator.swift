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

    private struct SyncKey: Hashable {
        let tenantID: String
        let userID: String
        let deviceID: String
        let protocolPublicKeyFingerprint: String
    }

    private let logger = Logger(subsystem: "com.skybridge.SkyBridgeCompassApp", category: "CurrentPathActivation")
    private var lastSuccessfulSyncKey: SyncKey?
    private var activeSyncKey: SyncKey?

    private init() {}

    func syncIfNeeded(session: AuthSession?) async {
        guard let session,
              !session.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              session.accessToken != "guest_token" else {
            lastSuccessfulSyncKey = nil
            activeSyncKey = nil
            return
        }

        do {
            _ = try await CurrentPathAuthorityReadinessGate.shared.ensureReady()
        } catch {
            logger.error(
                "❌ current-path activation blocked by pending identity rotation recovery: \(error.localizedDescription, privacy: .public)"
            )
            return
        }

        let binding: ProtocolIdentityBinding
        do {
            binding = try await Self.currentPathLocalBinding()
        } catch {
            logger.error("❌ current-path activation skipped: local binding unavailable: \(error.localizedDescription, privacy: .public)")
            return
        }

        let authenticatedClient: (
            client: SignalServerClient,
            authenticationScope: SignalServerClient.IdentityRotationAuthenticationScope
        )
        do {
            authenticatedClient = try await CrossNetworkConnectionManager
                .makeAuthenticatedSignalServerClientSnapshot()
        } catch {
            logger.error("❌ current-path activation skipped: authenticated scope unavailable: \(error.localizedDescription, privacy: .public)")
            return
        }

        let syncKey = SyncKey(
            tenantID: authenticatedClient.authenticationScope.tenantID,
            userID: authenticatedClient.authenticationScope.userID,
            deviceID: binding.deviceId,
            protocolPublicKeyFingerprint: binding.protocolPublicKeyFingerprint
        )
        if lastSuccessfulSyncKey == syncKey || activeSyncKey == syncKey {
            return
        }

        activeSyncKey = syncKey
        defer {
            if activeSyncKey == syncKey {
                activeSyncKey = nil
            }
        }

        do {
            let registered = try await authenticatedClient.client.registerCurrentDevice(
                binding: binding,
                deviceName: Host.current().localizedName ?? "Mac",
                expectedScope: authenticatedClient.authenticationScope
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
        let identity = try await CommittedLocalProtocolIdentitySnapshot.loadActive()
        let deviceID = try await SelfIdentityProvider.shared
            .snapshotEnsuringProtocolDeviceId(allowCreate: true)
            .deviceId
        guard !deviceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CurrentPathActivationError.identityNotProvisioned("deviceId")
        }
        guard !identity.publicKey.isEmpty else {
            throw CurrentPathActivationError.identityNotProvisioned("协议签名公钥")
        }
        return try ProtocolIdentityBinding(
            deviceId: deviceID,
            protocolSigningAlgorithm: identity.algorithm,
            protocolPublicKeyBytes: identity.publicKey
        )
    }

}
