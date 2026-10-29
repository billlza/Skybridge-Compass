#if os(macOS)
import CryptoKit
import Foundation
import Network
import SkyBridgeProtocolCore
import XCTest
@testable import SkyBridgeCore

/// Real loopback TCP and wire crypto, with isolated authority, settings and storage.
/// This does not establish a real account/MAIN handshake or touch a native output.
@MainActor
final class AudioFileSocketFixture {
    let manager: FileTransferManager
    let directory: URL
    let sessions = ClassicTransferSessionRegistry()
    let lifetime = ClassicTransferSessionRegistry.SessionLifetime()
    let transferID: String
    let peerID: String
    let resolvedPeerID: String
    let key: SymmetricKey
    let listener: NWListener
    private(set) var client: NWConnection?
    private(set) var server: NWConnection?
    private var receiving: Task<Void, Error>?
    private var productListener: FileTransferListenerService?
    private var byteChannel: (any ClassicFileTransferByteChannel)?
    private let defaults: UserDefaults
    private let defaultsName: String
    private let historyStore: CodablePersistenceStore<[PersistedFileTransferHistoryEntry]>

    init(transferID: String, peerID: String, keys: SessionKeys,
         audioFiles: AudioOriginalFileTransferRegistry, canonicalLookupID: Bool = false,
         useProductListener: Bool = false) throws {
        self.transferID = transferID; self.peerID = peerID
        resolvedPeerID = canonicalLookupID ? try XCTUnwrap(PeerTrustLookup.persistentDeviceId(from: peerID)) : peerID
        key = keys.deriveClassicFileTransferKey(transferId: transferID)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("audio-file-socket-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defaultsName = "AudioFileSocketTests.\(UUID())"
        defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        historyStore = .init(location: .userDefaults(key: "history"), rootDirectoryName: defaultsName, defaults: defaults)
        let directory = self.directory
        manager = FileTransferManager(historyStore: historyStore,
            resumeStore: ClassicTransferResumeStore(baseDirectory: directory.appendingPathComponent("resume")),
            environment: .init(primaryConnections: { [] }, discoveryConnections: { [] },
                sessionRegistry: sessions, scanSettings: { (false, .standard) }, audioFiles: audioFiles,
                makeAudioStagingURL: { directory.appendingPathComponent(".skybridge-classic-\(UUID()).partial") }))
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        if useProductListener { productListener = FileTransferListenerService(manager: manager, port: 0) }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                guard let self, self.server == nil else { connection.cancel(); return }
                self.server = connection
                if let productListener = self.productListener {
                    // Exercise the actual admission/state-callback owner without publishing
                    // Bonjour or reading/creating a product identity in this isolated fixture.
                    productListener.handleIncoming(connection)
                } else { connection.start(queue: .main) }
            }
        }
    }

    func open(keys: SessionKeys, purpose: FileTransferReceivePurpose = .general,
              startReceiving: Bool = true) async throws {
        try await registerSession(keys: keys, endpoint: "127.0.0.1")
        listener.start(queue: .main)
        try await wait { if case .ready = self.listener.state { true } else { false } }
        let connection = NWConnection(host: "127.0.0.1", port: try XCTUnwrap(listener.port), using: .tcp)
        client = connection; connection.start(queue: .main)
        try await wait {
            guard let server = self.server else { return false }
            if case .ready = server.state, case .ready = connection.state { return true }
            return false
        }
        let server = try XCTUnwrap(server), manager = manager, peerID = peerID
        guard startReceiving, productListener == nil else { return }
        receiving = Task { try await manager.receiveFile(from: server,
            peerContext: .init(declaredSenderDeviceId: peerID, endpointHostOrIP: "127.0.0.1",
                               peerLabel: "Isolated audio sender", transferId: "pending-metadata"), purpose: purpose) }
    }

    /// Native byte tests share the wire/crypto/storage fixture, without starting the TCP listener.
    func useByteChannel(_ channel: any ClassicFileTransferByteChannel, keys: SessionKeys) async throws {
        guard client == nil, server == nil, byteChannel == nil else { throw SocketError.invalidFrame }
        byteChannel = channel
        try await registerSession(keys: keys, endpoint: nil)
    }

    /// Test-only authority for both in-process and explicitly selected cross-process peers.
    func registerSession(keys: SessionKeys, endpoint: String?) async throws {
        let snapshot = ClassicTransferSessionSnapshot(sessionId: keys.sessionId,
            matchDeviceId: peerID, resolvedPeerDeviceId: resolvedPeerID, aliases: [peerID],
            endpointHostOrIP: endpoint, capabilities: ["file_transfer"], sessionKeys: keys)
        let lease = await sessions.upsertOwned(session: snapshot, lifetime: lifetime)
        XCTAssertNotNil(lease)
        await manager.awaitHistoryPersistence()
    }

    func result() async throws {
        if let productListener {
            try await wait { productListener.activeInboundConnectionCount == 0 }
            return
        }
        let receiving = try XCTUnwrap(receiving)
        // Cancel the actual connection if a regression would otherwise wait for production deadlines.
        let client = client, server = server
        let watchdog = Task {
            do { try await Task.sleep(for: .seconds(5)) }
            catch is CancellationError { return }
            catch { XCTFail("Unexpected watchdog error: \(error)"); return }
            client?.cancel(); server?.cancel(); receiving.cancel()
        }
        defer { watchdog.cancel() }
        try await receiving.value
    }

    func close() {
        productListener?.stop()
        receiving?.cancel(); client?.cancel(); server?.cancel(); listener.cancel(); byteChannel?.cancel()
        lifetime.invalidate()
    }

    func removeStorage() throws {
        defaults.removePersistentDomain(forName: defaultsName)
        try FileManager.default.removeItem(at: directory)
    }

    func shutdown() async throws {
        close()
        if let receiving { _ = await receiving.result }
        try await byteChannel?.closeAndAwait(timeout: .seconds(3))
        await manager.stop()
        await manager.awaitHistoryPersistence()
        try removeStorage()
    }

    func cancelAcceptedConnection() throws { try XCTUnwrap(server).cancel() }
    func stopProductListener() throws { try XCTUnwrap(productListener).stop() }

    func metadata(file: Data, invalidMAC: Bool = false, offeredHash: String? = nil,
                  fileName: String = "original.wav", senderDeviceID: String? = nil,
                  requiresApproval: Bool = true) throws -> FileMetadata {
        let sender = senderDeviceID ?? peerID
        let hash = offeredHash ?? Data(SHA256.hash(data: file)).map { String(format: "%02x", $0) }.joined()
        let unsigned = FileMetadata(transferId: transferID, fileName: fileName, fileSize: Int64(file.count),
            fileHash: hash, chunkSize: 65_536, securityVersion: ClassicTransferInboundPolicy.currentSecurityVersion,
            metadataAuthTag: nil, compression: nil, senderDeviceId: sender, senderDeviceName: "Isolated sender",
            senderPlatform: "Android", senderOSVersion: nil, senderModelName: nil, senderChip: nil,
            approvalProtocol: requiresApproval ? ClassicTransferApprovalContract.protocolIdentifier : nil)
        let tag = invalidMAC ? Data(repeating: 0, count: 32) : Data(HMAC<SHA256>.authenticationCode(for: try transcript(unsigned), using: key))
        return FileMetadata(transferId: unsigned.transferId, fileName: unsigned.fileName, fileSize: unsigned.fileSize,
            fileHash: unsigned.fileHash, chunkSize: unsigned.chunkSize, securityVersion: unsigned.securityVersion,
            metadataAuthTag: tag, compression: nil, senderDeviceId: sender, senderDeviceName: unsigned.senderDeviceName,
            senderPlatform: unsigned.senderPlatform, senderOSVersion: nil, senderModelName: nil, senderChip: nil,
            approvalProtocol: unsigned.approvalProtocol)
    }

    func sendMetadata(_ metadata: FileMetadata) async throws {
        try await send(type: .metadata, data: JSONEncoder().encode(metadata))
    }

    func sendResumeRequest() async throws {
        let version = ClassicTransferInboundPolicy.currentSecurityVersion
        let input = try ClassicTransferCanonicalTranscript.resumeRequest(transferID: transferID,
            senderDeviceID: peerID, resumeOffset: 0, securityVersion: version)
        let request = ResumeRequestPayload(transferId: transferID, senderDeviceId: peerID,
            resumeOffset: 0, securityVersion: version,
            authTag: Data(HMAC<SHA256>.authenticationCode(for: input, using: key)))
        try await send(type: .resumeRequest, data: JSONEncoder().encode(request))
    }

    func approval(for metadata: FileMetadata) async throws {
        let (type, payload) = try await receiveMessage()
        XCTAssertEqual(type, .approval)
        let response = try JSONDecoder().decode(ClassicTransferApprovalResponse.self, from: payload)
        let request = try ClassicTransferApprovalRequest(transferID: transferID, authenticatedMetadataTranscript: transcript(metadata))
        let refusal = try ClassicTransferApprovalContract.validateResponse(response, for: request, using: key)
        XCTAssertNil(refusal)
    }

    func sendChunks(_ file: Data, corruptTag: Bool = false, sendEOF: Bool = true) async throws {
        for offset in stride(from: 0, to: file.count, by: 65_536) {
            let block = file.subdata(in: offset..<min(file.count, offset + 65_536))
            let sealed = try AES.GCM.seal(block, using: key)
            let chunk = FileChunk(index: offset / 65_536, data: sealed.ciphertext, size: block.count,
                nonce: sealed.nonce.withUnsafeBytes { Data($0) },
                authenticationTag: corruptTag ? Data(repeating: 0, count: 16) : sealed.tag)
            try await send(type: .chunk, data: JSONEncoder().encode(chunk))
        }
        if sendEOF { try await send(type: .complete, data: Data()) }
    }

    func receipt() async throws -> FileTransferReceipt {
        let (type, payload) = try await receiveMessage()
        XCTAssertEqual(type, .receipt)
        let receipt = try JSONDecoder().decode(FileTransferReceipt.self, from: payload)
        let input = try ClassicTransferCanonicalTranscript.receipt(transferID: receipt.transferId,
            success: receipt.success, receivedBytes: receipt.receivedBytes, fileHash: receipt.fileHash,
            error: receipt.error, securityVersion: receipt.securityVersion ?? 0)
        XCTAssertTrue(ClassicTransferAuthenticationContract.isValidHMACSHA256(receipt.authTag, authenticating: input, using: key))
        XCTAssertEqual(receipt.transferId, transferID)
        try await byteChannel?.completeAndClose(timeout: .seconds(5))
        return receipt
    }

    private func transcript(_ metadata: FileMetadata) throws -> Data {
        try ClassicTransferCanonicalTranscript.metadata(transferID: metadata.transferId, fileName: metadata.fileName,
            fileSize: metadata.fileSize, fileHash: metadata.fileHash, chunkSize: metadata.chunkSize,
            securityVersion: metadata.securityVersion ?? 0, compression: metadata.compression,
            senderDeviceID: metadata.senderDeviceId, senderDeviceName: metadata.senderDeviceName,
            senderPlatform: metadata.senderPlatform, senderOSVersion: metadata.senderOSVersion,
            senderModelName: metadata.senderModelName, senderChip: metadata.senderChip,
            approvalProtocol: metadata.approvalProtocol)
    }

    private func send(type: FileTransferWireMessageType, data: Data) async throws {
        var frame = Data()
        for word in [type.rawValue, UInt32(data.count)] {
            frame.append(contentsOf: withUnsafeBytes(of: word.bigEndian) { Array($0) })
        }
        frame.append(data)
        if let byteChannel { try await byteChannel.send(frame, requireEffectAuthorization: {}); return }
        let connection = try XCTUnwrap(client)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: frame, completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                })
            }
        } onCancel: { connection.cancel() }
    }

    private func receiveMessage() async throws -> (FileTransferWireMessageType, Data) {
        let connection = client, byteChannel = byteChannel
        guard connection != nil || byteChannel != nil else { throw SocketError.closed }
        func receiveExactly(_ count: Int) async throws -> Data {
            if let byteChannel {
                return try await byteChannel.receive(length: count, timeout: 5, zeroByteDisconnectError: nil)
            }
            return try await read(count, connection: XCTUnwrap(connection))
        }
        let watchdog = Task {
            do { try await Task.sleep(for: .seconds(5)) }
            catch is CancellationError { return }
            catch { XCTFail("Unexpected watchdog error: \(error)"); return }
            connection?.cancel(); byteChannel?.cancel()
        }
        defer { watchdog.cancel() }
        let header = try await receiveExactly(8)
        let raw = header.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
        let size = header.suffix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
        guard size <= 2_000_000, let type = FileTransferWireMessageType(rawValue: raw) else { throw SocketError.invalidFrame }
        return (type, try await receiveExactly(Int(size)))
    }

    private func read(_ count: Int, connection: NWConnection) async throws -> Data {
        var bytes = Data()
        while bytes.count < count {
            let remaining = count - bytes.count
            let data: Data = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { data, _, complete, error in
                        if let error { continuation.resume(throwing: error) }
                        else if let data, !data.isEmpty { continuation.resume(returning: data) }
                        else { continuation.resume(throwing: complete ? SocketError.closed : SocketError.emptyRead) }
                    }
                }
            } onCancel: { connection.cancel() }
            bytes.append(data)
        }
        return bytes
    }

    private func wait(_ ready: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !ready() {
            guard ContinuousClock.now < deadline else { throw SocketError.timedOut }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
    private enum SocketError: Error { case closed, emptyRead, invalidFrame, timedOut }
}
#endif
