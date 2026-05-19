import XCTest

@testable import SkyBridgeCore

final class FileTransferRuntimeModelsTests: XCTestCase {
  func testProgressUpdateClampsVisibleCountersBeforeSpeedThrottle() {
    let transfer = FileTransfer(
      id: UUID().uuidString,
      fileName: "sample.bin",
      fileSize: 100,
      deviceId: "peer-device",
      direction: .outgoing,
      status: .transferring
    )

    transfer.updateProgress(transferredBytes: 150)

    XCTAssertEqual(transfer.transferredBytes, 100)
    XCTAssertEqual(transfer.progress, 1.0)
  }

  func testZeroByteTransferReportsCompleteProgress() {
    let transfer = FileTransfer(
      id: UUID().uuidString,
      fileName: "empty.txt",
      fileSize: 0,
      deviceId: "peer-device",
      direction: .incoming,
      status: .transferring
    )

    transfer.updateProgress(transferredBytes: 20)

    XCTAssertEqual(transfer.transferredBytes, 0)
    XCTAssertEqual(transfer.progress, 1.0)
  }

  func testFormattedSpeedsKeepExistingUnits() {
    let transfer = FileTransfer(
      id: UUID().uuidString,
      fileName: "sample.bin",
      fileSize: 100,
      deviceId: "peer-device",
      direction: .outgoing,
      status: .transferring
    )

    transfer.transferSpeed = 999
    XCTAssertEqual(transfer.formattedSpeed, "999 B/s")

    transfer.averageSpeed = 1_250
    XCTAssertEqual(transfer.formattedAverageSpeed, "1.2 KB/s")

    transfer.peakSpeed = 1_250_000
    XCTAssertEqual(transfer.formattedPeakSpeed, "1.2 MB/s")

    transfer.transferSpeed = 1_250_000_000
    XCTAssertEqual(transfer.formattedSpeed, "1.2 GB/s")
  }

  func testFormattedTimeRemainingKeepsExistingLabels() {
    let transfer = FileTransfer(
      id: UUID().uuidString,
      fileName: "sample.bin",
      fileSize: 100,
      deviceId: "peer-device",
      direction: .outgoing,
      status: .transferring
    )

    transfer.estimatedTimeRemaining = 0
    XCTAssertEqual(transfer.formattedTimeRemaining, "计算中...")

    transfer.estimatedTimeRemaining = .infinity
    XCTAssertEqual(transfer.formattedTimeRemaining, "计算中...")

    transfer.estimatedTimeRemaining = 9
    XCTAssertEqual(transfer.formattedTimeRemaining, "9秒")

    transfer.estimatedTimeRemaining = 65
    XCTAssertEqual(transfer.formattedTimeRemaining, "1:05")

    transfer.estimatedTimeRemaining = 3_661
    XCTAssertEqual(transfer.formattedTimeRemaining, "1:01:01")
  }
}
