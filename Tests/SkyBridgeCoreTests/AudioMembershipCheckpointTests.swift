import Foundation
import XCTest
import SkyBridgeProtocolCore

final class AudioMembershipCheckpointTests: XCTestCase {
    func testExactDualClockAnchorsAndEvidenceIDSurviveRepeatedRestoration() throws {
        let fixture = try Fixture()
        let evidence = try fixture.evidence()
        let saved = try fixture.encode([evidence])
        let first = try fixture.restore(saved, elapsed: 20_000)
        XCTAssertEqual(first.evidence, [evidence])
        XCTAssertEqual(first.expiredEntryCount, 0)
        let savedAgain = try fixture.encode(first.evidence, elapsed: 20_000)
        XCTAssertEqual(savedAgain, saved)
        let later = try fixture.restore(savedAgain, elapsed: 3_599_999)
        XCTAssertEqual(later.evidence, [evidence])
        XCTAssertEqual(later.evidence.first?.expiresAtMonotonic, evidence.expiresAtMonotonic)
        let expired = try fixture.restore(savedAgain, elapsed: 3_600_000)
        XCTAssertTrue(expired.evidence.isEmpty)
        XCTAssertEqual(expired.expiredEntryCount, 1)
    }

    func testEitherOriginalClockCanExpireAnEntry() throws {
        let fixture = try Fixture()
        let data = try fixture.encode([fixture.evidence()])
        let wallExpired = try AudioMembershipCheckpoint.restore(data, account: fixture.account,
            loginID: fixture.loginID, bootSessionID: fixture.bootID,
            nowMilliseconds: fixture.wall + 3_600_000, monotonicNow: fixture.instant)
        let monotonicExpired = try AudioMembershipCheckpoint.restore(data, account: fixture.account,
            loginID: fixture.loginID, bootSessionID: fixture.bootID,
            nowMilliseconds: fixture.wall, monotonicNow: fixture.instant.advanced(by: .milliseconds(3_600_000)))
        for outcome in [wallExpired, monotonicExpired] {
            XCTAssertTrue(outcome.evidence.isEmpty)
            XCTAssertEqual(outcome.expiredEntryCount, 1)
        }
    }

    func testRollbackRejectsInsteadOfDiscardingOrRebasing() throws {
        let fixture = try Fixture()
        let data = try fixture.encode([fixture.evidence()])
        for wallRollback in [true, false] {
            XCTAssertThrowsError(try AudioMembershipCheckpoint.restore(data, account: fixture.account,
                loginID: fixture.loginID, bootSessionID: fixture.bootID,
                nowMilliseconds: fixture.wall - (wallRollback ? 1 : 0),
                monotonicNow: fixture.instant.advanced(by: wallRollback ? .zero : .nanoseconds(-1)))) {
                XCTAssertEqual($0 as? AudioMembershipError, .clockMovedBackwards)
            }
        }
    }

    func testNewLoginAndNewBootCannotReuseTheSameAccountCheckpoint() throws {
        let fixture = try Fixture()
        let data = try fixture.encode([fixture.evidence()])
        XCTAssertThrowsError(try AudioMembershipCheckpoint.restore(data, account: fixture.account,
            loginID: UUID(), bootSessionID: fixture.bootID, nowMilliseconds: fixture.wall,
            monotonicNow: fixture.instant)) { XCTAssertEqual($0 as? AudioMembershipCheckpointError, .loginChanged) }
        XCTAssertThrowsError(try AudioMembershipCheckpoint.restore(data, account: fixture.account,
            loginID: fixture.loginID, bootSessionID: UUID(), nowMilliseconds: fixture.wall,
            monotonicNow: fixture.instant)) { XCTAssertEqual($0 as? AudioMembershipCheckpointError, .bootChanged) }
    }

    func testEachAccountScopeFieldMustMatch() throws {
        let fixture = try Fixture()
        let data = try fixture.encode([fixture.evidence()])
        for account in [
            try AudioAccountIdentity(authority: "https://other.invalid", tenantID: "tenant", userID: "user"),
            try AudioAccountIdentity(authority: fixture.account.authority, tenantID: "other", userID: "user"),
            try AudioAccountIdentity(authority: fixture.account.authority, tenantID: "tenant", userID: "other")
        ] {
            XCTAssertThrowsError(try AudioMembershipCheckpoint.restore(data, account: account,
                loginID: fixture.loginID, bootSessionID: fixture.bootID,
                nowMilliseconds: fixture.wall, monotonicNow: fixture.instant)) {
                XCTAssertEqual($0 as? AudioMembershipCheckpointError, .accountChanged)
            }
        }
    }

