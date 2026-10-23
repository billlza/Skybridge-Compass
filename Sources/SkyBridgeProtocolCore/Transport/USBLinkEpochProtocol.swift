import Foundation
import os

/// One fresh physical-link epoch, not an authenticated MAIN session. The native
/// owner supplies an unpredictable local nonce, raw-byte/discard observations,
/// one reader/writer and actual cleanup. Only its owned, nonblocking clock is
/// called under the state lock. Readiness grants no identity/account/audio rights.
public final class USBLinkEpochProtocol: Sendable {
    public enum Role: Sendable { case client, server }
    public enum Phase: Sendable { case starting, ready, failed }
    public enum Failure: Error, Equatable, Sendable {
        case invalidConfiguration, invalidArgument, clock, timeout, startupBudget, controlBudget, candidates
        case protocolViolation, wrongDispatch, wrongEpoch, peerRestarted, peerClosed, notReady, writePending
        case backpressureOrder, staleBudget
    }
    public struct Limits: Sendable {
        public let startupMillis: Int64, offerIntervalMillis: Int64, startupWireBytes: Int64
        public let startupRecords: Int, candidates: Int, controlTransmissions: Int, receiveBufferBytes: Int
        public init(startupMillis: Int64 = 10_000, offerIntervalMillis: Int64 = 500,
                    startupWireBytes: Int64 = 1024 * 1024, startupRecords: Int = 128,
                    candidates: Int = 4, controlTransmissions: Int = 64,
                    receiveBufferBytes: Int = 2 * USBLinkWire.maximumBodyBytes) {
            self.startupMillis = startupMillis; self.offerIntervalMillis = offerIntervalMillis
            self.startupWireBytes = startupWireBytes; self.startupRecords = startupRecords
            self.candidates = candidates; self.controlTransmissions = controlTransmissions
            self.receiveBufferBytes = receiveBufferBytes
        }
    }
    public enum Receive: Sendable { case progress, quarantined, buffered, backpressure }
    public enum WriteResult: Sendable { case waiting, written, failed(any Error) }
    /// Written confirms the local native write only, never a receiver receipt.
    public final class WriteTicket: Sendable {
        private let state = OSAllocatedUnfairLock(initialState: WriteResult.waiting)
        public var result: WriteResult { state.withLock { $0 } }
        fileprivate init() {}
        fileprivate func finish(_ result: WriteResult) { state.withLock { $0 = result } }
    }
    /// Wrap each decoded record once; a backpressured record must retain identity
    /// until the reader retries it. No later record may overtake it.
    public final class Inbound: Sendable {
        public let record: USBLinkWire.Record
        public init(_ record: USBLinkWire.Record) { self.record = record }
    }
    public final class Outbound: Sendable {
        public let record: USBLinkWire.Record
        fileprivate init(_ record: USBLinkWire.Record) { self.record = record }
        public func wireBytes() -> Data { USBLinkWire.encode(record) }
    }
    public struct Snapshot: Sendable {
        public let phase: Phase, peer: USBLinkWire.Nonce?, candidates: Int, startupBytes: Int64
        public let startupRecords: Int, discardedRecords: Int, quarantinedRecords: Int
        public let controlTransmissions: Int, queuedControls: Int, dispatchPending: Bool
        public let bufferedBytes: Int, writePending: Bool, nextWakeMillis: Int64?
    }
    private let state: OSAllocatedUnfairLock<State>
    public convenience init(role: Role, local: USBLinkWire.Nonce, limits: Limits = Limits()) throws {
        let origin = DispatchTime.now().uptimeNanoseconds
        try self.init(role: role, local: local, limits: limits, elapsedMillis: {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now >= origin else { throw Failure.clock }
            return Int64((now - origin) / 1_000_000)
        })
    }
    /// Clock returns elapsed milliseconds since this owner was created. It must
    /// not block or re-enter this instance. Sampling and state updates are atomic.
    public init(role: Role, local: USBLinkWire.Nonce, limits: Limits = Limits(),
                elapsedMillis: @escaping @Sendable () throws -> Int64) throws {
        guard (1...60_000).contains(limits.startupMillis),
              (1...limits.startupMillis).contains(limits.offerIntervalMillis),
              (76...16 * 1024 * 1024).contains(limits.startupWireBytes),
              (4...4096).contains(limits.startupRecords), (1...16).contains(limits.candidates),
              (4...1024).contains(limits.controlTransmissions),
              (USBLinkWire.maximumBodyBytes...256 * 1024).contains(limits.receiveBufferBytes) else {
            throw Failure.invalidConfiguration
        }
        state = OSAllocatedUnfairLock(initialState: State(role: role, local: local, limits: limits, elapsedMillis: elapsedMillis))
    }
    public var failure: (any Error)? { state.withLock { $0.terminal } }
    public var snapshot: Snapshot { state.withLock { $0.snapshot } }
    public func observeInboundBytes(_ count: Int) throws { try state.withLock { try $0.observeBytes(count) } }
    public func observeDiscard(reason: USBLinkWire.Failure, encodedBodyBytes: Int) throws {
        try state.withLock { try $0.observeDiscard(reason, encodedBodyBytes) }
    }
    public func tick() throws { try state.withLock { _ = try $0.touch() } }
    public func receive(_ inbound: Inbound) throws -> Receive { try state.withLock { try $0.receive(inbound) } }
    /// nil means a ready, empty buffer only. Provisional DATA cannot leave early.
    public func readPayload(maximumBytes: Int) throws -> Data? { try state.withLock { try $0.read(maximumBytes) } }
    public func queueData(_ bytes: Data) throws -> WriteTicket { try state.withLock { try $0.queue(bytes) } }
    public func pollOutbound() throws -> Outbound? { try state.withLock { try $0.poll() } }
    /// Recheck immediately before every native fragment; polling alone is insufficient.
    public func authorizeOutbound(_ outbound: Outbound) throws { try state.withLock { try $0.authorize(outbound) } }
    public func reportWritten(_ outbound: Outbound) throws { try state.withLock { try $0.written(outbound) } }
    public func reportWriteFailure(_ outbound: Outbound, cause: any Error) throws {
        try state.withLock { try $0.writeFailed(outbound, cause) }
    }
    public func failCarrier(_ cause: any Error) { state.withLock { _ = $0.fail(cause) } }

