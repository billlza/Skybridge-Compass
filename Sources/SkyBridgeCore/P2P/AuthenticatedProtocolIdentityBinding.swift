import Foundation

/// Capability token required by every post-authentication pairing-identity
/// persistence path. A payload cannot construct this value itself: the token
/// is issued only after its declared device ID and protocol key are bound to
/// the authority authenticated by the current handshake, or to an explicit
/// PIB-1 operator approval already committed for that exact device ID.
@available(macOS 14.0, iOS 17.0, *)
struct ValidatedPairingIdentityAuthority: Sendable, Equatable {
    let declaredDeviceId: String
    let authorizedDeviceIds: [String]
    let protocolSigningAlgorithm: ProtocolSigningAlgorithm
    let protocolPublicKeyFingerprint: String
    let protocolPublicKey: Data

    fileprivate init(
        declaredDeviceId: String,
        authorizedDeviceIds: [String],
        protocolSigningAlgorithm: ProtocolSigningAlgorithm,
        protocolPublicKeyFingerprint: String,
        protocolPublicKey: Data
    ) {
        self.declaredDeviceId = declaredDeviceId
        self.authorizedDeviceIds = authorizedDeviceIds
        self.protocolSigningAlgorithm = protocolSigningAlgorithm
        self.protocolPublicKeyFingerprint = protocolPublicKeyFingerprint
        self.protocolPublicKey = protocolPublicKey
    }
}

@available(macOS 14.0, iOS 17.0, *)
struct PIBOperatorApprovalReceipt: Sendable, Equatable {
    let declaredDeviceId: String
    let binding: ProtocolIdentityBindingV2
}

/// Matches a post-authentication identity payload to the authority proved by
/// the handshake. The payload is never a trust source on its own: callers may
/// persist or auto-approve a key only when this exact binding succeeds.
@available(macOS 14.0, iOS 17.0, *)
enum AuthenticatedProtocolIdentityBinding {
    /// Binds a current-path pairing payload to the protocol key actually
    /// authenticated by this WebRTC handshake and to the stable device ID
    /// admitted by the verified current-path bootstrap. This is deliberately
    /// distinct from SOA/PIB admission: no synthetic SOA identity is created.
    static func validatedCurrentPathPairingIdentityAuthority(
        payload: AppMessage.PairingIdentityExchangePayload,
        authenticatedAuthority: AuthenticatedRemoteAuthority?,
        expectedStableDeviceId: String?
    ) -> ValidatedPairingIdentityAuthority? {
        guard let payload = payload.normalizedBootstrapPayload,
            let authenticatedAuthority,
            let expectedStableDeviceId = expectedStableDeviceId?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !expectedStableDeviceId.isEmpty,
            payload.deviceId == expectedStableDeviceId,
            let protocolPublicKey = matchingPublicKey(
                in: payload,
                authority: authenticatedAuthority
            )
        else {
            return nil
        }

        let normalizedFingerprint = authenticatedAuthority.protocolPublicKeyFingerprint
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard normalizedFingerprint.count == 64,
            normalizedFingerprint.allSatisfy(\.isHexDigit)
        else {
            return nil
        }

        return ValidatedPairingIdentityAuthority(
            declaredDeviceId: expectedStableDeviceId,
            authorizedDeviceIds: [expectedStableDeviceId],
            protocolSigningAlgorithm: authenticatedAuthority.protocolSigningAlgorithm,
            protocolPublicKeyFingerprint: normalizedFingerprint,
            protocolPublicKey: protocolPublicKey
        )
    }

    /// Resolves the operator-approved PIB receipt and issues the capability
    /// required by post-authentication identity persistence.
    ///
    /// Keep this lookup at the protocol boundary so every pairing handler uses
    /// the same SOA/PIB admission rules. A missing handshake authority, invalid
    /// payload, or absent exact operator approval all fail closed.
    static func validatedPairingIdentityAuthorityForPersistence(
        payload: AppMessage.PairingIdentityExchangePayload,
        authority: AuthenticatedRemoteAuthority?,
        authenticatedRemoteSOAPeerId: Data?,
        sessionDeviceIds: [String]
    ) async -> ValidatedPairingIdentityAuthority? {
        guard let authority,
            let normalizedPayload = payload.normalizedBootstrapPayload
        else {
            return nil
        }

        let operatorApprovalReceipt: PIBOperatorApprovalReceipt? = await MainActor.run {
            let trust = TrustSyncService.shared
            guard let record = trust.getTrustRecord(deviceId: normalizedPayload.deviceId),
                let binding = record.authenticatedProtocolIdentityBinding(
                    for: authority.protocolSigningAlgorithm
                )
            else {
                return nil
            }
            return PIBOperatorApprovalReceipt(
                declaredDeviceId: record.deviceId,
                binding: binding
            )
        }

        return validatedPairingIdentityAuthority(
            payload: normalizedPayload,
            authority: authority,
            authenticatedRemoteSOAPeerId: authenticatedRemoteSOAPeerId,
            sessionDeviceIds: sessionDeviceIds,
            operatorApprovalReceipt: operatorApprovalReceipt
        )
    }

