import Foundation

/// A scalar projection of native WebRTC statistics. It contains no SDK objects and
/// is evaluated once for both the transport classification and the displayed peer address.
enum WebRTCICEStatistics {
    struct Record: Sendable {
        let type: String
        var values: [String: String]
    }

    struct Selection: Sendable {
        let path: WebRTCSession.ICETransportPath
        let remoteAddress: String?
        /// Counts and fixed labels only; never candidate addresses or report identifiers.
        let diagnostic: String
    }

    static func select(from records: [String: Record]) -> Selection {
        // W3C RTCTransportStats.selectedCandidatePairId is the authority for the
        // currently selected pair. Nomination is not selection, and libwebrtc's
        // standard reports need not provide the non-standard `selected` flag.
        let transports = records.filter {
            $0.value.type == "transport" && $0.value.values["selectedCandidatePairId"] != nil
        }
        let pairs = records.values.filter { $0.type == "candidate-pair" }
        let legacyFlagCount = pairs.filter {
            isTrue($0.values["selected"])
                || (isTrue($0.values["nominated"]) && $0.values["state"] == "succeeded")
        }.count
        let diagnostic = "selectedReferences=\(transports.count) pairs=\(pairs.count) legacyFlags=\(legacyFlagCount)"
        func unresolved(_ reason: String) -> Selection {
            Selection(path: .unknown, remoteAddress: nil, diagnostic: "\(diagnostic) result=\(reason)")
        }
        guard transports.count == 1, let (transportID, transport) = transports.first else {
            return unresolved("transport-ambiguous-or-missing")
        }
        guard let pairID = transport.values["selectedCandidatePairId"],
              !pairID.isEmpty, let pair = records[pairID], pair.type == "candidate-pair" else {
            return unresolved("pair-missing")
        }
        guard pair.values["state"] == "succeeded", pair.values["transportId"] == transportID else {
            return unresolved("pair-state-or-transport-invalid")
        }
        guard let localID = pair.values["localCandidateId"], !localID.isEmpty,
              let remoteID = pair.values["remoteCandidateId"], !remoteID.isEmpty,
              localID != remoteID else {
            return unresolved("candidate-references-invalid")
        }
        func candidate(_ id: String, role: String) -> Record? {
            guard let record = records[id], record.type == role,
                  record.values["transportId"] == transportID else { return nil }
            return record
        }
        let local = candidate(localID, role: "local-candidate")
        let remote = candidate(remoteID, role: "remote-candidate")
        var candidates: [String: WebRTCSelectedICETransportPathPolicy.Candidate] = [:]
        if let local { candidates[localID] = .init(candidateType: local.values["candidateType"]) }
        if let remote { candidates[remoteID] = .init(candidateType: remote.values["candidateType"]) }
        let path = WebRTCSelectedICETransportPathPolicy.classify(
            candidatePairs: [.init(
                isAuthoritySelected: true, localCandidateID: localID, remoteCandidateID: remoteID
            )],
            candidatesByID: candidates
        )
        let address = (remote?.values["address"] ?? remote?.values["ip"])
            .flatMap { value -> String? in
                guard !value.isEmpty,
                      value.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil
                else { return nil }
                return value
            }
        return Selection(
            path: path,
            remoteAddress: address,
            diagnostic: "\(diagnostic) localCandidate=\(local != nil) remoteCandidate=\(remote != nil) address=\(address != nil) path=\(path.rawValue)"
        )
    }

    private static func isTrue(_ value: String?) -> Bool {
        value == "1" || value == "true"
    }
}
