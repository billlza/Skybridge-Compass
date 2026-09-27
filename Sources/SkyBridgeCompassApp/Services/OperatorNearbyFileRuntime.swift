import Foundation
import SkyBridgeCore
import SkyBridgeProtocolCore

/// Adapts existing app services; it owns no credentials, peer store or transport.
@MainActor
enum OperatorNearbyFileRuntime {
    static let methods = ["crossnet.nearby", "crossnet.connect_nearby", "crossnet.file.send",
                          "crossnet.usb.devices", "crossnet.usb.inspect", "crossnet.usb.peers", "crossnet.usb.connect", "crossnet.usb.connect_device", "crossnet.trust.preview", "crossnet.trust.recover"]

    static func nearby(scanSeconds: Int) async throws -> OperatorNearbyResult {
        let service = P2PDiscoveryService.shared
        if scanSeconds > 0 {
            try await service.ensureStartedAndScanning()
            try await Task.sleep(for: .seconds(scanSeconds))
        }
        var seen = Set<UUID>()
        let targets = (service.connectedUSBControlDevices + service.discoveredDevices)
            .filter { seen.insert($0.id).inserted && isSkyBridgePeer($0) }
        let devices = targets.map { device in
            OperatorNearbyDevice(
                deviceRef: device.id.uuidString, name: device.name, platform: device.platformName,
                authenticated: service.authenticatedConnection(to: device) != nil,
                transport: service.authenticatedConnection(to: device)?.controlTransport.rawValue
            )
        }
        return OperatorNearbyResult(devices: devices)
    }

    static func connect(deviceRef: String) async throws -> OperatorNearbyConnectResult {
        let device = try resolve(deviceRef)
        let service = P2PDiscoveryService.shared
        guard !NativeHandshakeConfiguration.isBusy else {
            throw CrossnetControlFailure.sessionMutationRejected("peer_has_active_work")
        }
        if let existing = service.authenticatedConnection(to: device) {
            try await service.retireAuthenticatedConnection(existing, for: device)
        }
        try Task.checkCancellation()
        guard !NativeHandshakeConfiguration.isBusy else {
            throw CrossnetControlFailure.sessionMutationRejected("peer_has_active_work")
        }
        try await service.connectToDevice(device)
        guard let connection = service.authenticatedConnection(to: device) else {
            throw CrossnetControlFailure.sessionRuntimeApplyFailed
        }
        try await connection.waitForCurrentPeerIdentityExchange()
        return connectedResult(device, connection: connection)
    }

    static func usbDevices() async throws -> OperatorUSBDevicesResult {
        let devices = try await USBMultiplexTransport.devices()
        return OperatorUSBDevicesResult(devices: devices.map {
            OperatorUSBDevice(udid: $0.udid, deviceID: $0.deviceID, productID: $0.productID)
        })
    }

    static func connectUSB(_ request: OperatorUSBConnectRequest) async throws -> OperatorNearbyConnectResult {
        let service = P2PDiscoveryService.shared
        let device = try service.usbControlTarget(peerID: request.peerID,
                                                 expectedFingerprint: request.expectedFingerprint, udid: request.udid)
        try await reconnectUSB(device, udid: request.udid)
        guard let connection = service.authenticatedConnection(to: device), connection.controlTransport == .usb,
              connection.authenticatedProtocolFingerprint == request.expectedFingerprint else {
            throw CrossnetControlFailure.sessionRuntimeApplyFailed
        }
        try await connection.waitForCurrentPeerIdentityExchange()
        return connectedResult(device, connection: connection)
    }

    static func usbPeers() async throws -> OperatorUSBPeersResult {
        OperatorUSBPeersResult(peers: try await TrustSyncService.shared.usbPeerChoices())
    }

    static func connectUSBDevice(_ request: OperatorUSBDeviceConnectRequest) async throws -> OperatorNearbyConnectResult {
        let device = try resolve(request.deviceRef)
        let service = P2PDiscoveryService.shared
        try await reconnectUSB(device, udid: request.udid)
        guard let connection = service.authenticatedConnection(to: device),
              connection.controlTransport == .usb, connection.negotiatedPQC == true else {
            throw CrossnetControlFailure.sessionRuntimeApplyFailed
        }
        try await connection.waitForCurrentPeerIdentityExchange()
        return connectedResult(device, connection: connection)
    }

