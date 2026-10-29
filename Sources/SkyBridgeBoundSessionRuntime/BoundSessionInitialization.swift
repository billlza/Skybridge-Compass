import CBoundSession
import CryptoKit
import Foundation

/// The storage adapter must perform synchronous, strict, durable, add-only
/// operations in the actual platform's protected namespace. Neither this port
/// nor native digest equality authenticates a caller's policy/identity inputs.
public protocol BoundSessionInitializationStore: Sendable {
    func load(scope: Data, slot: BoundSessionInitializationSlot) throws -> Data?
    func insertIfAbsent(_ value: Data, scope: Data, slot: BoundSessionInitializationSlot) throws -> Bool
}

public enum BoundSessionInitializationSlot: UInt32, Sendable {
    case intent = 1
    case anchor = 2
    case activation = 3
}

public enum BoundSessionInitializationError: Error {
    case invalidInput(String)
    case capabilityUnavailable(actual: UInt64)
    case native(status: Int32, name: String)
    case storage(status: Int32, underlying: any Error)
    case nativeOutputContract(String)
}

/// Public context of the ORIGINAL enrollment. The trusted platform factory,
/// not this value type, proves verified policy/committed identity/peer origin.
/// No private key or wire-message codec enters this adapter.
public struct BoundSessionInitializationContext: Sendable {
    public let trustRootFingerprint: Data
    public let trustRootIdentifierSHA256: Data
    public let localIdentityFingerprint: Data
    public let peerIdentityFingerprint: Data
    public let trustedPolicyState: Data
    public let localRecipientDigest: Data
    public let peerRecipientDigest: Data
    public let providerIdentity: Data
    public let initializationID: Data

    public init(trustRootFingerprint: Data, trustRootIdentifierSHA256: Data,
                localIdentityFingerprint: Data, peerIdentityFingerprint: Data,
                trustedPolicyState: Data, localRecipientDigest: Data,
                peerRecipientDigest: Data, providerIdentity: Data, initializationID: Data) throws {
        for value in [trustRootFingerprint, trustRootIdentifierSHA256, localIdentityFingerprint,
                      peerIdentityFingerprint, localRecipientDigest, peerRecipientDigest,
                      providerIdentity, initializationID] {
            try validateDigest(value)
        }
        guard trustedPolicyState.count == 36,
              trustedPolicyState.prefix(4).contains(where: { $0 != 0 }),
              trustedPolicyState.suffix(32).contains(where: { $0 != 0 }) else {
            throw BoundSessionInitializationError.invalidInput("original verified Q state")
        }
        self.trustRootFingerprint = trustRootFingerprint
        self.trustRootIdentifierSHA256 = trustRootIdentifierSHA256
        self.localIdentityFingerprint = localIdentityFingerprint
        self.peerIdentityFingerprint = peerIdentityFingerprint
        self.trustedPolicyState = trustedPolicyState
        self.localRecipientDigest = localRecipientDigest
        self.peerRecipientDigest = peerRecipientDigest
        self.providerIdentity = providerIdentity
        self.initializationID = initializationID
    }

    /// Stable native-defined namespace; deliberately excludes policy/provider
    /// changes. This computation is checked against native begin's output.
    public var scope: Data {
        var hash = SHA256()
        hash.update(data: Data("bound-session/protected-initialization/scope/v1\0".utf8))
        for value in [trustRootFingerprint, trustRootIdentifierSHA256,
                      localIdentityFingerprint, peerIdentityFingerprint] {
            hash.update(data: value)
        }
        return Data(hash.finalize())
    }
}

public struct BoundSessionInitializationResources: Sendable {
    public let authorityDatabase: URL
    public let receiverRegistry: URL
    public let receiverDatabase: URL
    public let authorityIncarnation: Data
    public let receiverIncarnation: Data
    public let maxHeads: UInt32
    public let maxOperations: UInt32
    public let maxCommands: UInt32
    public let maxOutboxPayloadBytes: UInt32

