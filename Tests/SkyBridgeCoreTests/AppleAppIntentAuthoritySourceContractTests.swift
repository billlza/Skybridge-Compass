import Foundation
import XCTest

final class AppleAppIntentAuthoritySourceContractTests: XCTestCase {
    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func readSource(_ relativePath: String) throws -> String {
        try String(contentsOf: repositoryRoot().appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func slice(
        _ source: String,
        from startMarker: String,
        to endMarker: String
    ) throws -> String {
        guard let start = source.range(of: startMarker) else {
            throw XCTSkip("Missing start marker: \(startMarker)")
        }
        guard let end = source.range(of: endMarker, range: start.upperBound..<source.endIndex) else {
            throw XCTSkip("Missing end marker: \(endMarker)")
        }
        return String(source[start.lowerBound..<end.lowerBound])
    }

    func testSiriIntentOnlyOpensAppAndPostsPendingRequest() throws {
        let source = try readSource("Sources/SkyBridgeCompassApp/SiriIntents.swift")

        XCTAssertTrue(source.contains("static let openAppWhenRun = true"))
        XCTAssertTrue(source.contains("准备指定远程终端的连接确认"))
        XCTAssertTrue(source.contains("请在应用内确认连接"))
        XCTAssertTrue(source.contains("NotificationCenter.default.post"))
        XCTAssertTrue(source.contains(".skyBridgeIntentConnect"))
        XCTAssertFalse(source.contains("sessionService.connect"))
        XCTAssertFalse(source.contains("tenantController.requirePermission"))
        XCTAssertFalse(source.contains("try?"))
    }

    func testDashboardIntentNotificationHandlerCannotReachConnectionAuthority() throws {
        let source = try readSource("Sources/SkyBridgeCompassApp/DashboardViewModel.swift")
        let subscription = try slice(
            source,
            from: "NotificationCenter.default.publisher(for: .skyBridgeIntentConnect)",
            to: ".store(in: &cancellables)"
        )
        let handler = try slice(
            source,
            from: "private func recordSiriConnectRequest(targetName: String)",
            to: "func confirmPendingSiriConnectionRequest() async"
        )

        XCTAssertTrue(source.contains("@Published private(set) var pendingSiriConnectionRequest"))
        XCTAssertTrue(source.contains("struct PendingSiriConnectionRequest"))
        XCTAssertTrue(subscription.contains("self?.recordSiriConnectRequest(targetName: target)"))
        XCTAssertFalse(subscription.contains("Task {"))
        XCTAssertFalse(subscription.contains("connect("))
        XCTAssertFalse(subscription.contains("try?"))

        XCTAssertTrue(handler.contains("matches.count == 1"))
        XCTAssertTrue(handler.contains("pendingSiriConnectionRequest = PendingSiriConnectionRequest"))
        XCTAssertTrue(handler.contains("未执行连接"))
        XCTAssertFalse(handler.contains("sessionService.connect"))
        XCTAssertFalse(handler.contains("tenantController.requirePermission"))
        XCTAssertFalse(handler.contains("try?"))
        XCTAssertFalse(handler.contains("else if let fallback = discoveredDevices.first"))
        XCTAssertFalse(handler.contains("discoveredDevices.first {"))
    }

    func testOnlyExplicitInAppConfirmationCanConnectPendingSiriRequest() throws {
        let source = try readSource("Sources/SkyBridgeCompassApp/DashboardViewModel.swift")
        let confirmation = try slice(
            source,
            from: "func confirmPendingSiriConnectionRequest() async",
            to: "func activateTenant"
        )

        XCTAssertTrue(confirmation.contains("guard let request = pendingSiriConnectionRequest"))
        XCTAssertTrue(confirmation.contains("discoveredDevices.first(where: { $0.id == request.matchedDeviceID })"))
        XCTAssertTrue(confirmation.contains("await connect(to: matched)"))
        XCTAssertFalse(confirmation.contains("try?"))
        XCTAssertFalse(confirmation.contains("discoveredDevices.first {"))
        XCTAssertFalse(confirmation.contains("else if let fallback = discoveredDevices.first"))
    }

    func testWidgetAppIntentsStayNavigationOrRefreshOnly() throws {
        let source = try readSource("Sources/SkyBridgeCompassWidgets/WidgetIntents.swift")
        let widgetIntentSlices = try [
            slice(source, from: "struct ScanDevicesIntent: AppIntent", to: "// MARK: - Open App Intent"),
            slice(source, from: "struct OpenAppIntent: AppIntent", to: "// MARK: - Open Device Detail Intent"),
            slice(source, from: "struct OpenDeviceDetailIntent: AppIntent", to: "// MARK: - Open Monitor Intent"),
            slice(source, from: "struct OpenMonitorIntent: AppIntent", to: "// MARK: - Open Transfers Intent"),
            slice(source, from: "struct OpenTransfersIntent: AppIntent", to: "// MARK: - Refresh Widget Intent"),
            slice(source, from: "struct RefreshWidgetIntent: AppIntent", to: "// MARK: - Notification Names")
        ]
        let forbiddenAuthorityTokens = [
            "sessionService",
            "connect(",
            "tenantController",
            "trustDevice(",
            "addTrustRecord",
            "recordAuthenticatedRemoteAuthority",
            "KeychainManager",
            "KEMTrustStore",
            "CryptoProviderFactory",
            "StrictPQCAdmissionGate",
            "FileTransferEngine",
            "FileTransferManager",
            "RemoteDesktopManager",
            "release_eligible",
            "macos-stable.json",
            "try?"
        ]

        XCTAssertTrue(source.contains(".widgetIntentScanDevices"))
        XCTAssertTrue(source.contains(".widgetIntentOpenDeviceDetail"))
        XCTAssertTrue(source.contains(".widgetIntentOpenMonitor"))
        XCTAssertTrue(source.contains(".widgetIntentOpenTransfers"))
        XCTAssertTrue(source.contains("WidgetCenter.shared.reloadTimelines"))
        XCTAssertFalse(source.contains("SKYBRIDGE_APPLE_PQC_SDK_CONDITION"))

        for widgetIntentSlice in widgetIntentSlices {
            for token in forbiddenAuthorityTokens {
                XCTAssertFalse(
                    widgetIntentSlice.contains(token),
                    "Widget AppIntents may only post navigation/refresh signals or reload timelines; authority token found: \(token)"
                )
            }
        }
    }

    func testAppIntentBoundaryRunsInOS27CompatibilityLane() throws {
        let script = try readSource("Scripts/run_os27_beta_compatibility.sh")

        XCTAssertTrue(script.contains("AppleAppIntentAuthoritySourceContractTests"))
        XCTAssertTrue(
            script.contains("AppleAIAdvisorySourceContractTests|AppleAppIntentAuthoritySourceContractTests|AIAdvisoryBoundaryTests"),
            "OS27 source-contract and full-validation filters must keep the AppIntent authority boundary next to AI advisory guardrails."
        )
    }
}
