import Darwin
import Foundation

/// Target-owned secret storage boundary used by the Q-Periapt native runtime.
///
/// Platform integration layers may bridge their own secure containers at this
/// boundary without making the shared runtime depend on an application module.
public protocol QPeriaptSecretBuffer: AnyObject, Sendable {
    init(count: Int)

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

/// Manually allocated, zeroizing secret storage for Q-Periapt native results.
///
/// The allocation is never copy-on-write. Access and explicit zeroization are
/// serialized so a platform bridge cannot race a native operation.
public final class QPeriaptSecretBytes: QPeriaptSecretBuffer, @unchecked Sendable {
    private let pointer: UnsafeMutableRawPointer
    private let count: Int
    private let accessLock = NSRecursiveLock()

    public init(count: Int) {
        precondition(count >= 0, "QPeriaptSecretBytes count must not be negative")
        self.count = count
        pointer = UnsafeMutableRawPointer.allocate(
            byteCount: max(count, 1),
            alignment: MemoryLayout<UInt8>.alignment
        )
        if count > 0 {
            pointer.initializeMemory(as: UInt8.self, repeating: 0, count: count)
        }
    }

    public init(data: Data) {
        count = data.count
        pointer = UnsafeMutableRawPointer.allocate(
            byteCount: max(data.count, 1),
            alignment: MemoryLayout<UInt8>.alignment
        )
        if !data.isEmpty {
            data.withUnsafeBytes { source in
                guard let sourceAddress = source.baseAddress else { return }
                pointer.copyMemory(from: sourceAddress, byteCount: source.count)
            }
        }
    }

    deinit {
        accessLock.lock()
        if count > 0 {
            secureZero(pointer, count: count)
        }
        accessLock.unlock()
        pointer.deallocate()
    }

    public var byteCount: Int {
        count
    }

    public func copyData() -> Data {
        accessLock.lock()
        defer { accessLock.unlock() }
        guard count > 0 else { return Data() }
        return Data(bytes: pointer, count: count)
    }

    public func withUnsafeBytes<Result>(
        _ body: (UnsafeRawBufferPointer) throws -> Result
    ) rethrows -> Result {
        accessLock.lock()
        defer { accessLock.unlock() }
        return try body(UnsafeRawBufferPointer(start: pointer, count: count))
    }

    public func withUnsafeMutableBytes<Result>(
        _ body: (UnsafeMutableRawBufferPointer) throws -> Result
    ) rethrows -> Result {
        accessLock.lock()
        defer { accessLock.unlock() }
        return try body(UnsafeMutableRawBufferPointer(start: pointer, count: count))
    }

    public func zeroize() {
        accessLock.lock()
        defer { accessLock.unlock() }
        if count > 0 {
            secureZero(pointer, count: count)
        }
    }
}

private typealias ExplicitBzeroFunction = @convention(c) (
    UnsafeMutableRawPointer?,
    Int
) -> Void

private typealias MemsetSFunction = @convention(c) (
    UnsafeMutableRawPointer?,
    Int,
    Int32,
    Int
) -> Int32

private final class QPeriaptSecureZeroSymbols: @unchecked Sendable {
    static let shared = QPeriaptSecureZeroSymbols()

    let explicitBzero: ExplicitBzeroFunction?
    let memsetS: MemsetSFunction?
    private let processHandle: UnsafeMutableRawPointer?

    private init() {
        let handle = dlopen(nil, RTLD_NOW)
        processHandle = handle
        if let handle {
            explicitBzero = dlsym(handle, "explicit_bzero").map {
                unsafeBitCast($0, to: ExplicitBzeroFunction.self)
            }
            memsetS = dlsym(handle, "memset_s").map {
                unsafeBitCast($0, to: MemsetSFunction.self)
            }
        } else {
            explicitBzero = nil
            memsetS = nil
        }
    }
}

private func secureZero(_ pointer: UnsafeMutableRawPointer, count: Int) {
    let symbols = QPeriaptSecureZeroSymbols.shared
    if let explicitBzero = symbols.explicitBzero {
        explicitBzero(pointer, count)
        return
    }
    if let memsetS = symbols.memsetS {
        _ = memsetS(pointer, count, 0, count)
        return
    }

    let bytes = pointer.assumingMemoryBound(to: UInt8.self)
    for index in 0..<count {
        bytes[index] = 0
    }
    withExtendedLifetime(pointer) {}
}
