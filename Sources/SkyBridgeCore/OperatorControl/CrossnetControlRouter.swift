import Foundation

public struct CrossnetControlRuntime: Sendable {
    public let hello: @Sendable () async -> CrossnetControlHelloResult
    public let status: @Sendable () async -> CrossnetControlStatusResult
    public let settingsSnapshot: @Sendable () async -> CrossnetControlSettingsSnapshotResult
    /// Applies one allowlisted setting to the live Mac app runtime and reports the
    /// value read back afterwards.
    ///
    /// Defaults to ``unavailableSettingsMutation``, so a runtime that does not
    /// explicitly wire mutation up keeps the previous `method_not_enabled`
    /// behaviour instead of silently gaining write authority.
    public let applySetting: @Sendable (CrossnetControlSettingsMutationRequest) async throws
        -> CrossnetControlSettingsMutationResult

    public init(
        hello: @escaping @Sendable () async -> CrossnetControlHelloResult,
        status: @escaping @Sendable () async -> CrossnetControlStatusResult,
        settingsSnapshot: @escaping @Sendable () async -> CrossnetControlSettingsSnapshotResult,
        applySetting: @escaping @Sendable (CrossnetControlSettingsMutationRequest) async throws
            -> CrossnetControlSettingsMutationResult = CrossnetControlRuntime
            .unavailableSettingsMutation
    ) {
        self.hello = hello
        self.status = status
        self.settingsSnapshot = settingsSnapshot
        self.applySetting = applySetting
    }

    /// Fail-closed default mutation handler.
    public static let unavailableSettingsMutation:
        @Sendable (CrossnetControlSettingsMutationRequest) async throws
        -> CrossnetControlSettingsMutationResult = { _ in
            throw CrossnetControlFailure.methodNotEnabled
        }
}

public struct CrossnetControlRouter: Sendable {
    private let runtime: CrossnetControlRuntime

    public init(runtime: CrossnetControlRuntime) {
        self.runtime = runtime
    }

    public func handleLine(_ line: Data) async -> Data {
        let request: CrossnetControlRequest
        do {
            request = try CrossnetControlWire.decodeRequest(line: line)
        } catch let failure as CrossnetControlFailure {
            return CrossnetControlWire.failureData(id: nil, failure: failure)
        } catch {
            return CrossnetControlWire.failureData(
                id: nil,
                failure: .malformedRequest("invalid JSON request")
            )
        }

        do {
            switch request.method {
            case "crossnet.hello":
                return try CrossnetControlWire.successData(
                    id: request.id,
                    result: await runtime.hello()
                )
            case "crossnet.status":
                if request.params.bool("watch") == true {
                    throw CrossnetControlFailure.watchNotSupported
                }
                return try CrossnetControlWire.successData(
                    id: request.id,
                    result: await runtime.status()
                )
            case "crossnet.settings.snapshot":
                let snapshot = try CrossnetControlSettingsProjectionPolicy.validate(
                    await runtime.settingsSnapshot()
                )
                return try CrossnetControlWire.successData(
                    id: request.id,
                    result: snapshot
                )
            case "crossnet.settings.set":
                try Self.requireAuthenticatedOperatorContext(await runtime.hello())
                let mutation = try CrossnetControlSettingsMutationPolicy.parse(
                    params: request.params
                )
                let applied = try CrossnetControlSettingsMutationPolicy.validate(
                    try await runtime.applySetting(mutation),
                    request: mutation
                )
                return try CrossnetControlWire.successData(
                    id: request.id,
                    result: applied
                )
            case "crossnet.connect":
                _ = try CrossnetControlWire.strictConnectionCode(request.params.string("code"))
                try Self.requireAuthenticatedOperatorContext(await runtime.hello())
                throw CrossnetControlFailure.methodNotEnabled
            case "crossnet.host":
                _ = try CrossnetControlHostLeaseMode.parse(params: request.params)
                try Self.requireAuthenticatedOperatorContext(await runtime.hello())
                throw CrossnetControlFailure.methodNotEnabled
            case "crossnet.disconnect":
                try Self.requireAuthenticatedOperatorContext(await runtime.hello())
                throw CrossnetControlFailure.methodNotEnabled
            default:
                throw CrossnetControlFailure.methodNotFound
            }
        } catch let failure as CrossnetControlFailure {
            return CrossnetControlWire.failureData(id: request.id, failure: failure)
        } catch {
            return CrossnetControlWire.failureData(
                id: request.id,
                failure: .internalError("failed to encode response")
            )
        }
    }

    private static func requireAuthenticatedOperatorContext(_ hello: CrossnetControlHelloResult) throws {
        guard hello.authLoaded else {
            throw CrossnetControlFailure.authRequired
        }
        guard hello.tenantBound else {
            throw CrossnetControlFailure.tenantRequired
        }
    }
}
