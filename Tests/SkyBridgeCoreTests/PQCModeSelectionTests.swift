import Foundation
import XCTest
import SkyBridgeProtocolCore

final class PQCModeSelectionTests: XCTestCase {
    private func isolated(_ test: (UserDefaults, PQCModePolicyStore) throws -> Void) throws {
        let name = "pqc-mode-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try test(defaults, PQCModePolicyStore(defaults: defaults, environment: [:]))
    }
    func testSavedQMissingFlagStaysStrict() throws {
        try isolated { defaults, store in
            defaults.set(true, forKey: PQCModePolicyStore.preferQKey)
            let policy = try store.snapshot()
            XCTAssertEqual(policy.selection, .init(preference: .qperiapt, strictlyMatchSelectedMode: true))
            XCTAssertThrowsError(try policy.selection.select(fromVerifiedIntersection: [0x0001, 0x0101]))
        }
    }
    func testNewAndLegacyNativePreferenceAreOrdinary() throws {
        try isolated { defaults, store in
            XCTAssertFalse(try store.snapshot().selection.strictlyMatchSelectedMode)
            defaults.set(true, forKey: PQCModePolicyStore.preferXWingKey)
            XCTAssertFalse(try store.snapshot().selection.strictlyMatchSelectedMode)
        }
    }
    func testOrdinaryPrefersQThenXThenMLRegardlessPicker() throws {
        for preference in PQCModeSelection.Preference.allCases {
            let mode = PQCModeSelection(preference: preference, strictlyMatchSelectedMode: false)
            XCTAssertEqual(try mode.select(fromVerifiedIntersection: [0x0101, 0x0001, 0x0012]), 0x0012)
            XCTAssertEqual(try mode.select(fromVerifiedIntersection: [0x0101, 0x0001]), 0x0001)
            XCTAssertEqual(try mode.select(fromVerifiedIntersection: [0x0101]), 0x0101)
            XCTAssertThrowsError(try mode.select(fromVerifiedIntersection: []))
        }
    }
    func testStrictMatrixNeverSelectsAnotherSuite() throws {
        for selected in PQCModeSelection.Preference.allCases {
            let mode = PQCModeSelection(preference: selected, strictlyMatchSelectedMode: true)
            XCTAssertEqual(mode.permittedSuiteWireIds, [selected.rawValue])
            for offered in PQCModeSelection.Preference.allCases {
                if selected == offered { XCTAssertEqual(try mode.select(fromVerifiedIntersection: [offered.rawValue]), selected.rawValue) }
                else { XCTAssertThrowsError(try mode.select(fromVerifiedIntersection: [offered.rawValue])) }
            }
        }
    }
    func testRuntimeNotReadyIsNeverAdvertised() {
        let mode = PQCModeSelection(preference: .qperiapt, strictlyMatchSelectedMode: false)
        XCTAssertEqual(mode.locallyReadySuites([0x0101]), [0x0101])
        XCTAssertEqual(PQCModeSelection(preference: .qperiapt, strictlyMatchSelectedMode: true).locallyReadySuites([0x0101]), [])
    }
    func testMalformedStoredFlagsFailWithoutRepair() throws {
        try isolated { defaults, store in
            for key in [PQCModePolicyStore.preferQKey, PQCModePolicyStore.preferXWingKey, PQCModePolicyStore.strictMatchKey] {
                defaults.set("false", forKey: key)
                XCTAssertThrowsError(try store.snapshot())
                XCTAssertThrowsError(try store.setStrictMatch(false))
                XCTAssertEqual(defaults.string(forKey: key), "false")
                defaults.removeObject(forKey: key)
            }
        }
    }
    func testPolicyChangeAndABACannotPublishOldAttempt() throws {
        try isolated { _, store in
            let a = try store.snapshot()
            _ = try store.setStrictMatch(true)
            _ = try store.setStrictMatch(false)
            XCTAssertEqual(try store.snapshot().selection, a.selection)
            XCTAssertNotEqual(try store.snapshot().revision, a.revision)
            var published = false
            XCTAssertThrowsError(try store.withCurrent(a) { published = true })
            XCTAssertFalse(published)
            try store.withCurrent(store.snapshot()) { published = true }
            XCTAssertTrue(published)
        }
    }
    func testNoopWriteDoesNotReplaceAttemptAndPreferenceRetainsStrict() throws {
        try isolated { _, store in
            let a = try store.snapshot()
            XCTAssertEqual(try store.setStrictMatch(false), a)
            _ = try store.setStrictMatch(true)
            XCTAssertTrue(try store.setPreference(.xwing).selection.strictlyMatchSelectedMode)
        }
    }
    func testFrozenOfferNeverReappliesPreferenceOrExpandsCapabilities() throws {
        XCTAssertEqual(try PQCModeSelection.frozenHandshakeOffer(selected: 0x0101,
            providerSuites: [0x0001, 0x0101], signingAlgorithm: "ML-DSA-65"), [0x0101])
        XCTAssertThrowsError(try PQCModeSelection.frozenHandshakeOffer(selected: 0x0012,
            providerSuites: [0x0001, 0x0101], signingAlgorithm: "ML-DSA-65"))
        XCTAssertThrowsError(try PQCModeSelection.frozenHandshakeOffer(selected: 0x0012,
            providerSuites: [0x0012], signingAlgorithm: "ML-DSA-87"))
    }
    private final class DroppingXWriteDefaults: UserDefaults {
        override func set(_ value: Any?, forKey defaultName: String) {
            if defaultName != PQCModePolicyStore.preferXWingKey { super.set(value, forKey: defaultName) }
        }
    }
    func testLostExclusiveFlagWriteFailsEvenWhenQWouldMaskIt() throws {
        let name = "pqc-mode-lost-write-\(UUID().uuidString)"
        let backing = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { backing.removePersistentDomain(forName: name) }
        backing.set(true, forKey: PQCModePolicyStore.preferXWingKey)
        let dropping = try XCTUnwrap(DroppingXWriteDefaults(suiteName: name))
        let store = PQCModePolicyStore(defaults: dropping, environment: [:])
        let before = try store.snapshot()
        XCTAssertThrowsError(try store.setPreference(.qperiapt))
        XCTAssertEqual(try store.snapshot(), before)
        XCTAssertTrue(backing.bool(forKey: PQCModePolicyStore.preferXWingKey))
        XCTAssertNil(backing.object(forKey: PQCModePolicyStore.preferQKey))
    }
    func testUnknownOrDuplicateIntersectionFails() {
        let mode = PQCModeSelection(preference: .mlkem, strictlyMatchSelectedMode: false)
        XCTAssertThrowsError(try mode.select(fromVerifiedIntersection: [0xFFFF]))
        XCTAssertThrowsError(try mode.select(fromVerifiedIntersection: [0x0101, 0x0101]))
    }
    func testAuthenticatedProfileMismatchSelectsNativeAndStaleRequestRequiresRefresh() throws {
        let prefix = "q-periapt-abi2-policy-v1/" + String(repeating: "a", count: 64) + "/" + String(repeating: "b", count: 64)
        let profile = prefix + "/1/" + String(repeating: "c", count: 64)
        let peerProfile = prefix + "/2/" + String(repeating: "c", count: 64)
        let proof = SignedKEMNegotiationProvenance(requestedSuiteWireIds: [0x0012, 0x0001, 0x0101],
            permittedSuiteWireIds: [0x0001, 0x0012, 0x0101], requesterPlatform: "iOS", requesterOSVersion: "iOS 26.0",
            requesterQProfile: profile, responderQProfile: peerProfile)
        try proof.validate(keys: [0x0001, 0x0101], responderPlatform: "android", responderOSVersion: "Android 16 API 36")
        let mode = PQCModeSelection(preference: .qperiapt, strictlyMatchSelectedMode: false)
        XCTAssertEqual(try proof.select(mode: mode, locallyReadySuites: [0x0012, 0x0001, 0x0101], localQProfile: profile), 0x0001)
        XCTAssertThrowsError(try proof.select(mode: mode, locallyReadySuites: [0x0001, 0x0101], localQProfile: nil))
        XCTAssertThrowsError(try proof.validate(keys: [0x0012, 0x0001, 0x0101], responderPlatform: "android", responderOSVersion: "Android 16 API 36"))
    }
}
