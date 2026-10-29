import CryptoKit
import Foundation
import Network
import SkyBridgeProtocolCore

enum IOSLanConnectionError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedPlatform, invalidDevice, identityMismatch, existingOperation, capacity, accountSelectionChanged, accountRouteUnavailable

    var errorDescription: String? {
        switch self {
        case .unsupportedPlatform: return "请扫描 Mac 或 Windows 电脑上的连接二维码。"
        case .invalidDevice: return "连接信息缺少有效的设备身份，请在电脑上刷新二维码。"
        case .identityMismatch: return "连接信息与电脑身份不一致，请重新扫描电脑上的二维码。"
        case .existingOperation: return "这台电脑正在连接，请等待当前操作完成。"
        case .capacity: return "本次运行的直连记录已满，请重启应用后再试。"
        case .accountSelectionChanged: return "账号或所选设备信息已变化，请刷新账号设备后重新连接。"
        case .accountRouteUnavailable: return "电脑的连接地址已失效，请刷新账号设备，或扫描电脑上最新的二维码。"
        }
    }
}

/// Captures an exact account row in the locally verified account request scope.
/// This selects a peer; it never grants trust or manufactures a network endpoint.
struct IOSAccountConnectionSelection: Sendable, Equatable {
    let record: AccountDeviceRecord
    let accountScope: String
    let authenticationGeneration: UInt64

    init(record: AccountDeviceRecord, snapshot: AccountDeviceListSnapshot?,
         isAuthenticated: Bool, callerRemoved: Bool, authenticationGeneration: UInt64) throws {
        guard let snapshot, let accountScope = snapshot.accountScope, !accountScope.isEmpty,
              ProtocolSigningAlgorithm(rawValue: record.protocolSigningAlgorithm) != nil,
              !PeerIdentityAliasResolver.isEndpointAlias(record.deviceId),
              PeerIdentityAliasResolver.persistentDeviceId(from: record.deviceId) != nil,
              record.protocolPublicKeyFingerprint.utf8.count == 64,
              record.protocolPublicKeyFingerprint.utf8.allSatisfy({
                  (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
              }) else { throw IOSLanConnectionError.accountSelectionChanged }
        self.record = record
        self.accountScope = accountScope
        self.authenticationGeneration = authenticationGeneration
        try requireCurrent(snapshot: snapshot, isAuthenticated: isAuthenticated, callerRemoved: callerRemoved,
                           authenticationGeneration: authenticationGeneration)
    }

    func requireCurrent(snapshot: AccountDeviceListSnapshot?, isAuthenticated: Bool, callerRemoved: Bool,
                        authenticationGeneration: UInt64) throws {
        guard isAuthenticated, !callerRemoved, let snapshot,
              authenticationGeneration == self.authenticationGeneration,
              snapshot.accountScope == accountScope,
              snapshot.devices.contains(where: { $0.isCaller && $0.status == "active" }),
              snapshot.devices.contains(where: { $0.id == record.id && !$0.isCaller && $0.status == "active" }) else {
            throw IOSLanConnectionError.accountSelectionChanged
        }
    }

    func requireDiscovery(_ device: DiscoveredDevice, fingerprint: String?) throws {
        guard AccountDeviceLANMatch.matches(accountDeviceId: record.deviceId,
            accountFingerprint: record.protocolPublicKeyFingerprint,
            discoveredDeviceId: device.id, discoveredFingerprint: fingerprint) else {
            throw IOSLanConnectionError.identityMismatch
        }
    }
}

/// A route from the verified account response. Expiry retires a pending dial,
/// not an already established authenticated connection.
struct IOSAccountLANRouteSelection: Sendable, Equatable {
    let account: IOSAccountConnectionSelection
    let primary: IOSLanConnectionTarget
    let alternatives: [IOSLanConnectionTarget]
    let deadline: ContinuousClock.Instant

