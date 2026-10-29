import XCTest

final class AuthenticationViewSourceContractTests: XCTestCase {
    func testMacAuthenticationReturnSubmitsThroughSharedCaptchaAwareAction() throws {
        let source = try repositorySource("Sources/SkyBridgeCompassApp/AuthenticationView.swift")
        let submitFunction = try sourceFunction(named: "submitSelectedLoginMethod", in: source)
        let emailBranch = try sourceSlice(
            in: submitFunction,
            from: "case .email:",
            to: "}"
        )
        let beginTurnstileFunction = try sourceFunction(named: "beginSupabaseTurnstileAction", in: source)
        let appleFlowFunction = try sourceFunction(named: "beginAppleSignInFlow", in: source)

        XCTAssertTrue(
            source.contains(".onSubmit {\n            submitSelectedLoginMethod()"),
            "Return from SwiftUI text fields must route through the shared submit helper."
        )
        XCTAssertTrue(
            source.contains("private var defaultAuthenticationSubmitButton: some View")
        )
        XCTAssertTrue(
            source.contains("Button(action: submitSelectedLoginMethod)")
        )
        XCTAssertTrue(
            source.contains(".keyboardShortcut(.defaultAction)"),
            "The mac login surface needs a default action for Return when no field owns submit."
        )
        XCTAssertTrue(
            source.contains("!viewModel.showCaptchaView"),
            "Return must not start a second auth request while the behavior captcha is active."
        )
        XCTAssertTrue(
            source.contains("!isAuthenticationSubmitInFlight"),
            "Direct async submit paths need a synchronous re-entry guard for Enter/default-action double dispatch."
        )
        XCTAssertTrue(
            source.contains("pendingSupabaseTurnstileContext == nil")
        )
        XCTAssertTrue(
            source.contains("pendingSupabaseTurnstileAction == nil")
        )

        XCTAssertTrue(
            submitFunction.contains("case .email:")
        )
        XCTAssertTrue(
            emailBranch.contains("beginSupabaseTurnstileAction(viewModel.isRegistrationMode ? .registerEmail : .loginEmail)"),
            "Email Return must use the same Turnstile-gated action as the visible button."
        )
        XCTAssertFalse(
            emailBranch.contains("loginWithEmail"),
            "Email Return must not bypass Turnstile by calling the view model directly."
        )
        XCTAssertTrue(
            submitFunction.contains("submitPhoneLoginForm()"),
            "Phone Return should share the visible phone primary action."
        )
        XCTAssertTrue(
            submitFunction.contains("submitNebulaLoginForm()"),
            "Nebula Return should share the visible Nebula primary action."
        )
        XCTAssertTrue(
            source.contains("performRequestIfNeeded(for: nativeAppleSignInRequestID)"),
            "Native Apple Return should trigger the existing ASAuthorization flow instead of the web OAuth fallback."
        )

        XCTAssertTrue(
            beginTurnstileFunction.contains("failSupabaseTurnstileChallenge(\"turnstile_origin_missing\")"),
            "A missing Supabase origin is not proof that captcha is unnecessary."
        )
        XCTAssertTrue(
            appleFlowFunction.contains("failSupabaseTurnstileChallenge(\"turnstile_origin_missing\")"),
            "Native Apple authorization must not continue without a known Supabase origin for Turnstile."
        )
    }