    func testExpiredAndValidPairsAreSeparatedWithoutRenewal() throws {
        let fixture = try Fixture()
        let short = try fixture.evidence(peerIndex: 1, lifetime: 1)
        let long = try fixture.evidence(peerIndex: 2, lifetime: 500)
        let outcome = try fixture.restore(fixture.encode([short, long]), elapsed: 1)
        XCTAssertEqual(outcome.evidence, [long])
        XCTAssertEqual(outcome.expiredEntryCount, 1)
    }

    func testEmptyCheckpointIsValidButContainsNoAuthority() throws {
        let fixture = try Fixture()
        let restored = try fixture.restore(fixture.encode([]))
        XCTAssertTrue(restored.evidence.isEmpty)
        XCTAssertEqual(restored.expiredEntryCount, 0)
    }

    func testEncodingRefusesExpiredOrOtherAccountEvidence() throws {
        let fixture = try Fixture()
        let evidence = try fixture.evidence(lifetime: 100)
        XCTAssertThrowsError(try fixture.encode([evidence], elapsed: 100)) {
            XCTAssertEqual($0 as? AudioMembershipError, .expired)
        }
        let other = try AudioAccountIdentity(authority: fixture.account.authority, tenantID: "different", userID: "user")
        XCTAssertThrowsError(try AudioMembershipCheckpoint.encode([evidence], account: other,
            loginID: fixture.loginID, bootSessionID: fixture.bootID,
            nowMilliseconds: fixture.wall, monotonicNow: fixture.instant)) {
            XCTAssertEqual($0 as? AudioMembershipError, .scopeMismatch)
        }
    }

    func testEntryAndEncodedByteLimitsAreEnforced() throws {
        let fixture = try Fixture()
        let entries = try (0..<32).map { try fixture.evidence(peerIndex: $0) }
        let data = try fixture.encode(entries)
        XCTAssertLessThanOrEqual(data.count, AudioMembershipCheckpoint.maximumEncodedBytes)
        XCTAssertEqual(try fixture.restore(data).evidence, entries)
        XCTAssertThrowsError(try fixture.encode(entries + [fixture.evidence(peerIndex: 32)])) {
            XCTAssertEqual($0 as? AudioMembershipCheckpointError, .capacity)
        }
        XCTAssertThrowsError(try fixture.restore(Data(repeating: 32, count: 65_537))) {
            XCTAssertEqual($0 as? AudioMembershipCheckpointError, .capacity)
        }
        let overfull = try mutate(data) { root in
            var entries = try XCTUnwrap(root["entries"] as? [[String: Any]])
            entries.append(try XCTUnwrap(entries.first))
            root["entries"] = entries
        }
        XCTAssertThrowsError(try fixture.restore(overfull)) {
            XCTAssertEqual($0 as? AudioMembershipCheckpointError, .capacity)
        }
    }

    func testDuplicatePairAndDuplicateIdentifierAreBothRejected() throws {
        let fixture = try Fixture()
        let first = try fixture.evidence(peerIndex: 1)
        let samePairNewID = try fixture.evidence(peerIndex: 1)
        XCTAssertThrowsError(try fixture.encode([first, samePairNewID])) {
            XCTAssertEqual($0 as? AudioMembershipCheckpointError, .duplicateEntry)
        }
        let data = try fixture.encode([first, fixture.evidence(peerIndex: 2)])
        let duplicatedID = try mutate(data) { root in
            var entries = try XCTUnwrap(root["entries"] as? [[String: Any]])
            entries[1]["id"] = entries[0]["id"]
            root["entries"] = entries
        }
        XCTAssertThrowsError(try fixture.restore(duplicatedID)) {
            XCTAssertEqual($0 as? AudioMembershipCheckpointError, .duplicateEntry)
        }
        let duplicatedPair = try mutate(data) { root in
            var entries = try XCTUnwrap(root["entries"] as? [[String: Any]])
            entries[1]["peer"] = entries[0]["peer"]
            root["entries"] = entries
        }
        XCTAssertThrowsError(try fixture.restore(duplicatedPair)) {
            XCTAssertEqual($0 as? AudioMembershipCheckpointError, .duplicateEntry)
        }
    }

