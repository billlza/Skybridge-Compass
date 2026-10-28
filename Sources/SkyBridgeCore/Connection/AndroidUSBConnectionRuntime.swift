#if os(macOS)
import Foundation
import IOKit
import SkyBridgeAppleTransport

struct AndroidUSBSessionCleanupFailure: Error, Sendable { let failures: [any Error] }

/// Concrete product pipeline. The coordinator owns this instance before any
/// preparation, native acquisition or authentication begins.
@MainActor
final class AndroidUSBConnectionRuntime: AndroidUSBSessionRuntime {
    private static let linkStartupMillis: Int64 = 15_000
    private weak var service: P2PDiscoveryService?
    private let manager: USBCConnectionManager
    private let source: USBDeviceInfo
    private let peer: AndroidUSBSelectedPeer
    private let authority: AndroidUSBAttemptAuthority
    private let target: DiscoveredDevice
    private(set) var attemptKey: String?
    private(set) var connection: P2PConnection?
    private var physical: USBHostMultiplexConnection?
    private var bootstrap: USBHostBootstrapChannel?
    private var frames: USBHostControlFrameTransport?
    private var pendingStream: USBHostMultiplexConnection.Stream?
    private var sessionReleased = true, framesReleased = true, inventoryReleaseUnknown = false
    private var retired = false

    init(source: USBDeviceInfo, peer: AndroidUSBSelectedPeer, authority: AndroidUSBAttemptAuthority,
         service: P2PDiscoveryService, manager: USBCConnectionManager) throws {
        guard source.deviceType == .androidDevice, let registry = source.registryEntryID, registry != 0,
              let location = source.locationID, location != 0 else { throw USBHostByteError.invalidRegistryEntry }
        self.source = source; self.peer = peer; self.authority = authority
        self.service = service; self.manager = manager
        target = DiscoveredDevice(id: UUID(), name: peer.name, ipv4: nil, ipv6: nil, platformName: "android",
            services: [BonjourInteropContract.controlServiceType], portMap: [:], connectionTypes: [.usb],
            uniqueIdentifier: "usb-android:\(location)", deviceId: peer.deviceID, pubKeyFP: peer.fingerprint)
    }

    static func isAccessory(_ device: USBDeviceInfo) -> Bool {
        device.vendorID == 0x18d1 && (device.productID == 0x2d00 || device.productID == 0x2d01)
    }
    static func reenumeratedDevice(_ devices: [USBDeviceInfo], prepared: AndroidUSBPreparedAttachment) throws -> USBDeviceInfo? {
        let candidates = devices.filter { $0.locationID == prepared.locationID && isAccessory($0) }
        guard candidates.count <= 1 else { throw AndroidUSBConnectionError.ambiguousAttachment }
        guard let device = candidates.first else { return nil }
        guard let registry = device.registryEntryID, registry != 0, registry != prepared.source.registryEntryID else {
            throw AndroidUSBConnectionError.attachmentChanged
        }
        return device
    }

    /// A selected registry generation must still exist on its original port.
    /// Names and hardware serials cannot substitute a different USB attachment.
    static func currentAccessoryDevice(_ devices: [USBDeviceInfo], selected: USBDeviceInfo) throws -> USBDeviceInfo {
        guard isAccessory(selected), let registry = selected.registryEntryID, registry != 0,
              let location = selected.locationID, location != 0 else { throw AndroidUSBConnectionError.attachmentChanged }
        let candidates = devices.filter { $0.locationID == location && isAccessory($0) }
        guard candidates.count <= 1 else { throw AndroidUSBConnectionError.ambiguousAttachment }
        guard let current = candidates.first, current.deviceType == .androidDevice,
              current.registryEntryID == registry, current.vendorID == selected.vendorID,
              current.productID == selected.productID else { throw AndroidUSBConnectionError.attachmentChanged }
        return current
    }

    private func prepareEndpoint() async throws -> (device: USBDeviceInfo, nonce: UUID) {
        if Self.isAccessory(source) {
            let devices = try await manager.readNativeAndroidUSBDevices()
            try authority.requireCurrent()
            // This nonce binds a fresh bootstrap route; it is not a remembered
            // AOA permission or identity. Epoch v2 must isolate any queued bytes
            // before MAIN, which still verifies the selected protocol peer.
            return (try Self.currentAccessoryDevice(devices, selected: source), UUID())
        }
        let prepared = try await manager.prepareAndroidUSB(source, attemptID: authority.id,
            requireAttemptCurrent: authority.requireCurrent)
        guard prepared.linkProfile == .epochV2 else { throw USBHostAccessoryError.profileMismatch }
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while true {
            try authority.requireCurrent()
            guard ContinuousClock.now < deadline else { throw AndroidUSBConnectionError.reenumerationTimedOut }
            let devices = try await manager.readNativeAndroidUSBDevices()
            try authority.requireCurrent()
            guard ContinuousClock.now < deadline else { throw AndroidUSBConnectionError.reenumerationTimedOut }
            if let selected = try Self.reenumeratedDevice(devices, prepared: prepared) {
                return (selected, prepared.attachmentNonce)
            }
            try await Task.sleep(for: .milliseconds(200))
        }
    }

