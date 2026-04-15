import XCTest
@testable import SkyBridgeCore

final class RegistrationRiskPayloadTests: XCTestCase {
    func testNormalizedRegistrationIdentifierHashUsesNormalizedEmail() {
        let lower = SupabaseService.normalizedRegistrationIdentifierHash(
            "user@example.com",
            type: .email
        )
        let mixed = SupabaseService.normalizedRegistrationIdentifierHash(
            " User@Example.com ",
            type: .email
        )

        XCTAssertEqual(lower, mixed)
        XCTAssertEqual(lower.count, 64)
    }

    func testNormalizedRegistrationIdentifierHashUsesNormalizedPhone() {
        let plain = SupabaseService.normalizedRegistrationIdentifierHash(
            "+8613811112222",
            type: .phone
        )
        let formatted = SupabaseService.normalizedRegistrationIdentifierHash(
            " +86 138-1111-2222 ",
            type: .phone
        )

        XCTAssertEqual(plain, formatted)
        XCTAssertEqual(plain.count, 64)
    }
}
