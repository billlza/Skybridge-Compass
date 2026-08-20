/// Exact selected ICE path classification shared by shipping Apple products.
///
/// Statistics may be incomplete during ICE churn. A direct result therefore
/// requires one unambiguous authority-selected candidate pair and complete
/// candidate types for both ends. A relay result is conclusive when either
/// candidate referenced by that exact pair is a relay.
public enum WebRTCSelectedICETransportPathClassifier {
    public enum Path: String, Sendable, Equatable {
        case unknown
        case direct
        case relay
    }

    public struct Candidate: Sendable, Equatable {
        public let candidateType: String?

        public init(candidateType: String?) {
            self.candidateType = candidateType
        }
    }

    public struct CandidatePair: Sendable, Equatable {
        public let isAuthoritySelected: Bool
        public let localCandidateID: String?
        public let remoteCandidateID: String?

        public init(
            isAuthoritySelected: Bool,
            localCandidateID: String?,
            remoteCandidateID: String?
        ) {
            self.isAuthoritySelected = isAuthoritySelected
            self.localCandidateID = localCandidateID
            self.remoteCandidateID = remoteCandidateID
        }
    }

    private static let directCandidateTypes: Set<String> = [
        "host", "srflx", "prflx"
    ]

    public static func classify(
        candidatePairs: [CandidatePair],
        candidatesByID: [String: Candidate]
    ) -> Path {
        let selectedPairs = candidatePairs.filter(\.isAuthoritySelected)
        guard selectedPairs.count == 1,
              let selectedPair = selectedPairs.first else {
            return .unknown
        }
        let candidateIDs = [
            validatedCandidateID(selectedPair.localCandidateID),
            validatedCandidateID(selectedPair.remoteCandidateID),
        ]
        for candidateID in candidateIDs.compactMap({ $0 }) {
            if normalizedCandidateType(
                candidatesByID[candidateID]?.candidateType
            ) == "relay" {
                return .relay
            }
        }
        guard let localCandidateID = candidateIDs[0],
              let remoteCandidateID = candidateIDs[1],
              localCandidateID != remoteCandidateID,
              let localCandidateType = normalizedCandidateType(
                candidatesByID[localCandidateID]?.candidateType
              ),
              let remoteCandidateType = normalizedCandidateType(
                candidatesByID[remoteCandidateID]?.candidateType
              ),
              directCandidateTypes.contains(localCandidateType),
              directCandidateTypes.contains(remoteCandidateType) else {
            return .unknown
        }
        return .direct
    }

    private static func validatedCandidateID(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private static func normalizedCandidateType(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value.lowercased()
    }
}