    private struct Candidate: Sendable {
        var replacementProbe = false
        var selectDispatched = false, selectWritten = false, acceptReceived = false
        var acceptDispatched = false, acceptWritten = false, readyReceived = false
    }
    private struct Control: Equatable, Sendable { let kind: USBLinkWire.Kind, recipient: USBLinkWire.Nonce? }
    private struct PendingWrite: Sendable { let record: USBLinkWire.Record, ticket: WriteTicket }
    private struct State: Sendable {
        typealias W = USBLinkWire
        let role: Role, local: W.Nonce, limits: Limits, elapsedMillis: @Sendable () throws -> Int64
        var candidates: [W.Nonce: Candidate] = [:], controls: [Control] = []
        var selected: W.Nonce?, ready = false, terminal: (any Error)?
        var lastTime: Int64 = 0, nextOffer: Int64 = 0, offerWritten = false
        var startupBytes: Int64 = 0, startupRecords = 0, discards = 0
        var quarantined = 0, sentControls = 0, readyControls = 0
        var flight: Outbound?, pendingWrite: PendingWrite?, blockedRecord: Inbound?
        var buffer = Data(), readPosition = 0, buffered = 0

        var snapshot: Snapshot {
            let wake: Int64?
            if terminal != nil || ready { wake = nil }
            else if flight != nil { wake = limits.startupMillis }
            else if !controls.isEmpty { wake = lastTime }
            else { wake = role == .client ? min(nextOffer, limits.startupMillis) : limits.startupMillis }
            return Snapshot(phase: terminal != nil ? .failed : ready ? .ready : .starting,
                peer: selected, candidates: candidates.count, startupBytes: startupBytes,
                startupRecords: startupRecords, discardedRecords: discards, quarantinedRecords: quarantined,
                controlTransmissions: sentControls, queuedControls: controls.count, dispatchPending: flight != nil,
                bufferedBytes: buffered, writePending: pendingWrite != nil, nextWakeMillis: wake)
        }
        mutating func observeBytes(_ count: Int) throws {
            guard count >= 0 else { throw Failure.invalidArgument }
            _ = try touch()
            if !ready {
                guard Int64(count) <= limits.startupWireBytes - startupBytes else { throw stop(.startupBudget) }
                startupBytes += Int64(count)
            }
        }
        mutating func observeDiscard(_ reason: W.Failure, _ count: Int) throws {
            _ = try touch()
            guard !ready, [W.Failure.truncated, .body, .checksum, .escape].contains(reason),
                  (1...(W.maximumEncodedBytes - 2)).contains(count) else { throw stop(.protocolViolation) }
            try countStartupRecord()
            guard discards < W.maximumStartupDiscards else { throw stop(.startupBudget) }
            discards += 1
        }
        mutating func receive(_ inbound: Inbound) throws -> Receive {
            _ = try touch()
            if let blockedRecord, blockedRecord !== inbound { throw stop(.backpressureOrder) }
            let r = inbound.record
            if !ready { try countStartupRecord() }
            else if r.kind != .data {
                guard readyControls < limits.startupRecords else { throw stop(.controlBudget) }
                readyControls += 1
            }
            guard r.sender != local else { throw stop(.protocolViolation) }
            if r.kind == .offer {
                guard role == .server else { throw stop(.protocolViolation) }
                return try onOffer(r.sender)
            }
            guard r.recipient == local else { return try quarantine() }
            if r.kind == .select && role == .client { return try onSelect(r.sender) }
            if r.kind == .accept && role == .server { return try onAccept(r.sender) }
            if r.kind == .ready && role == .client { return try onReady(r.sender) }
            if r.kind == .data {
                guard r.sender == selected else {
                    if ready && candidates[r.sender] == nil { throw stop(.wrongEpoch) }
                    return try quarantine()
                }
                guard ready || canBufferEarly else { throw stop(.protocolViolation) }
                guard r.body.count <= limits.receiveBufferBytes - buffered else {
                    guard ready else { throw stop(.startupBudget) }
                    blockedRecord = inbound; return .backpressure
                }
                append(r.body); blockedRecord = nil; return .buffered
            }
            if r.kind == .close {
                if r.sender == selected { throw stop(.peerClosed) }
                return try quarantine()
            }
            throw stop(.protocolViolation)
        }
        mutating func read(_ maximum: Int) throws -> Data? {
            guard (1...W.maximumBodyBytes).contains(maximum) else { throw Failure.invalidArgument }
            _ = try touch()
            guard ready else { throw Failure.notReady }
            guard buffered > 0 else { return nil }
            let count = min(maximum, buffered), first = min(count, buffer.count - readPosition)
            var result = buffer.subdata(in: readPosition..<(readPosition + first))
            if first < count { result.append(buffer.prefix(count - first)) }
            readPosition = (readPosition + count) % buffer.count; buffered -= count
            return result
        }
        mutating func queue(_ bytes: Data) throws -> WriteTicket {
            guard (1...W.maximumBodyBytes).contains(bytes.count) else { throw Failure.invalidArgument }
            _ = try touch()
            guard ready else { throw Failure.notReady }
            guard pendingWrite == nil else { throw Failure.writePending }
            guard let selected else { throw stop(.protocolViolation) }
            let ticket = WriteTicket()
            pendingWrite = PendingWrite(record: try W.Record(kind: .data, sender: local, recipient: selected, body: bytes), ticket: ticket)
            return ticket
        }
        mutating func poll() throws -> Outbound? {
            let now = try touch()
            guard flight == nil else { return nil }
            if !ready && role == .client && now >= nextOffer {
                try enqueue(.offer, nil); nextOffer = now + limits.offerIntervalMillis
            }
            let outgoing: Outbound
            if !controls.isEmpty {
                guard sentControls < limits.controlTransmissions else { throw stop(.controlBudget) }
                let next = controls.removeFirst(); sentControls += 1
                outgoing = Outbound(try W.Record(kind: next.kind, sender: local, recipient: next.recipient))
                if next.kind == .select || next.kind == .accept {
                    guard let peer = next.recipient, var c = candidates[peer] else { throw stop(.protocolViolation) }
                    if next.kind == .select { c.selectDispatched = true } else { c.acceptDispatched = true }
                    candidates[peer] = c
                }
            } else {
                guard let pendingWrite else { return nil }
                guard ready else { throw stop(.protocolViolation) }
                outgoing = Outbound(pendingWrite.record)
            }
            flight = outgoing; return outgoing
        }
        mutating func authorize(_ outgoing: Outbound) throws {
            try requireFlight(outgoing); _ = try touch()
            if outgoing.record.kind == .data && (!ready || outgoing.record.recipient != selected) { throw stop(.wrongEpoch) }
        }
        mutating func written(_ outgoing: Outbound) throws {
            try requireFlight(outgoing)
            flight = nil // Account the real callback even when this epoch already failed.
            _ = try touch()
            let r = outgoing.record
            switch r.kind {
            case .offer: offerWritten = true
            case .select:
                guard let peer = r.recipient, var c = candidates[peer] else { throw stop(.protocolViolation) }
                c.selectWritten = true; candidates[peer] = c
                if c.acceptReceived {
                    if ready && c.replacementProbe && selected != peer { throw stop(.peerRestarted) }
                    try chooseServerPeer(peer)
                }
            case .accept:
                guard let peer = r.recipient, var c = candidates[peer] else { throw stop(.protocolViolation) }
                c.acceptWritten = true; candidates[peer] = c
                if ready && c.replacementProbe && selected != peer && c.readyReceived { throw stop(.peerRestarted) }
                completeClientIfReady()
            case .ready:
                if r.recipient == selected { establish() }
            case .data:
                guard let pendingWrite else { throw stop(.protocolViolation) }
                pendingWrite.ticket.finish(.written); self.pendingWrite = nil
            case .close: throw stop(.protocolViolation)
            }
        }
        mutating func writeFailed(_ outgoing: Outbound, _ cause: any Error) throws {
            try requireFlight(outgoing); flight = nil; _ = fail(cause)
        }
        mutating func onOffer(_ peer: W.Nonce) throws -> Receive {
            if let selected {
                if peer == selected { try enqueue(.ready, peer) }
                else if ready {
                    if let known = candidates[peer], !known.replacementProbe { return try quarantine() }
                    var c = try candidate(peer); c.replacementProbe = true; candidates[peer] = c
                    try enqueue(.select, peer)
                } else { return try quarantine() }
            } else { _ = try candidate(peer); try enqueue(.select, peer) }
            return .progress
        }
        mutating func onSelect(_ peer: W.Nonce) throws -> Receive {
            guard offerWritten || flight?.record.kind == .offer else { throw stop(.protocolViolation) }
            if ready {
                if peer != selected {
                    if let known = candidates[peer], !known.replacementProbe { return try quarantine() }
                    var c = try candidate(peer); c.replacementProbe = true; candidates[peer] = c
                }
                try enqueue(.accept, peer); return .progress
            }
            if peer != selected {
                if candidates[peer] != nil { return try quarantine() }
                if let selected, candidates[selected]?.readyReceived == true { throw stop(.peerRestarted) }
                _ = try candidate(peer); selected = peer
                controls.removeAll { $0.kind == .accept && $0.recipient != peer }
            }
            try enqueue(.accept, peer); return .progress
        }
        mutating func onAccept(_ peer: W.Nonce) throws -> Receive {
            guard var c = candidates[peer] else { return try quarantine() }
            if selected != nil && selected != peer {
                guard ready && c.replacementProbe else { return try quarantine() }
                guard c.selectDispatched else { throw stop(.protocolViolation) }
                c.acceptReceived = true; candidates[peer] = c
                if c.selectWritten { throw stop(.peerRestarted) }
                return .progress
            }
            guard c.selectDispatched else { throw stop(.protocolViolation) }
            c.acceptReceived = true; candidates[peer] = c
            if c.selectWritten { try chooseServerPeer(peer) }
            return .progress
        }
        mutating func onReady(_ peer: W.Nonce) throws -> Receive {
            guard var c = candidates[peer] else { return try quarantine() }
            guard selected == peer || ready && c.replacementProbe else { return try quarantine() }
            guard c.acceptDispatched else { throw stop(.protocolViolation) }
            c.readyReceived = true; candidates[peer] = c
            if selected != peer && c.acceptWritten { throw stop(.peerRestarted) }
            completeClientIfReady(); return .progress
        }
        mutating func chooseServerPeer(_ peer: W.Nonce) throws {
            if selected != nil && selected != peer { return }
            selected = peer; controls.removeAll { $0.recipient != peer }; try enqueue(.ready, peer)
        }
        mutating func completeClientIfReady() {
            guard let selected, let c = candidates[selected] else { return }
            if c.readyReceived && c.acceptWritten { establish() }
        }
        mutating func establish() {
            ready = true
            if role == .client { controls.removeAll { $0.kind == .offer } }
        }
        var canBufferEarly: Bool {
            guard let selected else { return false }
            if role == .client { return candidates[selected]?.readyReceived == true }
            return flight?.record.kind == .ready && flight?.record.recipient == selected
        }
        mutating func candidate(_ peer: W.Nonce) throws -> Candidate {
            if let existing = candidates[peer] { return existing }
            guard candidates.count < limits.candidates else { throw stop(.candidates) }
            let c = Candidate(); candidates[peer] = c; return c
        }
        mutating func enqueue(_ kind: W.Kind, _ peer: W.Nonce?) throws {
            let request = Control(kind: kind, recipient: peer)
            if controls.contains(request) || flight?.record.kind == kind && flight?.record.recipient == peer { return }
            guard controls.count < limits.candidates + 2 else { throw stop(.controlBudget) }
            controls.append(request)
        }
        mutating func quarantine() throws -> Receive {
            guard quarantined < limits.startupRecords else { throw stop(.staleBudget) }
            quarantined += 1; return .quarantined
        }
        mutating func countStartupRecord() throws {
            guard startupRecords < limits.startupRecords else { throw stop(.startupBudget) }
            startupRecords += 1
        }
        mutating func append(_ bytes: Data) {
            if buffer.isEmpty { buffer = Data(count: limits.receiveBufferBytes) }
            let position = (readPosition + buffered) % buffer.count
            let first = min(bytes.count, buffer.count - position)
            buffer.replaceSubrange(position..<(position + first), with: bytes.prefix(first))
            if first < bytes.count { buffer.replaceSubrange(0..<(bytes.count - first), with: bytes.dropFirst(first)) }
            buffered += bytes.count
        }
        func requireFlight(_ outgoing: Outbound) throws {
            guard flight === outgoing else { throw Failure.wrongDispatch }
        }
        mutating func touch() throws -> Int64 {
            if let terminal { throw terminal }
            let now: Int64
            do { now = try elapsedMillis() } catch { throw fail(error) }
            guard now >= 0 && now >= lastTime else { throw stop(.clock) }
            lastTime = now
            guard ready || now < limits.startupMillis else { throw stop(.timeout) }
            return now
        }
        mutating func fail(_ cause: any Error) -> any Error {
            let first = terminal ?? cause; terminal = first
            ready = false; controls.removeAll(); blockedRecord = nil
            buffer = Data(); buffered = 0; readPosition = 0
            pendingWrite?.ticket.finish(.failed(first)); pendingWrite = nil
            return first // Keep flight until its actual native callback arrives.
        }
        mutating func stop(_ reason: Failure) -> any Error { fail(reason) }
    }
}