    public init(authorityDatabase: URL, receiverRegistry: URL, receiverDatabase: URL,
                authorityIncarnation: Data, receiverIncarnation: Data,
                maxHeads: UInt32 = 1024, maxOperations: UInt32 = 16384,
                maxCommands: UInt32 = 66560, maxOutboxPayloadBytes: UInt32 = 531) throws {
        try validateDigest(authorityIncarnation)
        try validateDigest(receiverIncarnation)
        for url in [authorityDatabase, receiverRegistry, receiverDatabase] {
            guard url.isFileURL, url.path.hasPrefix("/"), !url.path.utf8.contains(0),
                  url.path.utf8.count <= 4096 else {
                throw BoundSessionInitializationError.invalidInput("original absolute resource path")
            }
        }
        for (value, bound) in zip([maxHeads, maxOperations, maxCommands, maxOutboxPayloadBytes],
                                  [1024, 16384, 66560, 531] as [UInt32]) {
            guard value > 0, value <= bound else {
                throw BoundSessionInitializationError.invalidInput("original authority capacity")
            }
        }
        self.authorityDatabase = authorityDatabase
        self.receiverRegistry = receiverRegistry
        self.receiverDatabase = receiverDatabase
        self.authorityIncarnation = authorityIncarnation
        self.receiverIncarnation = receiverIncarnation
        self.maxHeads = maxHeads
        self.maxOperations = maxOperations
        self.maxCommands = maxCommands
        self.maxOutboxPayloadBytes = maxOutboxPayloadBytes
    }
}

/// Copyable opaque C capability, not an automatically closing resource object.
/// The App owner must retain it after ANY advance/close error and explicitly
/// close/destroy it. No Swift registry, finalizer or fallback discards ownership.
public struct BoundSessionInitializationHandle: Sendable, Hashable {
    fileprivate let bytes: Data
}

public struct BoundSessionInitializationOpened: Sendable {
    public let handle: BoundSessionInitializationHandle
    public let scope: Data
    public let planBinding: Data
}

/// An initialization anchor, never a Ready, file grant or App activation receipt.
public struct BoundSessionInitializationAnchor: Sendable, Equatable {
    public let receiver: Data
    public let plan: Data
}

public struct BoundSessionInitializationOwnerState: Sendable, Equatable {
    public let openOwner: Bool
    public let unresolvedCreation: Bool
    public let failedClose: Bool
}

/// Sole Apple translation of the existing native v6 API. Calls are synchronous:
/// run them on an owned off-main executor, with no await or callback reentry.
/// Allocation, records, state transitions and recovery stay in the shared Rust.
public enum BoundSessionInitializationNative {
    public static let maximumRecordBytes = Int(BS_FFI_INITIALIZATION_RECORD_MAX_V6)
    public static let keychainService = "com.skybridge.compass.bound-session.initialization.v1"

    public static func keychainAccount(scope: Data, slot: BoundSessionInitializationSlot) throws -> String {
        try validateDigest(scope)
        return scope.map { String(format: "%02x", $0) }.joined() + "." + String(slot.rawValue)
    }

    public static func validateRecord(_ value: Data) throws {
        guard !value.isEmpty, value.count <= maximumRecordBytes else {
            throw BoundSessionInitializationError.invalidInput("empty or oversized protected record")
        }
    }

