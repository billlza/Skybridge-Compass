import XCTest
@testable import SkyBridgeCore

@MainActor
final class SupabaseOAuthAuthorizationURLTests: XCTestCase {
    func testMakeAppleOAuthAuthorizationURLBuildsDeepLinkAuthorizeRequest() throws {
        SupabaseService.shared.updateConfiguration(
            .init(
                url: URL(string: "https://demo-project.supabase.co")!,
                anonKey: "anon-key"
            )
        )

        let redirectURL = URL(string: "skybridge://auth/apple-callback")!
        let authorizationURL = try SupabaseService.shared.makeAppleOAuthAuthorizationURL(
            redirectTo: redirectURL,
            captchaToken: "turnstile-token"
        )

        let components = try XCTUnwrap(URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false))
        let queryItems = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "demo-project.supabase.co")
        XCTAssertEqual(components.path, "/auth/v1/authorize")
        XCTAssertEqual(queryItems["provider"], "apple")
        XCTAssertEqual(queryItems["redirect_to"], redirectURL.absoluteString)
        XCTAssertEqual(queryItems["scopes"], "name email")
        XCTAssertEqual(queryItems["captcha_token"], "turnstile-token")
    }
}
