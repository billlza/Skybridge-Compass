// MARK: - Transfer Progress Property Tests
// **Feature: macos-widgets, Property 4: Transfer Progress Calculation**
// **Validates: Requirements 4.1, 4.2, 4.3**

import Testing
import Foundation
@testable import SkyBridgeWidgetShared

@Suite("Transfer Progress Property Tests")
struct TransferProgressPropertyTests {
    
 // MARK: - Property 4: Transfer Progress Calculation
    
    @Test("aggregateProgress equals sum(transferredBytes) / sum(totalBytes)", arguments: 0..<100)
    func testAggregateProgressAccuracy(iteration: Int) {
        let transferCount = Int.random(in: 1...20)
        let transfers = WidgetTestGenerators.transfers(count: transferCount)
        let data = WidgetTransfersData(transfers: transfers)
        
        let totalBytes = transfers.reduce(Int64(0)) { $0 + $1.totalBytes }
        let transferredBytes = transfers.reduce(Int64(0)) { $0 + $1.transferredBytes }
        
        let expectedProgress: Double
        if totalBytes == 0 {
            expectedProgress = 0.0
        } else {
            expectedProgress = Double(transferredBytes) / Double(totalBytes)
        }
        
        #expect(abs(data.aggregateProgress - expectedProgress) < 0.001, """
            Aggregate progress mismatch:
            Expected: \(expectedProgress)
            Actual: \(data.aggregateProgress)
            Total bytes: \(totalBytes)
            Transferred bytes: \(transferredBytes)
            """)
    }
    
    @Test("aggregateProgress is 0.0 when sum(totalBytes) == 0")
    func testAggregateProgressZeroTotal() {
        let transfers = (0..<5).map { i in
            WidgetTransferInfo(
                id: "t-\(i)",
                fileName: "file\(i).txt",
                progress: 0,
                totalBytes: 0,
                transferredBytes: 0,
                isUpload: true,
                deviceName: "Device"
            )
        }
        let data = WidgetTransfersData(transfers: transfers)
        
        #expect(data.aggregateProgress == 0.0)
    }
    
    @Test("aggregateProgress is bounded between 0.0 and 1.0", arguments: 0..<100)
    func testAggregateProgressBounded(iteration: Int) {
        let data = WidgetTestGenerators.transfersData(transferCount: Int.random(in: 0...10))
        
        #expect(data.aggregateProgress >= 0.0)
        #expect(data.aggregateProgress <= 1.0)
    }
    
    @Test("aggregateProgress is 0.0 for empty transfers")
    func testAggregateProgressEmpty() {
        let data = WidgetTransfersData.empty
        #expect(data.aggregateProgress == 0.0)
    }
    
    @Test("aggregateProgress is 1.0 when all transfers complete")
    func testAggregateProgressAllComplete() {
        let transfers = (0..<5).map { i in
            WidgetTransferInfo(
                id: "t-\(i)",
                fileName: "file\(i).txt",
                progress: 1.0,
                totalBytes: 1000,
                transferredBytes: 1000,
                isUpload: true,
                deviceName: "Device"
            )
        }
        let data = WidgetTransfersData(transfers: transfers)
        
        #expect(data.aggregateProgress == 1.0)
    }
    
 // MARK: - Active Count Tests
    
    @Test("activeCount equals count of transfers where progress < 1.0", arguments: 0..<50)
    func testActiveCountAccuracy(iteration: Int) {
        let data = WidgetTestGenerators.transfersData(transferCount: Int.random(in: 0...10))
        
        let expectedActiveCount = data.transfers.filter { $0.isActive }.count
        
        #expect(data.activeCount == expectedActiveCount)
    }
}
