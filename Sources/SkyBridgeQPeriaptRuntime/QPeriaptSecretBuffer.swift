import Foundation
import SkyBridgeProtocolCore

/// Target-owned secret storage boundary used by the Q-Periapt native runtime.
///
/// The throwing allocation contract prevents native metadata or a corrupted ABI
/// length from terminating the process. Platform adapters all share the same
/// `SecureBytes` implementation from `SkyBridgeProtocolCore`.
public protocol QPeriaptSecretBuffer: AnyObject, Sendable {
    init(count: Int) throws

    var byteCount: Int { get }

    func copyData() -> Data

    func withUnsafeBytes<Result>(
        _ body: (UnsafeRawBufferPointer) throws -> Result
    ) rethrows -> Result

    func withUnsafeMutableBytes<Result>(
        _ body: (UnsafeMutableRawBufferPointer) throws -> Result
    ) rethrows -> Result

    func zeroize()
}

extension SecureBytes: QPeriaptSecretBuffer {}

/// Backwards-compatible name for clients of the standalone runtime target. It
/// is an alias, not a wrapper or a second allocation implementation.
public typealias QPeriaptSecretBytes = SecureBytes
