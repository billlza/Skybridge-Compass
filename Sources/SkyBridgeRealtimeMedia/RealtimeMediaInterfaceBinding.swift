import Foundation
import Network
import SkyBridgeProtocolCore

public enum SkyBridgeRealtimeMediaInterfaceBindingError: Error, LocalizedError, Sendable, Equatable {
    case missingAuthenticatedControlPath
    case controlPathUnsatisfied
    case missingRemoteHost
    case rejected(ApplePeerConnectivityPolicy.RemoteControlMediaInterfaceBindingRejectionReason)
    case selectedInterfaceDisappeared

    public var errorDescription: String? {
        switch self {
        case .missingAuthenticatedControlPath:
            return "missing_authenticated_control_path"
        case .controlPathUnsatisfied:
            return "authenticated_control_path_unsatisfied"
        case .missingRemoteHost:
            return "authenticated_control_path_missing_remote_host"
        case .rejected(let reason):
            return reason.rawValue
        case .selectedInterfaceDisappeared:
            return "selected_interface_disappeared"
        }
    }
}

/// A process-local route binding derived from an already authenticated
/// remote-control connection. The interface object never crosses the wire;
/// peers continue to exchange only `SkyBridgeMediaEndpoint` host/port data.
public struct SkyBridgeRealtimeMediaInterfaceBinding: @unchecked Sendable, Equatable {
    public struct Identity: Sendable, Equatable {
        public let normalizedName: String
        public let index: Int
        public let expectedRemoteScope: String?

        public init(
            normalizedName: String,
            index: Int,
            expectedRemoteScope: String?
        ) {
            self.normalizedName = normalizedName
            self.index = index
            self.expectedRemoteScope = expectedRemoteScope
        }
    }

    public let interface: NWInterface
    public let identity: Identity
    /// Canonical host from the authenticated connection path. This is used as
    /// the direct-LAN destination when the peer advertises a wildcard host.
    public let authenticatedRemoteHost: String

    public static func == (
        lhs: SkyBridgeRealtimeMediaInterfaceBinding,
        rhs: SkyBridgeRealtimeMediaInterfaceBinding
    ) -> Bool {
        lhs.identity == rhs.identity
            && lhs.authenticatedRemoteHost == rhs.authenticatedRemoteHost
            && lhs.interface.type == rhs.interface.type
    }

    public static func resolveAuthenticatedControlPath(
        connection: NWConnection,
        advertisedHost: String?,
        authenticatedSessionEstablished: Bool
    ) throws -> SkyBridgeRealtimeMediaInterfaceBinding {
        guard authenticatedSessionEstablished else {
            throw SkyBridgeRealtimeMediaInterfaceBindingError.missingAuthenticatedControlPath
        }
        guard let path = connection.currentPath, path.status == .satisfied else {
            throw SkyBridgeRealtimeMediaInterfaceBindingError.controlPathUnsatisfied
        }
        guard case .hostPort(let remoteHost, _) = path.remoteEndpoint else {
            throw SkyBridgeRealtimeMediaInterfaceBindingError.missingRemoteHost
        }
        let authenticated = normalizedAddress(String(describing: remoteHost))
        guard authenticated.addressClass != .invalid,
              authenticated.addressClass != .unresolved,
              let authenticatedHost = authenticated.canonicalHost else {
            throw SkyBridgeRealtimeMediaInterfaceBindingError.missingRemoteHost
        }

        let evidence = ApplePeerConnectivityPolicy.RemoteControlMediaInterfaceBindingEvidence(
            advertisedHostRelation: advertisedHostRelation(
                advertisedHost,
                authenticatedHost: authenticatedHost
            ),
            authenticatedAddressClass: authenticated.addressClass,
            authenticatedInterfaceScope: authenticated.scope,
            candidates: path.availableInterfaces.map { interface in
                ApplePeerConnectivityPolicy.RemoteControlMediaInterfaceCandidate(
                    name: interface.name,
                    index: Int(interface.index),
                    interfaceClass: ApplePeerConnectivityPolicy.remoteControlInterfaceClass(
                        interfaceName: interface.name,
                        isWiFi: interface.type == .wifi,
                        isWiredEthernet: interface.type == .wiredEthernet
                    ),
                    pathUsesInterfaceType: path.usesInterfaceType(interface.type)
                )
            }
        )

        let selectedName: String
        let selectedIndex: Int
        switch ApplePeerConnectivityPolicy.remoteControlMediaInterfaceBindingDecision(
            for: evidence
        ) {
        case .use(let interfaceName, let interfaceIndex):
            selectedName = interfaceName
            selectedIndex = interfaceIndex
        case .reject(let reason):
            throw SkyBridgeRealtimeMediaInterfaceBindingError.rejected(reason)
        }

        let selected = path.availableInterfaces.filter {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                == selectedName
                && Int($0.index) == selectedIndex
        }
        guard selected.count == 1, let interface = selected.first else {
            throw SkyBridgeRealtimeMediaInterfaceBindingError.selectedInterfaceDisappeared
        }
        return SkyBridgeRealtimeMediaInterfaceBinding(
            interface: interface,
            identity: Identity(
                normalizedName: selectedName,
                index: selectedIndex,
                expectedRemoteScope: authenticated.scope
            ),
            authenticatedRemoteHost: authenticatedHost
        )
    }