    init(account: IOSAccountConnectionSelection, snapshot: AccountDeviceListSnapshot?,
         now: ContinuousClock.Instant) throws {
        guard let snapshot, snapshot.accountScope == account.accountScope,
              let row = snapshot.devices.first(where: { $0.id == account.record.id }),
              !row.isCaller, let route = row.lanControlRoute,
              let deadline = snapshot.liveRouteDeadline(for: row.id, at: now),
              let first = route.addresses.first else { throw IOSLanConnectionError.accountRouteUnavailable }
        func target(_ address: String) throws -> IOSLanConnectionTarget {
            try IOSLanConnectionTarget(LanDirectConnectionInfo(host: address, port: route.port,
                deviceId: row.deviceId, protocolFingerprint: row.protocolPublicKeyFingerprint.lowercased(),
                deviceName: String(AccountDevicePresentationPolicy.displayName(for: row).prefix(32)),
                platform: row.platformRawValue ?? ""))
        }
        self.account = account; self.deadline = deadline
        primary = try target(first)
        alternatives = try route.addresses.dropFirst().map(target)
    }

    var targets: [IOSLanConnectionTarget] { [primary] + alternatives }

    var endpointDigest: String {
        let material = "skybridge-account-routes-v1|" + targets.map(\.endpointDigest).joined(separator: "|")
        return SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func requireCurrent(snapshot: AccountDeviceListSnapshot?, isAuthenticated: Bool, callerRemoved: Bool,
                        authenticationGeneration: UInt64, now: ContinuousClock.Instant) throws {
        try account.requireCurrent(snapshot: snapshot, isAuthenticated: isAuthenticated,
            callerRemoved: callerRemoved, authenticationGeneration: authenticationGeneration)
        guard now < deadline, let snapshot,
              snapshot.liveRouteDeadline(for: account.record.id, at: now) != nil,
              let row = snapshot.devices.first(where: { $0.id == account.record.id }),
              let route = row.lanControlRoute, route.port == primary.info.port,
              route.addresses == targets.map({ $0.info.host }), row.platformRawValue == primary.info.platform
        else { throw IOSLanConnectionError.accountRouteUnavailable }
    }
}

/// QR, verified account routes and Bonjour share PIB/SKR/Finished identity checks.
enum IOSSelectedConnectionTarget: Sendable {
    case lan(IOSLanConnectionTarget)
    case account(IOSAccountConnectionSelection)
    case accountLAN(IOSAccountLANRouteSelection)

    var directLAN: IOSLanConnectionTarget? {
        switch self {
        case .lan(let target): return target
        case .accountLAN(let route): return route.primary
        case .account: return nil
        }
    }

    var directEndpoints: [NWEndpoint]? {
        switch self {
        case .lan(let target): return [target.endpoint]
        case .accountLAN(let route): return route.targets.map(\.endpoint)
        case .account: return nil
        }
    }

    var directEndpointDigest: String? {
        if case .accountLAN(let route) = self { return route.endpointDigest }
        return directLAN?.endpointDigest
    }

    var accountSelection: IOSAccountConnectionSelection? {
        switch self {
        case .account(let selection): return selection
        case .accountLAN(let route): return route.account
        case .lan: return nil
        }
    }

    var deviceID: String {
        switch self {
        case .lan(let target): return target.info.deviceId
        case .account(let selection): return selection.record.deviceId
        case .accountLAN(let route): return route.account.record.deviceId
        }
    }

    var fingerprint: String {
        switch self {
        case .lan(let target): return target.info.protocolFingerprint
        case .account(let selection): return selection.record.protocolPublicKeyFingerprint.lowercased()
        case .accountLAN(let route): return route.account.record.protocolPublicKeyFingerprint.lowercased()
        }
    }

    func matchesDeviceID(_ deviceID: String) -> Bool {
        PeerSessionArbiter.soaPeerId(from: deviceID) == PeerSessionArbiter.soaPeerId(from: self.deviceID)
    }

    func requireCandidate(deviceID: String, fingerprint: String, signingAlgorithm: String) throws {
        guard matchesDeviceID(deviceID), fingerprint.lowercased() == self.fingerprint else {
            throw IOSLanConnectionError.identityMismatch
        }
        if let selection = accountSelection,
           signingAlgorithm != selection.record.protocolSigningAlgorithm {
            throw IOSLanConnectionError.identityMismatch
        }
    }

    func requireAuthenticatedBinding(_ binding: AuthenticatedHandshakePeerBinding) throws {
        guard binding.authority.protocolPublicKeyFingerprint.lowercased() == fingerprint,
              binding.authenticatedRemoteSOAPeerId == PeerSessionArbiter.soaPeerId(from: deviceID) else {
            throw IOSLanConnectionError.identityMismatch
        }
        if let selection = accountSelection,
           binding.authority.protocolSigningAlgorithm != selection.record.protocolSigningAlgorithm {
            throw IOSLanConnectionError.identityMismatch
        }
    }

