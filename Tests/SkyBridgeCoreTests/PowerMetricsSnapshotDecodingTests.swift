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
        XCTAssertNil(snapshot.temperatureReadings)
        XCTAssertNil(snapshot.fanReadings)
        XCTAssertNil(snapshot.powerReadings)
        XCTAssertNil(snapshot.cpuTemperatureHottestC)
        XCTAssertNil(snapshot.cpuTemperatureAverageC)
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

    func testDecodeSnapshotWithSensorCatalogMetadata() throws {
        let payload: [String: Any] = [
            "timestamp": 757_382_400.0,
            "monitoringMode": "expertPrivate",
            "cpuUsagePercent": NSNull(),
            "memoryUsagePercent": 49.8,
            "gpuUsagePercent": NSNull(),
            "cpuPowerWatts": 12.4,
            "gpuPowerWatts": 8.2,
            "anePowerWatts": 0.9,
            "ramPowerWatts": 1.6,
            "packagePowerWatts": 24.8,
            "cpuTemperatureC": 64.0,
            "gpuTemperatureC": 58.0,
            "fanRPMs": [2100, 2100],
            "loadAvg1": 1.1,
            "loadAvg5": 1.0,
            "loadAvg15": 0.9,
            "protocolVersion": 3,
            "helperVersion": "2.4.0",
            "helperStartedAt": 757_382_300.0,
            "temperatureReadings": [
                [
                    "key": "TC0P",
                    "group": "cpu",
                    "source": "smc",
                    "valueCelsius": 61.0
                ],
                [
                    "key": "Tp09",
                    "group": "cpu",
                    "source": "smc",
                    "valueCelsius": 64.0
                ],
                [
                    "key": "IOHID:GPU",
                    "group": "gpu",
                    "source": "iohid",
                    "valueCelsius": 58.0
                ]
            ],
            "fanReadings": [
                [
                    "index": 0,
                    "key": "F0Ac",
                    "rpm": 2100,
                    "source": "smc"
                ],
                [
                    "index": 1,
                    "key": "F1Ac",
                    "rpm": 2100,
                    "source": "smc"
                ]
            ],
            "powerReadings": [
                [
                    "component": "cpu",
                    "source": "ioreport",
                    "watts": 12.4
                ],
                [
                    "component": "gpu",
                    "source": "ioreport",
                    "watts": 8.2
                ],
                [
                    "component": "ane",
                    "source": "ioreport",
                    "watts": 0.9
                ],
                [
                    "component": "ram",
                    "source": "ioreport",
                    "watts": 1.6
                ],
                [
                    "component": "package",
                    "source": "ioreport",
                    "watts": 24.8
                ]
            ],
            "cpuTemperatureHottestC": 64.0,
            "gpuTemperatureHottestC": 58.0,
            "cpuTemperatureAverageC": 62.5,
            "gpuTemperatureAverageC": 58.0
        ]

        let data = try JSONSerialization.data(withJSONObject: payload)
        let snapshot = try JSONDecoder().decode(PowerMetricsSnapshot.self, from: data)

        XCTAssertEqual(snapshot.protocolVersion, 3)
        XCTAssertEqual(snapshot.temperatureReadings?.count, 3)
        XCTAssertEqual(snapshot.temperatureReadings?.first?.key, "TC0P")
        XCTAssertEqual(snapshot.temperatureReadings?.first?.group, .cpu)
        XCTAssertEqual(snapshot.temperatureReadings?.first?.source, .smc)
        XCTAssertEqual(snapshot.fanReadings?.count, 2)
        XCTAssertEqual(snapshot.fanReadings?.map(\.rpm), [2100, 2100])
        XCTAssertEqual(snapshot.cpuPowerWatts, 12.4)
        XCTAssertEqual(snapshot.gpuPowerWatts, 8.2)
        XCTAssertEqual(snapshot.anePowerWatts, 0.9)
        XCTAssertEqual(snapshot.ramPowerWatts, 1.6)
        XCTAssertEqual(snapshot.packagePowerWatts, 24.8)
        XCTAssertEqual(snapshot.powerReadings?.map(\.component), [.cpu, .gpu, .ane, .ram, .package])
        XCTAssertEqual(snapshot.powerReadings?.map(\.source), [.ioreport, .ioreport, .ioreport, .ioreport, .ioreport])
        XCTAssertEqual(snapshot.powerReadings?.map(\.watts), [12.4, 8.2, 0.9, 1.6, 24.8])
        XCTAssertEqual(snapshot.cpuTemperatureHottestC, 64.0)
        XCTAssertEqual(snapshot.cpuTemperatureAverageC, 62.5)
        XCTAssertEqual(snapshot.gpuTemperatureHottestC, 58.0)
        XCTAssertEqual(snapshot.gpuTemperatureAverageC, 58.0)
    }

    func testUnknownTemperatureGroupDecodesAsUnknown() throws {
        let payload: [String: Any] = [
            "timestamp": 757_382_400.0,
            "cpuUsagePercent": NSNull(),
            "memoryUsagePercent": NSNull(),
            "gpuUsagePercent": NSNull(),
            "gpuPowerWatts": NSNull(),
            "cpuTemperatureC": NSNull(),
            "gpuTemperatureC": NSNull(),
            "fanRPMs": NSNull(),
            "loadAvg1": NSNull(),
            "loadAvg5": NSNull(),
            "loadAvg15": NSNull(),
            "temperatureReadings": [
                [
                    "key": "TX9Z",
                    "group": "futureGroup",
                    "source": "smc",
                    "valueCelsius": 42.0
                ]
            ]
        ]

        let data = try JSONSerialization.data(withJSONObject: payload)
        let snapshot = try JSONDecoder().decode(PowerMetricsSnapshot.self, from: data)

        XCTAssertEqual(snapshot.temperatureReadings?.first?.group, .unknown)
    }

    func testUnknownPowerComponentDecodesAsUnknown() throws {
        let payload: [String: Any] = [
            "timestamp": 757_382_400.0,
            "cpuUsagePercent": NSNull(),
            "memoryUsagePercent": NSNull(),
            "gpuUsagePercent": NSNull(),
            "gpuPowerWatts": NSNull(),
            "cpuTemperatureC": NSNull(),
            "gpuTemperatureC": NSNull(),
            "fanRPMs": NSNull(),
            "loadAvg1": NSNull(),
            "loadAvg5": NSNull(),
            "loadAvg15": NSNull(),
            "powerReadings": [
                [
                    "component": "mediaEngine",
                    "source": "ioreport",
                    "watts": 2.4
                ]
            ]
        ]

        let data = try JSONSerialization.data(withJSONObject: payload)
        let snapshot = try JSONDecoder().decode(PowerMetricsSnapshot.self, from: data)

        XCTAssertEqual(snapshot.powerReadings?.first?.component, .unknown)
    }
}