    func testZeroIdentifiersAndUnsupportedSchemaAreRejected() throws {
        let fixture = try Fixture()
        let zero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        XCTAssertThrowsError(try AudioMembershipCheckpoint.encode([], account: fixture.account,
            loginID: zero, bootSessionID: fixture.bootID, nowMilliseconds: fixture.wall)) {
            XCTAssertEqual($0 as? AudioMembershipCheckpointError, .invalidIdentifier)
        }
        let data = try fixture.encode([fixture.evidence()])
        for key in ["loginID", "bootSessionID"] {
            let invalid = try mutate(data) { $0[key] = zero.uuidString }
            XCTAssertThrowsError(try fixture.restore(invalid)) {
                XCTAssertEqual($0 as? AudioMembershipCheckpointError, .invalidIdentifier)
            }
        }
        let invalidID = try mutateEntry(data) { $0["id"] = zero.uuidString }
        XCTAssertThrowsError(try fixture.restore(invalidID)) {
            XCTAssertEqual($0 as? AudioMembershipCheckpointError, .invalidIdentifier)
        }
        let future = try mutate(data) { $0["version"] = 2 }
        XCTAssertThrowsError(try fixture.restore(future)) {
            XCTAssertEqual($0 as? AudioMembershipCheckpointError, .unsupportedVersion)
        }
    }

    func testRequiredFieldsAndMalformedJSONDoNotBecomeEmptyCache() throws {
        let fixture = try Fixture()
        let data = try fixture.encode([fixture.evidence()])
        for key in ["account", "entries", "loginID", "bootSessionID", "version"] {
            let incomplete = try mutate(data) { $0.removeValue(forKey: key) }
            XCTAssertThrowsError(try fixture.restore(incomplete)) { XCTAssertTrue($0 is DecodingError) }
        }
        for invalid in [Data(), Data("[]".utf8), Data("{broken".utf8)] {
            XCTAssertThrowsError(try fixture.restore(invalid)) { XCTAssertTrue($0 is DecodingError) }
        }
    }

    func testInvalidIdentityClaimsAndSelfPlaybackAreRejected() throws {
        let fixture = try Fixture()
        let data = try fixture.encode([fixture.evidence()])
        for (field, value) in [("algorithm", "unsupported"), ("fingerprint", "abc"), ("deviceID", " peer ")] {
            let invalid = try mutateEntry(data) { entry in
                var peer = try XCTUnwrap(entry["peer"] as? [String: Any])
                peer[field] = value; entry["peer"] = peer
            }
            XCTAssertThrowsError(try fixture.restore(invalid))
        }
        let selfPair = try mutateEntry(data) { $0["peer"] = $0["local"] }
        XCTAssertThrowsError(try fixture.restore(selfPair)) {
            XCTAssertEqual($0 as? AudioMembershipError, .selfPlayback)
        }
    }

    func testInvalidLifetimeAndDifferentClockIntervalsAreRejected() throws {
        let fixture = try Fixture()
        let data = try fixture.encode([fixture.evidence()])
        for (key, value) in [("issuedAtMilliseconds", Int64(0)),
                             ("expiresAtMilliseconds", fixture.wall),
                             ("expiresAtMilliseconds", fixture.wall + 3_600_001),
                             ("expiresAtMilliseconds", fixture.wall + 3_599_999)] {
            let invalid = try mutateEntry(data) { $0[key] = value }
            XCTAssertThrowsError(try fixture.restore(invalid)) {
                XCTAssertEqual($0 as? AudioMembershipCheckpointError, .invalidTime)
            }
        }
        let reverse = try mutateEntry(data) { $0["expiresAtMonotonic"] = $0["issuedAtMonotonic"] }
        XCTAssertThrowsError(try fixture.restore(reverse)) {
            XCTAssertEqual($0 as? AudioMembershipCheckpointError, .invalidTime)
        }
    }