    /// Explicit first-enrollment authority is a caller premise. Store uncertainty
    /// may follow committed intent: keep THIS context/resources or restore scope.
    /// Native begin allocates no authority or receiver files.
    public static func begin(context: BoundSessionInitializationContext,
                             resources: BoundSessionInitializationResources,
                             store: any BoundSessionInitializationStore) throws -> BoundSessionInitializationOpened {
        try requireCapability()
        var config = BsFfiInitializationConfigV6()
        config.abi_version = 6
        config.struct_size = UInt32(MemoryLayout<BsFfiInitializationConfigV6>.size)
        config.resources.abi_version = 5
        config.resources.struct_size = UInt32(MemoryLayout<BsFfiFirstUseConfigV5>.size)
        config.resources.max_heads = resources.maxHeads
        config.resources.max_operations = resources.maxOperations
        config.resources.max_commands = resources.maxCommands
        config.resources.max_outbox_payload_bytes = resources.maxOutboxPayloadBytes
        try fixedCopy(resources.authorityIncarnation, to: &config.resources.authority_incarnation)
        try fixedCopy(resources.receiverIncarnation, to: &config.resources.receiver_incarnation)
        try fixedCopy(context.trustRootFingerprint, to: &config.trust_root_fingerprint)
        try fixedCopy(context.trustRootIdentifierSHA256, to: &config.trust_root_identifier_sha256)
        try fixedCopy(context.localIdentityFingerprint, to: &config.local_identity_fingerprint)
        try fixedCopy(context.peerIdentityFingerprint, to: &config.peer_identity_fingerprint)
        try fixedCopy(context.trustedPolicyState, to: &config.trusted_policy_state)
        try fixedCopy(context.localRecipientDigest, to: &config.local_recipient_digest)
        try fixedCopy(context.peerRecipientDigest, to: &config.peer_recipient_digest)
        try fixedCopy(context.providerIdentity, to: &config.provider_identity)
        try fixedCopy(context.initializationID, to: &config.initialization_id)
        let paths = [resources.authorityDatabase, resources.receiverRegistry, resources.receiverDatabase]
            .map { Data($0.path.utf8) }
        var output = BsFfiInitializationOpenV6()
        try withStore(store) { port in
            try paths[0].withUnsafeBytes { authority in
                try paths[1].withUnsafeBytes { registry in
                    try paths[2].withUnsafeBytes { receiver in
                        config.resources.authority_database = try nativeBytes(authority)
                        config.resources.receiver_registry = try nativeBytes(registry)
                        config.resources.receiver_database = try nativeBytes(receiver)
                        return bs_ffi_initialization_begin_v6(&config, &port, &output)
                    }
                }
            }
        }
        return try opened(&output, expectedScope: context.scope)
    }

    /// Existing-only restoration: native reads the entire original tuple from
    /// protected state; this API accepts no replacement paths or incarnations.
    public static func restore(scope: Data, store: any BoundSessionInitializationStore) throws -> BoundSessionInitializationOpened {
        try requireCapability()
        try validateDigest(scope)
        var output = BsFfiInitializationOpenV6()
        try withStore(store) { port in
            try scope.withUnsafeBytes { bytes in
                bs_ffi_initialization_restore_v6(try nativeBytes(bytes), &port, &output)
            }
        }
        return try opened(&output, expectedScope: scope)
    }

    public static func advance(_ handle: BoundSessionInitializationHandle,
                               store: any BoundSessionInitializationStore) throws -> BoundSessionInitializationAnchor {
        var output = BsFfiFirstUseAnchorV5()
        let native = try nativeHandle(handle)
        try withStore(store) { port in bs_ffi_initialization_advance_v6(native, &port, &output) }
        guard output.abi_version == 5, output.struct_size == UInt32(MemoryLayout<BsFfiFirstUseAnchorV5>.size),
              fixedData(&output.reserved).allSatisfy({ $0 == 0 }) else {
            throw BoundSessionInitializationError.nativeOutputContract("original anchor layout")
        }
        let receiver = fixedData(&output.receiver_anchor), plan = fixedData(&output.plan_anchor)
        try validateDigest(receiver)
        try validateDigest(plan)
        return BoundSessionInitializationAnchor(receiver: receiver, plan: plan)
    }

