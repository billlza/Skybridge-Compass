import Foundation
import CryptoKit
import SkyBridgeProtocolCore

extension P2PDiscoveryService {
    nonisolated static var protocolIdentityLogRedaction: String { "<redacted>" }

    nonisolated static func normalizeInboundControlFrame(_ payload: Data) -> Data {
        let trafficUnwrapped = TrafficPadding.unwrapIfNeeded(payload, label: "rx")
        return HandshakePadding.unwrapIfNeeded(trafficUnwrapped, label: "rx")
    }

    struct PreparedInboundHandshakeFrame {
        let messageA: HandshakeMessageA
        let localSOAPeerId: Data
    }

    /// Bootstrap control frames are intentionally rejected by this preparer
    /// without invoking the SOA loader. Only a successfully decoded MessageA
    /// may require the committed local SOA identity.
    nonisolated static func prepareInboundHandshakeFrame(
        _ frame: Data,
        cachedLocalSOAPeerId: Data?,
        loadLocalSOAPeerId: () async throws -> Data
    ) async throws -> PreparedInboundHandshakeFrame? {
        guard let messageA = try? HandshakeMessageA.decode(from: frame) else {
            return nil
        }
        let localSOAPeerId: Data
        if let cachedLocalSOAPeerId {
            localSOAPeerId = cachedLocalSOAPeerId
        } else {
            localSOAPeerId = try await loadLocalSOAPeerId()
        }
        return PreparedInboundHandshakeFrame(
            messageA: messageA,
            localSOAPeerId: localSOAPeerId
        )
    }

    nonisolated static func isLikelyHandshakeControlFrame(_ data: Data) -> Bool {
        if (try? HandshakeFinished.decode(from: data)) != nil { return true }
        if (try? HandshakeMessageA.decode(from: data)) != nil { return true }
        if (try? HandshakeMessageB.decode(from: data)) != nil { return true }
        return false
    }

    struct BootstrapControlResponse: Sendable {
        enum Kind: Sendable {
            case signedKEMRefreshServed
            case signedKEMRefreshRejected
            case protocolIdentityBindingServed
            case protocolIdentityBindingConfirmed
            case protocolIdentityBindingRejected
        }

        let kind: Kind
        let message: AppMessage
        let statusLine: String
        let protocolIdentityBindingRequest: AppMessage.ProtocolIdentityBindingRequestPayload?
        let protocolIdentityBindingPayload: AppMessage.SignedProtocolIdentityBindingPayload?
        let protocolIdentityBindingCode: String?

        var isFailure: Bool {
            switch kind {
            case .signedKEMRefreshRejected, .protocolIdentityBindingRejected:
                return true
            case .signedKEMRefreshServed, .protocolIdentityBindingServed, .protocolIdentityBindingConfirmed:
                return false
            }
        }
    }

    nonisolated static func makeBootstrapControlResponse(
        for plaintextControl: AppMessage
    ) async -> BootstrapControlResponse? {
        await makeBootstrapControlResponse(
            for: plaintextControl,
            makeSignedKEMRefreshPayload: { request in
                try await Self.makeSignedKEMRefreshPayload(for: request)
            },
            makeSignedProtocolIdentityBindingPayload: { request in
                try await Self.makeSignedProtocolIdentityBindingPayload(for: request)
            }
        )
    }

    nonisolated static func makeBootstrapControlResponse(
        for plaintextControl: AppMessage,
        makeSignedKEMRefreshPayload: (AppMessage.KEMRefreshRequestPayload) async throws -> AppMessage.SignedKEMRefreshPayload,
        makeSignedProtocolIdentityBindingPayload: (AppMessage.ProtocolIdentityBindingRequestPayload) async throws -> AppMessage.SignedProtocolIdentityBindingPayload
    ) async -> BootstrapControlResponse? {
        await makeBootstrapControlResponse(
            for: plaintextControl,
            makeSignedKEMRefreshPayload: makeSignedKEMRefreshPayload,
            makeSignedProtocolIdentityBindingPayload: makeSignedProtocolIdentityBindingPayload,
            finalizeProtocolIdentityBinding: { confirm in
                try await Self.finalizeProtocolIdentityBinding(confirm)
            }
        )
    }