    func testNonCanonicalClockComponentsCannotNormalizeIntoValidEvidence() throws {
        let fixture = try Fixture()
        let data = try fixture.encode([fixture.evidence()])
        for (key, value) in [("seconds", Int64(-1)), ("attoseconds", Int64(-1)),
                             ("attoseconds", Int64(1_000_000_000_000_000_000))] {
            let invalid = try mutateEntry(data) { entry in
                var instant = try XCTUnwrap(entry["issuedAtMonotonic"] as? [String: Any])
                instant[key] = value; entry["issuedAtMonotonic"] = instant
            }
            XCTAssertThrowsError(try fixture.restore(invalid)) {
                XCTAssertEqual($0 as? AudioMembershipCheckpointError, .invalidTime)
            }
        }
    }

    private func mutate(_ data: Data, _ update: (inout [String: Any]) throws -> Void) throws -> Data {
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        try update(&root)
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    private func mutateEntry(_ data: Data, _ update: (inout [String: Any]) throws -> Void) throws -> Data {
        try mutate(data) { root in
            var entries = try XCTUnwrap(root["entries"] as? [[String: Any]])
            XCTAssertFalse(entries.isEmpty)
            var entry = try XCTUnwrap(entries.first)
            try update(&entry); entries[0] = entry; root["entries"] = entries
        }
    }

    private struct Fixture {
        let account: AudioAccountIdentity
        let local: AudioProtocolIdentity
        let loginID = UUID()
        let bootID = UUID()
        let wall: Int64 = 1_000_000
        // Nanoseconds must survive exactly; millisecond rebasing would hide this.
        let instant = ContinuousClock().systemEpoch.advanced(by: .seconds(20_000) + .nanoseconds(17))

        init() throws {
            account = try AudioAccountIdentity(authority: "https://signal.example.invalid", tenantID: "tenant", userID: "user")
            local = try AudioProtocolIdentity(deviceID: "audio-local-device-0001", algorithm: .ed25519, fingerprint: String(repeating: "a", count: 64))
        }

        func evidence(peerIndex: Int = 1, lifetime: Int64 = 3_600_000) throws -> AudioAccountMembership {
            let peer = try AudioProtocolIdentity(deviceID: "audio-peer-device-\(peerIndex)", algorithm: .ed25519, fingerprint: String(repeating: "b", count: 64))
            let snapshot = AccountDeviceListSnapshot(generatedAtEpochMilliseconds: wall, callerDeviceId: local.deviceID,
                truncated: false, devices: [row(local, caller: true), row(peer, caller: false)], accountScope: account.serverScope)
            return try AudioAccountMembership.verifyFreshResponse(snapshot, account: account, local: local, peer: peer,
                requestStartedMilliseconds: wall, receivedMilliseconds: wall,
                requestStartedMonotonic: instant, receivedMonotonic: instant, lifetimeMilliseconds: lifetime)
        }

        func encode(_ evidence: [AudioAccountMembership], elapsed: Int64 = 0) throws -> Data {
            try AudioMembershipCheckpoint.encode(evidence, account: account, loginID: loginID, bootSessionID: bootID,
                nowMilliseconds: wall + elapsed, monotonicNow: instant.advanced(by: .milliseconds(elapsed)))
        }

        func restore(_ data: Data, elapsed: Int64 = 0) throws -> AudioMembershipCheckpoint.Restoration {
            try AudioMembershipCheckpoint.restore(data, account: account, loginID: loginID, bootSessionID: bootID,
                nowMilliseconds: wall + elapsed, monotonicNow: instant.advanced(by: .milliseconds(elapsed)))
        }

        private func row(_ identity: AudioProtocolIdentity, caller: Bool) -> AccountDeviceRecord {
            AccountDeviceRecord(deviceId: identity.deviceID, deviceName: nil, status: "active",
                protocolSigningAlgorithm: identity.algorithm.rawValue, protocolPublicKeyFingerprint: identity.fingerprint,
                platformRawValue: nil, deviceModel: nil, osVersion: nil, appVersion: nil, lanAddresses: [], publicAddress: nil,
                capabilities: [], registeredAtEpochMilliseconds: nil, lastSeenAtEpochMilliseconds: nil,
                presenceUpdatedAtEpochMilliseconds: nil, online: false, isCaller: caller)
        }
    }
}
