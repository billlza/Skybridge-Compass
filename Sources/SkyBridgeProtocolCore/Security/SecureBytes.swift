import Foundation

/// Allocation failures that callers can handle without terminating the process.
public enum SecureBytesError: Error, LocalizedError, Sendable, Equatable {
    case invalidCount(Int)
    case countExceedsLimit(actual: Int, maximum: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidCount(let count):
            return "Secure byte count must not be negative: \(count)"
        case .countExceedsLimit(let actual, let maximum):
            return "Secure byte count exceeds the allocation limit: \(actual) > \(maximum)"
        }
    }
}

/// Manually allocated sensitive bytes whose storage is wiped before release.
///
/// This type lives in `SkyBridgeProtocolCore` so the macOS core and iOS app use
/// one implementation and one allocation/error contract.
public final class SecureBytes: @unchecked Sendable {
    /// Key material and KEM shared secrets are small. A hard upper bound prevents
    /// an untrusted native length or protocol field from becoming an unbounded
    /// allocation before the provider validates its algorithm contract.
    public static let maximumAllocationSize = 16 * 1_024 * 1_024

    private let pointer: UnsafeMutableRawPointer
    private let count: Int
    private let accessLock = NSRecursiveLock()

    public typealias WipingFunction = @Sendable (UnsafeMutableRawPointer, Int) -> Void

#if DEBUG || SKYBRIDGE_TESTING
    private final class WipingFunctionStorage: @unchecked Sendable {
        private let lock = NSLock()
        private var function: WipingFunction

        init(function: @escaping WipingFunction) {
            self.function = function
        }

        func load() -> WipingFunction {
            lock.lock()
            defer { lock.unlock() }
            return function
        }

        func store(_ function: @escaping WipingFunction) {
            lock.lock()
            self.function = function
            lock.unlock()
        }
    }

    private static let wipingFunctionStorage = WipingFunctionStorage { pointer, count in
        secureZero(pointer, count)
    }

    /// Test-only zeroization probe. Access is synchronized so parallel tests do
    /// not race while replacing the probe.
    public static var wipingFunction: WipingFunction {
        get { wipingFunctionStorage.load() }
        set { wipingFunctionStorage.store(newValue) }
    }
#else
    /// Release builds expose no mutable hook for replacing secure zeroization.
    internal static let wipingFunction: WipingFunction = { pointer, count in
        secureZero(pointer, count)
    }
#endif

    /// Creates zero-initialized sensitive storage.
    public init(count: Int) throws {
        guard count >= 0 else {
            throw SecureBytesError.invalidCount(count)
        }
        guard count <= Self.maximumAllocationSize else {
            throw SecureBytesError.countExceedsLimit(
                actual: count,
                maximum: Self.maximumAllocationSize
            )
        }
        self.count = count
        let allocationSize = max(count, 1)
        pointer = UnsafeMutableRawPointer.allocate(
            byteCount: allocationSize,
            alignment: MemoryLayout<UInt8>.alignment
        )
        if count > 0 {
            pointer.initializeMemory(as: UInt8.self, repeating: 0, count: count)
        }
    }

    /// Copies existing sensitive data into independently owned storage.
    public init(data: Data) {
        count = data.count
        let allocationSize = max(data.count, 1)
        pointer = UnsafeMutableRawPointer.allocate(
            byteCount: allocationSize,
            alignment: MemoryLayout<UInt8>.alignment
        )
        if !data.isEmpty {
            data.withUnsafeBytes { source in
                guard let baseAddress = source.baseAddress else { return }
                pointer.copyMemory(from: baseAddress, byteCount: data.count)
            }
        }
    }

    /// Copies existing sensitive bytes into independently owned storage.
    public init(bytes: [UInt8]) {
        count = bytes.count
        let allocationSize = max(bytes.count, 1)
        pointer = UnsafeMutableRawPointer.allocate(
            byteCount: allocationSize,
            alignment: MemoryLayout<UInt8>.alignment
        )
        if !bytes.isEmpty {
            bytes.withUnsafeBytes { source in
                guard let baseAddress = source.baseAddress else { return }
                pointer.copyMemory(from: baseAddress, byteCount: bytes.count)
            }
        }
    }

    deinit {
        if count > 0 {
            Self.wipe(pointer, count: count)
        }
        pointer.deallocate()
    }

    public var byteCount: Int { count }
    public var isEmpty: Bool { count == 0 }

    /// Returns a `Data` value with storage independent of this instance.
    public var data: Data { copyData() }

    /// Returns a `Data` value with storage independent of this instance.
    public func copyData() -> Data {
        accessLock.lock()
        defer { accessLock.unlock() }
        guard count > 0 else { return Data() }
        return Data(bytes: pointer, count: count)
    }

    /// Compatibility spelling retained for the iOS callers during the shared
    /// type migration. It returns an owned copy, never the backing allocation.
    public func unsafeRawBytes() -> Data { copyData() }

    /// Compatibility spelling retained for the iOS callers during the shared
    /// type migration. It returns an owned copy, never the backing allocation.
    public var bytes: Data { copyData() }

    public func withUnsafeBytes<R>(
        _ body: (UnsafeRawBufferPointer) throws -> R
    ) rethrows -> R {
        accessLock.lock()
        defer { accessLock.unlock() }
        return try body(UnsafeRawBufferPointer(start: pointer, count: count))
    }

    public func withUnsafeMutableBytes<R>(
        _ body: (UnsafeMutableRawBufferPointer) throws -> R
    ) rethrows -> R {
        accessLock.lock()
        defer { accessLock.unlock() }
        return try body(UnsafeMutableRawBufferPointer(start: pointer, count: count))
    }

    public func zeroize() {
        accessLock.lock()
        defer { accessLock.unlock() }
        if count > 0 {
            Self.wipe(pointer, count: count)
        }
    }

    private static func wipe(_ pointer: UnsafeMutableRawPointer, count: Int) {
        wipingFunction(pointer, count)
    }
}

extension SecureBytes: ContiguousBytes {}

#if canImport(Darwin)
import Darwin

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

/// Resolves secure-zero symbols once and retains the process-image handle for
/// the process lifetime rather than acquiring a handle for every wipe.
private final class SecureZeroSymbols: @unchecked Sendable {
    static let shared = SecureZeroSymbols()

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

private func secureZero(_ pointer: UnsafeMutableRawPointer, _ count: Int) {
    let symbols = SecureZeroSymbols.shared
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
    withExtendedLifetime(pointer) { _ in }
}
#else
private func secureZero(_ pointer: UnsafeMutableRawPointer, _ count: Int) {
    let bytes = pointer.assumingMemoryBound(to: UInt8.self)
    for index in 0..<count {
        bytes[index] = 0
    }
    withExtendedLifetime(pointer) { _ in }
}
#endif

#if DEBUG || SKYBRIDGE_TESTING
/// Test-only observer for verifying that deinitialization reaches the secure
/// wipe boundary. The tracker never replaces the release implementation.
public final class SecureBytesWipeTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedWipeCount = 0
    private var recordedLastWipedSize = 0

    public init() {}

    public var wipeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedWipeCount
    }

    public var lastWipedSize: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedLastWipedSize
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        recordedWipeCount = 0
        recordedLastWipedSize = 0
    }

    public func makeWipingFunction() -> SecureBytes.WipingFunction {
        { [weak self] pointer, count in
            secureZero(pointer, count)
            guard let self else { return }
            lock.lock()
            defer { lock.unlock() }
            recordedWipeCount += 1
            recordedLastWipedSize = count
        }
    }
}
#endif
