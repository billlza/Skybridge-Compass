#if os(macOS)
import Foundation
import SkyBridgeProtocolCore
import os

/// A physical AOA generation and its bounded logical streams. Stream ACKs/pings are transport
/// facts only. Product identity, same-account grants and operation authority remain mandatory.
public final class USBHostMultiplexConnection: Sendable {
    public struct Configuration: Sendable {
        public let limits: USBLogicalStreamProtocol.Limits
        public let frameRead, nativeWrite, pingInterval, pingReply, pendingAccept, halfClose: Duration
        public init(limits: USBLogicalStreamProtocol.Limits = .init(), frameRead: Duration = .seconds(35),
                    nativeWrite: Duration = .seconds(5), pingInterval: Duration = .seconds(15),
                    pingReply: Duration = .seconds(10), pendingAccept: Duration = .seconds(15),
                    halfClose: Duration = .seconds(30)) {
            self.limits = limits; self.frameRead = frameRead; self.nativeWrite = nativeWrite
            self.pingInterval = pingInterval; self.pingReply = pingReply
            self.pendingAccept = pendingAccept; self.halfClose = halfClose
        }
        fileprivate func validate() throws {
            guard [frameRead, nativeWrite, pingInterval, pingReply, pendingAccept, halfClose]
                .allSatisfy({ $0 > .zero && $0 <= .seconds(60) }), frameRead >= pingInterval + pingReply else {
                throw USBHostMultiplexError.invalidConfiguration
            }
        }
    }
    public struct ShutdownState: Sendable {
        public let retired, nativeWorkersExited, referencesReleased, pumpsJoined, logicalOwnersReleased: Bool
        public let cleanupFailure: (any Error)?
    }
    private let core: USBHostMultiplexCore
    private let tasks = USBMultiplexTasks()

