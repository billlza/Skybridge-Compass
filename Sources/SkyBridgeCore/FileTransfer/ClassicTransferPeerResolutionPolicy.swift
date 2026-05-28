import CryptoKit
import Foundation
import Network

@available(macOS 14.0, iOS 17.0, *)
enum ClassicTransferAuthenticatedSessionKind: Int, Sendable, Equatable {
    case sessionSnapshot = 0
    case liveConnection = 1

    var logLabel: String {
        switch self {
        case .sessionSnapshot:
            return "sessionSnapshot"
        case .liveConnection:
            return "liveConnection"
        }
    }
}

@available(macOS 14.0, iOS 17.0, *)
struct ClassicTransferAuthenticatedSessionSource: Sendable {
    let candidate: ClassicTransferAuthenticatedPeerCandidate
    let transferKey: SymmetricKey
    let lastSeenAt: Date
    let sourceKind: ClassicTransferAuthenticatedSessionKind
}

@available(macOS 14.0, iOS 17.0, *)
struct ClassicTransferResolvedAuthenticatedSession: Sendable {
    let source: ClassicTransferAuthenticatedSessionSource
    let resolution: ClassicTransferPeerResolutionOutcome
}

@available(macOS 14.0, iOS 17.0, *)
struct ClassicTransferAuthenticatedPeerCandidate: Sendable, Equatable {
    let matchDeviceId: String
    let resolvedPeerDeviceId: String
    let aliases: [String]
    let endpointHostOrIP: String?
    let capabilities: [String]
}

@available(macOS 14.0, iOS 17.0, *)
enum ClassicTransferPeerResolutionBranch: String, Sendable, Equatable {
    case declaredSenderDeviceId = "declared_sender_device_id"
    case aliasOrCanonicalDeviceId = "alias_or_canonical_device_id"
    case endpointHostOrIP = "endpoint_host_or_ip"
}

@available(macOS 14.0, iOS 17.0, *)
struct ClassicTransferPeerResolutionOutcome: Sendable, Equatable {
    let matchDeviceId: String
    let resolvedPeerDeviceId: String
    let matchedBy: ClassicTransferPeerResolutionBranch
    let declaredCandidates: [String]
    let endpointCandidates: [String]
    let supportsClassicResume: Bool
}

@available(macOS 14.0, iOS 17.0, *)
enum ClassicTransferPeerResolutionPolicy {
    nonisolated static func resolvePeer(
        peerContext: FileTransferPeerContext,
        authenticatedPeers: [ClassicTransferAuthenticatedPeerCandidate]
    ) -> ClassicTransferPeerResolutionOutcome? {
        let exactDeclared = PeerTrustLookup.trimmedIdentifier(peerContext.declaredSenderDeviceId)
        let declaredCandidates = normalizedLookupCandidates(
            PeerTrustLookup.lookupCandidates(for: exactDeclared),
            excluding: exactDeclared
        )
        let endpointCandidates = normalizedLookupCandidates(
            PeerTrustLookup.lookupCandidates(for: peerContext.endpointHostOrIP)
        )

        func exactDeclaredMatch() -> ClassicTransferAuthenticatedPeerCandidate? {
            guard let exactDeclared else { return nil }
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
                endpointCandidates: endpointCandidates,
                supportsClassicResume: ClassicTransferCapability.supportsClassicResume(in: exactMatch.capabilities)
            )
        }

        if let aliasMatch = candidateMatch(for: declaredCandidates) {
            return ClassicTransferPeerResolutionOutcome(
                matchDeviceId: aliasMatch.matchDeviceId,
                resolvedPeerDeviceId: aliasMatch.resolvedPeerDeviceId,
                matchedBy: .aliasOrCanonicalDeviceId,
                declaredCandidates: declaredCandidates,
                endpointCandidates: endpointCandidates,
                supportsClassicResume: ClassicTransferCapability.supportsClassicResume(in: aliasMatch.capabilities)
            )
        }

        if let endpointMatch = candidateMatch(for: endpointCandidates) {
            return ClassicTransferPeerResolutionOutcome(
                matchDeviceId: endpointMatch.matchDeviceId,
                resolvedPeerDeviceId: endpointMatch.resolvedPeerDeviceId,
                matchedBy: .endpointHostOrIP,
                declaredCandidates: declaredCandidates,
                endpointCandidates: endpointCandidates,
                supportsClassicResume: ClassicTransferCapability.supportsClassicResume(in: endpointMatch.capabilities)
            )
        }