    func run(progress: @escaping @MainActor (AndroidUSBConnectionPhase) -> Void) async throws {
        guard let service else { throw AndroidUSBConnectionError.unavailable }
        try authority.requireCurrent()
        attemptKey = P2PDiscoveryService.handshakeDeviceIdentifier(for: target)
        service.reserveAndroidUSBAttempt(for: target, id: authority.id)
        do {
            try await service.prepareSelectedAndroidUSBPeer(target, attempt: authority.id)
            try authority.requireCurrent()
            let endpoint = try await prepareEndpoint()
            try authority.requireCurrent()
            guard let registry = endpoint.device.registryEntryID else { throw USBHostByteError.invalidRegistryEntry }
            progress(.opening)
            let native = try USBHostMultiplexConnection(deviceRegistryID: registry,
                configuration: .init(linkProfile: .epochV2,
                    epochLimits: .init(startupMillis: Self.linkStartupMillis)),
                requireAttachmentCurrent: authority.requireCurrent)
            physical = native
            try await native.start(timeout: .milliseconds(Self.linkStartupMillis))
            try authority.requireCurrent()
            let channel = try USBHostBootstrapChannel(connection: native, attachmentNonce: endpoint.nonce,
                requireAttachmentCurrent: authority.requireCurrent)
            bootstrap = channel
            progress(.authenticating)
            try await service.prepareAndroidUSBHandshake(for: target, bootstrap: channel)
            try authority.requireCurrent()
            let stream = try await native.openStream()
            pendingStream = stream
            try authority.requireCurrent()
            let carrier = try USBHostControlFrameTransport(stream: stream)
            frames = carrier; framesReleased = false; pendingStream = nil
            let authenticated = service.makeAndroidUSBConnection(for: target, frames: carrier,
                attachmentNonce: endpoint.nonce, fileConnection: native)
            connection = authenticated; sessionReleased = false
            try await service.authenticatePreparedConnection(authenticated)
            try authority.requireCurrent()
            try service.publishAndroidUSBConnection(authenticated, for: target, attempt: authority.id, expectedPeer: peer)
        } catch {
            if case USBDeviceInventoryError.cleanup = error { inventoryReleaseUnknown = true }
            throw error
        }
    }

    func releaseAttempt() { service?.finishAndroidUSBAttempt(for: target, id: authority.id) }
    var connectionEndFailure: (any Error)? {
        let cause = frames?.terminalFailure ?? physical?.terminalFailure
        // Explicit local disconnect closes this carrier too. A peer reset,
        // deadline or native failure retains its distinct first cause.
        if cause as? USBHostMultiplexError == .closed { return nil }
        return cause
    }
    func retire() {
        guard !retired else { return }
        retired = true; authority.retire()
        physical?.close()
        manager.cancelAndroidUSBPreparation(attemptID: authority.id)
        connection?.disconnect()
        frames?.close(); pendingStream?.close()
        service?.removeAndroidUSBConnection(connection, for: target, attempt: authority.id)
    }
    var cleanupConfirmed: Bool {
        let native = physical?.shutdownState
        let physicalReleased = native.map { $0.nativeWorkersExited && $0.referencesReleased && $0.pumpsJoined && $0.logicalOwnersReleased } ?? true
        return !inventoryReleaseUnknown && sessionReleased && framesReleased && pendingStream == nil &&
            physicalReleased && bootstrap?.cleanupRequired != true && !manager.retainsAndroidUSBPreparation(attemptID: authority.id)
    }
    func closeAndAwait() async throws {
        retire()
        var failures: [any Error] = []
        if let connection { await connection.disconnectAndWait(); sessionReleased = true }
        if let frames {
            do { try await frames.closeAndAwait(); framesReleased = true }
            catch { failures.append(error) }
        }
        if let stream = pendingStream {
            do { try await stream.closeAndAwait(); pendingStream = nil }
            catch { failures.append(error) }
        }
        if let bootstrap {
            do { try await bootstrap.finishCleanup() }
            catch { failures.append(error) }
        }
        if let physical {
            do { try await physical.closeAndAwait(timeout: .seconds(5)) }
            catch { failures.append(error) }
        }
        do { try await manager.awaitAndroidUSBCleanup(attemptID: authority.id) }
        catch { failures.append(error) }
        if !cleanupConfirmed { failures.append(AndroidUSBConnectionError.cleanupUnconfirmed) }
        if !failures.isEmpty { throw AndroidUSBSessionCleanupFailure(failures: failures) }
    }
}
#endif