    public convenience init(deviceRegistryID: UInt64, role: USBLogicalStreamProtocol.Role = .client,
                            configuration: Configuration = Configuration(),
                            requireAttachmentCurrent: @escaping @Sendable () throws -> Void) throws {
        try configuration.validate()
        let wire = try USBLogicalStreamProtocol(role: role, limits: configuration.limits)
        let carrier = try USBHostByteTransport(deviceRegistryID: deviceRegistryID, requireAttachmentCurrent: requireAttachmentCurrent)
        self.init(carrier: carrier, wire: wire, configuration: configuration)
    }
    /// Isolated tests replace OS acquisition beneath the real native-byte owner, never the pumps.
    convenience init(carrier: USBHostByteTransport, role: USBLogicalStreamProtocol.Role,
                     configuration: Configuration = Configuration()) throws {
        try configuration.validate()
        self.init(carrier: carrier, wire: try USBLogicalStreamProtocol(role: role, limits: configuration.limits), configuration: configuration)
    }
    private init(carrier: USBHostByteTransport, wire: USBLogicalStreamProtocol, configuration: Configuration) {
        core = USBHostMultiplexCore(carrier: carrier, wire: wire, configuration: configuration)
    }
    deinit { core.retire(USBHostMultiplexError.closed) }
    public var terminalFailure: (any Error)? { core.failure }
    public var protocolSnapshot: USBLogicalStreamProtocol.Snapshot { core.snapshot }
    public var shutdownState: ShutdownState {
        let native = core.carrier.shutdownState
        return ShutdownState(retired: core.failure != nil, nativeWorkersExited: native.workersExited,
            referencesReleased: native.referencesReleased, pumpsJoined: tasks.joined,
            logicalOwnersReleased: core.cleanupConfirmed, cleanupFailure: native.cleanupFailure)
    }
    public func start(timeout: Duration = .seconds(5)) async throws {
        defer { withExtendedLifetime(self) {} }
        guard timeout > .zero && timeout <= .seconds(60) else { throw USBHostMultiplexError.invalidTimeout }
        try core.beginStart()
        defer { core.endStart() }
        try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                _ = try await core.carrier.open(timeout: timeout)
                try core.publishStart {
                    let core = core
                    tasks.start([{ await core.readLoop() }, { await core.writeLoop() }, { await core.deadlineLoop() }])
                }
            } catch { core.retire(error); throw core.failure ?? error }
        } onCancel: { [core] in core.retire(CancellationError()) }
    }
    public func openStream(timeout: Duration = .seconds(5), priority: USBLogicalStreamProtocol.Priority = .control) async throws -> Stream {
        defer { withExtendedLifetime(self) {} }
        return try await core.openStream(timeout: timeout, priority: priority)
    }
    public func acceptStream(timeout: Duration = .seconds(5), priority: USBLogicalStreamProtocol.Priority = .control) async throws -> Stream {
        defer { withExtendedLifetime(self) {} }
        return try await core.acceptStream(timeout: timeout, priority: priority)
    }
    public func close() { core.retire(USBHostMultiplexError.closed) }
    /// Single cleanup observer at a time. All native/pump and logical-operation owners must
    /// finish; a timed-out observer leaves the retired owner available for an explicit retry.
    public func closeAndAwait(timeout: Duration = .seconds(2)) async throws {
        defer { withExtendedLifetime(self) {} }
        guard timeout <= .seconds(60) else { throw USBHostMultiplexError.invalidTimeout }
        let budget = try USBMultiplexBudget(timeout)
        try core.beginCleanup()
        defer { core.endCleanup() }
        close()
        let core = core, tasks = tasks
        let observer = Task.detached {
            var nativeFailure: (any Error)?
            do { try await core.carrier.closeAndAwait(timeout: budget.remaining()) }
            catch {
                let native = core.carrier.shutdownState
                guard native.workersExited && native.referencesReleased else { throw USBHostMultiplexError.cleanupUnconfirmed }
                nativeFailure = error
            }
            try await core.awaitStartReturn(budget)
            try await tasks.join(budget: budget)
            try await core.releaseAfterExit(budget)
            if let nativeFailure { throw nativeFailure }
        }
        try await observer.value
    }

    public final class Stream: Sendable {
        public enum Read: Sendable { case bytes(Data), end }
        public let id: UInt32
        fileprivate let token: UUID
        fileprivate let core: USBHostMultiplexCore
        fileprivate init(id: UInt32, token: UUID, core: USBHostMultiplexCore) { self.id = id; self.token = token; self.core = core }
        deinit { core.abandon(id: id, token: token) }
        public var isClosed: Bool { core.isClosed(id: id, token: token) }
        public func readBytes(maximumBytes: Int, timeout: Duration) async throws -> Read {
            defer { withExtendedLifetime(self) {} }
            guard (1...USBLogicalStreamWire.initialWindow).contains(maximumBytes) else { throw USBHostMultiplexError.invalidByteCount }
            return try await core.operate(id: id, token: token, writing: false, timeout: timeout) { lease in
                try await core.read(id: id, token: token, maximum: maximumBytes, lease: lease)
            }
        }
        /// One lease covers prefix and body; concurrent reads cannot interleave frame parsing.
        public func readFrame(maximumBytes: Int = P2PControlFramePolicy.maximumBodyByteCount, timeout: Duration) async throws -> Data {
            defer { withExtendedLifetime(self) {} }
            guard (1...P2PControlFramePolicy.maximumBodyByteCount).contains(maximumBytes) else { throw USBHostMultiplexError.invalidByteCount }
            return try await core.operate(id: id, token: token, writing: false, timeout: timeout) { lease in
                let header = try await core.readExactly(id: id, token: token, count: 4, lease: lease)
                let raw = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                let count = try P2PControlFramePolicy.inboundBodyByteCount(from: raw)
                guard count <= maximumBytes else { throw USBHostMultiplexError.invalidByteCount }
                return try await core.readExactly(id: id, token: token, count: count, lease: lease)
            }
        }
        /// Bounded chunk API for authenticated file/control consumers. A whole file must not
        /// be accumulated here; callers use successive chunks with their captured authority.
        public func writeBytes(_ bytes: Data, timeout: Duration,
                               requireEffectAuthorization: @escaping @Sendable () throws -> Void) async throws {
            defer { withExtendedLifetime(self) {} }
            guard (1...(P2PControlFramePolicy.maximumBodyByteCount + 4)).contains(bytes.count) else { throw USBHostMultiplexError.invalidByteCount }
            try await core.operate(id: id, token: token, writing: true, timeout: timeout, effect: requireEffectAuthorization) { lease in
                try await core.write(id: id, token: token, bytes: Data(bytes), lease: lease)
            }
        }
        public func writeFrame(_ body: Data, timeout: Duration,
                               requireEffectAuthorization: @escaping @Sendable () throws -> Void) async throws {
            try await writeBytes(P2PControlFramePolicy.frame(body: body), timeout: timeout, requireEffectAuthorization: requireEffectAuthorization)
        }
        public func finishSending(timeout: Duration = .seconds(5)) async throws {
            defer { withExtendedLifetime(self) {} }
            try await core.operate(id: id, token: token, writing: true, timeout: timeout) { lease in
                try core.requestFIN(id: id, token: token)
                while try !core.finSent(id: id, token: token) { try await lease.wait() }
            }
        }
        public func close() { core.abort(id: id, token: token, cause: USBLogicalStreamError.cancelled) }
        public func closeAndAwait(timeout: Duration = .seconds(2)) async throws {
            defer { withExtendedLifetime(self) {} }
            let budget = try USBMultiplexBudget(timeout)
            try core.beginStreamCleanup(id: id, token: token)
            defer { core.endStreamCleanup(id: id, token: token) }
            close()
            let core = core, id = id, token = token
            let observer = Task.detached { try await core.awaitStreamRelease(id: id, token: token, budget: budget) }
            try await observer.value
        }
    }
}

