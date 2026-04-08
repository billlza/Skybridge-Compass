import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
final class RemoteControlTrustResolutionTests: XCTestCase {
    func testEquivalentInboundTrustRecordsCollapseToSingleCanonicalDevice() {
        let remotePeerId = RemoteControlInboundTrustResolver.soaPeerId(for: "id:peer-mac")

        let records = [
            TrustRecord(
                deviceId: "legacy-peer-a",
                pubKeyFP: String(repeating: "a", count: 64),
                publicKey: Data([0x01]),
                protocolPublicKey: Data([0x02]),
                protocolSigningAlgorithm: .mlDSA65,
                protocolPublicKeyFingerprint: String(repeating: "f", count: 64),
                signature: Data([0x03]),
                deviceName: "Lza's MacBook Pro",
                currentDeviceId: "id:peer-mac",
                knownDeviceIds: ["id:peer-mac", "bonjour:lza's macbook pro@local."]
            ),
            TrustRecord(
                deviceId: "shadow-peer-a",
                pubKeyFP: String(repeating: "b", count: 64),
                publicKey: Data([0x11]),
                protocolPublicKey: Data([0x12]),
                protocolSigningAlgorithm: .mlDSA65,
                protocolPublicKeyFingerprint: String(repeating: "f", count: 64),
                signature: Data([0x13]),
                deviceName: "Lza's MacBook Pro",
                currentDeviceId: "id:peer-mac",
                knownDeviceIds: ["id:peer-mac"]
            )
        ]

        XCTAssertEqual(
            RemoteControlInboundTrustResolver.resolve(remoteSOAPeerId: remotePeerId, records: records),
            .resolved(deviceId: "id:peer-mac", fingerprint: String(repeating: "f", count: 64))
        )
    }

    func testConflictingInboundTrustRecordsRemainAmbiguous() {
        let remotePeerId = RemoteControlInboundTrustResolver.soaPeerId(for: "id:shared-peer")

        let records = [
            TrustRecord(
                deviceId: "legacy-peer-a",
                pubKeyFP: String(repeating: "a", count: 64),
                publicKey: Data([0x01]),
                protocolPublicKey: Data([0x02]),
                protocolSigningAlgorithm: .mlDSA65,
                protocolPublicKeyFingerprint: String(repeating: "1", count: 64),
                signature: Data([0x03]),
                deviceName: "Lza's MacBook Pro",
                currentDeviceId: "id:peer-mac-a",
                knownDeviceIds: ["id:shared-peer"]
            ),
            TrustRecord(
                deviceId: "legacy-peer-b",
                pubKeyFP: String(repeating: "b", count: 64),
                publicKey: Data([0x11]),
                protocolPublicKey: Data([0x12]),
                protocolSigningAlgorithm: .mlDSA65,
                protocolPublicKeyFingerprint: String(repeating: "2", count: 64),
                signature: Data([0x13]),
                deviceName: "Lza's MacBook Pro",
                currentDeviceId: "id:peer-mac-b",
                knownDeviceIds: ["id:shared-peer"]
            )
        ]

        XCTAssertEqual(
            RemoteControlInboundTrustResolver.resolve(remoteSOAPeerId: remotePeerId, records: records),
            .ambiguous(
                deviceIds: ["id:peer-mac-a", "id:peer-mac-b"],
                fingerprints: [String(repeating: "1", count: 64), String(repeating: "2", count: 64)]
            )
        )
    }

    func testEquivalentBareAndPersistentCurrentDeviceIdsCollapse() {
        let rawUUID = "07CB9A6E-7492-4680-9DD7-F37DC8568891"
        let remotePeerId = RemoteControlInboundTrustResolver.soaPeerId(for: "id:\(rawUUID.lowercased())")

        let records = [
            TrustRecord(
                deviceId: "legacy-peer-a",
                pubKeyFP: String(repeating: "a", count: 64),
                publicKey: Data([0x01]),
                protocolPublicKey: Data([0x02]),
                protocolSigningAlgorithm: .mlDSA65,
                protocolPublicKeyFingerprint: String(repeating: "c", count: 64),
                signature: Data([0x03]),
                deviceName: "iPad",
                currentDeviceId: rawUUID,
                knownDeviceIds: [rawUUID, "id:\(rawUUID.lowercased())", "bonjour:ipad@local."]
            ),
            TrustRecord(
                deviceId: "shadow-peer-a",
                pubKeyFP: String(repeating: "b", count: 64),
                publicKey: Data([0x11]),
                protocolPublicKey: Data([0x12]),
                protocolSigningAlgorithm: .mlDSA65,
                protocolPublicKeyFingerprint: String(repeating: "c", count: 64),
                signature: Data([0x13]),
                deviceName: "iPad",
                currentDeviceId: "id:\(rawUUID.lowercased())",
                knownDeviceIds: ["id:\(rawUUID.lowercased())"]
            )
        ]

        XCTAssertEqual(
            RemoteControlInboundTrustResolver.resolve(remoteSOAPeerId: remotePeerId, records: records),
            .resolved(
                deviceId: "id:\(rawUUID.lowercased())",
                fingerprint: String(repeating: "c", count: 64)
            )
        )
    }
}
