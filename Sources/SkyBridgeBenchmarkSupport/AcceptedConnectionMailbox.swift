import Dispatch
import Network
import os.lock

final class AcceptReservation: Sendable {
    private struct State: Sendable {
        var completed = false
        var timer: DispatchSourceTimer?
    }

    fileprivate let iteration: Int
    private let mailbox: AcceptedConnectionMailbox
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let event = TimedEvent<NWConnection>()

    init(
        iteration: Int,
        mailbox: AcceptedConnectionMailbox
    ) {
        self.iteration = iteration
        self.mailbox = mailbox
    }

    func armTimeout(queue: DispatchQueue, timeoutSeconds: Double) {
        let iteration = self.iteration
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + timeoutSeconds)
        timer.setEventHandler { [weak self, weak mailbox] in
            guard let self, let mailbox else { return }
            mailbox.cancelReservation(
                self,
                iteration: iteration,
                reason: "timed out after \(timeoutSeconds)s"
            )
        }
        timer.activate()

        let retained = state.withLock { state -> Bool in
            guard !state.completed, state.timer == nil else { return false }
            state.timer = timer
            return true
        }
        if !retained {
            timer.cancel()
        }
    }

    func connection() async throws -> NWConnection {
        try await withTaskCancellationHandler {
            if Task.isCancelled {
                mailbox.cancelReservation(self, iteration: iteration, reason: "task cancelled")
            }
            return try await event.value()
        } onCancel: { [mailbox, self, iteration] in
            mailbox.cancelReservation(self, iteration: iteration, reason: "task cancelled")
        }
    }

    func finish(_ result: Result<NWConnection, NetworkLoopbackLifecycleError>) {
        let action = state.withLock { state -> (won: Bool, timer: DispatchSourceTimer?) in
            guard !state.completed else { return (false, nil) }
            state.completed = true
            let timer = state.timer
            state.timer = nil
            return (true, timer)
        }
        guard action.won else { return }
        action.timer?.cancel()
        event.resolve(result)
    }
}

final class AcceptedConnectionMailbox: Sendable {
    private struct InFlightConnection: Sendable {
        let connection: NWConnection
        let iteration: Int
    }

    private struct State: Sendable {
        var waiter: AcceptReservation?
        var inFlight: InFlightConnection?
        var terminalError: NetworkLoopbackLifecycleError?
    }

    private struct OfferAction: Sendable {
        let waiter: AcceptReservation?
        let accepted: NWConnection?
        let connectionsToCancel: [NWConnection]
        let error: NetworkLoopbackLifecycleError?
    }

    private let protocolName: String
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(protocolName: String) {
        self.protocolName = protocolName
    }

    func reserve(
        iteration: Int,
        queue: DispatchQueue,
        timeoutSeconds: Double
    ) throws -> AcceptReservation {
        let reservation = AcceptReservation(
            iteration: iteration,
            mailbox: self
        )
        let immediate = state.withLock { state -> Result<NWConnection?, NetworkLoopbackLifecycleError> in
            if let terminalError = state.terminalError {
                return .failure(terminalError)
            }
            guard state.waiter == nil else {
                return .failure(.invariantViolation(
                    "\(protocolName) has more than one outstanding accept waiter"
                ))
            }
            guard state.inFlight == nil else {
                return .failure(.invariantViolation(
                    "\(protocolName) started iteration \(iteration) before releasing the prior server connection"
                ))
            }
            state.waiter = reservation
            return .success(nil)
        }
        switch immediate {
        case .success(let connection):
            if let connection {
                reservation.finish(.success(connection))
            } else {
                reservation.armTimeout(queue: queue, timeoutSeconds: timeoutSeconds)
            }
            return reservation
        case .failure(let error):
            reservation.finish(.failure(error))
            throw error
        }
    }

    func offer(_ connection: NWConnection) -> NetworkLoopbackLifecycleError? {
        let action = state.withLock { state -> OfferAction in
            if let terminalError = state.terminalError {
                return OfferAction(
                    waiter: nil,
                    accepted: nil,
                    connectionsToCancel: [connection],
                    error: terminalError
                )
            }
            if let inFlight = state.inFlight {
                let error = NetworkLoopbackLifecycleError.accept(
                    protocolName: protocolName,
                    iteration: inFlight.iteration,
                    detail: "capacity 1 exceeded"
                )
                let waiter = state.waiter
                state.waiter = nil
                state.inFlight = nil
                state.terminalError = error
                return OfferAction(
                    waiter: waiter,
                    accepted: nil,
                    connectionsToCancel: [connection, inFlight.connection],
                    error: error
                )
            }
            if let waiter = state.waiter {
                state.waiter = nil
                state.inFlight = InFlightConnection(
                    connection: connection,
                    iteration: waiter.iteration
                )
                return OfferAction(
                    waiter: waiter,
                    accepted: connection,
                    connectionsToCancel: [],
                    error: nil
                )
            }

            let error = NetworkLoopbackLifecycleError.accept(
                protocolName: protocolName,
                iteration: nil,
                detail: "received a connection without an active reservation"
            )
            state.terminalError = error
            return OfferAction(
                waiter: nil,
                accepted: nil,
                connectionsToCancel: [connection],
                error: error
            )
        }
        action.connectionsToCancel.forEach { $0.cancel() }
        if let waiter = action.waiter {
            if let accepted = action.accepted {
                waiter.finish(.success(accepted))
            } else if let error = action.error {
                waiter.finish(.failure(error))
            }
        }
        return action.error
    }

    func release(_ connection: NWConnection, iteration: Int) throws {
        let error = state.withLock { state -> NetworkLoopbackLifecycleError? in
            guard let inFlight = state.inFlight else {
                return .invariantViolation(
                    "\(protocolName) has no in-flight server connection to release on iteration \(iteration)"
                )
            }
            guard inFlight.connection === connection else {
                return .invariantViolation(
                    "\(protocolName) attempted to release the wrong server connection on iteration \(iteration)"
                )
            }
            guard inFlight.iteration == iteration else {
                return .invariantViolation(
                    "\(protocolName) attempted to release iteration \(iteration) while iteration \(inFlight.iteration) is active"
                )
            }
            state.inFlight = nil
            return nil
        }
        if let error { throw error }
    }

    func cancelReservation(
        _ reservation: AcceptReservation,
        iteration: Int,
        reason: String
    ) {
        let action = state.withLock { state -> (AcceptReservation?, NetworkLoopbackLifecycleError?) in
            guard let waiter = state.waiter, waiter === reservation else {
                return (nil, nil)
            }
            let error = NetworkLoopbackLifecycleError.accept(
                protocolName: protocolName,
                iteration: iteration,
                detail: reason
            )
            state.waiter = nil
            state.terminalError = error
            return (waiter, error)
        }
        if let waiter = action.0, let error = action.1 {
            waiter.finish(.failure(error))
        }
    }

    func finish(_ error: NetworkLoopbackLifecycleError) {
        let action = state.withLock { state -> (
            waiter: AcceptReservation?,
            connections: [NWConnection],
            error: NetworkLoopbackLifecycleError
        ) in
            let terminalError = state.terminalError ?? error
            var connections: [NWConnection] = []
            if let inFlight = state.inFlight { connections.append(inFlight.connection) }
            let waiter = state.waiter
            state.waiter = nil
            state.inFlight = nil
            state.terminalError = terminalError
            return (waiter, connections, terminalError)
        }
        action.connections.forEach { $0.cancel() }
        action.waiter?.finish(.failure(action.error))
    }
}
