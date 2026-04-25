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
}