    public static func originalPlan(_ handle: BoundSessionInitializationHandle) throws -> Data {
        let native = try nativeHandle(handle)
        var bytes = Data(count: maximumRecordBytes)
        var length: UInt = 0
        let status = bytes.withUnsafeMutableBytes { buffer in
            bs_ffi_initialization_plan_v6(native, buffer.bindMemory(to: UInt8.self).baseAddress,
                                          UInt(buffer.count), &length)
        }
        try check(status)
        guard length > 0, length <= UInt(bytes.count) else {
            throw BoundSessionInitializationError.nativeOutputContract("original plan bound")
        }
        // Opaque bytes: do not implement a second plan/record decoder in Swift.
        return Data(bytes.prefix(Int(length)))
    }

    public static func state(_ handle: BoundSessionInitializationHandle) throws -> BoundSessionInitializationOwnerState {
        var output = BsFfiInitializationStateV6()
        try check(bs_ffi_initialization_state_v6(try nativeHandle(handle), &output))
        guard output.abi_version == 6, output.struct_size == UInt32(MemoryLayout<BsFfiInitializationStateV6>.size),
              output.open_owner <= 1, output.unresolved_creation <= 1, output.failed_close <= 1,
              output.reserved == 0 else {
            throw BoundSessionInitializationError.nativeOutputContract("owner state")
        }
        return BoundSessionInitializationOwnerState(openOwner: output.open_owner == 1,
            unresolvedCreation: output.unresolved_creation == 1, failedClose: output.failed_close == 1)
    }

    public static func close(_ handle: BoundSessionInitializationHandle) throws {
        try check(bs_ffi_initialization_close_v6(try nativeHandle(handle)))
    }

    /// Clear the caller's handle only after native retirement acknowledges it.
    /// Failure preserves the exact original handle for cleanup/reconciliation.
    public static func destroy(_ handle: inout BoundSessionInitializationHandle?) throws {
        guard let original = handle else {
            throw BoundSessionInitializationError.invalidInput("absent initialization handle")
        }
        try check(bs_ffi_initialization_destroy_v6(try nativeHandle(original)))
        handle = nil
    }

    private static func opened(_ output: inout BsFfiInitializationOpenV6, expectedScope: Data) throws -> BoundSessionInitializationOpened {
        guard output.abi_version == 6, output.struct_size == UInt32(MemoryLayout<BsFfiInitializationOpenV6>.size),
              fixedData(&output.scope) == expectedScope else {
            throw BoundSessionInitializationError.nativeOutputContract("original scope/open layout")
        }
        let bytes = fixedData(&output.handle.opaque), binding = fixedData(&output.plan_binding)
        guard bytes.count == 24, bytes.contains(where: { $0 != 0 }) else {
            throw BoundSessionInitializationError.nativeOutputContract("empty native handle")
        }
        try validateDigest(binding)
        return BoundSessionInitializationOpened(handle: BoundSessionInitializationHandle(bytes: bytes),
            scope: expectedScope, planBinding: binding)
    }

    private static func requireCapability() throws {
        let actual = bs_ffi_capabilities_v6()
        guard actual == UInt64(BS_FFI_CAPABILITY_PROTECTED_INITIALIZATION_V6) else {
            throw BoundSessionInitializationError.capabilityUnavailable(actual: actual)
        }
    }
}

