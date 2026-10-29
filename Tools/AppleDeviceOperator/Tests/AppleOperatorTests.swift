import XCTest

/// An installed-app UI operator. No fixture mode, state reset, product install,
/// mirror window, or automatic approval of system permission dialogs.
final class AppleOperatorTests: XCTestCase {
    struct Request: Decodable {
        let bundle_id: String
        let actions: [Action]
    }
    struct Action: Decodable {
        let action: String
        let identifier: String?
        let label: String?
        let text: String?
        let element_type: ElementType?
        let within_identifier: String?
        let child_identifier: String?
        let normalized_position: Double?
        let normalized_x: Double?
        let normalized_y: Double?
    }
    enum ElementType: String, Decodable {
        case button, other, slider
        case staticText = "static_text"
        case textField = "text_field"
        case secureTextField = "secure_text_field"
        case searchField = "search_field"
        case textView = "text_view"
        case scrollView = "scroll_view"
        case toggle = "switch"

        var queryType: XCUIElement.ElementType {
            switch self {
            case .button: return .button
            case .other: return .other
            case .staticText: return .staticText
            case .textField: return .textField
            case .secureTextField: return .secureTextField
            case .searchField: return .searchField
            case .textView: return .textView
            case .scrollView: return .scrollView
            case .toggle: return .switch
            case .slider: return .slider
            }
        }
    }
    struct Element: Encodable {
        let identifier: String
        let label: String
        let type: UInt
        let enabled: Bool
        let hittable: Bool
        let normalized_slider_position: Double?
    }
    struct Result: Encodable {
        let success: Bool
        let completion: String
        let bundle_id: String
        let executed_actions: Int
        let snapshot_format: String
        let elements: [Element]?
        let tree: String?
        let tree_truncated: Bool
        let error: String?
    }
    enum Failure: Error { case invalidRequest, ambiguousElement, elementNotHittable, invalidTextTarget, missingElement, queryTooBroad, systemAlertBlocksApplication }

