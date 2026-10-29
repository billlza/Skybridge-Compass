import Foundation
import os

/// Bounded state for one USB attachment. All state transitions are serialized by one lock;
/// this type performs no I/O, callback, wait or authentication while holding it. The native
/// owner supplies deadlines, one writer, purpose admission and real cleanup confirmation.
public final class USBLogicalStreamProtocol: Sendable {
    public enum Role: Sendable { case client, server }
    public enum Priority: Sendable { case control, bulk }
    public struct Limits: Sendable {
        public let owners: Int, pendingAccepts: Int, lifetimeStreams: Int, controlFrames: Int
        public init(owners: Int = 8, pendingAccepts: Int = 2, lifetimeStreams: Int = 4_096, controlFrames: Int = 32) {
            self.owners = owners; self.pendingAccepts = pendingAccepts
            self.lifetimeStreams = lifetimeStreams; self.controlFrames = controlFrames
        }
    }
    public enum ReadResult: Sendable { case data(Data), waiting, remoteFIN }
    public enum WriteResult: Sendable { case waiting, written, failed(any Error) }
    /// Written confirms this exact local native dispatch, never delivery or a file receipt.
    public final class WriteTicket: Sendable {
        private let state = OSAllocatedUnfairLock(initialState: WriteResult.waiting)
        public var result: WriteResult { state.withLock { $0 } }
        fileprivate init() {}
        fileprivate func finish(_ result: WriteResult) { state.withLock { $0 = result } }
    }
    public struct Outbound: Sendable {
        public let header: USBLogicalStreamWire.Header
        fileprivate let token: UUID
        private let bytes: Data
        fileprivate init(_ header: USBLogicalStreamWire.Header, body: Data = Data()) throws {
            self.header = header; token = UUID()
            bytes = try USBLogicalStreamWire.Frame(header: header, body: body).encoded()
        }
        public func wireBytes() -> Data { bytes }
    }
    public struct StreamSnapshot: Sendable {
        public let id: UInt32, claimed: Bool, acknowledged: Bool
        public let receiveCredit: UInt32, sendCredit: UInt32
        public let bufferedReceiveBytes: Int, pendingWriteBytes: Int
        public let localFINSent: Bool, remoteFIN: Bool, failed: Bool, dispatchPending: Bool
    }
    public struct Snapshot: Sendable {
        public let owners: Int, pendingAccepts: Int, lifetimeStreams: Int
        public let bufferedReceiveBytes: Int, pendingWriteBytes: Int, queuedControlFrames: Int
        public let dispatchPending: Bool, failed: Bool
    }
    private let state: OSAllocatedUnfairLock<State>
    public init(role: Role, limits: Limits = Limits()) throws {
        guard (1...32).contains(limits.owners), (1...limits.owners).contains(limits.pendingAccepts),
              (limits.owners...65_536).contains(limits.lifetimeStreams), (4...128).contains(limits.controlFrames) else {
            throw USBLogicalStreamError.invalidConfiguration
        }
        state = OSAllocatedUnfairLock(initialState: State(role: role, limits: limits))
    }
    public func openStream(priority: Priority = .control) throws -> UInt32 { try state.withLock { try $0.open(priority) } }
    public func acceptStream(priority: Priority = .control) throws -> UInt32? { try state.withLock { try $0.accept(priority) } }
    public func queueData(streamID: UInt32, bytes: Data) throws -> WriteTicket { try state.withLock { try $0.queue(streamID, bytes) } }
    public func read(streamID: UInt32, maximum: Int) throws -> ReadResult { try state.withLock { try $0.read(streamID, maximum) } }
    public func finishSending(streamID: UInt32) throws { try state.withLock { try $0.finishSending(streamID) } }
    public func resetStream(_ id: UInt32, cause: any Error = USBLogicalStreamError.cancelled) throws {
        try state.withLock { try $0.reset(id, cause) }
    }
    public func releaseStream(_ id: UInt32) throws { try state.withLock { try $0.release(id) } }
    public func canReleaseStream(_ id: UInt32) throws -> Bool { try state.withLock { try $0.canRelease(id) } }
    public func streamFailure(_ id: UInt32) throws -> (any Error)? { try state.withLock { try $0.stream(id).failure } }
    public var failure: (any Error)? { state.withLock { $0.terminal } }
    public var pendingAcceptIDs: [UInt32] { state.withLock { $0.accepts } }
    public func stopAccepting() throws { try state.withLock { try $0.stopAccepting() } }
    public func requestPing(_ nonce: UInt32) throws { try state.withLock { try $0.requestPing(nonce) } }
    public func takePingAcknowledgement() throws -> UInt32? { try state.withLock { try $0.takePong() } }
    public func receive(_ frame: USBLogicalStreamWire.Frame) throws { try state.withLock { try $0.receive(frame) } }
    public func pollOutbound() throws -> Outbound? { try state.withLock { try $0.poll() } }
    public func reportWritten(_ frame: Outbound) throws { try state.withLock { try $0.written(frame) } }
    public func reportWriteFailure(_ frame: Outbound, cause: any Error) throws {
        try state.withLock { try $0.writeFailed(frame, cause) }
    }
    /// Allowed only before native I/O starts, after retiring the exact logical owner.
    public func discardUnsentData(_ frame: Outbound) throws { try state.withLock { try $0.discard(frame) } }
    public func failCarrier(_ cause: any Error) { state.withLock { $0.fail(cause) } }
    public var snapshot: Snapshot { state.withLock { $0.snapshot } }
    public func snapshot(streamID: UInt32) throws -> StreamSnapshot { try state.withLock { try $0.snapshot(streamID) } }

