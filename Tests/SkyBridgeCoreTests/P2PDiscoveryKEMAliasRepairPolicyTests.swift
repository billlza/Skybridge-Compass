import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
final class P2PDiscoveryKEMAliasRepairPolicyTests: XCTestCase {
    func testAliasRepairCandidatesPreservePrimaryIdentityOrderAndDedupeDerivedAliases() {
        let device = DiscoveredDevice(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            name: "Trusted Mac",
            ipv4: nil,
            ipv6: nil,
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 50873],
            uniqueIdentifier: nil,
            source: .skybridgeBonjour,
            deviceId: "ID:Trusted-Mac_01"
        )

        let aliases = P2PDiscoveryKEMAliasRepairPolicy.aliasRepairCandidates(for: device)

        XCTAssertEqual(
            aliases,
            [
                "ID:Trusted-Mac_01",
                "id:trusted-mac_01",
                "Trusted-Mac_01",
                "trusted-mac_01",
                "11111111-1111-1111-1111-111111111111",
                "id:11111111-1111-1111-1111-111111111111"
            ]
        )
        XCTAssertEqual(aliases.count, Set<String>(aliases).count)
    }

    func testUniqueTrustRecordIgnoresRecordsWithoutUsableActiveKEMMaterial() {
        let device = discoveredDevice(
            name: "Unmatched Discovery Name",
            ipv6: "fe80::c55:97f0:7246:915%en0"
        )
        let matchingAlias = "host:fe80::c55:97f0:7246:915"
        let nilKEMRecord = trustRecord(
            deviceId: "id:nil-kem",
            deviceName: "Other Device",
            kemPublicKeys: nil,
            knownDeviceIds: [matchingAlias]
        )
        let emptyKEMRecord = trustRecord(
            deviceId: "id:empty-kem",
            deviceName: "Other Device",
            kemPublicKeys: [],
            knownDeviceIds: [matchingAlias]
        )
        let invalidKEMRecord = trustRecord(
            deviceId: "id:invalid-kem",
            deviceName: "Other Device",
            kemPublicKeys: [
                KEMPublicKeyInfo(suiteWireId: CryptoSuite.xwingMLDSA.wireId, publicKey: Data())
            ],
            knownDeviceIds: [matchingAlias]
        )
        let classicKEMRecord = trustRecord(
            deviceId: "id:classic-kem",
            deviceName: "Other Device",
            kemPublicKeys: [
                KEMPublicKeyInfo(
                    suiteWireId: CryptoSuite.x25519Ed25519.wireId,
                    publicKey: Data(repeating: 0x11, count: 32)
                )
            ],
            knownDeviceIds: [matchingAlias]
        )
        let tombstoneRecord = trustRecord(
            deviceId: "id:tombstone-kem",
            deviceName: "Other Device",
            kemPublicKeys: [validXWingKey()],
            recordType: .revoke,
            knownDeviceIds: [matchingAlias]
        )
        let expiredRecord = trustRecord(
            deviceId: "id:expired-kem",
            deviceName: "Other Device",
            kemPublicKeys: [validXWingKey()],
            revokedAt: Date(timeIntervalSinceNow: -31 * 24 * 60 * 60),
            knownDeviceIds: [matchingAlias]
        )
        let quarantinedRecord = trustRecord(
            deviceId: "id:quarantined-kem",
            deviceName: "Other Device",
            kemPublicKeys: [validXWingKey()],
            knownDeviceIds: [matchingAlias],
            lifecycleState: .quarantined
        )
        let reverificationRecord = trustRecord(
            deviceId: "id:reverification-kem",
            deviceName: "Other Device",
            kemPublicKeys: [validXWingKey()],
            knownDeviceIds: [matchingAlias],
            lifecycleState: .reverificationRequired
        )
        let activeValidRecord = trustRecord(
            deviceId: "id:active-valid-kem",
            deviceName: "Other Device",
            kemPublicKeys: [validXWingKey()],
            knownDeviceIds: [matchingAlias]
        )

        let selected = P2PDiscoveryKEMAliasRepairPolicy.uniqueTrustRecord(
            for: device,
            records: [
                nilKEMRecord,
                emptyKEMRecord,
                invalidKEMRecord,
                classicKEMRecord,
                tombstoneRecord,
                expiredRecord,
                quarantinedRecord,
                reverificationRecord,
                activeValidRecord
            ]
        )

        XCTAssertEqual(selected?.deviceId, activeValidRecord.deviceId)
    }

    func testUniqueTrustRecordNormalizesBracketAndEmojiDisplayNameSuffixes() {
        let trustedRecord = trustRecord(
            deviceId: "id:trusted-qa-iphone",
            deviceName: "QA iPhone",
            kemPublicKeys: [validXWingKey()],
            knownDeviceIds: []
        )

        let selected = P2PDiscoveryKEMAliasRepairPolicy.uniqueTrustRecord(
            for: discoveredDevice(name: "QA iPhone 📱 (Nearby) [IPv6]【Debug】"),
            records: [trustedRecord]
        )

        XCTAssertEqual(selected?.deviceId, trustedRecord.deviceId)
    }

    func testKEMPublicKeyConversionFiltersEmptyValuesAndSortsBySuiteWireId() {
        let xwing = Data(repeating: 0x01, count: 1_216)
        let mlkem = Data(repeating: 0x02, count: 1_184)
        let fs = Data(repeating: 0x03, count: 1_184)
        let keys = P2PDiscoveryKEMAliasRepairPolicy.kemPublicKeys(
            from: [
                .mlkem768MLDSA65FS: fs,
                .xwingMLDSA: xwing,
                .mlkem768MLDSA65: mlkem,
                .x25519Ed25519: Data()
            ]
        )

        XCTAssertEqual(
            keys.map(\.suiteWireId),
            [
                CryptoSuite.xwingMLDSA.wireId,
                CryptoSuite.mlkem768MLDSA65.wireId,
                CryptoSuite.mlkem768MLDSA65FS.wireId
            ]
        )
        XCTAssertEqual(keys.map(\.publicKey), [xwing, mlkem, fs])
    }

    private func discoveredDevice(name: String, ipv6: String? = nil) -> DiscoveredDevice {
        DiscoveredDevice(
            id: UUID(uuidString: "0F8794F4-EC2A-4E70-BCE1-601264CE460F")!,
            name: name,
            ipv4: "192.168.10.40",
            ipv6: ipv6,
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 50873],
            uniqueIdentifier: "recent:name:\(name)",
            source: .skybridgeBonjour
        )
    }

    private func trustRecord(
        deviceId: String,
        deviceName: String,
        kemPublicKeys: [KEMPublicKeyInfo]?,
        recordType: TrustRecordType = .add,
        revokedAt: Date? = nil,
        knownDeviceIds: [String]? = nil,
        lifecycleState: TrustLifecycleState = .active
    ) -> TrustRecord {
        TrustRecord(
            deviceId: deviceId,
            pubKeyFP: String(repeating: "a", count: 64),
            publicKey: Data([0x01]),
            kemPublicKeys: kemPublicKeys,
            signature: Data([0x02]),
            recordType: recordType,
            revokedAt: revokedAt,
            deviceName: deviceName,
            currentDeviceId: deviceId,
            knownDeviceIds: knownDeviceIds,
            lifecycleState: lifecycleState
        )
    }

    private func validXWingKey() -> KEMPublicKeyInfo {
        KEMPublicKeyInfo(
            suiteWireId: CryptoSuite.xwingMLDSA.wireId,
            publicKey: Data(repeating: 0xCC, count: 1_216)
        )
    }
}
