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

    static func classify(
        candidatePairs: [CandidatePair],
        candidatesByID: [String: Candidate]
    ) -> WebRTCSession.ICETransportPath {
        let path = WebRTCSelectedICETransportPathClassifier.classify(
            candidatePairs: candidatePairs.map {
                .init(
                    isAuthoritySelected: $0.isAuthoritySelected,
                    localCandidateID: $0.localCandidateID,
                    remoteCandidateID: $0.remoteCandidateID
                )
            },
            candidatesByID: candidatesByID.mapValues {
                .init(candidateType: $0.candidateType)
            }
        )
        switch path {
        case .unknown: return .unknown
        case .direct: return .direct
        case .relay: return .relay
        }
    }
}