    nonisolated static func makeBootstrapControlResponse(
        for plaintextControl: AppMessage,
        makeSignedKEMRefreshPayload: (AppMessage.KEMRefreshRequestPayload) async throws -> AppMessage.SignedKEMRefreshPayload,
        makeSignedProtocolIdentityBindingPayload: (AppMessage.ProtocolIdentityBindingRequestPayload) async throws -> AppMessage.SignedProtocolIdentityBindingPayload,
        finalizeProtocolIdentityBinding: (AppMessage.ProtocolIdentityBindingConfirmPayload) async throws -> AppMessage.SignedProtocolIdentityBindingFinalAckPayload
    ) async -> BootstrapControlResponse? {
        switch plaintextControl {
        case .kemRefreshRequest(let request):
            let responseStartedAt = Date()
            let requestHashHex = request.canonicalRequestHashHexIfRepresentable
            do {
                let refresh = try await makeSignedKEMRefreshPayload(request)
                guard let requestHashHex,
                      let requestReference = P2PEvidenceReference.requestHash(requestHashHex) else {
                    throw AppMessage.KEMRefreshValidationError.requestHashMismatch
                }
                let payloadHashHex = SHA256.hash(data: refresh.signaturePreimage)
                    .map { String(format: "%02x", $0) }
                    .joined()
                guard let payloadReference = P2PEvidenceReference.payloadHash(payloadHashHex) else {
                    throw AppMessage.KEMRefreshValidationError.requestHashMismatch
                }
                let responderLatencyMs = Date().timeIntervalSince(responseStartedAt) * 1_000.0
                let statusLine = String(
                    format: "🔐 SKR-1 signed LAN KEM refresh served: requester=%@ target=%@ skr_ref=%@ payload_ref=%@ keyId=%@ generation=%llu suites=%@ wireId=%@ responderLatencyMs=%.1f lifecycle=request>served",
                    Self.protocolIdentityLogRedaction,
                    Self.protocolIdentityLogRedaction,
                    requestReference,
                    payloadReference,
                    Self.protocolIdentityLogRedaction,
                    refresh.generation,
                    refresh.kemPublicKeys.map { String(format: "0x%04X", $0.suiteWireId) }.joined(separator: ","),
                    refresh.kemPublicKeys.map { String(format: "0x%04X", $0.suiteWireId) }.joined(separator: ","),
                    responderLatencyMs
                )
                return BootstrapControlResponse(
                    kind: .signedKEMRefreshServed,
                    message: .signedKEMRefresh(refresh),
                    statusLine: statusLine,
                    protocolIdentityBindingRequest: nil,
                    protocolIdentityBindingPayload: nil,
                    protocolIdentityBindingCode: nil
                )
            } catch {
                let responderLatencyMs = Date().timeIntervalSince(responseStartedAt) * 1_000.0
                let reasonCode = Self.signedKEMRefreshFailureCode(for: error)
                let failure = AppMessage.KEMRefreshFailurePayload(
                    requesterDeviceId: request.requesterDeviceId,
                    targetDeviceId: request.targetDeviceId,
                    stage: "kem_refresh",
                    reasonCode: reasonCode,
                    reason: reasonCode,
                    requestHashHex: requestHashHex
                )
                let statusLine = String(
                    format: "⛔️ SKR-1 signed LAN KEM refresh rejected: requester=%@ target=%@ reasonCode=%@ reason=%@ responderLatencyMs=%.1f lifecycle=request>rejected",
                    Self.protocolIdentityLogRedaction,
                    Self.protocolIdentityLogRedaction,
                    failure.reasonCode,
                    Self.protocolIdentityLogRedaction,
                    responderLatencyMs
                )
                return BootstrapControlResponse(
                    kind: .signedKEMRefreshRejected,
                    message: .kemRefreshFailure(failure),
                    statusLine: statusLine,
                    protocolIdentityBindingRequest: nil,
                    protocolIdentityBindingPayload: nil,
                    protocolIdentityBindingCode: nil
                )
            }

        case .protocolIdentityBindingRequest(let request):
            let requestHashHex = request.canonicalRequestHashHexIfRepresentable
            do {
                let binding = try await makeSignedProtocolIdentityBindingPayload(request)
                let code = binding.shortAuthenticationCode(request: request)
                let transactionReference = P2PEvidenceReference.transaction(request.transactionId)
                let statusLine = "🔐 PIB-1 protocol identity binding served: requester=\(Self.protocolIdentityLogRedaction) target=\(Self.protocolIdentityLogRedaction) pib_ref=\(transactionReference) fingerprint=\(Self.protocolIdentityLogRedaction) code=\(Self.protocolIdentityLogRedaction) lifecycle=identity-oob>served"
                return BootstrapControlResponse(
                    kind: .protocolIdentityBindingServed,
                    message: .signedProtocolIdentityBinding(binding),
                    statusLine: statusLine,
                    protocolIdentityBindingRequest: request,
                    protocolIdentityBindingPayload: binding,
                    protocolIdentityBindingCode: code
                )
            } catch {
                let reasonCode = Self.protocolIdentityBindingFailureCode(for: error)
                let failure = AppMessage.KEMRefreshFailurePayload(
                    requesterDeviceId: request.requesterDeviceId,
                    targetDeviceId: request.targetDeviceId,
                    stage: "identity_binding",
                    reasonCode: reasonCode,
                    reason: reasonCode,
                    requestHashHex: requestHashHex
                )
                let statusLine = "⛔️ PIB-1 protocol identity binding rejected: requester=\(Self.protocolIdentityLogRedaction) target=\(Self.protocolIdentityLogRedaction) reasonCode=\(failure.reasonCode) reason=\(Self.protocolIdentityLogRedaction) lifecycle=identity-oob>rejected"
                return BootstrapControlResponse(
                    kind: .protocolIdentityBindingRejected,
                    message: .kemRefreshFailure(failure),
                    statusLine: statusLine,
                    protocolIdentityBindingRequest: nil,
                    protocolIdentityBindingPayload: nil,
                    protocolIdentityBindingCode: nil
                )
            }

        case .protocolIdentityBindingConfirm(let confirm):
            do {
                let ack = try await finalizeProtocolIdentityBinding(confirm)
                let transactionReference = P2PEvidenceReference.transaction(confirm.transactionId)
                return BootstrapControlResponse(
                    kind: .protocolIdentityBindingConfirmed,
                    message: .signedProtocolIdentityBindingFinalAck(ack),
                    statusLine: "🔐 PIB-1 v3 confirmation committed and acknowledged pib_ref=\(transactionReference) lifecycle=identity-oob>confirmed",
                    protocolIdentityBindingRequest: nil,
                    protocolIdentityBindingPayload: nil,
                    protocolIdentityBindingCode: nil
                )
            } catch {
                let reasonCode = Self.protocolIdentityBindingFailureCode(for: error)
                let failure = AppMessage.KEMRefreshFailurePayload(
                    requesterDeviceId: confirm.requesterDeviceId,
                    targetDeviceId: confirm.responderDeviceId,
                    stage: "identity_binding_confirm",
                    reasonCode: reasonCode,
                    reason: reasonCode,
                    requestHashHex: confirm.requestHashHex
                )
                return BootstrapControlResponse(
                    kind: .protocolIdentityBindingRejected,
                    message: .kemRefreshFailure(failure),
                    statusLine: "⛔️ PIB-1 v3 confirmation rejected reasonCode=\(failure.reasonCode) lifecycle=identity-oob>confirm-rejected",
                    protocolIdentityBindingRequest: nil,
                    protocolIdentityBindingPayload: nil,
                    protocolIdentityBindingCode: nil
                )
            }

        default:
            return nil
        }
    }

