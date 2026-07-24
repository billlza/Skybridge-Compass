import Foundation
import Testing
import SkyBridgeProtocolCore
@testable import SkyBridgeCore

@Suite("Device identity rotation coordinator")
struct DeviceIdentityRotationCoordinatorTests {
    @Test("Challenge-stage journal round trips with its auth and key scope")
    func requestJournalRoundTrip() throws {
        let oldKey = Data(repeating: 0x21, count: 32)
        let newKey = Data(repeating: 0x43, count: 32)
        let request = PendingDeviceIdentityRotationRequest(
            version: PendingDeviceIdentityRotationRequest.currentVersion,
            requestID: "11111111-2222-4333-8444-555555555555",
            expectedTenantID: "tenant-rotation-test",
            expectedUserID: "user-rotation-test",
            deviceID: "device-rotation-test-0001",
            oldAlgorithm: .ed25519,
            oldProtection: .softwareKeychain,
            oldFingerprint: ProtocolIdentityBinding.computeFingerprint(
                algorithm: .ed25519,
                publicKeyBytes: oldKey
            ),
            oldPublicKey: oldKey,
            newAlgorithm: .ed25519,
            newProtection: .softwareKeychain,
            newFingerprint: ProtocolIdentityBinding.computeFingerprint(
                algorithm: .ed25519,
                publicKeyBytes: newKey
            ),
            newPublicKey: newKey
        )

        let decoded = try JSONDecoder().decode(
            PendingDeviceIdentityRotationRequest.self,
            from: JSONEncoder().encode(request)
        )
        let bindings = try decoded.bindings()

        #expect(decoded.requestID == request.requestID)
        #expect(decoded.expectedTenantID == request.expectedTenantID)
        #expect(decoded.expectedUserID == request.expectedUserID)
        #expect(decoded.authenticationScope
            == SignalServerClient.IdentityRotationAuthenticationScope(
                tenantID: request.expectedTenantID,
                userID: request.expectedUserID
            ))
        #expect(bindings.old.protocolPublicKeyBytes == oldKey)
        #expect(bindings.new.protocolPublicKeyBytes == newKey)
    }

    @Test("Commit-ready journal reconstructs the exact signed transcript")
    func commitJournalRoundTrip() throws {
        let deviceID = "device-rotation-test-0002"
        let oldKey = Data(repeating: 0x12, count: 32)
        let newKey = Data(repeating: 0x34, count: 32)
        let oldIdentity = try ProtocolIdentityBinding(
            deviceId: deviceID,
            protocolSigningAlgorithm: .ed25519,
            protocolPublicKeyBytes: oldKey
        )
        let newIdentity = try ProtocolIdentityBinding(
            deviceId: deviceID,
            protocolSigningAlgorithm: .ed25519,
            protocolPublicKeyBytes: newKey
        )
        let transcript = try DeviceIdentityRotationTranscript(
            rotationID: "11111111-2222-4333-8444-555555555555",
            nonce: Data(0..<32),
            expiresAtMilliseconds: 1_900_000_060_000,
            tenantID: "tenant-rotation-test",
            userID: "user-rotation-test",
            deviceID: deviceID,
            oldGeneration: 4,
            oldIdentity: oldIdentity,
            newIdentity: newIdentity
        )
        let pending = PendingDeviceIdentityRotation(
            version: PendingDeviceIdentityRotation.currentVersion,
            requestID: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            rotationID: transcript.rotationID,
            nonce: transcript.nonce,
            issuedAtMilliseconds: 1_900_000_000_000,
            expiresAtMilliseconds: transcript.expiresAtMilliseconds,
            tenantID: transcript.tenantID,
            userID: transcript.userID,
            deviceID: deviceID,
            oldGeneration: transcript.oldGeneration,
            oldAlgorithm: .ed25519,
            oldProtection: .softwareKeychain,
            oldFingerprint: oldIdentity.protocolPublicKeyFingerprint,
            oldPublicKey: oldKey,
            newAlgorithm: .ed25519,
            newProtection: .softwareKeychain,
            newFingerprint: newIdentity.protocolPublicKeyFingerprint,
            newPublicKey: newKey,
            transcriptHash: transcript.sha256Hex,
            transcriptBase64: transcript.encoded.base64EncodedString(),
            oldSignature: Data(repeating: 0x55, count: 64),
            newSignature: Data(repeating: 0x66, count: 64),
            clientVersion: "1.2.3",
            protocolVersion: "2"
        )

        let decoded = try JSONDecoder().decode(
            PendingDeviceIdentityRotation.self,
            from: JSONEncoder().encode(pending)
        )
        let challenge = try decoded.challenge()

        #expect(challenge.transcript == transcript)
        #expect(challenge.transcript.sha256Hex == pending.transcriptHash)
        #expect(decoded.oldSignature.count == 64)
        #expect(decoded.newSignature.count == 64)
        #expect(decoded.authenticationScope
            == SignalServerClient.IdentityRotationAuthenticationScope(
                tenantID: pending.tenantID,
                userID: pending.userID
            ))
    }

    @Test("Only explicit uncommitted rotation expiry is terminal-cleanable")
    func expiryClassificationIsExact() {
        #expect(SignalServerClient.isUncommittedIdentityRotationExpired(
            SignalServerClient.ClientError.serverRejected(
                410,
                #"{"bodyBytes":32,"error":"rotation_expired"}"#
            )
        ))
        #expect(!SignalServerClient.isUncommittedIdentityRotationExpired(
            SignalServerClient.ClientError.serverRejected(
                503,
                #"{"bodyBytes":32,"error":"rotation_expired"}"#
            )
        ))
        #expect(!SignalServerClient.isUncommittedIdentityRotationExpired(
            SignalServerClient.ClientError.serverRejected(
                410,
                #"{"bodyBytes":32,"error":"rotation_state_conflict"}"#
            )
        ))
    }

    @Test("Coordinator persists each recovery boundary before the next side effect")
    func coordinatorSourceOrdering() throws {
        let source = try String(
            contentsOfFile:
                "Sources/SkyBridgeCore/Settings/CurrentPathDeviceIdentityRotationCoordinator.swift",
            encoding: .utf8
        )
        let complete = try #require(source.range(of: "private func completePendingRequest("))
        let end = try #require(source.range(
            of: "private func commitIdentityRotationPreservingOnlyRecoverableState(",
            range: complete.upperBound..<source.endIndex
        ))
        let body = String(source[complete.lowerBound..<end.lowerBound])

        #expect(try position("journalStore.save(pending)", in: body)
            < position("commitIdentityRotationPreservingOnlyRecoverableState(", in: body))
        #expect(try position("commitIdentityRotationPreservingOnlyRecoverableState(", in: body)
            < position("commitPreparedProtocolIdentityConfiguration(prepared)", in: body))
        #expect(source.contains("requestJournalStore.save(request)"))
        #expect(source.contains("idempotencyKey: request.requestID"))
        #expect(source.contains("currentAuthenticatedIdentityRotationScope()"))
        #expect(source.contains("expectedScope: request.authenticationScope"))
        #expect(source.contains("expectedScope: pending.authenticationScope"))
        #expect(source.contains("validateCommittedAuthorityMatchesPendingNewIdentity(pending)"))
    }

    @Test("Authority readiness gate coalesces concurrent recovery")
    @MainActor
    func authorityReadinessGateCoalescesConcurrentRecovery() async throws {
        let probe = BlockingRotationRecoveryProbe()
        let gate = CurrentPathAuthorityReadinessGate(
            recoverPendingRotation: { await probe.recover() }
        )
        let first = Task { @MainActor in try await gate.ensureReady() }
        let second = Task { @MainActor in try await gate.ensureReady() }
        defer {
            first.cancel()
            second.cancel()
        }

        try await waitForRecoveryCount(1, probe: probe)
        #expect(await probe.recoveryCount() == 1)
        await probe.release()
        #expect(try await first.value)
        #expect(try await second.value)
        #expect(await probe.recoveryCount() == 1)
    }

    private func position(_ needle: String, in source: String) throws -> String.Index {
        try #require(source.range(of: needle)).lowerBound
    }

    @MainActor
    private func waitForRecoveryCount(
        _ expectedCount: Int,
        probe: BlockingRotationRecoveryProbe
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while await probe.recoveryCount() < expectedCount {
            guard clock.now < deadline else {
                throw RotationRecoveryProbeError.timedOut
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private actor BlockingRotationRecoveryProbe {
    private var count = 0
    private var released = false

    func recover() async -> Bool {
        count += 1
        while !released {
            await Task.yield()
        }
        return true
    }

    func recoveryCount() -> Int { count }

    func release() { released = true }
}

private enum RotationRecoveryProbeError: Error {
    case timedOut
}