    @MainActor
    func testOperateInstalledApp() throws {
        continueAfterFailure = false
        guard let raw = ProcessInfo.processInfo.environment["SKYBRIDGE_OPERATOR_REQUEST"],
              let bytes = raw.data(using: .utf8), bytes.count <= 65_536 else {
            throw Failure.invalidRequest
        }
        let request = try JSONDecoder().decode(Request.self, from: bytes)
        guard !request.bundle_id.isEmpty, (1...64).contains(request.actions.count) else {
            throw Failure.invalidRequest
        }
        let app = XCUIApplication(bundleIdentifier: request.bundle_id)
        // SpringBoard owns interruptions above the current app. Activating it first
        // navigates to Home and can hide the exact alert the request intends to inspect.
        if request.bundle_id != "com.apple.springboard" { app.activate() }
        var executed = 0
        do {
            for action in request.actions {
                if action.action == "snapshot" || action.action == "snapshot_tree" { executed += 1; continue }
                if request.bundle_id != "com.apple.springboard",
                   XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch.exists {
                    throw Failure.systemAlertBlocksApplication
                }
                let scope: XCUIElement
                if let identifier = action.within_identifier {
                    guard !identifier.isEmpty else { throw Failure.invalidRequest }
                    let scopes = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@", identifier))
                    guard scopes.firstMatch.waitForExistence(timeout: 10) else { throw Failure.missingElement }
                    guard scopes.count == 1 else { throw Failure.ambiguousElement }
                    scope = scopes.element(boundBy: 0)
                } else {
                    scope = app
                }
                let query: XCUIElementQuery
                let candidates = scope.descendants(matching: action.element_type?.queryType ?? .any)
                if let identifier = action.identifier, !identifier.isEmpty, action.label == nil {
                    query = candidates.matching(NSPredicate(format: "identifier == %@", identifier))
                } else if let label = action.label, action.identifier == nil,
                          !label.isEmpty || (action.action == "adjust_slider" && action.element_type == .slider) {
                    query = candidates.matching(NSPredicate(format: "label == %@", label))
                } else { throw Failure.invalidRequest }
                guard query.firstMatch.waitForExistence(timeout: 10) else { throw Failure.missingElement }
                let element: XCUIElement
                if let identifier = action.child_identifier {
                    guard !identifier.isEmpty else { throw Failure.invalidRequest }
                    guard query.count <= 64 else { throw Failure.queryTooBroad }
                    let matches = query.allElementsBoundByIndex.filter {
                        $0.children(matching: .any).matching(NSPredicate(format: "identifier == %@", identifier)).count > 0
                    }
                    guard !matches.isEmpty else { throw Failure.missingElement }
                    guard matches.count == 1 else { throw Failure.ambiguousElement }
                    element = matches[0]
                } else {
                    guard query.count == 1 else { throw Failure.ambiguousElement }
                    element = query.element(boundBy: 0)
                }
                switch action.action {
                case "assert_exists":
                    XCTAssertTrue(element.exists)
                case "tap":
                    // Settings may expose a labeled switch container around the actual
                    // control. Its center is the row label, not the toggle hit target.
                    let target: XCUIElement
                    if element.elementType == .switch {
                        let controls = element.children(matching: .switch)
                        guard controls.count <= 1 else { throw Failure.ambiguousElement }
                        target = controls.count == 1 ? controls.element(boundBy: 0) : element
                    } else {
                        target = element
                    }
                    try waitUntilActionable(target, bundleID: request.bundle_id)
                    target.tap()
                case "tap_at":
                    guard let x = action.normalized_x, let y = action.normalized_y,
                          x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else {
                        throw Failure.invalidRequest
                    }
                    try waitUntilActionable(element, bundleID: request.bundle_id)
                    element.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y)).tap()
                case "type":
                    guard [.textField, .secureTextField, .searchField, .textView].contains(element.elementType),
                          let text = action.text, text.utf8.count <= 4096 else { throw Failure.invalidTextTarget }
                    try waitUntilActionable(element, bundleID: request.bundle_id)
                    element.tap()
                    element.typeText(text)
                case "swipe_up": element.swipeUp()
                case "swipe_down": element.swipeDown()
                case "adjust_slider":
                    guard element.elementType == .slider,
                          let position = action.normalized_position,
                          position.isFinite, (0...1).contains(position) else { throw Failure.invalidRequest }
                    try waitUntilActionable(element, bundleID: request.bundle_id)
                    element.adjust(toNormalizedSliderPosition: CGFloat(position))
                default: throw Failure.invalidRequest
                }
                executed += 1
            }
            try attachResult(app: app, request: request, executed: executed, error: nil)
        } catch {
            try attachResult(app: app, request: request, executed: executed, error: String(describing: error))
            throw error
        }
    }

    @MainActor
    private func waitUntilActionable(_ element: XCUIElement, bundleID: String) throws {
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true AND enabled == true"),
            object: element
        )
        guard XCTWaiter.wait(for: [ready], timeout: 10) == .completed else {
            if bundleID != "com.apple.springboard",
               XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch.exists {
                throw Failure.systemAlertBlocksApplication
            }
            throw Failure.elementNotHittable
        }
    }

    @MainActor
    private func attachResult(app: XCUIApplication, request: Request, executed: Int, error: String?) throws {
        if request.actions.contains(where: { $0.action == "snapshot_tree" }) {
            // One hierarchy request avoids repeated remote queries for every
            // property of every historical row. Truncation remains explicit.
            let raw = Array(app.debugDescription.utf8)
            let limit = 1_048_576
            let result = Result(success: error == nil, completion: "ui_actions_executed",
                bundle_id: request.bundle_id, executed_actions: executed,
                snapshot_format: "tree", elements: nil,
                tree: String(decoding: raw.prefix(limit), as: UTF8.self),
                tree_truncated: raw.count > limit, error: error)
            try attach(result)
            return
        }
        let query = app.descendants(matching: .any)
        let count = query.count
        let elements = (0..<min(count, 512)).map { index in
            let element = query.element(boundBy: index)
            return Element(identifier: element.identifier, label: element.label,
                           type: element.elementType.rawValue, enabled: element.isEnabled, hittable: element.isHittable,
                           normalized_slider_position: element.elementType == .slider ? Double(element.normalizedSliderPosition) : nil)
        }
        let result = Result(success: error == nil, completion: "ui_actions_executed",
                            bundle_id: request.bundle_id, executed_actions: executed,
                            snapshot_format: "elements", elements: elements, tree: nil,
                            tree_truncated: count > 512, error: error)
        try attach(result)
    }

    private func attach(_ result: Result) throws {
        let encoded = try JSONEncoder().encode(result)
        // Device approval windows can close while xcodebuild finalizes its result
        // bundle. Emit the same captured result now; retain the attachment as well.
        print("APPLE_OPERATOR_RESULT_BASE64=" + encoded.base64EncodedString())
        let attachment = XCTAttachment(data: encoded, uniformTypeIdentifier: "public.json")
        attachment.name = "operator-result.json"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
