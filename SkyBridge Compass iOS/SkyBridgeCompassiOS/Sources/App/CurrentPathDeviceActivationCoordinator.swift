import Foundation
import UIKit

@available(iOS 17.0, *)
enum IOSCurrentPathDeviceActivationError: LocalizedError {
    case authenticationStateChanged

    var errorDescription: String? {
        switch self {
        case .authenticationStateChanged:
            return "登录身份在设备激活期间发生变化，请重新尝试"
        }
    }
}

/// Registers the exact committed protocol identity before settings can rotate it.
/// This is an application-lifecycle adapter; transport authentication and
/// response authority validation remain inside `SignalServerClientCompat`.
@available(iOS 17.0, *)
@MainActor
final class IOSCurrentPathDeviceActivationCoordinator {
    static let shared = IOSCurrentPathDeviceActivationCoordinator()

    private struct InFlightActivation {
        let id: UUID
        let task: Task<Bool, Error>
    }

    private struct InFlightInvalidation {
        let id: UUID
        let task: Task<Void, Never>
    }

    private struct SuccessfulSyncKey: Hashable {
        let tenantID: String
        let userID: String
        let deviceID: String
        let protocolPublicKeyFingerprint: String
    }

    private let signalServer: SignalServerClientCompat
    private let recoverPendingRotation: () async throws -> Bool
    private let loadBinding: () async throws -> ProtocolIdentityBindingCompat
    private let deviceName: () -> String
    private var authenticationGeneration: UInt64 = 0
    private var authenticationPrincipal: CurrentPathAuthenticationPrincipal?
    private var lastSuccessfulSyncKey: SuccessfulSyncKey?
    private var inFlightActivation: InFlightActivation?
    private var inFlightInvalidation: InFlightInvalidation?

    init(
        signalServer: SignalServerClientCompat = SignalServerClientCompat(),
        recoverPendingRotation: @escaping () async throws -> Bool = {
            try await IOSCurrentPathAuthorityReadinessGate.shared.ensureReady()
        },
        loadBinding: @escaping () async throws -> ProtocolIdentityBindingCompat = {
            let snapshot = try await SkyBridgeiOSCore.shared
                .committedActiveProtocolIdentitySnapshot()
            return try ProtocolIdentityBindingCompat(
                deviceId: snapshot.deviceId,
                protocolSigningAlgorithm: snapshot.algorithm,
                protocolPublicKeyBytes: snapshot.publicKey
            )
        },
        deviceName: @escaping () -> String = { UIDevice.current.name }
    ) {
        self.signalServer = signalServer
        self.recoverPendingRotation = recoverPendingRotation
        self.loadBinding = loadBinding
        self.deviceName = deviceName
    }

    func syncIfNeeded(
        authenticationPrincipal requestedPrincipal: CurrentPathAuthenticationPrincipal?
    ) async {
        guard let requestedPrincipal else {
            if authenticationPrincipal != nil {
                authenticationPrincipal = nil
                await invalidateAuthenticationScope()
            } else {
                await waitForInvalidationBarrier()
            }
            return
        }
        do {
            _ = try await activateCurrentIdentityIfNeeded(
                authenticationPrincipal: requestedPrincipal
            )
        } catch is CancellationError {
            return
        } catch IOSCurrentPathDeviceActivationError.authenticationStateChanged {
            return
        } catch {
            SkyBridgeLogger.shared.error(
                "Current-path device activation failed: \(error.localizedDescription)"
            )
        }
    }