private func validateDigest(_ value: Data) throws {
    guard value.count == 32, value.contains(where: { $0 != 0 }) else {
        throw BoundSessionInitializationError.invalidInput("nonzero 32-byte binding required")
    }
}
private func fixedCopy<T>(_ data: Data, to value: inout T) throws {
    guard data.count == MemoryLayout<T>.size else {
        throw BoundSessionInitializationError.invalidInput("fixed native field size")
    }
    withUnsafeMutableBytes(of: &value) { $0.copyBytes(from: data) }
}
private func fixedData<T>(_ value: inout T) -> Data { withUnsafeBytes(of: &value) { Data($0) } }
private func nativeBytes(_ value: UnsafeRawBufferPointer) throws -> BsFfiBytesV1 {
    guard let address = value.bindMemory(to: UInt8.self).baseAddress, !value.isEmpty else {
        throw BoundSessionInitializationError.invalidInput("empty borrowed bytes")
    }
    return BsFfiBytesV1(pointer: address, length: UInt(value.count))
}
private func nativeHandle(_ handle: BoundSessionInitializationHandle) throws -> BsFfiInitializationHandleV6 {
    var native = BsFfiInitializationHandleV6()
    try fixedCopy(handle.bytes, to: &native.opaque)
    return native
}
private func check(_ status: Int32) throws {
    guard status == BS_FFI_OK_V1 else {
        throw BoundSessionInitializationError.native(status: status, name: String(cString: bs_ffi_status_name_v1(status)))
    }
}

// Per-call only: the native implementation cannot retain this pointer and the
// synchronous C callbacks cannot await. No Sendable assertion or global storage.
private final class StoreCall {
    let store: any BoundSessionInitializationStore
    var failure: (any Error)?
    init(_ store: any BoundSessionInitializationStore) { self.store = store }
}
private func withStore(_ store: any BoundSessionInitializationStore,
                       operation: (inout BsFfiInitializationStoreV6) throws -> Int32) throws {
    let call = StoreCall(store)
    var native = BsFfiInitializationStoreV6()
    native.abi_version = 6
    native.struct_size = UInt32(MemoryLayout<BsFfiInitializationStoreV6>.size)
    native.context = Unmanaged.passUnretained(call).toOpaque()
    native.load = loadRecord
    native.insert_if_absent = insertRecord
    let status = try withExtendedLifetime(call) { try operation(&native) }
    if let failure = call.failure {
        // Preserve the concrete OS/storage error even when the native status is
        // an uncertain-publication failure; never relabel it as missing state.
        throw BoundSessionInitializationError.storage(status: status, underlying: failure)
    }
    try check(status)
}
private func loadRecord(_ context: UnsafeMutableRawPointer?, _ scope: UnsafePointer<UInt8>?,
                        _ slot: UInt32, _ output: UnsafeMutablePointer<UInt8>?,
                        _ capacity: UInt, _ length: UnsafeMutablePointer<UInt>?) -> Int32 {
    guard let context, let scope, let output, let length,
          let slot = BoundSessionInitializationSlot(rawValue: slot),
          capacity == UInt(BoundSessionInitializationNative.maximumRecordBytes) else { return -7002 }
    length.pointee = 0
    let call = Unmanaged<StoreCall>.fromOpaque(context).takeUnretainedValue()
    do {
        let key = Data(bytes: scope, count: 32)
        try validateDigest(key)
        guard let bytes = try call.store.load(scope: key, slot: slot) else { return 1 }
        try BoundSessionInitializationNative.validateRecord(bytes)
        bytes.copyBytes(to: output, count: bytes.count)
        length.pointee = UInt(bytes.count)
        return 0
    } catch {
        call.failure = error
        return -7001
    }
}
private func insertRecord(_ context: UnsafeMutableRawPointer?, _ scope: UnsafePointer<UInt8>?,
                          _ slot: UInt32, _ bytes: UnsafePointer<UInt8>?, _ length: UInt) -> Int32 {
    guard let context, let scope, let bytes, let slot = BoundSessionInitializationSlot(rawValue: slot),
          length > 0, length <= UInt(BoundSessionInitializationNative.maximumRecordBytes) else { return -7002 }
    let call = Unmanaged<StoreCall>.fromOpaque(context).takeUnretainedValue()
    do {
        let key = Data(bytes: scope, count: 32)
        try validateDigest(key)
        let value = Data(bytes: bytes, count: Int(length))
        return try call.store.insertIfAbsent(value, scope: key, slot: slot) ? 0 : 1
    } catch {
        call.failure = error
        return -7001
    }
}