    func testMacTurnstileWebViewFailsClosedInsteadOfPollingIndefinitely() throws {
        let source = try repositorySource("Sources/SkyBridgeCompassApp/SupabaseTurnstileView.swift")

        XCTAssertTrue(source.contains("webView.navigationDelegate = context.coordinator"))
        XCTAssertTrue(source.contains("WKScriptMessageHandler, WKNavigationDelegate"))
        XCTAssertTrue(source.contains("didFailProvisionalNavigation"))
        XCTAssertTrue(source.contains("didFail navigation"))
        XCTAssertTrue(source.contains("webViewWebContentProcessDidTerminate"))
        XCTAssertTrue(source.contains("turnstile_web_content_process_terminated"))

        XCTAssertTrue(source.contains("var terminal = false"))
        XCTAssertTrue(source.contains("var apiLoadTimer = null"))
        XCTAssertTrue(source.contains("var apiReadyTimer = null"))
        XCTAssertTrue(source.contains("apiScript.onerror"))
        XCTAssertTrue(source.contains("turnstile_api_load_failed"))
        XCTAssertTrue(source.contains("turnstile_api_load_timeout"))
        XCTAssertTrue(source.contains("turnstile_api_ready_timeout"))
        XCTAssertFalse(
            source.contains("window.setTimeout(renderWidget, 60)"),
            "The widget loader must not spin forever on a missing Cloudflare API object."
        )
        XCTAssertFalse(
            source.contains("window.addEventListener(\"load\", renderWidget)"),
            "The widget loader should not depend only on a window load event that may already have passed."
        )

        XCTAssertTrue(source.contains("private var didComplete = false"))
        XCTAssertTrue(source.contains("private func succeed(_ token: String)"))
        XCTAssertTrue(source.contains("private func fail(_ message: String)"))
        XCTAssertTrue(source.contains("guard !didComplete else { return }"))
        XCTAssertTrue(source.contains("coordinator.invalidate()"))
        XCTAssertTrue(source.contains("nsView.stopLoading()"))
        XCTAssertTrue(source.contains("nsView.navigationDelegate = nil"))
        XCTAssertTrue(
            source.contains("JSONSerialization.data(withJSONObject: value"),
            "Site key and action should be emitted as JSON string literals, not hand-escaped JavaScript."
        )
    }

    func testMacSupabaseRefreshCallSitesUseAuthenticationServiceSingleOwner() throws {
        let refreshCallSites = [
            "Sources/SkyBridgeCompassApp/AuthenticationViewModel.swift",
            "Sources/SkyBridgeCompassApp/UserProfileOverlay.swift",
            "Sources/SkyBridgeCompassApp/UserProfileView.swift"
        ]

        for relativePath in refreshCallSites {
            let source = try repositorySource(relativePath)
            let whitespaceCollapsed = source.components(
                separatedBy: .whitespacesAndNewlines
            ).joined()
            XCTAssertFalse(
                source.contains(".refreshAccessToken("),
                "\(relativePath) must not bypass AuthenticationService's session-bound refresh owner."
            )
            XCTAssertTrue(
                whitespaceCollapsed.contains("validSession(forceRefresh:true)"),
                "\(relativePath) must force refresh through AuthenticationService's authoritative session owner."
            )
        }
    }

    private func repositorySource(_ relativePath: String) throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repoRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func sourceFunction(named name: String, in source: String) throws -> String {
        guard let nameRange = source.range(of: "func \(name)") else {
            throw NSError(
                domain: "AuthenticationViewSourceContractTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Missing function \(name)"]
            )
        }
        guard let openingBrace = source[nameRange.lowerBound...].firstIndex(of: "{") else {
            throw NSError(
                domain: "AuthenticationViewSourceContractTests",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Missing opening brace for \(name)"]
            )
        }

        var depth = 0
        var current = openingBrace
        while current < source.endIndex {
            let character = source[current]
            if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    return String(source[nameRange.lowerBound...current])
                }
            }
            current = source.index(after: current)
        }

        throw NSError(
            domain: "AuthenticationViewSourceContractTests",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "Missing closing brace for \(name)"]
        )
    }

    private func sourceSlice(in source: String, from start: String, to end: String) throws -> String {
        guard let startRange = source.range(of: start) else {
            throw NSError(
                domain: "AuthenticationViewSourceContractTests",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Missing slice start \(start)"]
            )
        }
        guard let endRange = source[startRange.upperBound...].range(of: end) else {
            throw NSError(
                domain: "AuthenticationViewSourceContractTests",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Missing slice end \(end)"]
            )
        }
        return String(source[startRange.lowerBound..<endRange.upperBound])
    }
}