    public func validatesReadyPath(_ path: NWPath?) -> Bool {
        guard let path, path.status == .satisfied,
              path.usesInterfaceType(interface.type),
              path.availableInterfaces.contains(where: {
                  $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                      == identity.normalizedName
                      && Int($0.index) == identity.index
              }),
              case .hostPort(let remoteHost, _) = path.remoteEndpoint else {
            return false
        }
        let resolved = Self.normalizedAddress(String(describing: remoteHost))
        guard resolved.canonicalHost == authenticatedRemoteHost else { return false }
        if resolved.addressClass == .linkLocalIPv6 {
            return resolved.scope == identity.expectedRemoteScope
                && resolved.scope == identity.normalizedName
        }
        return true
    }

    private static func advertisedHostRelation(
        _ rawAdvertisedHost: String?,
        authenticatedHost: String
    ) -> ApplePeerConnectivityPolicy.RemoteControlMediaAdvertisedHostRelation {
        guard let rawAdvertisedHost else { return .unspecified }
        let trimmed = rawAdvertisedHost
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if trimmed.isEmpty
            || trimmed == "0.0.0.0"
            || trimmed == "::"
            || trimmed == "[::]"
            || trimmed == "localhost" {
            return .unspecified
        }
        let advertised = normalizedAddress(trimmed)
        guard let canonicalHost = advertised.canonicalHost else { return .mismatch }
        return canonicalHost == authenticatedHost ? .exactAuthenticatedHost : .mismatch
    }

    private static func normalizedAddress(
        _ raw: String
    ) -> (
        canonicalHost: String?,
        addressClass: ApplePeerConnectivityPolicy.RemoteControlResolvedAddressClass,
        scope: String?
    ) {
        var token = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if token.hasPrefix("[") && token.hasSuffix("]") {
            token.removeFirst()
            token.removeLast()
        }
        let components = token.split(
            separator: "%",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        let addressToken = String(components[0])
        let scope: String?
        if components.count == 2 {
            let candidate = String(components[1])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard !candidate.isEmpty,
                  candidate.utf8.count <= 64,
                  candidate.utf8.allSatisfy({ byte in
                      (byte >= 0x30 && byte <= 0x39)
                          || (byte >= 0x61 && byte <= 0x7a)
                          || byte == 0x2d
                          || byte == 0x2e
                          || byte == 0x5f
                  }) else {
                return (nil, .invalid, nil)
            }
            scope = candidate
        } else {
            scope = nil
        }

        if let ipv4 = IPv4Address(addressToken) {
            guard scope == nil else { return (nil, .invalid, nil) }
            let bytes = Array(ipv4.rawValue)
            guard bytes.count == 4,
                  !bytes.allSatisfy({ $0 == 0 }),
                  bytes[0] != 127,
                  !(224...239).contains(bytes[0]) else {
                return (nil, .invalid, nil)
            }
            let addressClass: ApplePeerConnectivityPolicy.RemoteControlResolvedAddressClass =
                bytes[0] == 169 && bytes[1] == 254 ? .linkLocalIPv4 : .routable
            return (String(describing: ipv4), addressClass, nil)
        }
        if let ipv6 = IPv6Address(addressToken) {
            let bytes = Array(ipv6.rawValue)
            guard bytes.count == 16,
                  !bytes.allSatisfy({ $0 == 0 }),
                  bytes != Array(repeating: 0, count: 15) + [1],
                  bytes[0] != 0xff else {
                return (nil, .invalid, nil)
            }
            let isLinkLocal = bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80
            guard isLinkLocal || scope == nil else { return (nil, .invalid, nil) }
            let canonicalAddress = String(describing: ipv6).lowercased()
            let canonicalHost = scope.map { "\(canonicalAddress)%\($0)" }
                ?? canonicalAddress
            return (
                canonicalHost,
                isLinkLocal ? .linkLocalIPv6 : .routable,
                scope
            )
        }
        return (nil, .invalid, nil)
    }
}