private final class USBHostMultiplexCore: Sendable {
    typealias Wire = USBLogicalStreamWire
    typealias Stream = USBHostMultiplexConnection.Stream
    private struct Handle: Sendable {
        let token: UUID
        var published = false
        var opening: USBMultiplexLease?, read: USBMultiplexLease?, write: USBMultiplexLease?
        var failure: (any Error)?
        var halfClosedAt: ContinuousClock.Instant?
        var cleanupObserver = false
        let cleanupWake = USBMultiplexWake()
        var idle: Bool { opening == nil && read == nil && write == nil }
    }
    private struct State: Sendable {
        var started = false, starting = false, ready = false, cleanupObserver = false, cleanupConfirmed = false
        var terminal: (any Error)?
        var handles: [UInt32: Handle] = [:]
        var released: Set<UInt32> = []
        var releasedWakes: [USBMultiplexWake] = []
        var pendingSince: [UInt32: ContinuousClock.Instant] = [:]
        var accepting: USBMultiplexLease?
        var lastPongAt = ContinuousClock.now
        var nextPing: UInt64 = 1, pingID: UInt32?
        var pingSentAt: ContinuousClock.Instant?
    }
    let carrier: USBHostByteTransport
    private let wire: USBLogicalStreamProtocol
    private let configuration: USBHostMultiplexConnection.Configuration
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let writerWake = USBMultiplexWake(), timerWake = USBMultiplexWake(), cleanupWake = USBMultiplexWake()
    init(carrier: USBHostByteTransport, wire: USBLogicalStreamProtocol, configuration: USBHostMultiplexConnection.Configuration) {
        self.carrier = carrier; self.wire = wire; self.configuration = configuration
    }
    var failure: (any Error)? { state.withLock { $0.terminal } }
    var snapshot: USBLogicalStreamProtocol.Snapshot { wire.snapshot }
    var cleanupConfirmed: Bool { state.withLock { $0.cleanupConfirmed } }
    private func requireReady(_ value: State) throws {
        if let failure = value.terminal { throw failure }
        guard value.ready else { throw USBHostMultiplexError.notStarted }
    }
    private func handle(_ id: UInt32, _ token: UUID, _ value: State) throws -> Handle {
        guard let handle = value.handles[id], handle.token == token else { throw USBHostMultiplexError.ownerRetired }
        return handle
    }
    private func ensure(_ id: UInt32, _ token: UUID, _ value: State) throws {
        let owner = try handle(id, token, value)
        if let failure = owner.failure { throw failure }
        if let failure = try wire.streamFailure(id) { throw failure }
        try requireReady(value)
    }
    /// Notifications are emitted after protocol/state locks have been released.
    private func notify(timer: Bool = false) {
        let wakes = state.withLock { value -> [USBMultiplexWake] in
            let removed = value.releasedWakes; value.releasedWakes.removeAll(keepingCapacity: true)
            return value.handles.values.flatMap { [$0.opening?.wake, $0.read?.wake, $0.write?.wake, $0.cleanupWake].compactMap { $0 } }
                + [value.accepting?.wake].compactMap { $0 } + removed
        }
        for wake in wakes { wake.signal() }
        writerWake.signal(); cleanupWake.signal()
        if timer { timerWake.signal() }
    }
    func beginStart() throws {
        try state.withLock { value in
            if let failure = value.terminal { throw failure }
            guard !value.started else { throw USBHostMultiplexError.alreadyStarted }
            value.started = true; value.starting = true
        }
    }
    func publishStart(_ publish: @Sendable () -> Void) throws {
        try state.withLock { value in
            if let failure = value.terminal { throw failure }
            value.ready = true; value.lastPongAt = .now
            publish() // Internal task publication only; no I/O or caller-supplied callback.
        }
        notify(timer: true)
    }
    func endStart() { state.withLock { $0.starting = false }; cleanupWake.signal() }
    func openStream(timeout: Duration, priority: USBLogicalStreamProtocol.Priority) async throws -> Stream {
        try Task.checkCancellation()
        let lease = USBMultiplexLease(budget: try USBMultiplexBudget(timeout)), token = UUID()
        let id = try state.withLock { value in
            try requireReady(value)
            let id = try wire.openStream(priority: priority)
            value.handles[id] = Handle(token: token, opening: lease); return id
        }
        notify()
        defer { finishOperation(id: id, token: token, opening: true, writing: false, lease: lease) }
        return try await withTaskCancellationHandler {
            do {
                while true {
                    let ready = try state.withLock { value in
                        try ensure(id, token, value); try lease.check(); try Task.checkCancellation()
                        if try wire.snapshot(streamID: id).acknowledged { value.handles[id]?.published = true; return true }
                        return false
                    }
                    if ready { return Stream(id: id, token: token, core: self) }
                    try await lease.wait()
                }
            } catch { abort(id: id, token: token, cause: error); throw streamFailure(id: id, token: token, fallback: error) }
        } onCancel: { self.abort(id: id, token: token, cause: CancellationError()) }
    }
    func acceptStream(timeout: Duration, priority: USBLogicalStreamProtocol.Priority) async throws -> Stream {
        try Task.checkCancellation()
        let lease = USBMultiplexLease(budget: try USBMultiplexBudget(timeout))
        try state.withLock { value in
            try requireReady(value)
            guard value.accepting == nil else { throw USBHostMultiplexError.acceptInProgress }
            value.accepting = lease
        }
        defer { lease.retire(); state.withLock { $0.accepting = nil }; notify(timer: true) }
        return try await withTaskCancellationHandler {
            while true {
                let accepted = try state.withLock { value -> Stream? in
                    try requireReady(value); try lease.check(); try Task.checkCancellation()
                    guard let id = try wire.acceptStream(priority: priority) else { return nil }
                    let token = UUID(); value.handles[id] = Handle(token: token, published: true)
                    value.pendingSince.removeValue(forKey: id)
                    return Stream(id: id, token: token, core: self)
                }
                if let accepted { notify(timer: true); return accepted }
                try await lease.wait()
            }
        } onCancel: { lease.retire(CancellationError()); lease.wake.signal() }
    }
    func operate<Value: Sendable>(id: UInt32, token: UUID, writing: Bool, timeout: Duration,
                                 effect: @escaping @Sendable () throws -> Void = {},
                                 action: (USBMultiplexLease) async throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        let lease = USBMultiplexLease(budget: try USBMultiplexBudget(timeout), effect: effect)
        try state.withLock { value in
            try ensure(id, token, value)
            if writing {
                guard value.handles[id]?.write == nil else { throw USBHostMultiplexError.writeInProgress }
                value.handles[id]?.write = lease
            } else {
                guard value.handles[id]?.read == nil else { throw USBHostMultiplexError.readInProgress }
                value.handles[id]?.read = lease
            }
        }
        defer { finishOperation(id: id, token: token, opening: false, writing: writing, lease: lease) }
        return try await withTaskCancellationHandler {
            do {
                try lease.check()
                let result = try await action(lease)
                if writing { try lease.authorize() }
                try state.withLock { value in try ensure(id, token, value); try lease.check() }
                return result
            } catch { abort(id: id, token: token, cause: error); throw streamFailure(id: id, token: token, fallback: error) }
        } onCancel: { self.abort(id: id, token: token, cause: CancellationError()) }
    }
    private func finishOperation(id: UInt32, token: UUID, opening: Bool, writing: Bool, lease: USBMultiplexLease) {
        lease.retire()
        do {
            try state.withLock { value in
                _ = try handle(id, token, value)
                if opening { value.handles[id]?.opening = nil }
                else if writing { value.handles[id]?.write = nil }
                else { value.handles[id]?.read = nil }
                try reap(&value)
            }
            notify()
        } catch { retire(error) }
    }
    func read(id: UInt32, token: UUID, maximum: Int, lease: USBMultiplexLease) async throws -> Stream.Read {
        while true {
            let result = try state.withLock { value in
                try ensure(id, token, value); try lease.check()
                return try wire.read(streamID: id, maximum: maximum)
            }
            switch result {
            case .data(let bytes): notify(); return .bytes(bytes)
            case .remoteFIN: return .end
            case .waiting: try await lease.wait()
            }
        }
    }
    func readExactly(id: UInt32, token: UUID, count: Int, lease: USBMultiplexLease) async throws -> Data {
        var result = Data(); result.reserveCapacity(count)
        while result.count < count {
            switch try await read(id: id, token: token, maximum: min(Wire.initialWindow, count - result.count), lease: lease) {
            case .bytes(let bytes): result.append(bytes)
            case .end: throw USBHostMultiplexError.unexpectedEnd
            }
        }
        return result
    }
    func write(id: UInt32, token: UUID, bytes: Data, lease: USBMultiplexLease) async throws {
        var offset = 0
        while offset < bytes.count {
            try lease.authorize()
            let start = offset, end = min(bytes.count, offset + Wire.outboundDataBytes)
            let ticket = try state.withLock { value in
                try ensure(id, token, value); try lease.check()
                return try wire.queueData(streamID: id, bytes: bytes.subdata(in: start..<end))
            }
            notify()
            while true {
                try state.withLock { value in try ensure(id, token, value); try lease.check() }
                switch ticket.result {
                case .written: offset = end
                case .failed(let error): throw error
                case .waiting: try await lease.wait(); continue
                }
                break
            }
        }
    }
    func requestFIN(id: UInt32, token: UUID) throws {
        try state.withLock { value in
            try ensure(id, token, value); try wire.finishSending(streamID: id)
            if value.handles[id]?.halfClosedAt == nil { value.handles[id]?.halfClosedAt = .now }
        }
        notify(timer: true)
    }
    func finSent(id: UInt32, token: UUID) throws -> Bool {
        try state.withLock { value in try ensure(id, token, value); return try wire.snapshot(streamID: id).localFINSent }
    }
    private func streamFailure(id: UInt32, token: UUID, fallback: any Error) -> any Error {
        do {
            return try state.withLock { value in
                let owner = try handle(id, token, value)
                return try owner.failure ?? wire.streamFailure(id) ?? value.terminal ?? fallback
            }
        } catch { return error }
    }
    func isClosed(id: UInt32, token: UUID) -> Bool {
        do { try state.withLock { value in try ensure(id, token, value) }; return false } catch { return true }
    }
    private func abortLocked(_ id: UInt32, cause: any Error, _ value: inout State) throws {
        guard var owner = value.handles[id] else { throw USBHostMultiplexError.ownerRetired }
        if owner.failure == nil { owner.failure = try wire.streamFailure(id) ?? value.terminal ?? cause }
        owner.opening?.retire(); owner.read?.retire(); owner.write?.retire(); owner.halfClosedAt = nil
        value.handles[id] = owner
        if wire.failure == nil, try wire.streamFailure(id) == nil, let error = owner.failure { try wire.resetStream(id, cause: error) }
    }
    func abort(id: UInt32, token: UUID, cause: any Error) {
        do {
            try state.withLock { value in
                if value.released.contains(id) { return }
                _ = try handle(id, token, value); try abortLocked(id, cause: cause, &value)
            }
            notify(timer: true)
        } catch { retire(error) }
    }
    /// Dropping the last public view transfers reset/release to the connection, without an
    /// ARC cycle through the handle table or retaining an unreachable published owner.
    func abandon(id: UInt32, token: UUID) {
        do {
            try state.withLock { value in
                if value.released.contains(id) { return }
                _ = try handle(id, token, value)
                value.handles[id]?.published = false
                try abortLocked(id, cause: USBLogicalStreamError.cancelled, &value)
                try reap(&value)
            }
            notify(timer: true)
        } catch { retire(error) }
    }
    private func reap(_ value: inout State) throws {
        for (id, owner) in value.handles where !owner.published && owner.idle && owner.failure != nil {
            if try wire.canReleaseStream(id) { try release(id, &value) }
        }
    }
    private func release(_ id: UInt32, _ value: inout State) throws {
        guard let owner = value.handles[id], owner.idle else { throw USBHostMultiplexError.cleanupUnconfirmed }
        try wire.releaseStream(id)
        value.releasedWakes.append(owner.cleanupWake)
        value.handles.removeValue(forKey: id); value.released.insert(id)
    }

