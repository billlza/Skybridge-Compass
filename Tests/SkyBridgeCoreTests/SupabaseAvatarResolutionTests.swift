import XCTest
@testable import SkyBridgeCore

final class SupabaseAvatarResolutionTests: XCTestCase {
    func testAuthSessionDecodesLegacyPayloadWithoutAvatarURL() throws {
        let payload: [String: Any] = [
            "accessToken": "token",
            "refreshToken": "refresh",
            "userIdentifier": "user-1",
            "nebulaId": "nebula-1",
            "displayName": "Sky",
            "issuedAt": 0
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)

        let session = try JSONDecoder().decode(AuthSession.self, from: data)

        XCTAssertNil(session.avatarURL)
        XCTAssertEqual(session.displayName, "Sky")
    }

    func testAuthSessionRoundTripsAvatarURL() throws {
        let session = AuthSession(
            accessToken: "token",
            refreshToken: "refresh",
            userIdentifier: "user-1",
            nebulaId: "nebula-1",
            displayName: "Sky",
            avatarURL: "https://demo.example.com/avatar.jpg",
            issuedAt: Date(timeIntervalSinceReferenceDate: 0)
        )

        let encoded = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(AuthSession.self, from: encoded)

        XCTAssertEqual(decoded.avatarURL, "https://demo.example.com/avatar.jpg")
        XCTAssertEqual(decoded.nebulaId, "nebula-1")
    }

    func testNormalizedRemoteAssetURLExpandsRelativeStoragePaths() {
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
    }

    func testNormalizedRemoteAssetURLPreservesAbsoluteURLs() {
        let baseURL = URL(string: "https://demo.example.com")!
        XCTAssertEqual(
            SupabaseService.normalizedRemoteAssetURL(
                "https://cdn.example.com/avatar.jpg",
                baseURL: baseURL
            ),
            "https://cdn.example.com/avatar.jpg"
        )
    }

    func testAvatarFinalizeResponseDecodesCanonicalFields() throws {
        let payload: [String: Any] = [
            "avatar_id": "A0B87616-D8A6-4C70-A2AB-8806A251CE8D",
            "avatar_url": "https://demo.example.com/storage/v1/object/public/avatars/user/avatar.jpg",
            "storage_path": "user/avatar.jpg",
            "universal_user_id": "8E2B4A39-4D07-4483-BFEF-C0728E31861F",
            "auth_user_id": "9C7F72B5-2F1D-42EC-ABAE-FA7BA412C5B0",
            "is_active": true,
            "projection_status": "projected_and_mirrored",
            "auth_metadata_mirrored": true
        ]

        let data = try JSONSerialization.data(withJSONObject: payload)
        let decoded = try JSONDecoder().decode(SupabaseService.AvatarFinalizeResponse.self, from: data)

        XCTAssertEqual(decoded.storagePath, "user/avatar.jpg")
        XCTAssertEqual(
            decoded.avatarURL,
            "https://demo.example.com/storage/v1/object/public/avatars/user/avatar.jpg"
        )
        XCTAssertEqual(decoded.projectionStatus, "projected_and_mirrored")
        XCTAssertEqual(decoded.authMetadataMirrored, true)
        XCTAssertTrue(decoded.isActive)
    }
}
