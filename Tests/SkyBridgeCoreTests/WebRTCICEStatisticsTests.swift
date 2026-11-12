import XCTest
@testable import SkyBridgeCore

final class WebRTCICEStatisticsTests: XCTestCase {
    private typealias Record = WebRTCICEStatistics.Record

    func testTransportReferenceSelectsSucceededPairWithoutLegacyFlags() {
        let selection = WebRTCICEStatistics.select(from: report())
        XCTAssertEqual(selection.path, .direct)
        XCTAssertEqual(selection.remoteAddress, "192.0.2.42")
    }

    func testNominatedUnselectedPairCannotSupplyAddressOrChangePath() {
        var records = report()
        records["old-pair"] = Record(type: "candidate-pair", values: [
            "transportId": "transport", "state": "succeeded", "nominated": "1",
            "localCandidateId": "local", "remoteCandidateId": "old-remote",
        ])
        records["old-remote"] = Record(type: "remote-candidate", values: [
            "transportId": "transport", "candidateType": "relay", "address": "192.0.2.99",
        ])
        let selection = WebRTCICEStatistics.select(from: records)
        XCTAssertEqual(selection.path, .direct)
        XCTAssertEqual(selection.remoteAddress, "192.0.2.42")
    }

    func testDanglingTransportReferenceDoesNotFallBackToNominatedPair() {
        var records = report()
        records["transport"]?.values["selectedCandidatePairId"] = "removed-pair"
        records["pair"]?.values["nominated"] = "1"
        assertUnknown(records)
        records["transport"] = nil
        assertUnknown(records)
    }

    func testMultipleSelectedTransportsCannotChooseAnArbitraryAddress() {
        var records = report()
        records["other-transport"] = records["transport"]
        assertUnknown(records)
    }

    func testSelectedPairMustHaveSucceededAndBelongToSelectingTransport() {
        for state in ["waiting", "in-progress", "failed", "frozen", "", "SUCCEEDED"] {
            var records = report()
            records["pair"]?.values["state"] = state
            assertUnknown(records)
        }
        var records = report()
        records["pair"]?.values["transportId"] = "old-transport"
        assertUnknown(records)
    }

    func testPairReferenceMustPointToCandidatePairRecord() {
        var records = report()
        records["pair"] = Record(type: "remote-candidate", values: records["pair"]?.values ?? [:])
        assertUnknown(records)
    }

    func testRemoteAddressRequiresCorrectCandidateRoleAndTransport() {
        for remote in [
            Record(type: "local-candidate", values: [
                "transportId": "transport", "candidateType": "host", "address": "192.0.2.42",
            ]),
            Record(type: "remote-candidate", values: [
                "transportId": "old-transport", "candidateType": "host", "address": "192.0.2.42",
            ]),
        ] {
            var records = report()
            records["remote"] = remote
            assertUnknown(records)
        }
        var records = report()
        records["pair"]?.values["remoteCandidateId"] = "local"
        assertUnknown(records)
    }

    func testMissingAddressIsNotReplacedByAnotherCandidate() {
        var records = report()
        records["remote"]?.values["address"] = nil
        let selection = WebRTCICEStatistics.select(from: records)
        XCTAssertEqual(selection.path, .direct)
        XCTAssertNil(selection.remoteAddress)
    }

    func testAddressMayBeIPv6OrMDNSButCannotContainControlCharacters() {
        for address in ["2001:db8::42", "peer.local"] {
            var records = report()
            records["remote"]?.values["address"] = address
            XCTAssertEqual(WebRTCICEStatistics.select(from: records).remoteAddress, address)
        }
        for address in ["", " ", "192.0.2.42\n", "192.0.2.42\u{0000}"] {
            var records = report()
            records["remote"]?.values["address"] = address
            XCTAssertNil(WebRTCICEStatistics.select(from: records).remoteAddress)
        }
    }

    func testRelayEvidenceFromExactSelectedPairRetainsClassifierContract() {
        for candidate in ["local", "remote"] {
            var records = report()
            records[candidate]?.values["candidateType"] = "relay"
            XCTAssertEqual(WebRTCICEStatistics.select(from: records).path, .relay)
            // A missing other endpoint prevents a direct conclusion, but cannot
            // erase the relay evidence of the exact selected pair.
            records[candidate == "local" ? "remote" : "local"] = nil
            XCTAssertEqual(WebRTCICEStatistics.select(from: records).path, .relay)
        }
    }

    func testDiagnosticContainsOnlyCountsAndFixedLabels() {
        let selection = WebRTCICEStatistics.select(from: report())
        XCTAssertEqual(selection.diagnostic,
                       "selectedReferences=1 pairs=1 legacyFlags=0 localCandidate=true remoteCandidate=true address=true path=direct")
    }

    private func assertUnknown(_ records: [String: Record], file: StaticString = #filePath, line: UInt = #line) {
        let selection = WebRTCICEStatistics.select(from: records)
        XCTAssertEqual(selection.path, .unknown, file: file, line: line)
        XCTAssertNil(selection.remoteAddress, file: file, line: line)
    }

    private func report() -> [String: Record] {
        [
            "transport": Record(type: "transport", values: ["selectedCandidatePairId": "pair"]),
            "pair": Record(type: "candidate-pair", values: [
                "transportId": "transport", "state": "succeeded",
                "localCandidateId": "local", "remoteCandidateId": "remote",
            ]),
            "local": Record(type: "local-candidate", values: [
                "transportId": "transport", "candidateType": "host", "address": "192.0.2.10",
            ]),
            "remote": Record(type: "remote-candidate", values: [
                "transportId": "transport", "candidateType": "srflx", "address": "192.0.2.42",
            ]),
        ]
    }
}
