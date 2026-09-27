import Foundation

public struct OperatorNearbyDevice: Codable, Equatable, Sendable {
    public let device_ref: String
    public let name: String
    public let platform: String?
    public let authenticated: Bool
    public let transport: String?

    public init(deviceRef: String, name: String, platform: String?, authenticated: Bool, transport: String? = nil) {
        self.device_ref = deviceRef
        self.name = name
        self.platform = platform
        self.authenticated = authenticated
        self.transport = transport
    }
}

public struct OperatorNearbyResult: Codable, Equatable, Sendable {
    public let runtime_target: String
    public let devices: [OperatorNearbyDevice]

    public init(devices: [OperatorNearbyDevice]) {
        self.runtime_target = "mac_app_runtime"
        self.devices = devices
    }
}

public struct OperatorNearbyConnectResult: Codable, Equatable, Sendable {
    public let runtime_target: String
    public let device_ref: String
    public let authenticated: Bool
    public let transport: String?
    public let negotiated_suite: String?
    public let peer_fingerprint: String?
    public let pqc: Bool?

    public init(deviceRef: String, authenticated: Bool, transport: String? = nil,
                negotiatedSuite: String? = nil, peerFingerprint: String? = nil, pqc: Bool? = nil) {
        self.runtime_target = "mac_app_runtime"
        self.device_ref = deviceRef
        self.authenticated = authenticated
        self.transport = transport
        self.negotiated_suite = negotiatedSuite
        self.peer_fingerprint = peerFingerprint
        self.pqc = pqc
    }
}

public struct OperatorUSBDevice: Codable, Equatable, Sendable {
    public let udid: String
    public let device_id: UInt32
    public let product_id: UInt32
    public let transport: String

    public init(udid: String, deviceID: UInt32, productID: UInt32) {
        self.udid = udid; self.device_id = deviceID; self.product_id = productID
        self.transport = "usb"
    }
}

public struct OperatorUSBDevicesResult: Codable, Equatable, Sendable {
    public let runtime_target: String
    public let devices: [OperatorUSBDevice]

    public init(devices: [OperatorUSBDevice]) {
        self.runtime_target = "mac_app_runtime"; self.devices = devices
    }
}

public struct OperatorUSBPeersResult: Codable, Equatable, Sendable {
    public let runtime_target: String
    public let peers: [USBPeerChoice]

    public init(peers: [USBPeerChoice]) {
        self.runtime_target = "mac_app_runtime"
        self.peers = peers
    }
}

public struct OperatorUSBConnectRequest: Sendable {
    public let udid: String
    public let peerID: String
    public let expectedFingerprint: String

    public init(params: CrossnetControlParams) throws {
        guard let udid = params.string("udid"), (24...64).contains(udid.utf8.count),
              udid.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0)
                  || (97...102).contains($0) || $0 == 45 }),
              let peer = params.string("peer_id"), let peerUUID = UUID(uuidString: peer),
              let fingerprint = params.string("expected_fingerprint"), fingerprint.count == 64,
              fingerprint.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw CrossnetControlFailure.malformedRequest("USB connect requires a USB UDID, stable peer UUID and full lowercase protocol fingerprint")
        }
        self.udid = udid; self.peerID = peerUUID.uuidString; self.expectedFingerprint = fingerprint
    }
}

/// Connects an app-resolved device over an explicitly selected physical cable.
/// The reference is resolved by the native owner; the existing handshake still
/// validates its stable identity and current trust pins.
public struct OperatorUSBDeviceConnectRequest: Sendable {
    public let udid: String
    public let deviceRef: String

    public init(params: CrossnetControlParams) throws {
        guard let udid = params.string("udid"), (24...64).contains(udid.utf8.count),
              udid.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0)
                  || (97...102).contains($0) || $0 == 45 }),
              let ref = params.string("device_ref"), UUID(uuidString: ref) != nil else {
            throw CrossnetControlFailure.malformedRequest("USB device connect requires a physical UDID and an app device reference")
        }
        self.udid = udid
        self.deviceRef = ref
    }
}

public struct OperatorTrustRecoveryRequest: Sendable {
    public let usb: OperatorUSBConnectRequest
    public let authorization: TrustMirrorRecoveryAuthorization

