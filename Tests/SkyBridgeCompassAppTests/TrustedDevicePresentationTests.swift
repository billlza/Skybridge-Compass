import AppKit
import CryptoKit
import SwiftUI
import XCTest
import SkyBridgeCore
@testable import SkyBridgeCompassApp

@MainActor
final class TrustedDevicePresentationTests: XCTestCase {
    func testUnboundSavedPairingDoesNotClaimAnOnlineOrOfflineTrustedPeer() {
        let placeholder = TrustRecord(
            deviceId: "11111111-1111-4111-8111-111111111111",
            pubKeyFP: "", publicKey: Data(),
            capabilities: ["trusted", "file_transfer", "platform=iPadOS"],
            signature: Data(), deviceName: "iPad"
        )
        for reachability: OnlineDeviceStatus in [.offline, .online, .connected] {
            let card = TrustedDeviceCard(record: placeholder, subtitle: "iPad Pro", status: reachability) {}
            XCTAssertTrue(["待验证", "Needs verification", "要確認"].contains(card.statusText),
                "A saved record with no bound key cannot describe the current device as \(card.statusText)")
        }
    }

    func testBoundLegacyPeerRetainsEachReachabilityState() {
        let record = TrustRecord(
            deviceId: "id:bound-ipad", pubKeyFP: String(repeating: "a", count: 64),
            publicKey: Data(repeating: 1, count: 32), capabilities: ["trusted"],
            signature: Data(), deviceName: "iPad"
        )
        let labels = [OnlineDeviceStatus.offline, .online, .connected].map {
            TrustedDeviceCard(record: record, subtitle: "iPad Pro", status: $0) {}.statusText
        }
        XCTAssertEqual(Set(labels).count, 3)
        XCTAssertTrue(["离线", "Offline", "オフライン"].contains(labels[0]))
        XCTAssertTrue(["在线", "Online", "オンライン"].contains(labels[1]))
        XCTAssertTrue(["已连接", "Connected", "接続済み"].contains(labels[2]))
    }

    func testCurrentProtocolBindingWithEmptyLegacyFingerprintIsVisibleInDetails() throws {
        let key = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let fingerprint = ProtocolIdentityBinding.computeFingerprint(algorithm: .ed25519, publicKeyBytes: key)
        let record = TrustRecord(
            deviceId: "id:bound-ipad", pubKeyFP: "", publicKey: Data(),
            protocolIdentityBindingsV2: [ProtocolIdentityBindingV2(
                algorithm: .ed25519, publicKey: key, fingerprint: fingerprint,
                source: .authenticatedHandshake, generation: 1
            )], capabilities: ["trusted"], signature: Data(), deviceName: "iPad"
        )
        let projected = try XCTUnwrap(TrustSyncService.buildDisplayGroups(from: [record]).first).displayRecord
        let detail = detailView(projected)
        XCTAssertEqual(detail.identityFingerprintText, fingerprint)
        XCTAssertTrue(["已配对/已信任", "Paired / Trusted", "ペア済み / 信頼済み"].contains(detail.trustSummaryText))
        let card = TrustedDeviceCard(record: projected, subtitle: "iPad Pro", status: .online) {}
        XCTAssertTrue(["在线", "Online", "オンライン"].contains(card.statusText))
    }

    func testUnboundPairingDetailsAndCardAgreeAndRender() throws {
        let record = TrustRecord(
            deviceId: "11111111-1111-4111-8111-111111111111", pubKeyFP: "", publicKey: Data(),
            capabilities: ["trusted", "platform=iPadOS"], signature: Data(), deviceName: "iPad"
        )
        let detail = detailView(record)
        XCTAssertTrue(["配对记录待验证", "Pairing needs verification", "ペアリング記録の確認が必要"].contains(detail.trustSummaryText))
        XCTAssertTrue(["未绑定", "Unbound", "未バインド"].contains(detail.identityFingerprintText))
        _ = NSApplication.shared
        let content = VStack(spacing: 20) {
            TrustedDeviceCard(record: record, subtitle: "iPad Pro 11-inch (M4) · iPadOS", status: .offline) {}
            detail
        }
        .padding(24)
        .frame(width: 760, height: 580)
        .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: content)
        host.frame = CGRect(x: 0, y: 0, width: 760, height: 580)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        XCTAssertGreaterThan(bitmap.pixelsWide, 0)
        if let directory = ProcessInfo.processInfo.environment["SKYBRIDGE_UI_TEST_ARTIFACT_DIR"] {
            let root = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: root.appendingPathComponent("unbound-pairing-presentation.png"))
        }
    }

    private func detailView(_ record: TrustRecord) -> TrustedDeviceDetailView {
        TrustedDeviceDetailView(
            record: record, relatedRecords: [record],
            presentationMetadata: ApplePeerDeviceMetadataNormalizer.Presentation(
                modelName: "iPad Pro 11-inch (M4)", chip: "M4", platform: "iPadOS", osVersion: nil
            ), status: .offline, onDisconnect: nil, onRepairP2PTrust: { _ in }, onRemoveTrust: { _, _ in }
        )
    }
}
