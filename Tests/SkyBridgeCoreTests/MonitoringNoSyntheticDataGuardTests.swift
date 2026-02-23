import XCTest

final class MonitoringNoSyntheticDataGuardTests: XCTestCase {
    func testMonitoringFilesDoNotContainSyntheticRandomPaths() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/SkyBridgeCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root

        let monitoredFiles = [
            "Sources/SkyBridgeCore/Performance/AppleSiliconSystemMonitor.swift",
            "Sources/SkyBridgeCore/Performance/AppleSiliconGPUMonitor.swift",
            "Sources/SkyBridgeCore/Performance/AppleSiliconFanMonitor.swift",
            "Sources/SkyBridgeCore/SystemMonitor/FanSpeedMonitor.swift",
            "Sources/SkyBridgeCore/SystemMonitor/ConcurrentSystemMonitor.swift",
            "Sources/SkyBridgeCompassApp/Core/Performance/ConcurrentSystemMonitor.swift",
            "Sources/SkyBridgeCompassApp/Core/Performance/GPUUsageMonitor.swift",
            "Sources/SkyBridgeCompassApp/Core/Performance/PerformanceMonitor.swift",
            "Sources/SkyBridgeCore/Performance/ThermalManager.swift",
            "Sources/SkyBridgeCore/Performance/HardwareMonitorService.swift",
            "Sources/SkyBridgeCore/SystemMonitor/SimpleSystemMonitor.swift",
            "Sources/SkyBridgeCore/SystemMonitor/SystemMonitorManager.swift",
            "Sources/SkyBridgeCore/Performance/SystemPerformanceMonitor.swift"
        ]

        let forbiddenPatterns = [
            "Double.random(",
            "Int.random(",
            "Bool.random(",
            "estimateGPUUsageFromTemperature",
            "(watts - 2)",
            "estimateTemperatureFromThermalState",
            "readAppleSiliconTemperatureFromPowerMetrics"
        ]

        for path in monitoredFiles {
            let url = root.appendingPathComponent(path)
            let content = try String(contentsOf: url, encoding: .utf8)
            for pattern in forbiddenPatterns {
                XCTAssertFalse(
                    content.contains(pattern),
                    "Forbidden synthetic monitoring pattern '\\(pattern)' found in \\(path)"
                )
            }
        }
    }
}
