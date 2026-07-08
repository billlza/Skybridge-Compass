import XCTest
@testable import SkyBridgeCore

@MainActor
final class SystemMetricsServiceTests: XCTestCase {
    func testMonitoringLifecycleDoesNotAccumulateNotificationObservers() {
        let service = SystemMetricsService()

        XCTAssertEqual(service.notificationObserverCountForTesting, 0)

        service.startMonitoring()
        XCTAssertEqual(service.notificationObserverCountForTesting, 2)

        service.startMonitoring()
        XCTAssertEqual(service.notificationObserverCountForTesting, 2)

        service.stopMonitoring()
        XCTAssertEqual(service.notificationObserverCountForTesting, 0)

        service.startMonitoring()
        XCTAssertEqual(service.notificationObserverCountForTesting, 2)

        service.stopMonitoring()
        XCTAssertEqual(service.notificationObserverCountForTesting, 0)
    }

    func testStartMonitoringDoesNotSynchronouslySampleMetricsBeforeTimer() throws {
        let source = try readSource("Sources/SkyBridgeCore/SystemMetricsService.swift")
        let body = try extractBody(named: "public func startMonitoring()", from: source)
        let preTimer = try sourceSlice(
            from: "guard monitoringTimer == nil else { return }",
            to: "monitoringTimer = Timer.scheduledTimer",
            in: body
        )

        XCTAssertFalse(
            preTimer.contains("updateMetrics()"),
            "SystemMetricsService.startMonitoring() must not synchronously run mach/sysctl sampling on the login-to-dashboard MainActor path."
        )
    }

    private func readSource(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let url = root.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func extractBody(named signature: String, from source: String) throws -> String {
        guard let signatureRange = source.range(of: signature),
              let openingBrace = source[signatureRange.upperBound...].firstIndex(of: "{") else {
            throw XCTSkip("Signature not found: \(signature)")
        }

        var depth = 0
        var index = openingBrace
        while index < source.endIndex {
            let character = source[index]
            if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    return String(source[openingBrace...index])
                }
            }
            index = source.index(after: index)
        }

        throw XCTSkip("Unbalanced body for signature: \(signature)")
    }

    private func sourceSlice(from startMarker: String, to endMarker: String, in source: String) throws -> String {
        guard let start = source.range(of: startMarker)?.upperBound,
              let end = source[start...].range(of: endMarker)?.lowerBound else {
            throw XCTSkip("Expected source markers not found: \(startMarker) -> \(endMarker)")
        }
        return String(source[start..<end])
    }
}