    func readLoop() async {
        do {
            while true {
                try state.withLock { try requireReady($0) }
                let budget = try USBMultiplexBudget(configuration.frameRead)
                let header = try Wire.decodeHeader(await readNativeExactly(Wire.headerBytes, budget: budget))
                let body = header.type == .data ? try await readNativeExactly(Int(header.value), budget: budget) : Data()
                let frame = try Wire.Frame(header: header, body: body)
                let timer = try state.withLock { value in
                    try requireReady(value); try wire.receive(frame)
                    if header.type == .ping, header.has(Wire.ack), let nonce = try wire.takePingAcknowledgement() {
                        guard nonce == value.pingID else { throw USBHostMultiplexError.invalidPingAcknowledgement }
                        value.pingID = nil; value.pingSentAt = nil; value.lastPongAt = .now
                    }
                    let lifecycle = header.has(Wire.syn) || header.has(Wire.rst) || header.has(Wire.fin)
                    if lifecycle {
                        let pending = Set(wire.pendingAcceptIDs)
                        value.pendingSince = value.pendingSince.filter { pending.contains($0.key) }
                        for id in pending where value.pendingSince[id] == nil { value.pendingSince[id] = .now }
                    }
                    try reap(&value)
                    return lifecycle || header.type == .ping
                }
                notify(timer: timer)
            }
        } catch { retire(error) }
    }
    private func readNativeExactly(_ count: Int, budget: USBMultiplexBudget) async throws -> Data {
        var result = Data(); result.reserveCapacity(count)
        while result.count < count {
            let bytes = try await carrier.readBytes(maximumBytes: min(USBHostByteTransport.transferBytes, count - result.count), timeout: budget.remaining())
            try budget.check(); result.append(bytes)
        }
        return result
    }
    func writeLoop() async {
        do {
            while true {
                let frame = try state.withLock { value in try requireReady(value); return try wire.pollOutbound() }
                guard let frame else { try await writerWake.wait(); continue }
                let lease = frame.header.type == .data ? state.withLock { $0.handles[frame.header.streamID]?.write } : nil
                if frame.header.type == .data {
                    do {
                        guard let lease else { throw USBHostMultiplexError.missingWriteLease }
                        try lease.authorize()
                        try state.withLock { value in
                            guard let owner = value.handles[frame.header.streamID] else { throw USBHostMultiplexError.ownerRetired }
                            try ensure(frame.header.streamID, owner.token, value); try lease.check()
                        }
                    } catch {
                        try state.withLock { value in
                            try abortLocked(frame.header.streamID, cause: error, &value)
                            try wire.discardUnsentData(frame); try reap(&value)
                        }
                        notify(timer: true); continue
                    }
                }
                do {
                    let timeout = try min(configuration.nativeWrite, lease?.budget.remaining() ?? configuration.nativeWrite)
                    try await carrier.writeBytes(frame.wireBytes(), timeout: timeout, requireEffectAuthorization: {
                        if let lease {
                            do { try lease.authorize() }
                            catch {
                                // Preserve originating denial before raw cleanup or the reader can
                                // publish a secondary disconnect. Native entry makes failure physical.
                                do { try self.state.withLock { value in try self.abortLocked(frame.header.streamID, cause: error, &value) } }
                                catch { self.retire(error) }
                                self.notify(timer: true)
                                throw error
                            }
                        }
                    })
                    try state.withLock { value in try wire.reportWritten(frame); try reap(&value) }
                    notify()
                } catch {
                    try state.withLock { _ in try wire.reportWriteFailure(frame, cause: error) }
                    throw error
                }
            }
        } catch { retire(error) }
    }
    func deadlineLoop() async {
        do {
            while true {
                let next = try state.withLock { value -> ContinuousClock.Instant in
                    try requireReady(value)
                    let now = ContinuousClock.now
                    if let sent = value.pingSentAt, now >= sent.advanced(by: configuration.pingReply) { throw USBHostMultiplexError.timedOut }
                    for (id, since) in value.pendingSince where now >= since.advanced(by: configuration.pendingAccept) {
                        try wire.resetStream(id, cause: USBHostMultiplexError.timedOut); value.pendingSince.removeValue(forKey: id)
                    }
                    for (id, owner) in value.handles {
                        if owner.failure == nil, let since = owner.halfClosedAt,
                           try !wire.snapshot(streamID: id).remoteFIN, now >= since.advanced(by: configuration.halfClose) {
                            try abortLocked(id, cause: USBHostMultiplexError.timedOut, &value)
                        }
                    }
                    if value.pingID == nil, now >= value.lastPongAt.advanced(by: configuration.pingInterval) {
                        guard let nonce = UInt32(exactly: value.nextPing) else { throw USBHostMultiplexError.invalidPingAcknowledgement }
                        try wire.requestPing(nonce); value.nextPing += 1; value.pingID = nonce; value.pingSentAt = now
                    }
                    try reap(&value)
                    var next = value.pingSentAt?.advanced(by: configuration.pingReply) ?? value.lastPongAt.advanced(by: configuration.pingInterval)
                    for since in value.pendingSince.values { next = min(next, since.advanced(by: configuration.pendingAccept)) }
                    for (id, owner) in value.handles {
                        if owner.failure == nil, let since = owner.halfClosedAt, try !wire.snapshot(streamID: id).remoteFIN {
                            next = min(next, since.advanced(by: configuration.halfClose))
                        }
                    }
                    return next
                }
                notify()
                _ = try await timerWake.wait(until: next)
            }
        } catch { retire(error) }
    }
    func retire(_ cause: any Error) {
        let first = state.withLock { value in
            guard value.terminal == nil else { return false }
            value.terminal = cause; value.ready = false; wire.failCarrier(cause)
            for owner in value.handles.values { owner.opening?.retire(); owner.read?.retire(); owner.write?.retire() }
            value.accepting?.retire(cause); return true
        }
        if first { carrier.close(); notify(timer: true) }
    }
    func beginCleanup() throws {
        try state.withLock { value in
            guard !value.cleanupObserver else { throw USBHostMultiplexError.cleanupInProgress }
            value.cleanupObserver = true
        }
    }
    func endCleanup() { state.withLock { $0.cleanupObserver = false } }
    func awaitStartReturn(_ budget: USBMultiplexBudget) async throws {
        while state.withLock({ $0.starting }) {
            guard try await cleanupWake.wait(until: budget.deadline) else { throw USBHostMultiplexError.cleanupUnconfirmed }
        }
    }
    func releaseAfterExit(_ budget: USBMultiplexBudget) async throws {
        while true {
            let released = try state.withLock { value in
                guard value.accepting == nil && !value.starting && value.handles.values.allSatisfy(\.idle) else { return false }
                for id in Array(value.handles.keys) { try release(id, &value) }
                guard !wire.snapshot.dispatchPending && wire.snapshot.owners == 0 else { throw USBHostMultiplexError.cleanupUnconfirmed }
                value.cleanupConfirmed = true; return true
            }
            if released { notify(timer: true); return }
            guard try await cleanupWake.wait(until: budget.deadline) else { throw USBHostMultiplexError.cleanupUnconfirmed }
        }
    }
    func beginStreamCleanup(id: UInt32, token: UUID) throws {
        try state.withLock { value in
            if value.released.contains(id) { return }
            let owner = try handle(id, token, value)
            guard !owner.cleanupObserver else { throw USBHostMultiplexError.cleanupInProgress }
            value.handles[id]?.cleanupObserver = true
        }
    }
    func endStreamCleanup(id: UInt32, token: UUID) {
        state.withLock { value in if value.handles[id]?.token == token { value.handles[id]?.cleanupObserver = false } }
    }
    func awaitStreamRelease(id: UInt32, token: UUID, budget: USBMultiplexBudget) async throws {
        while true {
            let wait = try state.withLock { value -> USBMultiplexWake? in
                if value.released.contains(id) { return nil }
                let owner = try handle(id, token, value)
                if try owner.idle && wire.canReleaseStream(id) { try release(id, &value); return nil }
                return owner.cleanupWake
            }
            guard let wait else { notify(timer: true); return }
            guard try await wait.wait(until: budget.deadline) else { throw USBHostMultiplexError.cleanupUnconfirmed }
        }
    }
}
#endif