    nonisolated static func shouldRestartInboundHandshakeForRekey(
        state: HandshakeState,
        frame: Data
    ) -> Bool {
        switch state {
        case .waitingFinished, .established:
            return (try? HandshakeMessageA.decode(from: frame)) != nil
        default:
            return false
        }
    }

    nonisolated static func makeSignedKEMRefreshPayload(
        for request: AppMessage.KEMRefreshRequestPayload,
        keyManager: DeviceIdentityKeyManager = .shared
    ) async throws -> AppMessage.SignedKEMRefreshPayload {
        try await makeSignedKEMRefreshPayload(
            for: request,
            keyManager: keyManager,
            loadLocalIdentities: {
                guard let preferred = try await CommittedLocalProtocolIdentitySnapshot.loadPreferred(
                    matchingAuthoritativeFingerprint: request.targetProtocolIdentityFingerprint,
                    keyManager: keyManager
                ) else {
                    return []
                }
                return [preferred]
            }
        )
    }

    /// Core responder path with an explicit immutable identity snapshot
    /// boundary. The production entry point above resolves the committed
    /// configuration; focused integrations can supply the exact authority they
    /// established without mutating process-global settings.
    nonisolated static func makeSignedKEMRefreshPayload(
        for request: AppMessage.KEMRefreshRequestPayload,
        keyManager: DeviceIdentityKeyManager,
        loadLocalIdentities: @Sendable () async throws -> [CommittedLocalProtocolIdentitySnapshot]
    ) async throws -> AppMessage.SignedKEMRefreshPayload {
        try Task.checkCancellation()
        let requestedSuites: [CryptoSuite]
        do {
            requestedSuites = try request.validatedStrictResponderSuites()
        } catch {
            throw makeSKRFailure(error.localizedDescription)
        }
        guard let requestHashHex = request.canonicalRequestHashHexIfRepresentable else {
            throw makeSKRFailure("request timestamp is not representable as canonical milliseconds")
        }
        guard request.requesterProtocolIdentityFingerprint != nil else {
            throw makeSKRFailure("requester protocol identity fingerprint missing")
        }
        guard let requesterFingerprint = normalizedSKRFingerprint(request.requesterProtocolIdentityFingerprint) else {
            throw makeSKRFailure("requester protocol identity fingerprint invalid")
        }
        let targetFingerprint = normalizedSKRFingerprint(request.targetProtocolIdentityFingerprint)
        if request.targetProtocolIdentityFingerprint != nil, targetFingerprint == nil {
            throw makeSKRFailure("target protocol identity fingerprint invalid")
        }

        let requesterPins = await PeerProtocolIdentityBootstrapStore.shared.trustedFingerprints(
            forCandidates: signedKEMRefreshDeviceIdCandidates(request.requesterDeviceId)
        )
        try Task.checkCancellation()
        guard requesterPins.contains(requesterFingerprint) else {
            throw makeSKRFailure("requester protocol identity fingerprint not pinned")
        }

        let admissionGate = SignedKEMRefreshRequestAdmissionGate.shared
        if let cached = await admissionGate.cachedCompletedResponse(
            requestHashHex: requestHashHex,
            requesterDeviceId: request.requesterDeviceId,
            requesterFingerprint: requesterFingerprint
        ) {
            return cached
        }
        let admission = await admissionGate.admit(
            requestHashHex: requestHashHex,
            requesterDeviceId: request.requesterDeviceId,
            requesterFingerprint: requesterFingerprint
        )
        switch admission {
        case .allowed:
            break
        case .replay:
            throw makeSKRFailure("request replay detected")
        case .rateLimited:
            throw makeSKRFailure("requester rate limited")
        }

        let localIdentities: [CommittedLocalProtocolIdentitySnapshot]
        do {
            localIdentities = try await loadLocalIdentities()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            SkyBridgeLogger.p2p.error(
                "SKR-1 responder local identity load failed: code=local_protocol_identity_unavailable errorClass=\(String(reflecting: Swift.type(of: error)), privacy: .public) detail=\(error.localizedDescription, privacy: .private)"
            )
            throw makeSKRFailure("local protocol identity unavailable")
        }
        let selectedIdentity = localIdentities.first { identity in
            targetFingerprint == nil
                || targetFingerprint == identity.authoritativeFingerprint
        }
        guard let selectedIdentity else {
            throw makeSKRFailure("target protocol identity fingerprint mismatch")
        }

        let provider = CryptoProviderFactory.makeInboundPQCResponderProvider(
            policy: .requirePQC,
            peerSupportedSuites: requestedSuites
        )
        let rawKEMKeys: [KEMPublicKeyInfo]
        do {
            rawKEMKeys = try await keyManager.pairingIdentityKEMPublicKeys(
                using: provider,
                limitingTo: requestedSuites
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            SkyBridgeLogger.p2p.error(
                "SKR-1 responder KEM material load failed: code=local_pqc_kem_unavailable errorClass=\(String(reflecting: Swift.type(of: error)), privacy: .public) detail=\(error.localizedDescription, privacy: .private)"
            )
            throw makeSKRFailure("local PQC KEM material unavailable")
        }
        let requestedWireIds = Set(requestedSuites.map(\.wireId))
        let kemKeys = KEMPublicKeyInfo.normalizedValidKeys(rawKEMKeys).filter { key in
            requestedWireIds.contains(key.suiteWireId)
        }
        guard !kemKeys.isEmpty else {
            throw makeSKRFailure("no requested PQC KEM public key available")
        }

        let localIdRaw: String
        do {
            localIdRaw = try await SelfIdentityProvider.shared
                .existingProtocolIdentityDeviceIdReadOnly()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            SkyBridgeLogger.p2p.error(
                "SKR-1 responder local device identity load failed: code=local_device_id_unavailable errorClass=\(String(reflecting: Swift.type(of: error)), privacy: .public) detail=\(error.localizedDescription, privacy: .private)"
            )
            throw makeSKRFailure("local device id unavailable")
        }
        let localId = localIdRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !localId.isEmpty else {
            throw makeSKRFailure("local device id unavailable")
        }

        let now = Date()
        let generation = UInt64(max(0, (now.timeIntervalSince1970 * 1000.0).rounded(.down)))
        let keyId = signedKEMRefreshKeyId(
            protocolFingerprint: selectedIdentity.authoritativeFingerprint,
            kemPublicKeys: kemKeys
        )
        let aliases = PeerTrustLookup.lookupCandidates(for: localId)
        let unsigned = AppMessage.SignedKEMRefreshPayload(
            deviceId: localId,
            aliases: aliases,
            protocolSigningAlgorithm: selectedIdentity.algorithm.rawValue,
            protocolIdentityPublicKey: selectedIdentity.publicKey,
            protocolIdentityFingerprint: selectedIdentity.authoritativeFingerprint,
            kemPublicKeys: kemKeys,
            keyId: keyId,
            generation: generation,
            sentAt: now,
            expiresAt: now.addingTimeInterval(300),
            requestNonce: request.nonce,
            requestHashHex: requestHashHex,
            policyRequirePQC: true,
            policyAllowClassicFallback: false,
            routeScope: "lan",
            bonjourEndpointDigest: request.bonjourEndpointDigest,
            signature: Data()
        )
        let signatureProvider = ProtocolSignatureProviderSelector.select(for: selectedIdentity.algorithm)
        let signature: Data
        do {
            signature = try await signatureProvider.sign(
                unsigned.signaturePreimage,
                key: selectedIdentity.keyHandle
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            SkyBridgeLogger.p2p.error(
                "SKR-1 responder signing failed: code=local_protocol_identity_signing_unavailable errorClass=\(String(reflecting: Swift.type(of: error)), privacy: .public) detail=\(error.localizedDescription, privacy: .private)"
            )
            throw makeSKRFailure("local protocol identity signing unavailable")
        }
        try Task.checkCancellation()
        let response = AppMessage.SignedKEMRefreshPayload(
            deviceId: unsigned.deviceId,
            aliases: unsigned.aliases,
            protocolSigningAlgorithm: unsigned.protocolSigningAlgorithm,
            protocolIdentityPublicKey: unsigned.protocolIdentityPublicKey,
            protocolIdentityFingerprint: unsigned.protocolIdentityFingerprint,
            kemPublicKeys: unsigned.kemPublicKeys,
            keyId: unsigned.keyId,
            generation: unsigned.generation,
            sentAt: unsigned.sentAt,
            expiresAt: unsigned.expiresAt,
            requestNonce: unsigned.requestNonce,
            requestHashHex: unsigned.requestHashHex,
            policyRequirePQC: unsigned.policyRequirePQC,
            policyAllowClassicFallback: unsigned.policyAllowClassicFallback,
            routeScope: unsigned.routeScope,
            bonjourEndpointDigest: unsigned.bonjourEndpointDigest,
            signature: signature
        )
        await admissionGate.recordCompletedResponse(
            response,
            requestHashHex: requestHashHex,
            requesterDeviceId: request.requesterDeviceId,
            requesterFingerprint: requesterFingerprint
        )
        try Task.checkCancellation()
        return response
    }

    nonisolated private static func makeSKRFailure(_ reason: String) -> NSError {
        NSError(
            domain: "SkyBridge.SignedLANRefresh",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: reason]
        )
    }

    nonisolated static func makeSignedProtocolIdentityBindingPayload(
        for request: AppMessage.ProtocolIdentityBindingRequestPayload
    ) async throws -> AppMessage.SignedProtocolIdentityBindingPayload {
        try Task.checkCancellation()
        let requestValidationNow = Date()
        guard request.version == AppMessage.ProtocolIdentityBindingRequestPayload.currentVersion else {
            throw makePIBFailure("invalid request version")
        }
        guard let requestHashHex = request.canonicalRequestHashHexIfRepresentable else {
            throw makePIBFailure("request timestamp is not representable as canonical milliseconds")
        }
        guard request.policyRequirePQC, !request.policyAllowClassicFallback else {
            throw makePIBFailure("policy mismatch")
        }
        guard request.routeScope.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "lan" else {
            throw makePIBFailure("invalid route scope")
        }
        guard request.nonce.count >= 16 else {
            throw makePIBFailure("invalid request nonce")
        }
        guard request.sentAt.timeIntervalSince(requestValidationNow)
                <= P2PProtocolIdentityBindingAdmissionPolicy
                    .maximumRequestFutureSkewSeconds else {
            throw makePIBFailure("request timestamp is too far in the future")
        }
        guard requestValidationNow.timeIntervalSince(request.sentAt)
                <= P2PProtocolIdentityBindingAdmissionPolicy.maximumRequestAgeSeconds else {
            throw makePIBFailure("request timestamp is expired")
        }
        let requestedAlgorithms: Set<ProtocolSigningAlgorithm>
        do {
            requestedAlgorithms = Set(try request.validatedRequestedProtocolSigningAlgorithms())
        } catch {
            throw makePIBFailure(error.localizedDescription)
        }
        let requesterIdentity = try request.validatedRequesterProtocolIdentity()
        guard let requesterAlgorithm = requesterIdentity.normalizedAlgorithm,
              requesterIdentity.authoritativeFingerprint != nil,
              let requesterSignature = request.requesterSignature,
              !requesterSignature.isEmpty else {
            throw makePIBFailure("requester protocol identity proof invalid")
        }
        let requesterSignatureProvider = ProtocolSignatureProviderSelector.select(for: requesterAlgorithm)
        let requesterSignatureVerified = try await requesterSignatureProvider.verify(
            request.canonicalPreimage,
            signature: requesterSignature,
            publicKey: requesterIdentity.publicKey
        )
        try Task.checkCancellation()
        guard requesterSignatureVerified else {
            throw makePIBFailure("requester protocol identity signature invalid")
        }

        let selectedIdentity = try await CommittedLocalProtocolIdentitySnapshot.loadPreferred(
            matching: requestedAlgorithms
        )
        try Task.checkCancellation()
        guard let selectedIdentity else {
            throw makePIBFailure("local protocol identity unavailable")
        }

        let localIdRaw = try await SelfIdentityProvider.shared
            .existingProtocolIdentityDeviceIdReadOnly()
        try Task.checkCancellation()
        let localId = localIdRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !localId.isEmpty else {
            throw makePIBFailure("local device id unavailable")
        }
        let localAliases = PeerTrustLookup.lookupCandidates(for: localId)
        guard Self.localResponderMatchesProtocolIdentityBindingTarget(
            targetDeviceId: request.targetDeviceId,
            localId: localId,
            aliases: localAliases
        ) else {
            throw makePIBFailure("request target does not identify local responder")
        }

        let now = Date()
        let localPresentation = LocalDevicePresentation.current()
        let unsigned = AppMessage.SignedProtocolIdentityBindingPayload(
            transactionId: request.transactionId,
            deviceId: localId,
            aliases: localAliases,
            protocolSigningAlgorithm: selectedIdentity.algorithm.rawValue,
            protocolIdentityPublicKey: selectedIdentity.publicKey,
            protocolIdentityFingerprint: selectedIdentity.authoritativeFingerprint,
            deviceName: localPresentation.deviceName,
            sentAt: now,
            expiresAt: now.addingTimeInterval(
                P2PProtocolIdentityBindingAdmissionPolicy.maximumTransactionTTLSeconds
            ),
            requestNonce: request.nonce,
            requestHashHex: requestHashHex,
            policyRequirePQC: true,
            policyAllowClassicFallback: false,
            routeScope: "lan",
            bonjourEndpointDigest: request.bonjourEndpointDigest,
            signature: Data()
        )
        let signatureProvider = ProtocolSignatureProviderSelector.select(for: selectedIdentity.algorithm)
        let signature = try await signatureProvider.sign(unsigned.signaturePreimage, key: selectedIdentity.keyHandle)
        try Task.checkCancellation()
        let signed = AppMessage.SignedProtocolIdentityBindingPayload(
            transactionId: unsigned.transactionId,
            deviceId: unsigned.deviceId,
            aliases: unsigned.aliases,
            protocolSigningAlgorithm: unsigned.protocolSigningAlgorithm,
            protocolIdentityPublicKey: unsigned.protocolIdentityPublicKey,
            protocolIdentityFingerprint: unsigned.protocolIdentityFingerprint,
            deviceName: unsigned.deviceName,
            sentAt: unsigned.sentAt,
            expiresAt: unsigned.expiresAt,
            requestNonce: unsigned.requestNonce,
            requestHashHex: unsigned.requestHashHex,
            policyRequirePQC: unsigned.policyRequirePQC,
            policyAllowClassicFallback: unsigned.policyAllowClassicFallback,
            routeScope: unsigned.routeScope,
            bonjourEndpointDigest: unsigned.bonjourEndpointDigest,
            signature: signature
        )
        let registered = try await ProtocolIdentityBindingTransactionStore.shared.register(
            request: request,
            candidate: signed,
            responderKeyHandle: selectedIdentity.keyHandle
        )
        try Task.checkCancellation()
        return registered
    }

    nonisolated static func finalizeProtocolIdentityBinding(
        _ confirm: AppMessage.ProtocolIdentityBindingConfirmPayload
    ) async throws -> AppMessage.SignedProtocolIdentityBindingFinalAckPayload {
        try Task.checkCancellation()
        return try await ProtocolIdentityBindingTransactionStore.shared.resolveConfirmation(confirm) { context in
            try Task.checkCancellation()
            let request = context.request
            let candidate = context.candidate
            let validatedConfirm = try confirm.validatedForCandidate(request: request, candidate: candidate)
            let requesterIdentity = try request.validatedRequesterProtocolIdentity()
            guard let requesterAlgorithm = requesterIdentity.normalizedAlgorithm,
                  let requesterFingerprint = requesterIdentity.authoritativeFingerprint?.lowercased() else {
                throw makePIBFailure("requester protocol identity proof invalid")
            }
            let requesterVerifier = ProtocolSignatureProviderSelector.select(for: requesterAlgorithm)
            guard try await requesterVerifier.verify(
                validatedConfirm.signaturePreimage,
                signature: validatedConfirm.requesterSignature,
                publicKey: requesterIdentity.publicKey
            ) else {
                throw makePIBFailure("requester confirmation signature invalid")
            }
            try Task.checkCancellation()

            guard let responderAlgorithm = ProtocolSigningAlgorithm(rawValue: candidate.protocolSigningAlgorithm) else {
                throw makePIBFailure("invalid responder signature algorithm")
            }
            let approval = await PairingTrustApprovalService.shared.stageProtocolIdentityBindingRequesterApproval(
                peerEndpoint: request.bonjourEndpointDigest ?? "lan",
                requesterDeviceIds: signedKEMRefreshDeviceIdCandidates(request.requesterDeviceId),
                displayName: request.requesterDeviceId,
                model: nil,
                platform: nil,
                osVersion: nil,
                verificationCode: candidate.shortAuthenticationCode(request: request),
                requesterProtocolSigningAlgorithm: requesterAlgorithm,
                requesterProtocolIdentityFingerprint: requesterFingerprint,
                requesterProtocolIdentityPublicKey: requesterIdentity.publicKey,
                transactionId: request.transactionId,
                requestHashHex: request.canonicalRequestHashHex,
                candidateHashHex: candidate.canonicalCandidateHashHex,
                sasTranscriptHashHex: candidate.sasTranscriptHashHex(request: request)
            )
            try Task.checkCancellation()
            guard approval != .reject else {
                throw makePIBFailure("operator rejected requester protocol identity confirmation")
            }

            // The operator can spend up to 180 seconds comparing SAS. Recheck
            // both signed phase-one frames after that wait; an expired
            // candidate/confirm must never lead to a pin or a final ACK.
            let postApprovalNow = Date()
            _ = try candidate.validatedForOOBBinding(request: request, now: postApprovalNow)
            _ = try validatedConfirm.validatedForCandidate(
                request: request,
                candidate: candidate,
                now: postApprovalNow
            )
            guard let responderKey = context.responderKeyHandle else {
                throw makePIBFailure("responder signing key context unavailable")
            }
            let unsignedAck = AppMessage.SignedProtocolIdentityBindingFinalAckPayload(
                transactionId: request.transactionId,
                requesterDeviceId: request.requesterDeviceId,
                responderDeviceId: candidate.deviceId,
                requesterProtocolIdentityFingerprint: requesterFingerprint,
                responderProtocolIdentityFingerprint: candidate.protocolIdentityFingerprint,
                requestNonce: request.nonce,
                confirmationNonce: validatedConfirm.confirmationNonce,
                requestHashHex: request.canonicalRequestHashHex,
                candidateHashHex: candidate.canonicalCandidateHashHex,
                sasTranscriptHashHex: candidate.sasTranscriptHashHex(request: request),
                confirmHashHex: validatedConfirm.canonicalConfirmHashHex,
                accepted: true,
                sentAt: postApprovalNow,
                expiresAt: P2PProtocolIdentityBindingAdmissionPolicy
                    .boundedChildExpiry(
                        parentExpiry: validatedConfirm.expiresAt,
                        issuedAt: postApprovalNow
                ),
                responderSignature: Data()
            )
            let responderSigner = ProtocolSignatureProviderSelector.select(for: responderAlgorithm)
            let ackSignature = try await responderSigner.sign(
                unsignedAck.signaturePreimage,
                key: responderKey
            )
            try Task.checkCancellation()
            let signedAck = AppMessage.SignedProtocolIdentityBindingFinalAckPayload(
                transactionId: unsignedAck.transactionId,
                requesterDeviceId: unsignedAck.requesterDeviceId,
                responderDeviceId: unsignedAck.responderDeviceId,
                requesterProtocolIdentityFingerprint: unsignedAck.requesterProtocolIdentityFingerprint,
                responderProtocolIdentityFingerprint: unsignedAck.responderProtocolIdentityFingerprint,
                requestNonce: unsignedAck.requestNonce,
                confirmationNonce: unsignedAck.confirmationNonce,
                requestHashHex: unsignedAck.requestHashHex,
                candidateHashHex: unsignedAck.candidateHashHex,
                sasTranscriptHashHex: unsignedAck.sasTranscriptHashHex,
                confirmHashHex: unsignedAck.confirmHashHex,
                accepted: true,
                sentAt: unsignedAck.sentAt,
                expiresAt: unsignedAck.expiresAt,
                responderSignature: ackSignature
            )

            // Signing can cross an expiry boundary. Validate once more before
            // committing authoritative trust; this is the last reversible
            // point before the responder pin is installed.
            let commitNow = Date()
            _ = try candidate.validatedForOOBBinding(request: request, now: commitNow)
            _ = try validatedConfirm.validatedForCandidate(
                request: request,
                candidate: candidate,
                now: commitNow
            )
            _ = try signedAck.validatedForFinalization(
                request: request,
                candidate: candidate,
                confirm: validatedConfirm,
                now: commitNow
            )
            try Task.checkCancellation()
            let committedDecision = await PairingTrustApprovalService.shared
                .commitProtocolIdentityBindingRequesterApproval(
                    decision: approval,
                    transactionId: request.transactionId,
                    requesterDeviceIds: signedKEMRefreshDeviceIdCandidates(request.requesterDeviceId),
                    requesterProtocolSigningAlgorithm: requesterAlgorithm,
                    requesterProtocolIdentityFingerprint: requesterFingerprint,
                    requesterProtocolIdentityPublicKey: requesterIdentity.publicKey,
                    requestHashHex: request.canonicalRequestHashHex,
                    candidateHashHex: candidate.canonicalCandidateHashHex,
                    sasTranscriptHashHex: candidate.sasTranscriptHashHex(request: request),
                    now: commitNow
                )
            guard committedDecision != .reject else {
                throw makePIBFailure("requester protocol identity pin commit failed")
            }
            return signedAck
        }
    }

    nonisolated private static func makePIBFailure(_ reason: String) -> NSError {
        NSError(
            domain: "SkyBridge.ProtocolIdentityBinding",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: reason]
        )
    }