    private struct PendingWrite: Sendable {
        let bytes: Data
        let ticket = WriteTicket()
        var offset = 0
    }
    private struct StreamState: Sendable {
        let id: UInt32, local: Bool
        var priority: Priority, claimed: Bool
        var acknowledged = false, synDispatched = false, ackNeeded = false
        var receiveCredit = UInt32(USBLogicalStreamWire.initialWindow)
        var sendCredit = UInt32(USBLogicalStreamWire.initialWindow)
        var consumedCredit: UInt32 = 0
        var buffer: Data?
        var readPosition = 0, writePosition = 0, bufferedBytes = 0
        var write: PendingWrite?
        var finRequested = false, finDispatched = false, finSent = false, remoteFIN = false
        var resetNeeded = false, resetSent = false
        var failure: (any Error)?
        var lateFrames = 0
        init(_ id: UInt32, local: Bool, priority: Priority) {
            self.id = id; self.local = local; self.priority = priority; claimed = local
        }
        var hasData: Bool { failure == nil && write != nil && sendCredit > 0 && (!local || synDispatched) && !ackNeeded }
        var hasControl: Bool {
            if failure != nil { return resetNeeded && !resetSent }
            return local && !synDispatched || ackNeeded || finRequested && !finDispatched || consumedCredit > 0
        }
        mutating func fail(_ error: any Error, sendReset: Bool) {
            if failure == nil { failure = error }
            buffer = nil; bufferedBytes = 0; readPosition = 0; writePosition = 0; consumedCredit = 0
            if let failure { write?.ticket.finish(.failed(failure)) }
            write = nil; ackNeeded = false
            if sendReset && !(finSent && remoteFIN) { resetNeeded = true }
        }
    }
    private struct Retired: Sendable { var credit: UInt32, lateFrames: Int }
    private enum Kind: Sendable { case session, syn, ack, credit, data, fin, reset }
    private struct Dispatch: Sendable {
        let frame: Outbound, kind: Kind
        var streamID: UInt32? = nil
        var ticket: WriteTicket? = nil
        var dataBytes: Int = 0
    }
    private struct Ping: Sendable { let nonce: UInt32; var dispatched = false, acknowledged = false }
    private struct State: Sendable {
        typealias Wire = USBLogicalStreamWire
        let role: Role, limits: Limits
        var streams: [UInt32: StreamState] = [:], retired: [UInt32: Retired] = [:]
        var seen: Set<UInt32> = [], accepts: [UInt32] = [], controls: [Wire.Header] = []
        var nextID: UInt64, dispatch: Dispatch?, terminal: (any Error)?
        var localGoAway = false, remoteGoAway = false, ping: Ping?, highestPing: UInt32?
        var controlBurst = 0, priorityBurst = 0, preferSessionControl = true
        var lastControlID: UInt32 = 0, lastPriorityID: UInt32 = 0, lastBulkID: UInt32 = 0
        init(role: Role, limits: Limits) { self.role = role; self.limits = limits; nextID = role == .client ? 1 : 2 }
        func requireLive() throws { if let terminal { throw terminal } }
        func stream(_ id: UInt32) throws -> StreamState {
            guard let value = streams[id] else { throw USBLogicalStreamError.ownerRetired }; return value
        }
        func requireOwned(_ id: UInt32) throws {
            try requireLive()
            guard let s = streams[id] else { throw USBLogicalStreamError.ownerRetired }
            guard s.claimed else { throw USBLogicalStreamError.ownerNotAccepted }
            if let failure = s.failure { throw failure }
        }
        mutating func open(_ priority: Priority) throws -> UInt32 {
            try requireLive()
            guard !remoteGoAway else { throw USBLogicalStreamError.peerStoppedAccepting }
            guard streams.count < limits.owners, seen.count < limits.lifetimeStreams,
                  nextID <= UInt32.max - 2 else { throw USBLogicalStreamError.capacityExceeded }
            let id = UInt32(nextID); nextID += 2
            seen.insert(id); streams[id] = StreamState(id, local: true, priority: priority)
            return id
        }
        mutating func accept(_ priority: Priority) throws -> UInt32? {
            try requireLive()
            guard !accepts.isEmpty else { return nil }
            let id = accepts.removeFirst()
            guard var s = streams.removeValue(forKey: id), !s.claimed, s.failure == nil else {
                throw USBLogicalStreamError.ownerRetired
            }
            s.claimed = true; s.priority = priority; s.ackNeeded = true; streams[id] = s
            return id
        }
        mutating func queue(_ id: UInt32, _ bytes: Data) throws -> WriteTicket {
            try requireOwned(id)
            guard (1...Wire.outboundDataBytes).contains(bytes.count) else { throw USBLogicalStreamError.invalidArgument }
            guard streams[id]?.write == nil else { throw USBLogicalStreamError.writePending }
            guard streams[id]?.finRequested == false else { throw USBLogicalStreamError.sendingFinished }
            // Data slices can retain nonzero indices; pending offsets are zero-based.
            let write = PendingWrite(bytes: Data(bytes)); streams[id]?.write = write
            return write.ticket
        }
        mutating func read(_ id: UInt32, _ maximum: Int) throws -> ReadResult {
            try requireOwned(id)
            guard (1...Wire.initialWindow).contains(maximum) else { throw USBLogicalStreamError.invalidArgument }
            // Temporarily remove under the lock so the fixed ring has no dictionary alias that
            // would force a copy-on-write of its entire window for every read/write operation.
            guard var s = streams.removeValue(forKey: id) else { throw USBLogicalStreamError.ownerRetired }
            defer { streams[id] = s }
            guard s.bufferedBytes > 0 else { return s.remoteFIN ? .remoteFIN : .waiting }
            guard let buffer = s.buffer else { throw USBLogicalStreamError.protocolViolation("missing receive storage") }
            let count = min(maximum, s.bufferedBytes), first = min(count, Wire.initialWindow - s.readPosition)
            var result = buffer.subdata(in: s.readPosition..<(s.readPosition + first))
            if count > first { result.append(buffer.prefix(count - first)) }
            s.readPosition = (s.readPosition + count) % Wire.initialWindow; s.bufferedBytes -= count
            if !s.remoteFIN { s.consumedCredit += UInt32(count) }
            return .data(result)
        }
        mutating func finishSending(_ id: UInt32) throws {
            try requireOwned(id)
            guard streams[id]?.write == nil else { throw USBLogicalStreamError.writePending }
            streams[id]?.finRequested = true
        }
        mutating func reset(_ id: UInt32, _ cause: any Error) throws {
            try requireLive()
            guard var s = streams.removeValue(forKey: id) else { throw USBLogicalStreamError.ownerRetired }
            s.fail(cause, sendReset: !s.local || s.synDispatched); accepts.removeAll { $0 == id }
            streams[id] = s; retireUnclaimedIfReady(id)
        }
        func releasable(_ s: StreamState) -> Bool {
            if dispatch?.streamID == s.id { return false }
            if terminal != nil { return true }
            if s.failure != nil { return !s.resetNeeded || s.resetSent }
            return s.finSent && s.remoteFIN && s.bufferedBytes == 0 && s.write == nil
        }
        func canRelease(_ id: UInt32) throws -> Bool { try releasable(stream(id)) }
        mutating func release(_ id: UInt32) throws {
            let s = try stream(id)
            guard s.claimed else { throw USBLogicalStreamError.ownerNotAccepted }
            guard releasable(s) else { throw USBLogicalStreamError.cleanupUnconfirmed }
            retire(id)
        }
        mutating func retire(_ id: UInt32) {
            guard let s = streams.removeValue(forKey: id) else { return }
            accepts.removeAll { $0 == id }; retired[id] = Retired(credit: s.receiveCredit, lateFrames: s.lateFrames)
        }
        mutating func retireUnclaimedIfReady(_ id: UInt32) {
            if let s = streams[id], !s.claimed, s.failure != nil, releasable(s) { retire(id) }
        }
        mutating func stopAccepting() throws {
            try requireLive(); if localGoAway { return }
            try enqueue(.init(type: .goAway, flags: 0, streamID: 0, value: 0)); localGoAway = true
        }
        mutating func requestPing(_ nonce: UInt32) throws {
            try requireLive()
            guard ping == nil else { throw USBLogicalStreamError.pingPending }
            if let highestPing, nonce <= highestPing { throw USBLogicalStreamError.reusedPing }
            try enqueue(.init(type: .ping, flags: Wire.syn, streamID: 0, value: nonce))
            highestPing = nonce; ping = Ping(nonce: nonce)
        }
        mutating func takePong() throws -> UInt32? {
            try requireLive()
            guard let current = ping, current.acknowledged else { return nil }
            ping = nil; return current.nonce
        }
        mutating func receive(_ frame: Wire.Frame) throws {
            try requireLive()
            do {
                try Wire.validate(frame.header)
                guard frame.body.count == (frame.header.type == .data ? Int(frame.header.value) : 0) else {
                    throw USBLogicalStreamError.invalidBody
                }
                let h = frame.header
                switch h.type {
                case .ping:
                    if h.has(Wire.syn) { try enqueue(.init(type: .ping, flags: Wire.ack, streamID: 0, value: h.value)) }
                    else if ping?.dispatched == true, ping?.nonce == h.value { ping?.acknowledged = true }
                case .goAway:
                    guard h.value == 0 else { throw USBLogicalStreamError.protocolViolation("peer go-away error") }
                    remoteGoAway = true
                case .data, .windowUpdate: try receiveStream(h, frame.body)
                }
            } catch { fail(error); throw error }
        }
        mutating func receiveStream(_ h: Wire.Header, _ body: Data) throws {
            let id = h.streamID
            if h.has(Wire.syn) {
                let parity: UInt32 = role == .client ? 0 : 1
                guard id % 2 == parity, !seen.contains(id), seen.count < limits.lifetimeStreams else {
                    throw USBLogicalStreamError.protocolViolation("peer stream identifier or lifetime budget")
                }
                seen.insert(id)
                if localGoAway || streams.count >= limits.owners || accepts.count >= limits.pendingAccepts {
                    retired[id] = Retired(credit: UInt32(Wire.initialWindow), lateFrames: 0)
                    try enqueue(.init(type: .windowUpdate, flags: Wire.rst, streamID: id, value: 0))
                } else { streams[id] = StreamState(id, local: false, priority: .control); accepts.append(id) }
            }
            guard var s = streams.removeValue(forKey: id) else {
                guard var previous = retired[id] else { throw USBLogicalStreamError.protocolViolation("unknown stream") }
                previous.lateFrames += 1
                guard previous.lateFrames <= 64, body.count <= previous.credit else {
                    throw USBLogicalStreamError.protocolViolation("retired stream allowance exceeded")
                }
                previous.credit -= UInt32(body.count); retired[id] = previous; return
            }
            defer { streams[id] = s; retireUnclaimedIfReady(id) }
            if s.failure != nil {
                s.lateFrames += 1
                guard s.lateFrames <= 64, body.count <= s.receiveCredit else {
                    throw USBLogicalStreamError.protocolViolation("reset stream allowance exceeded")
                }
                s.receiveCredit -= UInt32(body.count); return
            }
            if h.has(Wire.ack) {
                guard s.local, s.synDispatched, !s.acknowledged else {
                    throw USBLogicalStreamError.protocolViolation("unexpected stream acknowledgement")
                }
                s.acknowledged = true
            }
            if h.has(Wire.rst) {
                guard body.count <= s.receiveCredit else { throw USBLogicalStreamError.protocolViolation("reset payload credit") }
                s.receiveCredit -= UInt32(body.count); s.fail(USBLogicalStreamError.resetByPeer, sendReset: false)
                accepts.removeAll { $0 == id }; return
            }
            if h.type == .windowUpdate {
                guard h.value <= UInt32.max - s.sendCredit else { throw USBLogicalStreamError.protocolViolation("credit overflow") }
                s.sendCredit += h.value
            } else {
                guard !s.remoteFIN || body.isEmpty, body.count <= s.receiveCredit else {
                    throw USBLogicalStreamError.protocolViolation("data after FIN or beyond receive credit")
                }
                s.receiveCredit -= UInt32(body.count)
                if !body.isEmpty {
                    guard body.count <= Wire.initialWindow - s.bufferedBytes else { throw USBLogicalStreamError.protocolViolation("receive capacity") }
                    if s.buffer == nil { s.buffer = Data(count: Wire.initialWindow) }
                    let first = min(body.count, Wire.initialWindow - s.writePosition)
                    s.buffer?.replaceSubrange(s.writePosition..<(s.writePosition + first), with: body.prefix(first))
                    if first < body.count { s.buffer?.replaceSubrange(0..<(body.count - first), with: body.dropFirst(first)) }
                    s.writePosition = (s.writePosition + body.count) % Wire.initialWindow; s.bufferedBytes += body.count
                }
            }
            if h.has(Wire.fin) {
                guard !s.remoteFIN else { throw USBLogicalStreamError.protocolViolation("repeated FIN") }
                s.remoteFIN = true; s.consumedCredit = 0
            }
        }
        mutating func poll() throws -> Outbound? {
            try requireLive()
            guard dispatch == nil else { throw USBLogicalStreamError.wrongDispatch }
            let dataAvailable = streams.values.contains { $0.hasData }
            let control = controlBurst < 8 || !dataAvailable ? try selectControl() : nil
            guard let chosen = try control ?? selectData() ?? selectControl() else { return nil }
            controlBurst = chosen.kind == .data ? 0 : min(8, controlBurst + 1)
            dispatch = chosen; return chosen.frame
        }
        mutating func selectControl() throws -> Dispatch? {
            let candidates = streams.values.filter { $0.hasControl }.map(\.id)
            if !controls.isEmpty && (preferSessionControl || candidates.isEmpty) {
                preferSessionControl = false; let header = controls.removeFirst()
                if header.type == .ping, header.has(Wire.syn), ping?.nonce == header.value { ping?.dispatched = true }
                return Dispatch(frame: try Outbound(header), kind: .session)
            }
            guard let id = nextAfter(candidates, lastControlID), var s = streams.removeValue(forKey: id) else { return nil }
            defer { streams[id] = s }
            preferSessionControl = true; lastControlID = id
            let kind: Kind, flags: UInt16, value: UInt32
            if s.resetNeeded { kind = .reset; flags = Wire.rst; value = 0 }
            else if s.local && !s.synDispatched { s.synDispatched = true; kind = .syn; flags = Wire.syn; value = 0 }
            else if s.ackNeeded { s.ackNeeded = false; kind = .ack; flags = Wire.ack; value = 0 }
            else if s.finRequested && !s.finDispatched { s.finDispatched = true; kind = .fin; flags = Wire.fin; value = 0 }
            else {
                kind = .credit; flags = 0; value = s.consumedCredit
                guard value > 0, s.receiveCredit <= UInt32(Wire.initialWindow), value <= UInt32(Wire.initialWindow) - s.receiveCredit else {
                    throw USBLogicalStreamError.protocolViolation("local receive-credit accounting")
                }
                s.consumedCredit = 0; s.receiveCredit += value
            }
            return Dispatch(frame: try Outbound(.init(type: .windowUpdate, flags: flags, streamID: id, value: value)), kind: kind, streamID: id)
        }
        mutating func selectData() throws -> Dispatch? {
            let candidates = streams.values.filter { $0.hasData }
            let priority = candidates.filter { $0.priority == .control }.map(\.id)
            let bulk = candidates.filter { $0.priority == .bulk }.map(\.id)
            let usePriority = !priority.isEmpty && (priorityBurst < 4 || bulk.isEmpty)
            guard let id = nextAfter(usePriority ? priority : bulk, usePriority ? lastPriorityID : lastBulkID),
                  var s = streams.removeValue(forKey: id) else { return nil }
            defer { streams[id] = s }
            guard let write = s.write else { throw USBLogicalStreamError.writePending }
            if usePriority { lastPriorityID = id; priorityBurst = min(4, priorityBurst + 1) }
            else { lastBulkID = id; priorityBurst = 0 }
            let count = min(write.bytes.count - write.offset, Int(s.sendCredit))
            guard count > 0 else { throw USBLogicalStreamError.protocolViolation("empty selected data") }
            s.sendCredit -= UInt32(count)
            let frame = try Outbound(.init(type: .data, flags: 0, streamID: id, value: UInt32(count)),
                                     body: write.bytes.subdata(in: write.offset..<(write.offset + count)))
            return Dispatch(frame: frame, kind: .data, streamID: id, ticket: write.ticket, dataBytes: count)
        }
        func nextAfter(_ ids: [UInt32], _ previous: UInt32) -> UInt32? { ids.filter { $0 > previous }.min() ?? ids.min() }
        mutating func written(_ frame: Outbound) throws {
            guard let sent = dispatch, sent.frame.token == frame.token else { throw USBLogicalStreamError.wrongDispatch }
            dispatch = nil
            guard let id = sent.streamID else { return }
            guard var s = streams.removeValue(forKey: id) else { throw USBLogicalStreamError.ownerRetired }
            defer { streams[id] = s; retireUnclaimedIfReady(id) }
            if sent.kind == .reset { s.resetSent = true; s.resetNeeded = false }
            if sent.kind == .fin { s.finSent = true }
            if sent.kind == .data, s.failure == nil, terminal == nil {
                guard var write = s.write, write.ticket === sent.ticket else { throw USBLogicalStreamError.wrongDispatch }
                write.offset += sent.dataBytes
                if write.offset == write.bytes.count { write.ticket.finish(.written); s.write = nil }
                else { s.write = write }
            }
        }
        mutating func writeFailed(_ frame: Outbound, _ cause: any Error) throws {
            guard dispatch?.frame.token == frame.token else { throw USBLogicalStreamError.wrongDispatch }
            dispatch = nil; fail(cause)
        }
        mutating func discard(_ frame: Outbound) throws {
            guard let pending = dispatch, pending.frame.token == frame.token, pending.kind == .data,
                  let id = pending.streamID, streams[id]?.failure != nil else { throw USBLogicalStreamError.wrongDispatch }
            dispatch = nil
        }
        mutating func enqueue(_ header: Wire.Header) throws {
            guard controls.count < limits.controlFrames else {
                let error = USBLogicalStreamError.protocolViolation("session control capacity")
                fail(error); throw error
            }
            controls.append(header)
        }
        mutating func fail(_ cause: any Error) {
            guard terminal == nil else { return }
            terminal = cause; controls.removeAll(); accepts.removeAll(); ping = nil
            for id in Array(streams.keys) {
                streams[id]?.fail(cause, sendReset: false); retireUnclaimedIfReady(id)
            }
        }
        var snapshot: Snapshot {
            Snapshot(owners: streams.count, pendingAccepts: accepts.count, lifetimeStreams: seen.count,
                     bufferedReceiveBytes: streams.values.reduce(0) { $0 + $1.bufferedBytes },
                     pendingWriteBytes: streams.values.reduce(0) { $0 + ($1.write.map { $0.bytes.count - $0.offset } ?? 0) },
                     queuedControlFrames: controls.count, dispatchPending: dispatch != nil, failed: terminal != nil)
        }
        func snapshot(_ id: UInt32) throws -> StreamSnapshot {
            let s = try stream(id)
            return StreamSnapshot(id: id, claimed: s.claimed, acknowledged: s.acknowledged,
                receiveCredit: s.receiveCredit, sendCredit: s.sendCredit, bufferedReceiveBytes: s.bufferedBytes,
                pendingWriteBytes: s.write.map { $0.bytes.count - $0.offset } ?? 0,
                localFINSent: s.finSent, remoteFIN: s.remoteFIN, failed: s.failure != nil || terminal != nil,
                dispatchPending: dispatch?.streamID == id)
        }
    }
}
