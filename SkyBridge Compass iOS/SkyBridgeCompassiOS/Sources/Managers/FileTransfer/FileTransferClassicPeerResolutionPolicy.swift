import Foundation

struct ClassicTransferAuthenticatedPeerCandidate: Sendable, Equatable {
    let matchDeviceId: String
    let resolvedPeerDeviceId: String
    let aliases: [String]
    let endpointHostOrIP: String?
    let capabilities: [String]
}

enum ClassicTransferPeerResolutionBranch: String, Sendable, Equatable {
    case declaredSenderDeviceId = "declared_sender_device_id"
    case aliasOrCanonicalDeviceId = "alias_or_canonical_device_id"
    case endpointHostOrIP = "endpoint_host_or_ip"
    case singleAuthenticatedFallback = "single_authenticated_fallback"
}

struct ClassicTransferPeerResolutionOutcome: Sendable, Equatable {
    let matchDeviceId: String
    let resolvedPeerDeviceId: String
    let matchedBy: ClassicTransferPeerResolutionBranch
    let declaredCandidates: [String]
    let endpointCandidates: [String]
}

enum FileTransferClassicPeerResolutionPolicy {
    nonisolated static func resolvePeer(
        peerContext: FileTransferPeerContext,
        authenticatedPeers: [ClassicTransferAuthenticatedPeerCandidate]
    ) -> ClassicTransferPeerResolutionOutcome? {
        let exactDeclared = peerContext.declaredSenderDeviceId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let declaredCandidates = normalizedTransferSecurityCandidates(
            PeerIdentityAliasResolver.lookupCandidates(for: exactDeclared),
            excluding: exactDeclared
        )
        let endpointCandidates = normalizedTransferSecurityCandidates(
            PeerIdentityAliasResolver.lookupCandidates(for: peerContext.endpointHostOrIP)
        )

        func exactDeclaredMatch() -> ClassicTransferAuthenticatedPeerCandidate? {
            guard let exactDeclared, !exactDeclared.isEmpty else { return nil }
            let exactLower = exactDeclared.lowercased()
            return authenticatedPeers.first { candidate in
                candidate.matchDeviceId.caseInsensitiveCompare(exactDeclared) == .orderedSame
                    || candidate.resolvedPeerDeviceId.caseInsensitiveCompare(exactDeclared) == .orderedSame
                    || candidate.aliases.contains(where: { $0.lowercased() == exactLower })
            }
        }

        func candidateMatch(for requestedCandidates: [String]) -> ClassicTransferAuthenticatedPeerCandidate? {
            guard !requestedCandidates.isEmpty else { return nil }
            let requestedLower = Set(requestedCandidates.map { $0.lowercased() })
            let matches = authenticatedPeers.filter { candidate in
                !requestedLower.isDisjoint(with: candidate.aliases.map { $0.lowercased() })
            }
            guard matches.count == 1 else { return nil }
            return matches.first
        }

        if let exactMatch = exactDeclaredMatch() {
            return ClassicTransferPeerResolutionOutcome(
                matchDeviceId: exactMatch.matchDeviceId,
                resolvedPeerDeviceId: exactMatch.resolvedPeerDeviceId,
                matchedBy: .declaredSenderDeviceId,
                declaredCandidates: declaredCandidates,
                endpointCandidates: endpointCandidates
            )
        }

        if let aliasMatch = candidateMatch(for: declaredCandidates) {
            return ClassicTransferPeerResolutionOutcome(
                matchDeviceId: aliasMatch.matchDeviceId,
                resolvedPeerDeviceId: aliasMatch.resolvedPeerDeviceId,
                matchedBy: .aliasOrCanonicalDeviceId,
                declaredCandidates: declaredCandidates,
                endpointCandidates: endpointCandidates
            )
        }

        if let endpointMatch = candidateMatch(for: endpointCandidates) {
            return ClassicTransferPeerResolutionOutcome(
                matchDeviceId: endpointMatch.matchDeviceId,
                resolvedPeerDeviceId: endpointMatch.resolvedPeerDeviceId,
                matchedBy: .endpointHostOrIP,
                declaredCandidates: declaredCandidates,
                endpointCandidates: endpointCandidates
            )
        }

        let hasExactDeclared = !(exactDeclared?.isEmpty ?? true)
        let hasPeerHints = hasExactDeclared || !declaredCandidates.isEmpty || !endpointCandidates.isEmpty
        if !hasPeerHints, authenticatedPeers.count == 1, let only = authenticatedPeers.first {
            return ClassicTransferPeerResolutionOutcome(
                matchDeviceId: only.matchDeviceId,
                resolvedPeerDeviceId: only.resolvedPeerDeviceId,
                matchedBy: .singleAuthenticatedFallback,
                declaredCandidates: declaredCandidates,
                endpointCandidates: endpointCandidates
            )
        }

        return nil
    }

    nonisolated static func preferredSenderDeviceId(
        stableDeviceId: String,
        vendorDeviceId: String?
    ) -> String {
        let normalizedStable = stableDeviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedStable.isEmpty {
            return normalizedStable
        }

        return vendorDeviceId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    nonisolated static func normalizedTransferSecurityCandidates(
        _ candidates: [String],
        excluding exactMatch: String? = nil
    ) -> [String] {
        var normalized: [String] = []
        var seen = Set<String>()
        let excluded = exactMatch?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for candidate in candidates {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let lowered = trimmed.lowercased()
            guard lowered != excluded else { continue }
            guard seen.insert(lowered).inserted else { continue }
            normalized.append(trimmed)
        }
        return normalized
    }

    nonisolated static func singlePeerFallbackDeviceId(
        requestedCandidates: [String],
        activeConnectionDeviceIDs: [String]
    ) -> String? {
        guard requestedCandidates.isEmpty else { return nil }
        let normalizedActive = normalizedTransferSecurityCandidates(activeConnectionDeviceIDs)
        guard normalizedActive.count == 1,
              let only = normalizedActive.first else {
            return nil
        }

        return only
    }
}