    private static func reconnectUSB(_ device: DiscoveredDevice, udid: String) async throws {
        let service = P2PDiscoveryService.shared
        // This is an explicit user reconnection, not an automatic retry of a
        // failed file or an uncertain management mutation.
        guard !NativeHandshakeConfiguration.isBusy else {
            throw CrossnetControlFailure.sessionMutationRejected("peer_has_active_work")
        }
        let attached = try await USBMultiplexTransport.devices()
        guard attached.contains(where: { $0.udid == udid }) else {
            throw USBMultiplexError.deviceUnavailable
        }
        try Task.checkCancellation()
        guard !NativeHandshakeConfiguration.isBusy else {
            throw CrossnetControlFailure.sessionMutationRejected("peer_has_active_work")
        }
        if let existing = service.authenticatedConnection(to: device) {
            try await service.retireAuthenticatedConnection(existing, for: device)
        }
        try Task.checkCancellation()
        guard !NativeHandshakeConfiguration.isBusy else {
            throw CrossnetControlFailure.sessionMutationRejected("peer_has_active_work")
        }
        try await service.connectToDevice(device, routePreference: .usbOnly(udid: udid))
    }

    private static func connectedResult(_ device: DiscoveredDevice, connection: P2PConnection) -> OperatorNearbyConnectResult {
        OperatorNearbyConnectResult(deviceRef: device.id.uuidString, authenticated: true,
                                    transport: connection.controlTransport.rawValue,
                                    negotiatedSuite: connection.negotiatedSuiteName,
                                    peerFingerprint: connection.authenticatedProtocolFingerprint,
                                    pqc: connection.negotiatedPQC)
    }

    static func send(_ request: OperatorFileSendRequest) throws -> AsyncStream<OperatorFileTransferEvent> {
        let device = try resolve(request.deviceRef)
        guard let connection = P2PDiscoveryService.shared.authenticatedConnection(to: device) else {
            throw CrossnetControlFailure.sessionMutationRejected("nearby_peer_not_authenticated")
        }
        let url = URL(fileURLWithPath: request.path)
        let attributes = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard attributes.isRegularFile == true, attributes.isSymbolicLink != true else {
            throw CrossnetControlFailure.malformedRequest("file send requires a regular source file")
        }
        let peerID = connection.device.deviceId
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let observation = OperatorFileTransferObservation(request: request, continuation: continuation)
            let task = Task { @MainActor in
                let ticker = Task { @MainActor in
                    do {
                        while !Task.isCancelled {
                            observation.progress()
                            try await Task.sleep(for: .milliseconds(200))
                        }
                    } catch is CancellationError {
                        // Normal termination of this owned progress timer.
                        return
                    } catch {
                        observation.fail(code: "progress_timer_failed")
                        observation.cancel()
                    }
                }
                let deadline = Task { @MainActor in
                    do {
                        try await Task.sleep(for: .seconds(request.timeoutSeconds))
                        observation.timedOut = true
                        observation.cancel()
                    } catch is CancellationError {
                        return
                    } catch {
                        observation.fail(code: "deadline_timer_failed")
                        observation.cancel()
                    }
                }
                defer {
                    ticker.cancel()
                    deadline.cancel()
                    continuation.finish()
                }
                await withTaskCancellationHandler {
                    do {
                        try Task.checkCancellation()
                        try await FileTransferManager.shared.sendFileToActivePeer(
                            at: url, matchingPeerIds: [peerID],
                            onTransferCreated: { observation.created($0) }
                        )
                        try observation.complete()
                    } catch {
                        let code: String
                        if observation.timedOut { code = "transfer_timed_out" }
                        else if Task.isCancelled { code = "transfer_cancelled" }
                        else if case ClassicTransferApprovalError.refused(let reason) = error {
                            code = reason == .denied ? "file_approval_denied" : "file_approval_unavailable"
                        }
                        else if case ClassicTransferApprovalError.capabilityEvidenceUnavailable = error { code = "file_approval_capability_unavailable" }
                        else if case FileTransferError.deliveryConfirmationUnknown = error { code = "delivery_unconfirmed" }
                        else if case FileTransferError.receiptWaitFailed(let stage, _) = error { code = stage.rawValue }
                        else { code = "transfer_failed" }
                        observation.fail(code: code)
                    }
                } onCancel: {
                    Task { @MainActor in observation.cancel() }
                }
            }
            observation.operation = task
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func resolve(_ ref: String) throws -> DiscoveredDevice {
        guard let id = UUID(uuidString: ref),
              let device = (P2PDiscoveryService.shared.connectedUSBControlDevices
                + P2PDiscoveryService.shared.discoveredDevices).first(where: { $0.id == id }),
              isSkyBridgePeer(device) else {
            throw CrossnetControlFailure.deviceNotFound
        }
        return device
    }

    private static func isSkyBridgePeer(_ device: DiscoveredDevice) -> Bool {
        !device.isLocalDevice && device.services.contains { $0.hasPrefix("_skybridge") }
    }
}

@MainActor
private final class OperatorFileTransferObservation {
    let request: OperatorFileSendRequest
    let continuation: AsyncStream<OperatorFileTransferEvent>.Continuation
    var operation: Task<Void, Never>?
    var transfer: FileTransfer?
    var timedOut = false
    private let deadline: ContinuousClock.Instant
    private var terminal = false

