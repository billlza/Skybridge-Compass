import Foundation

struct PersistedFileTransferHistoryEntry: Codable, Sendable {
  let id: String
  let fileName: String
  let fileSize: Int64
  let deviceId: String
  let direction: TransferDirection
  let createdAt: Date
  let status: TransferStatus
  let progress: Double
  let transferredBytes: Int64
  let transferSpeed: Double
  let estimatedTimeRemaining: TimeInterval
  let networkQuality: NetworkQuality
  let averageSpeed: Double
  let peakSpeed: Double
  let completedAt: Date?
  let error: String?
  let fileHash: String?
  let localPath: URL?
  let compression: String?
  let scanResult: FileScanResult?
  let deviceIPAddress: String?
  let devicePort: Int
  let deviceName: String?
  let resumeOffset: Int64
  let resumeDataPath: URL?

  init(_ transfer: FileTransfer) {
    self.id = transfer.id
    self.fileName = transfer.fileName
    self.fileSize = transfer.fileSize
    self.deviceId = transfer.deviceId
    self.direction = transfer.direction
    self.createdAt = transfer.createdAt
    self.status = transfer.status
    self.progress = transfer.progress
    self.transferredBytes = transfer.transferredBytes
    self.transferSpeed = transfer.transferSpeed
    self.estimatedTimeRemaining = transfer.estimatedTimeRemaining
    self.networkQuality = transfer.networkQuality
    self.averageSpeed = transfer.averageSpeed
    self.peakSpeed = transfer.peakSpeed
    self.completedAt = transfer.completedAt
    self.error = transfer.error
    self.fileHash = transfer.fileHash
    self.localPath = transfer.localPath
    self.compression = transfer.compression
    self.scanResult = transfer.scanResult
    self.deviceIPAddress = transfer.deviceIPAddress
    self.devicePort = transfer.devicePort
    self.deviceName = transfer.deviceName
    self.resumeOffset = transfer.resumeOffset
    self.resumeDataPath = transfer.resumeDataPath
  }

  var asRuntimeTransfer: FileTransfer {
    let transfer = FileTransfer(
      id: id,
      fileName: fileName,
      fileSize: fileSize,
      deviceId: deviceId,
      direction: direction,
      status: status,
      createdAt: createdAt
    )
    transfer.progress = progress
    transfer.transferredBytes = transferredBytes
    transfer.transferSpeed = transferSpeed
    transfer.estimatedTimeRemaining = estimatedTimeRemaining
    transfer.networkQuality = networkQuality
    transfer.averageSpeed = averageSpeed
    transfer.peakSpeed = peakSpeed
    transfer.completedAt = completedAt
    transfer.error = error
    transfer.fileHash = fileHash
    transfer.localPath = localPath
    transfer.compression = compression
    transfer.scanResult = scanResult
    transfer.deviceIPAddress = deviceIPAddress
    transfer.devicePort = devicePort
    transfer.deviceName = deviceName
    transfer.resumeOffset = resumeOffset
    transfer.resumeDataPath = resumeDataPath
    return transfer
  }
}
