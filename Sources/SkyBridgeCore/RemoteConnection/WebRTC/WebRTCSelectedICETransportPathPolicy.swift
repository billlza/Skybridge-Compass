/// Classifies a WebRTC path from the candidate pair selected by the RTC statistics report.
///
/// The report is observational and may be incomplete while ICE state changes. A direct result
/// therefore requires one unambiguous selected pair and complete candidate evidence for both
/// ends. Relay evidence is conclusive as soon as either candidate referenced by that pair is
/// present and reports the relay type.
enum WebRTCSelectedICETransportPathPolicy {
    struct Candidate: Sendable, Equatable {
        let candidateType: String?
    }

    struct CandidatePair: Sendable, Equatable {
        let isAuthoritySelected: Bool
        let localCandidateID: String?
        let remoteCandidateID: String?
    }

    private static let directCandidateTypes: Set<String> = ["host", "srflx", "prflx"]

    static func classify(
        candidatePairs: [CandidatePair],
        candidatesByID: [String: Candidate]
    ) -> WebRTCSession.ICETransportPath {
        let authoritySelectedPairs = candidatePairs.filter(\.isAuthoritySelected)
        guard authoritySelectedPairs.count == 1,
              let selectedPair = authoritySelectedPairs.first else {
            return .unknown
        }

        let candidateIDs = [
            validatedCandidateID(selectedPair.localCandidateID),
            validatedCandidateID(selectedPair.remoteCandidateID),
        ]

        for candidateID in candidateIDs.compactMap({ $0 }) {
            guard let candidate = candidatesByID[candidateID] else { continue }
            if normalizedCandidateType(candidate.candidateType) == "relay" {
                return .relay
            }
        }

        guard let localCandidateID = candidateIDs[0],
              let remoteCandidateID = candidateIDs[1],
              localCandidateID != remoteCandidateID,
              let localCandidate = candidatesByID[localCandidateID],
              let remoteCandidate = candidatesByID[remoteCandidateID],
              let localCandidateType = normalizedCandidateType(localCandidate.candidateType),
              let remoteCandidateType = normalizedCandidateType(remoteCandidate.candidateType),
              directCandidateTypes.contains(localCandidateType),
              directCandidateTypes.contains(remoteCandidateType) else {
            return .unknown
        }

        return .direct
    }

    private static func validatedCandidateID(_ candidateID: String?) -> String? {
        guard let candidateID, !candidateID.isEmpty else { return nil }
        return candidateID
    }

    private static func normalizedCandidateType(_ candidateType: String?) -> String? {
        guard let candidateType, !candidateType.isEmpty else { return nil }
        let normalized = candidateType.lowercased()
        return normalized.isEmpty ? nil : normalized
    }
}