    static func matchingPublicKey(
        in payload: AppMessage.PairingIdentityExchangePayload,
        authority: AuthenticatedRemoteAuthority
    ) -> Data? {
        let expectedAlgorithm = authority.protocolSigningAlgorithm.rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        let expectedFingerprint = authority.protocolPublicKeyFingerprint
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !expectedAlgorithm.isEmpty, !expectedFingerprint.isEmpty else {
            return nil
        }

        return
            (AppMessage.ProtocolIdentityPublicKeyInfo.normalizedValidKeys(
                payload.protocolIdentityPublicKeys
            ) ?? []).first { key in
                key.protocolSigningAlgorithm
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .uppercased() == expectedAlgorithm
                    && (authority.protocolPublicKey == nil
                        || key.publicKey == authority.protocolPublicKey)
                    && key.authoritativeFingerprint?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased() == expectedFingerprint
            }?.publicKey
    }

    /// Authorizes persistence of one post-authentication pairing payload.
    ///
    /// A current, authenticated SOA identity is the primary device-ID binding.
    /// When the transport did not negotiate SOA, only a raw-key PIB-1 operator
    /// approval for this exact declared ID may substitute. A contradictory SOA
    /// assertion is always rejected; an old approval must not override what the
    /// current signed handshake said its identity was.
    static func validatedPairingIdentityAuthority(
        payload: AppMessage.PairingIdentityExchangePayload,
        authority: AuthenticatedRemoteAuthority,
        authenticatedRemoteSOAPeerId: Data?,
        sessionDeviceIds: [String],
        operatorApprovalReceipt: PIBOperatorApprovalReceipt?
    ) -> ValidatedPairingIdentityAuthority? {
        guard let normalizedPayload = payload.normalizedBootstrapPayload else {
            return nil
        }
        let declaredDeviceId = normalizedPayload.deviceId
        guard isValidDeviceId(declaredDeviceId),
            let protocolPublicKey = matchingPublicKey(
                in: normalizedPayload,
                authority: authority
            )
        else {
            return nil
        }

        let normalizedFingerprint = authority.protocolPublicKeyFingerprint
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard normalizedFingerprint.count == 64,
            normalizedFingerprint.allSatisfy(\.isHexDigit)
        else {
            return nil
        }

        let declaredSOAPeerId = PeerSessionArbiter.soaPeerId(from: declaredDeviceId)
        let authorizedDeviceIds: [String]
        if let authenticatedRemoteSOAPeerId {
            guard authenticatedRemoteSOAPeerId.count == HandshakeSOAExtension.initiatorPeerIdLength,
                authenticatedRemoteSOAPeerId == declaredSOAPeerId,
                authority.protocolPublicKey == protocolPublicKey
            else {
                return nil
            }
            authorizedDeviceIds = deviceIdsBoundToSOA(
                declaredDeviceId: declaredDeviceId,
                sessionDeviceIds: sessionDeviceIds,
                authenticatedRemoteSOAPeerId: authenticatedRemoteSOAPeerId
            )
        } else {
            guard
                isExactPIBOperatorApproval(
                    operatorApprovalReceipt,
                    declaredDeviceId: declaredDeviceId,
                    authority: authority,
                    protocolPublicKey: protocolPublicKey,
                    normalizedFingerprint: normalizedFingerprint
                )
            else {
                return nil
            }
            authorizedDeviceIds = [declaredDeviceId]
        }

        return ValidatedPairingIdentityAuthority(
            declaredDeviceId: declaredDeviceId,
            authorizedDeviceIds: authorizedDeviceIds,
            protocolSigningAlgorithm: authority.protocolSigningAlgorithm,
            protocolPublicKeyFingerprint: normalizedFingerprint,
            protocolPublicKey: protocolPublicKey
        )
    }

    private static func isValidDeviceId(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 256 else { return false }
        return value.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0)
        }
    }

    private static func deviceIdsBoundToSOA(
        declaredDeviceId: String,
        sessionDeviceIds: [String],
        authenticatedRemoteSOAPeerId: Data
    ) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in [declaredDeviceId] + sessionDeviceIds {
            let candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isValidDeviceId(candidate),
                PeerSessionArbiter.soaPeerId(from: candidate) == authenticatedRemoteSOAPeerId
            else {
                continue
            }
            let dedupeKey = candidate.lowercased()
            if seen.insert(dedupeKey).inserted {
                result.append(candidate)
            }
        }
        return result
    }

    private static func isExactPIBOperatorApproval(
        _ receipt: PIBOperatorApprovalReceipt?,
        declaredDeviceId: String,
        authority: AuthenticatedRemoteAuthority,
        protocolPublicKey: Data,
        normalizedFingerprint: String
    ) -> Bool {
        guard let receipt,
            receipt.declaredDeviceId == declaredDeviceId,
            receipt.binding.pinSource == .pib1OperatorApproval,
            receipt.binding.protocolSigningAlgorithm == authority.protocolSigningAlgorithm,
            receipt.binding.publicKey == protocolPublicKey,
            receipt.binding.fingerprint
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() == normalizedFingerprint
        else {
            return false
        }
        return true
    }
}
