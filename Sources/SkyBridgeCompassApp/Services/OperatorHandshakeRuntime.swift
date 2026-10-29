import Foundation
import SkyBridgeCore
import SkyBridgeProtocolCore

@MainActor
enum OperatorHandshakeRuntime {
    static let methods = ["crossnet.handshake.list", "crossnet.handshake.status", "crossnet.handshake.set", "crossnet.handshake.revoke"]

    static func execute(_ request: OperatorHandshakeRequest) async throws -> OperatorHandshakeResult {
        var result = OperatorHandshakeResult(request: request, local: try NativeHandshakeConfiguration.snapshot())
        let service = P2PDiscoveryService.shared
        let target: DiscoveredDevice?
        if let usb = request.usb {
            target = try service.usbControlTarget(peerID: usb.peerID, expectedFingerprint: usb.expectedFingerprint, udid: usb.udid)
        } else if let ref = request.deviceRef {
            target = (service.connectedUSBControlDevices + service.discoveredDevices).first { $0.id.uuidString.lowercased() == ref.lowercased() }
            guard target != nil else { throw CrossnetControlFailure.sessionMutationRejected("handshake_target_not_found") }
        } else { target = nil }
        func recordSession() {
            guard let target, let connection = service.authenticatedConnection(to: target) else { return }
            result.negotiated_suite = connection.negotiatedSuiteName
            result.session_transport = connection.controlTransport.rawValue
            result.session_matches_configuration = result.local.configuredProfile.matches(suite: connection.negotiatedSuiteName)
                && (result.remote?.configuredProfile.matches(suite: connection.negotiatedSuiteName) ?? true)
        }
        recordSession()
        if request.action == .list { return result }
        var remoteStatus: HandshakeConfigurationResponse?
        if let target {
            do {
                let status = try await service.exchangeHandshakeConfiguration(for: target, action: .status, usbUDID: request.usb?.udid)
                remoteStatus = status.response
                result.remote = status.response.snapshot
                result.management_authorized = status.response.managementAuthorized
                result.management_transport = status.transport
                result.remote_error = status.response.error?.rawValue
            } catch { result.remote_error = code(error) }
        }
        if request.action == .status {
            result.success = result.remote_error == nil
            recordSession()
            return result
        }
        if request.action == .revoke, let target, let previous = remoteStatus, previous.error == nil {
            do {
                let response = try await service.exchangeHandshakeConfiguration(for: target, action: .revoke, previous: previous, usbUDID: request.usb?.udid)
                result.management_authorized = response.response.managementAuthorized
                result.remote_error = response.response.error?.rawValue
            } catch { result.remote_error = code(error) }
            result.success = result.remote_error == nil && result.management_authorized == false
            return result
        }
        guard request.action == .set, let profile = request.profile else {
            result.success = false
            return result
        }
        // Validate local before changing the peer. No rollback may overwrite an
        // independent edit on either host after one side has applied successfully.
        guard !result.local.busy else {
            result.local_error = HandshakeConfigurationError.transferActive.rawValue
            result.success = false; return result
        }
        guard profile != .classic, result.local.options.first(where: { $0.profile == profile })?.selectable == true else {
            result.local_error = (profile == .classic ? HandshakeConfigurationError.classicDisabled : .profileUnavailable).rawValue
            result.success = false; return result
        }
        if request.scope == "both" {
            guard let target, let previous = remoteStatus, previous.error == nil else {
                result.success = false; return result
            }
            do {
                let applied = try await service.exchangeHandshakeConfiguration(for: target, action: .apply, profile: profile, previous: previous, usbUDID: request.usb?.udid)
                result.remote = applied.response.snapshot
                result.remote_applied = applied.response.applied
                result.remote_error = applied.response.error?.rawValue
                result.management_authorized = applied.response.managementAuthorized
            } catch { result.remote_error = code(error) }
            guard result.remote_applied, result.remote_error == nil else {
                result.success = false; return result
            }
        }
        do {
            result.local = try await NativeHandshakeConfiguration.apply(profile, revision: result.local.revision)
            result.local_applied = true
        } catch {
            result.local_error = code(error)
            do { result.local = try NativeHandshakeConfiguration.snapshot() }
            catch { result.local_error = HandshakeConfigurationError.outcomeUnknown.rawValue }
        }
        result.success = result.local_applied && (request.scope == "local" || result.remote_applied)
        result.partial = request.scope == "both" && result.local_applied != result.remote_applied
        if result.success, request.reconnect, let target {
            do {
                guard !NativeHandshakeConfiguration.isBusy else { throw HandshakeConfigurationError.transferActive }
                if let existing = service.authenticatedConnection(to: target) {
                    try await service.retireAuthenticatedConnection(existing, for: target)
                }
                guard !NativeHandshakeConfiguration.isBusy else { throw HandshakeConfigurationError.transferActive }
                try await service.connectToDevice(target, routePreference: request.usb.map { .usbOnly(udid: $0.udid) } ?? .preferUSB)
                guard let connection = service.authenticatedConnection(to: target),
                      profile.matches(suite: connection.negotiatedSuiteName) else { throw HandshakeConfigurationError.applyFailed }
                try await connection.waitForCurrentPeerIdentityExchange()
                result.reconnected = true
            } catch { result.reconnect_error = code(error); result.success = false }
        }
        result.negotiated_suite = nil; result.session_transport = nil; result.session_matches_configuration = nil
        recordSession()
        return result
    }

    private static func code(_ error: Error) -> String {
        if let error = error as? HandshakeConfigurationError { return error.rawValue }
        if case P2PConnectionError.postAuthPairingIdentityExchangeTimeout = error { return "peer_identity_exchange_not_ready" }
        if let error = error as? USBMultiplexError { return "usb_" + error.rawValue }
        if error is CancellationError { return "cancelled_outcome_unconfirmed" }
        return "handshake_configuration_failed"
    }
}