    nonisolated static func protocolIdentityBindingFailureCode(for error: Error) -> String {
        let reason = error.localizedDescription.lowercased()
        if reason.contains("invalid request version") || reason.contains("version is invalid") {
            return "invalid_request_version"
        }
        if reason.contains("policy mismatch") || reason.contains("policy does not match strict pqc") {
            return "policy_mismatch"
        }
        if reason.contains("invalid route scope") || reason.contains("route scope is invalid") {
            return "invalid_route_scope"
        }
        if reason.contains("invalid request nonce") || reason.contains("request nonce is missing") {
            return "invalid_request_nonce"
        }
        if reason.contains("timestamp is not representable") {
            return "invalid_timestamp"
        }
        if reason.contains("requester protocol identity is missing") {
            return "missing_requester_protocol_identity"
        }
        if reason.contains("requester protocol identity is invalid")
            || reason.contains("requester protocol identity proof invalid") {
            return "invalid_requester_protocol_identity"
        }
        if reason.contains("requester signature is missing") {
            return "missing_requester_signature"
        }
        if reason.contains("requester protocol identity signature invalid") {
            return "invalid_requester_signature"
        }
        if reason.contains("operator rejected requester protocol identity") {
            return "requester_protocol_identity_rejected_by_operator"
        }
        if reason.contains("no requested protocol identity algorithm available") {
            return "unsupported_protocol_identity_algorithm"
        }
        if reason.contains("local protocol identity unavailable") {
            return "local_protocol_identity_unavailable"
        }
        if reason.contains("local device id unavailable") {
            return "local_device_id_unavailable"
        }
        if reason.contains("request target does not identify local responder") {
            return "request_target_mismatch"
        }
        return "protocol_identity_binding_rejected"
    }