    @discardableResult
    func activateCurrentIdentityIfNeeded(
        authenticationPrincipal requestedPrincipal: CurrentPathAuthenticationPrincipal
    ) async throws -> Bool {
        if authenticationPrincipal != requestedPrincipal {
            authenticationPrincipal = requestedPrincipal
            await invalidateAuthenticationScope()
        } else {
            await waitForInvalidationBarrier()
        }
        try Task.checkCancellation()
        guard authenticationPrincipal == requestedPrincipal else {
            throw IOSCurrentPathDeviceActivationError.authenticationStateChanged
        }
        if let inFlightActivation {
            return try await inFlightActivation.task.value
        }
        let activationID = UUID()
        let expectedGeneration = authenticationGeneration
        let task = Task { @MainActor [weak self] in
            guard let self else {
                throw IOSCurrentPathDeviceActivationError.authenticationStateChanged
            }
            return try await self.performActivation(
                expectedAuthenticationGeneration: expectedGeneration,
                expectedPrincipal: requestedPrincipal
            )
        }
        inFlightActivation = InFlightActivation(id: activationID, task: task)
        defer {
            if inFlightActivation?.id == activationID {
                inFlightActivation = nil
            }
        }
        return try await task.value
    }

    func resetAuthenticationScope() async {
        authenticationPrincipal = nil
        await invalidateAuthenticationScope()
    }

    private func invalidateAuthenticationScope() async {
        authenticationGeneration += 1
        lastSuccessfulSyncKey = nil
        let cancelledTask = inFlightActivation?.task
        cancelledTask?.cancel()
        inFlightActivation = nil
        let previousBarrier = inFlightInvalidation?.task
        guard previousBarrier != nil || cancelledTask != nil else { return }
        let invalidationID = UUID()
        let barrier = Task { @MainActor in
            if let previousBarrier {
                await previousBarrier.value
            }
            if let cancelledTask {
                _ = await cancelledTask.result
            }
        }
        inFlightInvalidation = InFlightInvalidation(
            id: invalidationID,
            task: barrier
        )
        await barrier.value
        if inFlightInvalidation?.id == invalidationID {
            inFlightInvalidation = nil
        }
    }

    private func waitForInvalidationBarrier() async {
        while let invalidation = inFlightInvalidation {
            await invalidation.task.value
            if inFlightInvalidation?.id == invalidation.id {
                inFlightInvalidation = nil
            }
        }
    }

    private func performActivation(
        expectedAuthenticationGeneration: UInt64,
        expectedPrincipal: CurrentPathAuthenticationPrincipal
    ) async throws -> Bool {
        try validateAuthenticationGeneration(expectedAuthenticationGeneration)
        _ = try await recoverPendingRotation()
        try validateAuthenticationGeneration(expectedAuthenticationGeneration)
        let binding = try await loadBinding()
        try validateAuthenticationGeneration(expectedAuthenticationGeneration)
        let syncKey = SuccessfulSyncKey(
            tenantID: expectedPrincipal.tenantID,
            userID: expectedPrincipal.userID,
            deviceID: binding.deviceId,
            protocolPublicKeyFingerprint: binding.protocolPublicKeyFingerprint
        )
        if lastSuccessfulSyncKey == syncKey {
            return false
        }
        try validateAuthenticationGeneration(expectedAuthenticationGeneration)
        let registered = try await signalServer.registerCurrentDevice(
            binding: binding,
            deviceName: deviceName(),
            expectedScope: SignalServerClientCompat.IdentityRotationAuthenticationScope(
                tenantID: expectedPrincipal.tenantID,
                userID: expectedPrincipal.userID
            )
        )
        try validateAuthenticationGeneration(expectedAuthenticationGeneration)
        guard registered.tenantID == expectedPrincipal.tenantID,
              registered.userID == expectedPrincipal.userID else {
            throw IOSCurrentPathDeviceActivationError.authenticationStateChanged
        }
        lastSuccessfulSyncKey = syncKey
        SkyBridgeLogger.shared.info(
            "Current-path device activated with the committed protocol authority"
        )
        return true
    }

    private func validateAuthenticationGeneration(_ expected: UInt64) throws {
        try Task.checkCancellation()
        guard authenticationGeneration == expected else {
            throw IOSCurrentPathDeviceActivationError.authenticationStateChanged
        }
    }
}