        return nil
    }

    nonisolated static func isPreferredSource(
        _ lhs: ClassicTransferAuthenticatedSessionSource,
        over rhs: ClassicTransferAuthenticatedSessionSource
    ) -> Bool {
        if lhs.lastSeenAt != rhs.lastSeenAt {
            return lhs.lastSeenAt > rhs.lastSeenAt
        }
        if lhs.sourceKind != rhs.sourceKind {
            return lhs.sourceKind.rawValue > rhs.sourceKind.rawValue
        }
        if lhs.candidate.resolvedPeerDeviceId != rhs.candidate.resolvedPeerDeviceId {
            return lhs.candidate.resolvedPeerDeviceId.localizedCaseInsensitiveCompare(rhs.candidate.resolvedPeerDeviceId) == .orderedAscending
        }
        return lhs.candidate.matchDeviceId.localizedCaseInsensitiveCompare(rhs.candidate.matchDeviceId) == .orderedAscending
    }

    nonisolated static func sortedSessionSources(
        _ sources: [ClassicTransferAuthenticatedSessionSource]
    ) -> [ClassicTransferAuthenticatedSessionSource] {
        sources.sorted { lhs, rhs in
            isPreferredSource(lhs, over: rhs)
        }
    }

    nonisolated static func resolveSessionSource(
        peerContext: FileTransferPeerContext,
        authenticatedSources: [ClassicTransferAuthenticatedSessionSource]
    ) -> ClassicTransferResolvedAuthenticatedSession? {
        let sortedSources = sortedSessionSources(authenticatedSources)
        let connectionCandidates = sortedSources.map(\.candidate)
        guard let resolution = resolvePeer(
            peerContext: peerContext,
            authenticatedPeers: connectionCandidates
        ) else {
            return nil
        }

        let exactDeclared = PeerTrustLookup.trimmedIdentifier(peerContext.declaredSenderDeviceId)
        let exactDeclaredLower = exactDeclared?.lowercased()
        let declaredCandidates = Set(resolution.declaredCandidates.map { $0.lowercased() })
        let endpointCandidates = Set(resolution.endpointCandidates.map { $0.lowercased() })

        func sourceMatchesResolution(_ source: ClassicTransferAuthenticatedSessionSource) -> Bool {
            let candidate = source.candidate
            switch resolution.matchedBy {
            case .declaredSenderDeviceId:
                guard let exactDeclaredLower else { return false }
                return candidate.matchDeviceId.lowercased() == exactDeclaredLower
                    || candidate.resolvedPeerDeviceId.lowercased() == exactDeclaredLower
                    || candidate.aliases.contains(where: { $0.lowercased() == exactDeclaredLower })
            case .aliasOrCanonicalDeviceId:
                return !declaredCandidates.isEmpty
                    && !declaredCandidates.isDisjoint(with: candidate.aliases.map { $0.lowercased() })
            case .endpointHostOrIP:
                return !endpointCandidates.isEmpty
                    && !endpointCandidates.isDisjoint(with: candidate.aliases.map { $0.lowercased() })
            }
        }

        guard let source = sortedSources.first(where: sourceMatchesResolution) else {
            return nil
        }
        return ClassicTransferResolvedAuthenticatedSession(source: source, resolution: resolution)
    }

    nonisolated static func normalizedLookupCandidates(
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

    nonisolated static func advertisedClassicTransferPort(in capabilities: [String]) -> Int? {
        for capability in capabilities {
            let parts = capability.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let key = parts[0]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: "-", with: "_")
            guard key == "filetransferport" ||
                    key == "file_transfer_port" ||
                    key == "transferport" ||
                    key == "transfer_port" else {
                continue
            }
            let rawPort = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard let port = Int(rawPort), (1...65535).contains(port) else { continue }
            return port
        }
        return nil
    }

    nonisolated static func isInboundPreMetadataDisconnect(_ error: Error) -> Bool {
        if let fileTransferError = error as? FileTransferError {
            switch fileTransferError {
            case .connectionClosed:
                return true
            default:
                return false
            }
        }

        if let posix = error as? POSIXError {
            return isConnectionClosedBeforeMetadata(posix.code)
        }

        if let nwError = error as? NWError,
           case .posix(let code) = nwError {
            return isConnectionClosedBeforeMetadata(code)
        }

        return false
    }

    private nonisolated static func isConnectionClosedBeforeMetadata(_ code: POSIXErrorCode) -> Bool {
        switch code {
        case .ECONNABORTED, .ECONNRESET, .ENOTCONN, .EPIPE:
            return true
        default:
            return false
        }
    }
}