    /// Mirrors the iOS PIB responder gate: only serve when the request names this
    /// host via its stable id or an established alias.
    nonisolated static func localResponderMatchesProtocolIdentityBindingTarget(
        targetDeviceId: String,
        localId: String,
        aliases: [String]
    ) -> Bool {
        let normalizedTarget = targetDeviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTarget.isEmpty else { return false }
        return Set([localId] + aliases).contains(normalizedTarget)
    }

    /// Request frames that `makeBootstrapControlResponse` owns. Distinct from
    /// `P2PConnection.isBootstrapControlMessage`, which also classifies responses
    /// and pairing-identity exchange for established-channel admission.
    nonisolated static func isInboundBootstrapControlRequest(_ message: AppMessage) -> Bool {
        switch message {
        case .kemRefreshRequest, .protocolIdentityBindingRequest, .protocolIdentityBindingConfirm:
            return true
        default:
            return false
        }
    }

    nonisolated static func signedKEMRefreshFailureCode(for error: Error) -> String {
        let reason = error.localizedDescription.lowercased()
        if reason.contains("target protocol identity fingerprint mismatch") {
            return "pinned_protocol_identity_mismatch_requires_oob"
        }
        if reason.contains("target protocol identity fingerprint invalid") {
            return "invalid_target_protocol_identity"
        }
        if reason.contains("invalid request version") {
            return "invalid_request_version"
        }
        if reason.contains("policy mismatch") {
            return "policy_mismatch"
        }
        if reason.contains("policy hash mismatch") {
            return "policy_hash_mismatch"
        }
        if reason.contains("request timestamp is expired") {
            return "stale_request"
        }
        if reason.contains("too far in the future") {
            return "future_request"
        }
        if reason.contains("timestamp is not representable") {
            return "invalid_timestamp"
        }
        if reason.contains("requested suite list is empty") {
            return "missing_requested_suite"
        }
        if reason.contains("request replay detected") {
            return "request_replay_detected"
        }
        if reason.contains("requester rate limited") {
            return "requester_rate_limited"
        }
        if reason.contains("requester protocol identity fingerprint not pinned") {
            return "requester_protocol_identity_not_pinned"
        }
        if reason.contains("requester protocol identity fingerprint missing") {
            return "missing_requester_protocol_identity"
        }
        if reason.contains("requester protocol identity fingerprint invalid") {
            return "invalid_requester_protocol_identity"
        }
        if reason.contains("invalid route scope") {
            return "invalid_route_scope"
        }
        if reason.contains("invalid request nonce") {
            return "invalid_request_nonce"
        }
        if reason.contains("unknown suite") {
            return "unknown_suite"
        }
        if reason.contains("classic suite rejected") || reason.contains("rejected classic suite") {
            return "classic_suite_rejected"
        }
        if reason.contains("no requested pqc kem public key available") {
            return "missing_requested_pqc_kem"
        }
        if reason.contains("local protocol identity unavailable") {
            return "local_protocol_identity_unavailable"
        }
        if reason.contains("local pqc kem material unavailable") {
            return "local_pqc_kem_unavailable"
        }
        if reason.contains("local protocol identity signing unavailable") {
            return "local_protocol_identity_signing_unavailable"
        }
        if reason.contains("local device id unavailable") {
            return "local_device_id_unavailable"
        }
        return "kem_refresh_rejected"
    }

