import XCTest
@testable import SkyBridgeCore

final class WebRTCSelectedICETransportPathPolicyTests: XCTestCase {
    private typealias Candidate = WebRTCSelectedICETransportPathPolicy.Candidate
    private typealias CandidatePair = WebRTCSelectedICETransportPathPolicy.CandidatePair

    func testDirectRequiresOneSelectedPairAndTwoCompleteDirectCandidates() {
        for localType in ["host", "srflx", "prflx"] {
            for remoteType in ["host", "srflx", "prflx"] {
                XCTAssertEqual(
                    classify(
                        selectedPairs: [pair()],
                        candidates: [
                            "local": Candidate(candidateType: localType),
                            "remote": Candidate(candidateType: remoteType),
                        ]
                    ),
                    .direct
                )
            }
        }
    }

    func testRelayOnEitherSelectedPairCandidateTakesPrecedenceOverIncompleteEvidence() {
        XCTAssertEqual(
            classify(
                selectedPairs: [pair(remoteCandidateID: nil)],
                candidates: ["local": Candidate(candidateType: "relay")]
            ),
            .relay
        )
        XCTAssertEqual(
            classify(
                selectedPairs: [pair(localCandidateID: nil)],
                candidates: ["remote": Candidate(candidateType: "RELAY")]
            ),
            .relay
        )
        XCTAssertEqual(
            classify(
                selectedPairs: [pair()],
                candidates: [
                    "local": Candidate(candidateType: "host"),
                    "remote": Candidate(candidateType: "relay"),
                ]
            ),
            .relay
        )
    }

    func testMissingOrMalformedDirectEvidenceIsUnknown() {
        let completeCandidates = [
            "local": Candidate(candidateType: "host"),
            "remote": Candidate(candidateType: "srflx"),
        ]

        XCTAssertEqual(classify(selectedPairs: []), .unknown)
        XCTAssertEqual(
            classify(selectedPairs: [pair(), pair()], candidates: completeCandidates),
            .unknown
        )
        XCTAssertEqual(
            classify(
                selectedPairs: [pair(), pair(localCandidateID: "relay")],
                candidates: completeCandidates.merging(
                    ["relay": Candidate(candidateType: "relay")],
                    uniquingKeysWith: { current, _ in current }
                )
            ),
            .unknown
        )
        XCTAssertEqual(
            classify(selectedPairs: [pair(localCandidateID: nil)], candidates: completeCandidates),
            .unknown
        )
        XCTAssertEqual(
            classify(selectedPairs: [pair(remoteCandidateID: "")], candidates: completeCandidates),
            .unknown
        )
        XCTAssertEqual(
            classify(selectedPairs: [pair()], candidates: ["local": Candidate(candidateType: "host")]),
            .unknown
        )
        XCTAssertEqual(
            classify(
                selectedPairs: [pair()],
                candidates: [
                    "local": Candidate(candidateType: nil),
                    "remote": Candidate(candidateType: "host"),
                ]
            ),
            .unknown
        )
        XCTAssertEqual(
            classify(
                selectedPairs: [pair()],
                candidates: [
                    "local": Candidate(candidateType: "unknown"),
                    "remote": Candidate(candidateType: "host"),
                ]
            ),
            .unknown
        )
        XCTAssertEqual(
            classify(
                selectedPairs: [pair()],
                candidates: [
                    "local": Candidate(candidateType: " host "),
                    "remote": Candidate(candidateType: "host"),
                ]
            ),
            .unknown
        )
        XCTAssertEqual(
            classify(
                selectedPairs: [pair(remoteCandidateID: "local")],
                candidates: ["local": Candidate(candidateType: "host")]
            ),
            .unknown
        )
    }

    func testUnselectedCandidatesCannotInfluenceTheSelectedPair() {
        let unselectedRelayPair = CandidatePair(
            isAuthoritySelected: false,
            localCandidateID: "unselected-relay",
            remoteCandidateID: "unselected-host"
        )
        XCTAssertEqual(
            classify(
                selectedPairs: [pair(), unselectedRelayPair],
                candidates: [
                    "local": Candidate(candidateType: "host"),
                    "remote": Candidate(candidateType: "prflx"),
                    "unselected-relay": Candidate(candidateType: "relay"),
                    "unselected-host": Candidate(candidateType: "host"),
                ]
            ),
            .direct
        )
    }

    private func classify(
        selectedPairs: [CandidatePair],
        candidates: [String: Candidate] = [:]
    ) -> WebRTCSession.ICETransportPath {
        WebRTCSelectedICETransportPathPolicy.classify(
            candidatePairs: selectedPairs,
            candidatesByID: candidates
        )
    }

    private func pair(
        localCandidateID: String? = "local",
        remoteCandidateID: String? = "remote"
    ) -> CandidatePair {
        CandidatePair(
            isAuthoritySelected: true,
            localCandidateID: localCandidateID,
            remoteCandidateID: remoteCandidateID
        )
    }
}
