import Foundation
import Network

/// Shared port validation helper to avoid `NWEndpoint.Port(rawValue:)!` crashes.
public enum NetworkPortValidationError: Error, LocalizedError, Sendable {
    case invalidPort(UInt16)
    case invalidPortInt(Int)
    
    public var errorDescription: String? {
        switch self {
        case .invalidPort(let port):
            return "Invalid network port: \(port)"
        case .invalidPortInt(let port):
            return "Invalid network port: \(port)"
        }
    }
}

public extension NWEndpoint.Port {
    /// Validates a `UInt16` port. Rejects `0` as an invalid listen/connect port in this app.
    static func validated(_ port: UInt16) throws -> NWEndpoint.Port {
        guard port != 0, let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NetworkPortValidationError.invalidPort(port)
        }
        return nwPort
    }
    
    /// Validates an `Int` port (1...65535).
    static func validated(_ port: Int) throws -> NWEndpoint.Port {
        guard (1...65535).contains(port) else {
            throw NetworkPortValidationError.invalidPortInt(port)
        }
        // Safe: validated range guarantees representable UInt16
        return try validated(UInt16(port))
    }
}


