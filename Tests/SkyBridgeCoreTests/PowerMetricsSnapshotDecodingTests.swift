import XCTest
@testable import SkyBridgeCore

final class PowerMetricsSnapshotDecodingTests: XCTestCase {
    func testDecodeLegacySnapshotWithoutStateMetadata() throws {
        let payload: [String: Any] = [
            "timestamp": 757_382_400.0,
            "cpuUsagePercent": NSNull(),
            "memoryUsagePercent": 52.3,
            "gpuUsagePercent": 73.4,
            "gpuPowerWatts": 9.8,
            "cpuTemperatureC": NSNull(),
            "gpuTemperatureC": NSNull(),
            "fanRPMs": NSNull(),
            "loadAvg1": 2.1,
            "loadAvg5": 1.9,
            "loadAvg15": 1.4
        ]

        let data = try JSONSerialization.data(withJSONObject: payload)
        let snapshot = try JSONDecoder().decode(PowerMetricsSnapshot.self, from: data)

        XCTAssertEqual(snapshot.gpuUsagePercent ?? 0, 73.4, accuracy: 0.001)
        XCTAssertEqual(snapshot.gpuPowerWatts ?? 0, 9.8, accuracy: 0.001)
        XCTAssertNil(snapshot.gpuUsageState)
        XCTAssertNil(snapshot.gpuPowerState)
        XCTAssertNil(snapshot.cpuTemperatureState)
        XCTAssertNil(snapshot.gpuTemperatureState)
        XCTAssertNil(snapshot.fanState)
    }

    func testDecodeSnapshotWithStateMetadata() throws {
        let payload: [String: Any] = [
            "timestamp": 757_382_400.0,
            "cpuUsagePercent": NSNull(),
            "memoryUsagePercent": 49.8,
            "gpuUsagePercent": NSNull(),
            "gpuPowerWatts": 8.2,
            "cpuTemperatureC": NSNull(),
            "gpuTemperatureC": NSNull(),
            "fanRPMs": NSNull(),
            "loadAvg1": 1.1,
            "loadAvg5": 1.0,
            "loadAvg15": 0.9,
            "gpuUsageState": [
                "availability": "unavailable",
                "reason": "notProvidedByOS",
                "source": "powermetrics",
                "sampledAt": 757_382_400.0
            ],
            "gpuPowerState": [
                "availability": "available",
                "reason": NSNull(),
                "source": "powermetrics",
                "sampledAt": 757_382_400.0
            ],
            "cpuTemperatureState": [
                "availability": "stale",
                "reason": NSNull(),
                "source": "powermetrics",
                "sampledAt": 757_382_397.0
            ]
        ]

        let data = try JSONSerialization.data(withJSONObject: payload)
        let snapshot = try JSONDecoder().decode(PowerMetricsSnapshot.self, from: data)

        XCTAssertEqual(snapshot.gpuPowerWatts ?? 0, 8.2, accuracy: 0.001)
        XCTAssertEqual(snapshot.gpuUsageState?.availability, .unavailable)
        XCTAssertEqual(snapshot.gpuUsageState?.reason, .notProvidedByOS)
        XCTAssertEqual(snapshot.gpuUsageState?.source, .powermetrics)
        XCTAssertEqual(snapshot.gpuPowerState?.availability, .available)
        XCTAssertEqual(snapshot.cpuTemperatureState?.availability, .stale)
        XCTAssertNil(snapshot.gpuTemperatureState)
        XCTAssertNil(snapshot.fanState)
    }
}