    public init(params: CrossnetControlParams) throws {
        usb = try OperatorUSBConnectRequest(params: params)
        guard !params.contains("preserve_shared_peer_id") || params.string("preserve_shared_peer_id") != nil else {
            throw CrossnetControlFailure.malformedRequest("shared peer preservation requires a stable UUID")
        }
        guard params.bool("approve_mirror_retirement") == true,
              let rawID = params.string("recovery_id"), let id = UUID(uuidString: rawID),
              let snapshot = params.string("snapshot_sha256"), snapshot.count == 64,
              snapshot.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw CrossnetControlFailure.malformedRequest("explicit mirror retirement approval, recovery UUID and preview snapshot are required")
        }
        authorization = try TrustMirrorRecoveryAuthorization(recoveryID: id, peerID: usb.peerID,
            expectedFingerprint: usb.expectedFingerprint, snapshotSHA256: snapshot,
            preservingSharedPeerID: params.string("preserve_shared_peer_id"))
    }
}

public struct OperatorFileSendRequest: Sendable {
    public let operationID: String
    public let deviceRef: String
    public let path: String
    public let timeoutSeconds: Int

    public init(operationID: String, params: CrossnetControlParams) throws {
        guard let deviceRef = params.string("device_ref"), UUID(uuidString: deviceRef) != nil,
              let path = params.string("path"), path.hasPrefix("/"), !path.contains("\0"),
              let timeout = params.int("timeout_seconds"), (1...3600).contains(timeout) else {
            throw CrossnetControlFailure.malformedRequest("file send requires a device reference, absolute path and 1...3600 second deadline")
        }
        self.operationID = operationID
        self.deviceRef = deviceRef
        self.path = path
        self.timeoutSeconds = timeout
    }
}

public struct OperatorFileTransferEvent: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case preparing, transferring, awaiting_receipt, completed, failed, cancelled, unconfirmed
    }

    public let operation_id: String
    public let runtime_target: String
    public let device_ref: String
    public let transfer_id: String?
    public let file_name: String
    public let status: Status
    public let bytes_transferred: Int64
    public let total_bytes: Int64
    public let sha256: String?
    public let receipt_verified: Bool
    public let transport: String?
    public let error_code: String?

    public let success: Bool
    public let automatic_retry_allowed: Bool

    public init(
        request: OperatorFileSendRequest, transferID: String? = nil,
        status: Status, bytesTransferred: Int64 = 0, totalBytes: Int64 = 0,
        sha256: String? = nil, receiptVerified: Bool = false, errorCode: String? = nil,
        transport: String? = nil
    ) {
        self.operation_id = request.operationID
        self.runtime_target = "mac_app_runtime"
        self.device_ref = request.deviceRef
        self.transfer_id = transferID
        self.file_name = URL(fileURLWithPath: request.path).lastPathComponent
        self.status = status
        self.bytes_transferred = bytesTransferred
        self.total_bytes = totalBytes
        self.sha256 = sha256
        self.receipt_verified = receiptVerified
        self.transport = transport
        self.error_code = errorCode
        self.success = status == .completed && receiptVerified
        self.automatic_retry_allowed = false
    }

    public func validated() throws -> Self {
        guard bytes_transferred >= 0, total_bytes >= 0, bytes_transferred <= total_bytes else {
            throw CrossnetControlFailure.internalError("invalid transfer byte counters")
        }
        if status == .completed {
            guard success, receipt_verified, let transfer_id, UUID(uuidString: transfer_id) != nil,
                  bytes_transferred == total_bytes,
                  let sha256, sha256.count == 64,
                  sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  error_code == nil else {
                throw CrossnetControlFailure.internalError("transfer completion lacks a verified receiver receipt")
            }
        } else if receipt_verified || success {
            throw CrossnetControlFailure.internalError("nonterminal transfer claimed receipt completion")
        }
        if [.failed, .cancelled, .unconfirmed].contains(status), error_code?.isEmpty != false {
            throw CrossnetControlFailure.internalError("terminal transfer failure omitted its code")
        }
        return self
    }
}