    init(request: OperatorFileSendRequest, continuation: AsyncStream<OperatorFileTransferEvent>.Continuation) {
        self.request = request
        self.continuation = continuation
        self.deadline = ContinuousClock.now.advanced(by: .seconds(request.timeoutSeconds))
    }

    func created(_ transfer: FileTransfer) {
        self.transfer = transfer
        if timedOut || operation?.isCancelled == true {
            FileTransferManager.shared.cancelTransfer(transfer.id)
        }
        progress()
    }

    func progress() {
        guard !terminal else { return }
        let state: OperatorFileTransferEvent.Status
        if let transfer, transfer.transferredBytes == transfer.fileSize, transfer.status != .preparing {
            state = .awaiting_receipt
        } else {
            state = transfer?.status == .transferring ? .transferring : .preparing
        }
        continuation.yield(event(status: state))
    }

    func complete() throws {
        if ContinuousClock.now >= deadline {
            timedOut = true
            throw CrossnetControlFailure.internalError("file transfer deadline expired")
        }
        guard !terminal, !timedOut, !Task.isCancelled,
              let transfer, transfer.status == .completed, transfer.receiverReceiptVerified else {
            throw CrossnetControlFailure.internalError("file operation did not confirm a receiver receipt")
        }
        let result = try event(status: .completed, receiptVerified: true).validated()
        terminal = true
        operation = nil
        continuation.yield(result)
    }

    func fail(code: String) {
        guard !terminal else { return }
        terminal = true
        operation = nil
        let unconfirmed = ["transfer_timed_out", "transfer_cancelled", "delivery_unconfirmed"].contains(code)
        continuation.yield(event(status: unconfirmed ? .unconfirmed : .failed, errorCode: code))
    }

    func cancel() {
        operation?.cancel()
        if let transfer, FileTransferManager.shared.activeTransfers[transfer.id] === transfer {
            FileTransferManager.shared.cancelTransfer(transfer.id)
        }
    }

    private func event(
        status: OperatorFileTransferEvent.Status, receiptVerified: Bool = false, errorCode: String? = nil
    ) -> OperatorFileTransferEvent {
        OperatorFileTransferEvent(
            request: request, transferID: transfer?.id, status: status,
            bytesTransferred: transfer?.transferredBytes ?? 0, totalBytes: transfer?.fileSize ?? 0,
            sha256: transfer?.fileHash, receiptVerified: receiptVerified, errorCode: errorCode,
            transport: transfer?.actualTransport
        )
    }
}