    func constrainedPins(_ existing: Set<String>) throws -> Set<String> {
        guard !existing.isEmpty else { return [] }
        guard existing.contains(where: { $0.lowercased() == fingerprint }) else {
            throw IOSLanConnectionError.identityMismatch
        }
        return [fingerprint]
    }
}

/// Routing has no authority side effects. Unsupported LAN versions are not
/// retried as server invitations or as the retired QR trust-import protocol.
@MainActor
enum IOSScannedConnectionRoute: Equatable {
    case lan(IOSLanConnectionTarget)
    case connectionCode(String)
    case crossNetwork(String)

    static func decode(_ text: String) throws -> Self {
        if text.lowercased().hasPrefix("skybridge://lan") {
            do {
                return .lan(try IOSLanConnectionTarget(LanDirectConnectionInfoCodec.decode(text)))
            } catch is LanDirectConnectionInfoError {
                throw ScanError.invalidLAN
            }
        }
        if let code = CrossNetworkWebRTCManager.extractConnectionCode(fromScannedString: text) {
            return .connectionCode(code)
        }
        if CrossNetworkWebRTCManager.isConnectLinkString(text) { return .crossNetwork(text) }
        throw ScanError.unrecognized
    }

    private enum ScanError: LocalizedError {
        case unrecognized, invalidLAN
        var errorDescription: String? {
            switch self {
            case .unrecognized: return "这不是可用的 SkyBridge 连接二维码，请扫描电脑上最新显示的二维码。"
            case .invalidLAN: return "连接二维码无效或版本不受支持，请更新两端应用并在电脑上刷新二维码。"
            }
        }
    }
}

/// One explicit user-selected route and identity constraint. This value is never
/// decoded from ordinary discovery metadata and never constitutes trust material.
struct IOSLanConnectionTarget: Sendable, Equatable {
    let info: LanDirectConnectionInfo
    let key: String

    init(_ info: LanDirectConnectionInfo) throws {
        guard info.platform == "macos" || info.platform == "windows" else {
            throw IOSLanConnectionError.unsupportedPlatform
        }
        let candidate = Self.device(for: info)
        guard let key = P2PConnectionEndpointPolicy.normalizedStrongDeviceId(for: candidate),
              !PeerIdentityAliasResolver.isEndpointAlias(info.deviceId) else {
            throw IOSLanConnectionError.invalidDevice
        }
        self.info = info; self.key = key
    }

    var device: DiscoveredDevice { Self.device(for: info) }

    var endpoint: NWEndpoint {
        // LanDirectConnectionInfo already requires a canonical numeric LAN host
        // and a nonzero UInt16 port. Keep that pair atomic, without TXT enrichment.
        .hostPort(host: NWEndpoint.Host(info.host), port: .init(integerLiteral: info.port))
    }

    var endpointDigest: String {
        let material = "skybridge-lan-route-v1|\(info.host)|\(info.port)|\(info.deviceId)|\(info.protocolFingerprint)"
        return SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func matchesDeviceID(_ deviceID: String) -> Bool {
        IOSSelectedConnectionTarget.lan(self).matchesDeviceID(deviceID)
    }

    func requireCandidate(deviceID: String, fingerprint: String) throws {
        try IOSSelectedConnectionTarget.lan(self).requireCandidate(deviceID: deviceID,
            fingerprint: fingerprint, signingAlgorithm: "")
    }

    /// Called only on the driver's Finished-verified binding, before persistence
    /// or session publication. A matching label or pre-handshake key is not enough.
    func requireAuthenticatedBinding(_ binding: AuthenticatedHandshakePeerBinding) throws {
        try IOSSelectedConnectionTarget.lan(self).requireAuthenticatedBinding(binding)
    }

    func constrainedPins(_ existing: Set<String>) throws -> Set<String> {
        try IOSSelectedConnectionTarget.lan(self).constrainedPins(existing)
    }

    private static func device(for info: LanDirectConnectionInfo) -> DiscoveredDevice {
        DiscoveredDevice(id: info.deviceId, name: info.deviceName, modelName: info.deviceName,
            platform: info.platform == "macos" ? .macOS : .windows, osVersion: "",
            ipAddress: info.host)
    }
}
