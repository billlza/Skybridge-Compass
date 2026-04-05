import XCTest
@testable import SkyBridgeCompass_iOS

@MainActor
@available(iOS 17.0, *)
final class ConnectionCodeFormatTests: XCTestCase {
    func testSanitizeConnectionCodeInputUppercasesFiltersAndCapsLength() {
        let raw = "ab-cd12 34efghjkmnpqrstuvwxyz23456789"
        let sanitized = CrossNetworkWebRTCManager.sanitizeConnectionCodeInput(raw)

        XCTAssertEqual(sanitized, "ABCD234EFGHJKMNP")
        XCTAssertEqual(sanitized.count, CrossNetworkWebRTCManager.maximumConnectionCodeLength)
    }

    func testCanSubmitConnectionCodeAcceptsLegacyAndCurrentLengths() {
        XCTAssertTrue(CrossNetworkWebRTCManager.canSubmitConnectionCode("ABCDEF"))
        XCTAssertTrue(CrossNetworkWebRTCManager.canSubmitConnectionCode("ABCDEFGH"))
        XCTAssertTrue(CrossNetworkWebRTCManager.canSubmitConnectionCode("ABCDEFGHJK"))
        XCTAssertFalse(CrossNetworkWebRTCManager.canSubmitConnectionCode("ABCDE"))
        XCTAssertFalse(CrossNetworkWebRTCManager.canSubmitConnectionCode("ABCDEFG"))
    }

    func testIOSDeviceSupportGateBlocksExplicit2018And2019A12FamilyDevices() {
        XCTAssertFalse(IOSDeviceSupportGate.isSupported(modelIdentifier: "iPhone11,2"))
        XCTAssertFalse(IOSDeviceSupportGate.isSupported(modelIdentifier: "iPhone11,8"))
        XCTAssertFalse(IOSDeviceSupportGate.isSupported(modelIdentifier: "iPad8,1"))
        XCTAssertFalse(IOSDeviceSupportGate.isSupported(modelIdentifier: "iPad11,3"))
    }

    func testIOSDeviceSupportGateAllows2020AndLaterDevices() {
        XCTAssertTrue(IOSDeviceSupportGate.isSupported(modelIdentifier: "iPhone12,8"))
        XCTAssertTrue(IOSDeviceSupportGate.isSupported(modelIdentifier: "iPhone13,2"))
        XCTAssertTrue(IOSDeviceSupportGate.isSupported(modelIdentifier: "iPad11,6"))
        XCTAssertTrue(IOSDeviceSupportGate.isSupported(modelIdentifier: "iPad13,1"))
    }

    func testSupabaseServiceNormalizesRelativeAvatarURLs() {
        let baseURL = URL(string: "https://demo.example.com")!

        XCTAssertEqual(
            SupabaseService.normalizedRemoteAssetURL(
                "/storage/v1/object/public/avatars/user.jpg",
                baseURL: baseURL
            ),
            "https://demo.example.com/storage/v1/object/public/avatars/user.jpg"
        )
        XCTAssertEqual(
            SupabaseService.normalizedRemoteAssetURL(
                "storage/v1/object/public/avatars/user.jpg",
                baseURL: baseURL
            ),
            "https://demo.example.com/storage/v1/object/public/avatars/user.jpg"
        )
        XCTAssertEqual(
            SupabaseService.normalizedRemoteAssetURL(
                "https://cdn.example.com/avatar.jpg",
                baseURL: baseURL
            ),
            "https://cdn.example.com/avatar.jpg"
        )
    }

    func testRemoteUserProfileCarriesAvatarAndNebulaFields() {
        let profile = SupabaseService.RemoteUserProfile(
            userId: "user-1",
            email: "person@example.com",
            displayName: "Primary Name",
            avatarURL: "https://demo.example.com/avatar.jpg",
            nebulaId: "NEBULA-123"
        )

        XCTAssertEqual(profile.userId, "user-1")
        XCTAssertEqual(profile.displayName, "Primary Name")
        XCTAssertEqual(profile.avatarURL, "https://demo.example.com/avatar.jpg")
        XCTAssertEqual(profile.nebulaId, "NEBULA-123")
    }

}
