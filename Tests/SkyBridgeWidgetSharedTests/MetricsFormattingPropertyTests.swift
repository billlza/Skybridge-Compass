// MARK: - Metrics Formatting Property Tests
// **Feature: macos-widgets, Property 5: System Metrics Formatting**
// **Validates: Requirements 3.1, 3.2, 3.3**

import Testing
import Foundation
@testable import SkyBridgeWidgetShared

@Suite("Metrics Formatting Property Tests")
struct MetricsFormattingPropertyTests {
    
 // MARK: - Property 5: System Metrics Formatting
 // *For any* WidgetSystemMetrics with valid percentage values (0-100),
 // the formatted display strings SHALL contain the percentage value
 // and appropriate unit suffix.
    
    @Test("CPU percentage formatting contains value and % suffix", arguments: 0..<100)
    func testCPUPercentageFormatting(iteration: Int) {
        let metrics = WidgetTestGenerators.systemMetrics()
        let formatted = MetricsFormatter.formatCPU(metrics)
        
 // Must contain % suffix
        #expect(formatted.contains("%"), """
            CPU formatted string must contain % suffix
            Metrics: CPU \(metrics.cpuUsage)%
            Formatted: \(formatted)
            """)
        
 // Must contain the numeric value (with tolerance for rounding)
        let expectedValue = String(format: "%.1f", metrics.cpuUsage)
        #expect(formatted.contains(expectedValue), """
            CPU formatted string must contain the value
            Expected value: \(expectedValue)
            Formatted: \(formatted)
            """)
    }
    
    @Test("Memory percentage formatting contains value and % suffix", arguments: 0..<100)
    func testMemoryPercentageFormatting(iteration: Int) {
        let metrics = WidgetTestGenerators.systemMetrics()
        let formatted = MetricsFormatter.formatMemory(metrics)
        
 // Must contain % suffix
        #expect(formatted.contains("%"), """
            Memory formatted string must contain % suffix
            Metrics: Memory \(metrics.memoryUsage)%
            Formatted: \(formatted)
            """)
        
 // Must contain the numeric value
        let expectedValue = String(format: "%.1f", metrics.memoryUsage)
        #expect(formatted.contains(expectedValue), """
            Memory formatted string must contain the value
            Expected value: \(expectedValue)
            Formatted: \(formatted)
            """)
    }
    
    @Test("Network upload formatting contains value and unit suffix", arguments: 0..<100)
    func testNetworkUploadFormatting(iteration: Int) {
        let metrics = WidgetTestGenerators.systemMetrics()
        let formatted = MetricsFormatter.formatNetworkUpload(metrics)
        
 // Must contain /s suffix (bytes per second)
        #expect(formatted.contains("/s"), """
            Network upload formatted string must contain /s suffix
            Metrics: Upload \(metrics.networkUpload) bytes/s
            Formatted: \(formatted)
            """)
        
 // Must contain appropriate unit (B, KB, MB, or GB)
        let hasUnit = formatted.contains("B/s") || formatted.contains("KB/s") ||
                      formatted.contains("MB/s") || formatted.contains("GB/s")
        #expect(hasUnit, """
            Network upload formatted string must contain unit
            Formatted: \(formatted)
            """)
    }
    
    @Test("Network download formatting contains value and unit suffix", arguments: 0..<100)
    func testNetworkDownloadFormatting(iteration: Int) {
        let metrics = WidgetTestGenerators.systemMetrics()
        let formatted = MetricsFormatter.formatNetworkDownload(metrics)
        
 // Must contain /s suffix
        #expect(formatted.contains("/s"), """
            Network download formatted string must contain /s suffix
            Metrics: Download \(metrics.networkDownload) bytes/s
            Formatted: \(formatted)
            """)
        
 // Must contain appropriate unit
        let hasUnit = formatted.contains("B/s") || formatted.contains("KB/s") ||
                      formatted.contains("MB/s") || formatted.contains("GB/s")
        #expect(hasUnit, """
            Network download formatted string must contain unit
            Formatted: \(formatted)
            """)
    }
    
 // MARK: - Edge Cases
    
    @Test("Zero values format correctly")
    func testZeroValuesFormat() {
        let metrics = WidgetSystemMetrics(
            cpuUsage: 0,
            memoryUsage: 0,
            networkUpload: 0,
            networkDownload: 0
        )
        
        #expect(MetricsFormatter.formatCPU(metrics) == "0.0%")
        #expect(MetricsFormatter.formatMemory(metrics) == "0.0%")
        #expect(MetricsFormatter.formatNetworkUpload(metrics) == "0 B/s")
        #expect(MetricsFormatter.formatNetworkDownload(metrics) == "0 B/s")
    }
    
    @Test("Maximum percentage values format correctly")
    func testMaxPercentageFormat() {
        let metrics = WidgetSystemMetrics(
            cpuUsage: 100,
            memoryUsage: 100,
            networkUpload: 0,
            networkDownload: 0
        )
        
        #expect(MetricsFormatter.formatCPU(metrics) == "100.0%")
        #expect(MetricsFormatter.formatMemory(metrics) == "100.0%")
    }
    
    @Test("Values above 100 are clamped")
    func testClampedValues() {
        let metrics = WidgetSystemMetrics(
            cpuUsage: 150,  // Will be clamped to 100
            memoryUsage: 200,  // Will be clamped to 100
            networkUpload: 0,
            networkDownload: 0
        )
        
 // After clamping, should show 100%
        #expect(MetricsFormatter.formatCPU(metrics) == "100.0%")
        #expect(MetricsFormatter.formatMemory(metrics) == "100.0%")
    }
    
    @Test("Negative values are clamped to zero")
    func testNegativeValuesClamped() {
        let metrics = WidgetSystemMetrics(
            cpuUsage: -10,  // Will be clamped to 0
            memoryUsage: -50,  // Will be clamped to 0
            networkUpload: -100,  // Will be clamped to 0
            networkDownload: -200  // Will be clamped to 0
        )
        
        #expect(MetricsFormatter.formatCPU(metrics) == "0.0%")
        #expect(MetricsFormatter.formatMemory(metrics) == "0.0%")
        #expect(MetricsFormatter.formatNetworkUpload(metrics) == "0 B/s")
        #expect(MetricsFormatter.formatNetworkDownload(metrics) == "0 B/s")
    }
    
 // MARK: - Unit Scaling Tests
    
    @Test("Bytes scale to appropriate units")
    func testBytesScaling() {
 // Bytes
        #expect(MetricsFormatter.formatBytes(500) == "500 B")
        
 // Kilobytes
        #expect(MetricsFormatter.formatBytes(1_500) == "1.5 KB")
        
 // Megabytes
        #expect(MetricsFormatter.formatBytes(1_500_000) == "1.5 MB")
        
 // Gigabytes
        #expect(MetricsFormatter.formatBytes(1_500_000_000) == "1.5 GB")
    }
    
    @Test("Bytes per second scale to appropriate units")
    func testBytesPerSecondScaling() {
 // Bytes/s
        #expect(MetricsFormatter.formatBytesPerSecond(500) == "500 B/s")
        
 // KB/s
        #expect(MetricsFormatter.formatBytesPerSecond(1_500) == "1.5 KB/s")
        
 // MB/s
        #expect(MetricsFormatter.formatBytesPerSecond(1_500_000) == "1.5 MB/s")
        
 // GB/s
        #expect(MetricsFormatter.formatBytesPerSecond(1_500_000_000) == "1.5 GB/s")
    }
    
 // MARK: - Consistency Tests
    
    @Test("Formatting is deterministic", arguments: 0..<50)
    func testFormattingDeterministic(iteration: Int) {
        let metrics = WidgetTestGenerators.systemMetrics()
        
        let cpu1 = MetricsFormatter.formatCPU(metrics)
        let cpu2 = MetricsFormatter.formatCPU(metrics)
        #expect(cpu1 == cpu2)
        
        let mem1 = MetricsFormatter.formatMemory(metrics)
        let mem2 = MetricsFormatter.formatMemory(metrics)
        #expect(mem1 == mem2)
        
        let up1 = MetricsFormatter.formatNetworkUpload(metrics)
        let up2 = MetricsFormatter.formatNetworkUpload(metrics)
        #expect(up1 == up2)
        
        let down1 = MetricsFormatter.formatNetworkDownload(metrics)
        let down2 = MetricsFormatter.formatNetworkDownload(metrics)
        #expect(down1 == down2)
    }
}