    nonisolated private static func normalizedSKRFingerprint(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard value.count == 64, value.allSatisfy(\.isHexDigit) else { return nil }
        return value
    }

    nonisolated private static func signedKEMRefreshDeviceIdCandidates(_ raw: String) -> [String] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var candidates = [trimmed]
        if trimmed.hasPrefix("id:") {
            candidates.append(String(trimmed.dropFirst(3)))
        } else {
            candidates.append("id:\(trimmed)")
        }
        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
    }

    nonisolated private static func signedKEMRefreshKeyId(
        protocolFingerprint: String,
        kemPublicKeys: [KEMPublicKeyInfo]
    ) -> String {
        var material = Data("SkyBridge-SKR-1-KeyId\n".utf8)
        for key in kemPublicKeys.sorted(by: { $0.suiteWireId < $1.suiteWireId }) {
            var wireId = key.suiteWireId.littleEndian
            var length = UInt32(key.publicKey.count).littleEndian
            material.append(Data(bytes: &wireId, count: MemoryLayout<UInt16>.size))
            material.append(Data(bytes: &length, count: MemoryLayout<UInt32>.size))
            material.append(key.publicKey)
        }
        let digest = SHA256.hash(data: material).prefix(8).map { String(format: "%02x", $0) }.joined()
        return "skr1-\(protocolFingerprint.prefix(12))-\(digest)"
    }
}
