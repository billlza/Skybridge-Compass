import Foundation

enum FileTransferHistoryPersistenceOperation: String, Sendable {
  case load
  case append
  case clear
}

public struct FileTransferHistoryPersistenceFailure: Equatable, Sendable {
  public let operation: String
  public let domain: String
  public let code: Int

  init(operation: FileTransferHistoryPersistenceOperation, error: Error) {
    let nsError = error as NSError
    self.operation = operation.rawValue
    self.domain = nsError.domain
    self.code = nsError.code
  }
}

struct BoundedHistorySnapshot<Entry: Sendable>: Sendable {
  let entries: [Entry]
  let generation: UInt64
}

/// Owns synchronous persistence I/O off the main actor and performs every mutation as a
/// canonical read-modify-write transaction. Entries are FIFO ordered and only the newest
/// `maximumEntryCount` records are retained.
actor BoundedCodableHistoryRepository<Entry: Codable & Sendable> {
  private let store: CodablePersistenceStore<[Entry]>
  private let maximumEntryCount: Int
  private var generation: UInt64 = 0

  init(store: CodablePersistenceStore<[Entry]>, maximumEntryCount: Int) {
    precondition(maximumEntryCount > 0, "maximumEntryCount must be positive")
    self.store = store
    self.maximumEntryCount = maximumEntryCount
  }

  func load() async throws -> BoundedHistorySnapshot<Entry> {
    let store = self.store
    let maximumEntryCount = self.maximumEntryCount
    let entries = try await CodablePersistenceStoreIOCoordinator.shared.perform(
      identity: store.persistenceIdentity
    ) {
      let persisted = try store.loadOrThrow() ?? []
      let bounded = Array(persisted.suffix(maximumEntryCount))
      if bounded.count != persisted.count {
        try store.save(bounded)
      }
      return bounded
    }
    return snapshot(entries)
  }

  func append(_ entry: Entry) async throws -> BoundedHistorySnapshot<Entry> {
    let store = self.store
    let maximumEntryCount = self.maximumEntryCount
    let entries = try await CodablePersistenceStoreIOCoordinator.shared.perform(
      identity: store.persistenceIdentity
    ) {
      var persisted = try store.loadOrThrow() ?? []
      persisted.append(entry)
      let bounded = Array(persisted.suffix(maximumEntryCount))
      try store.save(bounded)
      return bounded
    }
    return snapshot(entries)
  }

  func clear() async throws -> BoundedHistorySnapshot<Entry> {
    let store = self.store
    let entries = try await CodablePersistenceStoreIOCoordinator.shared.perform(
      identity: store.persistenceIdentity
    ) {
      try store.remove()
      return [Entry]()
    }
    return snapshot(entries)
  }

  private func snapshot(_ entries: [Entry]) -> BoundedHistorySnapshot<Entry> {
        generation += 1
    return BoundedHistorySnapshot(entries: entries, generation: generation)
  }
}

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
  let receiptDeliveryStatus: FileTransferReceiptDeliveryStatus?
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
    self.receiptDeliveryStatus = transfer.receiptDeliveryStatus
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
    transfer.receiptDeliveryStatus = receiptDeliveryStatus
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
