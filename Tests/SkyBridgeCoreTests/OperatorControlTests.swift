import XCTest
@testable import SkyBridgeCore

#if os(macOS)
import Darwin
#endif

final class OperatorControlRouterTests: XCTestCase {
    func testHelloReturnsProtocolAndAuthState() async throws {
        let router = CrossnetControlRouter(runtime: operatorControlTestRuntime())

        let response: WireResponse<CrossnetControlHelloResult> = try await route(
            router,
            #"{"v":1,"id":"hello-1","method":"crossnet.hello"}"#
        )

        XCTAssertEqual(response.v, 1)
        XCTAssertEqual(response.id, "hello-1")
        XCTAssertEqual(response.ok, true)
        XCTAssertEqual(response.result?.engineVersion, "test-engine")
        XCTAssertEqual(response.result?.proto, 1)
        XCTAssertEqual(response.result?.authLoaded, true)
        XCTAssertEqual(response.result?.tenantBound, true)
        XCTAssertNil(response.error)
    }

    func testStatusReturnsExplicitReadOnlyProjection() async throws {
        let router = CrossnetControlRouter(runtime: operatorControlTestRuntime())

        let response: WireResponse<CrossnetControlStatusResult> = try await route(
            router,
            #"{"v":1,"id":"status-1","method":"crossnet.status"}"#
        )

        XCTAssertEqual(response.ok, true)
        XCTAssertEqual(response.result?.connectionStatus, "connected")
        XCTAssertEqual(response.result?.readiness, "handshake_complete")
        XCTAssertEqual(response.result?.sessionPresent, true)
        XCTAssertEqual(response.result?.sessionRef, CrossnetControlSessionRef.redacted("raw-session-secret"))
        XCTAssertEqual(response.result?.suite, "ML-KEM-768+ECDH")
        XCTAssertEqual(response.result?.signalingHealth, "healthy")
        XCTAssertNil(response.result?.failureCode)
        XCTAssertNil(response.result?.failureClass)
    }

    func testStatusReportsAuthTenantReadOnlyStateWithoutBlocking() async throws {
        let router = CrossnetControlRouter(runtime: operatorControlTestRuntime(
            authLoaded: false,
            tenantBound: false
        ))

        let response: WireResponse<CrossnetControlStatusResult> = try await route(
            router,
            #"{"v":1,"id":"status-auth-state","method":"crossnet.status"}"#
        )

        XCTAssertEqual(response.ok, true)
        XCTAssertEqual(response.result?.authLoaded, false)
        XCTAssertEqual(response.result?.tenantBound, false)
        XCTAssertEqual(response.result?.failureCode, .authRequired)
        XCTAssertEqual(response.result?.failureClass, .operatorPrecondition)
        XCTAssertNil(response.error)
    }

    func testSettingsSnapshotReturnsAllowlistedReadOnlyMacProjection() async throws {
        let router = CrossnetControlRouter(runtime: operatorControlTestRuntime())

        let response: WireResponse<CrossnetControlSettingsSnapshotResult> = try await route(
            router,
            #"{"v":1,"id":"settings-1","method":"crossnet.settings.snapshot"}"#
        )

        XCTAssertEqual(response.ok, true)
        XCTAssertEqual(response.result?.runtimeTarget, "mac_app_runtime")
        XCTAssertEqual(response.result?.controlEffect, "read_only")
        let settings = try XCTUnwrap(response.result?.settings)
        XCTAssertEqual(
            settings.map(\.id),
            [
                "logging.verbose",
                "logging.level",
                "ui.show_realtime_fps",
                "ui.top_bar_ip_location",
                "ui.top_bar_network_speed",
                "ui.top_bar_network_latency",
                "pqc.prefer_xwing_hybrid",
                "pqc.signature_algorithm"
            ]
        )
        XCTAssertTrue(settings.allSatisfy { $0.mutable == false })
        XCTAssertEqual(settings.first { $0.id == "logging.verbose" }?.value, .bool(true))
        XCTAssertEqual(settings.first { $0.id == "logging.level" }?.value, .string("Debug"))
        XCTAssertEqual(
            settings.first { $0.id == "pqc.prefer_xwing_hybrid" }?.note,
            "policy_preference_not_runtime_proof"
        )
        XCTAssertFalse(settings.contains { $0.id.localizedCaseInsensitiveContains("path") })
        XCTAssertFalse(settings.contains { $0.id.localizedCaseInsensitiveContains("token") })
        XCTAssertFalse(settings.contains { $0.id.localizedCaseInsensitiveContains("session") })
    }

    func testSettingsSnapshotRejectsNonMacRuntimeProjectionWithoutEchoingRuntime() async throws {
        let snapshot = CrossnetControlSettingsSnapshotResult(
            runtimeTarget: "ios_app_runtime",
            controlEffect: "read_only",
            settings: [
                operatorControlSetting(
                    id: "logging.verbose",
                    valueType: "bool",
                    value: .bool(true),
                    mutable: false
                )
            ]
        )

        try await assertSettingsProjectionFailure(
            snapshot,
            reason: "settings_projection_invalid_runtime",
            absentFragments: ["ios_app_runtime"]
        )
    }

    func testSettingsSnapshotRejectsMutableAndNonAllowlistedProjectionWithoutEchoingValues() async throws {
        let mutableSnapshot = CrossnetControlSettingsSnapshotResult(settings: [
            operatorControlSetting(
                id: "logging.verbose",
                valueType: "bool",
                value: .bool(true),
                mutable: true
            )
        ])
        try await assertSettingsProjectionFailure(
            mutableSnapshot,
            reason: "settings_projection_mutable",
            absentFragments: ["logging.verbose"]
        )

        let secretValue = "session-token-secret"
        let nonAllowlistedSnapshot = CrossnetControlSettingsSnapshotResult(settings: [
            operatorControlSetting(
                id: "auth.token",
                valueType: "string",
                value: .string(secretValue),
                mutable: false
            )
        ])
        try await assertSettingsProjectionFailure(
            nonAllowlistedSnapshot,
            reason: "settings_projection_not_allowlisted",
            absentFragments: ["auth.token", secretValue]
        )
    }

    func testSettingsSnapshotRejectsDuplicateIDsAndValueTypeMismatch() async throws {
        let duplicateSnapshot = CrossnetControlSettingsSnapshotResult(settings: [
            operatorControlSetting(
                id: "logging.verbose",
                valueType: "bool",
                value: .bool(true),
                mutable: false
            ),
            operatorControlSetting(
                id: "logging.verbose",
                valueType: "bool",
                value: .bool(false),
                mutable: false
            )
        ])
        try await assertSettingsProjectionFailure(
            duplicateSnapshot,
            reason: "settings_projection_duplicate_id",
            absentFragments: ["logging.verbose"]
        )

        let mismatchedSnapshot = CrossnetControlSettingsSnapshotResult(settings: [
            operatorControlSetting(
                id: "logging.verbose",
                valueType: "string",
                value: .bool(true),
                mutable: false
            )
        ])
        try await assertSettingsProjectionFailure(
            mismatchedSnapshot,
            reason: "settings_projection_value_type_mismatch",
            absentFragments: ["logging.verbose"]
        )
    }

    func testSettingsSnapshotRejectsInvalidStringValueDomainsWithoutEchoingValues() async throws {
        let invalidLogLevel = "Debug\nsession-token-secret"
        let invalidLogLevelSnapshot = CrossnetControlSettingsSnapshotResult(settings: [
            operatorControlSetting(
                id: "logging.level",
                valueType: "string",
                value: .string(invalidLogLevel),
                mutable: false
            )
        ])
        try await assertSettingsProjectionFailure(
            invalidLogLevelSnapshot,
            reason: "settings_projection_invalid_value",
            absentFragments: [invalidLogLevel, "session-token-secret"]
        )

        let invalidSignatureAlgorithm = "ML-DSA-65\nsession-token-secret"
        let invalidSignatureSnapshot = CrossnetControlSettingsSnapshotResult(settings: [
            operatorControlSetting(
                id: "pqc.signature_algorithm",
                valueType: "string",
                value: .string(invalidSignatureAlgorithm),
                mutable: false,
                note: "policy_preference_not_runtime_proof"
            )
        ])
        try await assertSettingsProjectionFailure(
            invalidSignatureSnapshot,
            reason: "settings_projection_invalid_value",
            absentFragments: [invalidSignatureAlgorithm, "session-token-secret"]
        )

        let invalidNoteSnapshot = CrossnetControlSettingsSnapshotResult(settings: [
            operatorControlSetting(
                id: "pqc.signature_algorithm",
                valueType: "string",
                value: .string("ML-DSA-65"),
                mutable: false,
                note: "session-token-secret"
            )
        ])
        try await assertSettingsProjectionFailure(
            invalidNoteSnapshot,
            reason: "settings_projection_invalid_note",
            absentFragments: ["session-token-secret"]
        )
    }

    func testSettingsMutationRequiresAuthTenantAndStaysDisabled() async throws {
        let missingAuthRouter = CrossnetControlRouter(runtime: operatorControlTestRuntime(
            authLoaded: false,
            tenantBound: true
        ))
        let missingAuthResponse: WireResponse<NoResult> = try await route(
            missingAuthRouter,
            #"{"v":1,"id":"settings-auth","method":"crossnet.settings.set","params":{"id":"logging.verbose","value":false}}"#
        )
        XCTAssertEqual(missingAuthResponse.ok, false)
        XCTAssertEqual(missingAuthResponse.error?.code, "auth_required")

        let missingTenantRouter = CrossnetControlRouter(runtime: operatorControlTestRuntime(
            authLoaded: true,
            tenantBound: false
        ))
        let missingTenantResponse: WireResponse<NoResult> = try await route(
            missingTenantRouter,
            #"{"v":1,"id":"settings-tenant","method":"crossnet.settings.set","params":{"id":"logging.verbose","value":false}}"#
        )
        XCTAssertEqual(missingTenantResponse.ok, false)
        XCTAssertEqual(missingTenantResponse.error?.code, "tenant_required")

        let enabledContextRouter = CrossnetControlRouter(runtime: operatorControlTestRuntime())
        let disabledResponse: WireResponse<NoResult> = try await route(
            enabledContextRouter,
            #"{"v":1,"id":"settings-disabled","method":"crossnet.settings.set","params":{"id":"logging.verbose","value":false}}"#
        )
        XCTAssertEqual(disabledResponse.ok, false)
        XCTAssertEqual(disabledResponse.error?.code, "method_not_enabled")
    }

    func testSettingsMutationAppliesAllowlistedSettingAndReportsRuntimeReadBack() async throws {
        let router = CrossnetControlRouter(runtime: operatorControlTestRuntime(
            applySetting: operatorControlEchoingSettingsMutation()
        ))

        let boolResponse: WireResponse<CrossnetControlSettingsMutationResult> = try await route(
            router,
            #"{"v":1,"id":"set-bool","method":"crossnet.settings.set","params":{"id":"logging.verbose","value":true}}"#
        )
        XCTAssertEqual(boolResponse.ok, true)
        XCTAssertEqual(boolResponse.error?.code, nil)
        XCTAssertEqual(boolResponse.result?.id, "logging.verbose")
        XCTAssertEqual(boolResponse.result?.runtimeTarget, "mac_app_runtime")
        XCTAssertEqual(boolResponse.result?.controlEffect, "mac_runtime_mutation")
        XCTAssertEqual(boolResponse.result?.valueType, "bool")
        XCTAssertEqual(boolResponse.result?.observedValue, .bool(true))
        XCTAssertEqual(boolResponse.result?.runtimeApplied, true)

        // Operator-supplied casing is normalized so the read-back comparison is
        // meaningful rather than a string-equality accident.
        let levelResponse: WireResponse<CrossnetControlSettingsMutationResult> = try await route(
            router,
            #"{"v":1,"id":"set-level","method":"crossnet.settings.set","params":{"id":"logging.level","value":"warn"}}"#
        )
        XCTAssertEqual(levelResponse.ok, true)
        XCTAssertEqual(levelResponse.result?.observedValue, .string("Warning"))
    }

    func testSettingsMutationFailsClosedWhenRuntimeReadBackDiverges() async throws {
        let divergentRouter = CrossnetControlRouter(runtime: operatorControlTestRuntime(
            applySetting: operatorControlEchoingSettingsMutation(observedOverride: .bool(false))
        ))
        let divergentResponse: WireResponse<NoResult> = try await route(
            divergentRouter,
            #"{"v":1,"id":"set-drift","method":"crossnet.settings.set","params":{"id":"logging.verbose","value":true}}"#
        )
        XCTAssertEqual(divergentResponse.ok, false)
        XCTAssertEqual(divergentResponse.error?.code, "setting_runtime_apply_failed")

        let unappliedRouter = CrossnetControlRouter(runtime: operatorControlTestRuntime(
            applySetting: operatorControlEchoingSettingsMutation(runtimeApplied: false)
        ))
        let unappliedResponse: WireResponse<NoResult> = try await route(
            unappliedRouter,
            #"{"v":1,"id":"set-unapplied","method":"crossnet.settings.set","params":{"id":"logging.verbose","value":true}}"#
        )
        XCTAssertEqual(unappliedResponse.ok, false)
        XCTAssertEqual(unappliedResponse.error?.code, "setting_runtime_apply_failed")
    }

    func testSettingsMutationRefusesImmutableUnknownAndOutOfDomainValues() async throws {
        let router = CrossnetControlRouter(runtime: operatorControlTestRuntime(
            applySetting: operatorControlEchoingSettingsMutation()
        ))

        // Readable-but-immutable must be distinguishable from unknown, and must
        // not echo the attempted value.
        let immutableData = try await routeData(
            router,
            #"{"v":1,"id":"set-pqc","method":"crossnet.settings.set","params":{"id":"pqc.signature_algorithm","value":"ML-DSA-87"}}"#
        )
        let immutable = try JSONDecoder().decode(WireResponse<NoResult>.self, from: immutableData)
        XCTAssertEqual(immutable.error?.code, "setting_immutable")
        let immutableText = String(decoding: immutableData, as: UTF8.self)
        XCTAssertTrue(immutableText.contains("peer re-pinning"), immutableText)
        XCTAssertFalse(immutableText.contains("ML-DSA-87"), immutableText)

        let unknown: WireResponse<NoResult> = try await route(
            router,
            #"{"v":1,"id":"set-unknown","method":"crossnet.settings.set","params":{"id":"logging.nope","value":true}}"#
        )
        XCTAssertEqual(unknown.error?.code, "setting_not_found")

        // Wrong value kind for a bool setting.
        let wrongType: WireResponse<NoResult> = try await route(
            router,
            #"{"v":1,"id":"set-wrong-type","method":"crossnet.settings.set","params":{"id":"logging.verbose","value":"yes"}}"#
        )
        XCTAssertEqual(wrongType.error?.code, "setting_invalid_value")

        // Out-of-domain logging level.
        let badLevel: WireResponse<NoResult> = try await route(
            router,
            #"{"v":1,"id":"set-bad-level","method":"crossnet.settings.set","params":{"id":"logging.level","value":"loud"}}"#
        )
        XCTAssertEqual(badLevel.error?.code, "setting_invalid_value")

        // Auth is still checked before any of the above.
        let unauthenticated = CrossnetControlRouter(runtime: operatorControlTestRuntime(
            authLoaded: false,
            applySetting: operatorControlEchoingSettingsMutation()
        ))
        let unauthenticatedResponse: WireResponse<NoResult> = try await route(
            unauthenticated,
            #"{"v":1,"id":"set-noauth","method":"crossnet.settings.set","params":{"id":"logging.verbose","value":true}}"#
        )
        XCTAssertEqual(unauthenticatedResponse.error?.code, "auth_required")
    }

    func testSettingsMutableAllowlistIsAStrictSubsetOfTheReadableProjection() {
        XCTAssertTrue(
            CrossnetControlSettingsMutationPolicy.mutableSettingIDs
                .isStrictSubset(of: CrossnetControlSettingsProjectionPolicy.allowedSettingIDs),
            "a writable id that is not readable would be an unobservable mutation"
        )
        XCTAssertTrue(
            CrossnetControlSettingsMutationPolicy.mutableSettingIDs
                .isDisjoint(with: CrossnetControlSettingsMutationPolicy.protocolIdentityBoundSettingIDs),
            "protocol identity settings must never be directly writable"
        )
        XCTAssertEqual(
            CrossnetControlSettingsMutationPolicy.mutableSettingIDs
                .union(CrossnetControlSettingsMutationPolicy.protocolIdentityBoundSettingIDs),
            CrossnetControlSettingsProjectionPolicy.allowedSettingIDs,
            "every readable id must be explicitly classified as mutable or protocol-identity bound"
        )
    }

    func testStatusWatchFailsClosedUntilStreamingIsImplemented() async throws {
        let router = CrossnetControlRouter(runtime: operatorControlTestRuntime())

        let response: WireResponse<NoResult> = try await route(
            router,
            #"{"v":1,"id":"watch-1","method":"crossnet.status","params":{"watch":true}}"#
        )

        XCTAssertEqual(response.ok, false)
        XCTAssertEqual(response.id, "watch-1")
        XCTAssertEqual(response.error?.code, "watch_not_supported")
        XCTAssertNil(response.result)
    }

    func testMutatingMethodsAreNotEnabledInReadOnlySlice() async throws {
        let router = CrossnetControlRouter(runtime: operatorControlTestRuntime())

        let hostResponse: WireResponse<NoResult> = try await route(
            router,
            #"{"v":1,"id":"host-1","method":"crossnet.host"}"#
        )
        XCTAssertEqual(hostResponse.error?.code, "method_not_enabled")

        let disconnectResponse: WireResponse<NoResult> = try await route(
            router,
            #"{"v":1,"id":"disconnect-1","method":"crossnet.disconnect"}"#
        )
        XCTAssertEqual(disconnectResponse.error?.code, "method_not_enabled")
    }

    func testHostValidatesLeaseBeforeReportingDisabledMethod() async throws {
        let router = CrossnetControlRouter(runtime: operatorControlTestRuntime())

        let invalidResponse: WireResponse<NoResult> = try await route(
            router,
            #"{"v":1,"id":"host-bad-lease","method":"crossnet.host","params":{"lease_mode":"forever"}}"#
        )
        XCTAssertEqual(invalidResponse.ok, false)
        XCTAssertEqual(invalidResponse.id, "host-bad-lease")
        XCTAssertEqual(invalidResponse.error?.code, "invalid_lease_mode")

        let nonStringResponse: WireResponse<NoResult> = try await route(
            router,
            #"{"v":1,"id":"host-non-string-lease","method":"crossnet.host","params":{"lease_mode":1}}"#
        )
        XCTAssertEqual(nonStringResponse.ok, false)
        XCTAssertEqual(nonStringResponse.error?.code, "invalid_lease_mode")

        let longLeaseResponse: WireResponse<NoResult> = try await route(
            router,
            #"{"v":1,"id":"host-long-disabled","method":"crossnet.host","params":{"lease_mode":"long"}}"#
        )
        XCTAssertEqual(longLeaseResponse.ok, false)
        XCTAssertEqual(longLeaseResponse.error?.code, "method_not_enabled")
    }

    func testHostRequiresMacAppAuthAndTenantBeforeMutation() async throws {
        let missingAuthRouter = CrossnetControlRouter(runtime: operatorControlTestRuntime(
            authLoaded: false,
            tenantBound: true
        ))
        let missingAuthResponse: WireResponse<NoResult> = try await route(
            missingAuthRouter,
            #"{"v":1,"id":"host-auth","method":"crossnet.host","params":{"lease_mode":"short"}}"#
        )
        XCTAssertEqual(missingAuthResponse.ok, false)
        XCTAssertEqual(missingAuthResponse.error?.code, "auth_required")

        let missingTenantRouter = CrossnetControlRouter(runtime: operatorControlTestRuntime(
            authLoaded: true,
            tenantBound: false
        ))
        let missingTenantResponse: WireResponse<NoResult> = try await route(
            missingTenantRouter,
            #"{"v":1,"id":"host-tenant","method":"crossnet.host","params":{"lease_mode":"short"}}"#
        )
        XCTAssertEqual(missingTenantResponse.ok, false)
        XCTAssertEqual(missingTenantResponse.error?.code, "tenant_required")
    }

    func testConnectValidatesCodeBeforeReportingDisabledMethod() async throws {
        let router = CrossnetControlRouter(runtime: operatorControlTestRuntime())

        let invalidResponse: WireResponse<NoResult> = try await route(
            router,
            #"{"v":1,"id":"connect-bad","method":"crossnet.connect","params":{"code":"abc123"}}"#
        )
        XCTAssertEqual(invalidResponse.error?.code, "invalid_code")

        let disabledResponse: WireResponse<NoResult> = try await route(
            router,
            #"{"v":1,"id":"connect-disabled","method":"crossnet.connect","params":{"code":"ABCDEFGH"}}"#
        )
        XCTAssertEqual(disabledResponse.error?.code, "method_not_enabled")
    }

    func testConnectAndDisconnectRequireMacAppAuthAndTenantBeforeMutation() async throws {
        let missingAuthRouter = CrossnetControlRouter(runtime: operatorControlTestRuntime(
            authLoaded: false,
            tenantBound: true
        ))
        let invalidCodeResponse: WireResponse<NoResult> = try await route(
            missingAuthRouter,
            #"{"v":1,"id":"connect-invalid-before-auth","method":"crossnet.connect","params":{"code":"abc123"}}"#
        )
        XCTAssertEqual(invalidCodeResponse.error?.code, "invalid_code")

        let missingAuthConnectResponse: WireResponse<NoResult> = try await route(
            missingAuthRouter,
            #"{"v":1,"id":"connect-auth","method":"crossnet.connect","params":{"code":"ABCDEFGH"}}"#
        )
        XCTAssertEqual(missingAuthConnectResponse.error?.code, "auth_required")

        let missingAuthDisconnectResponse: WireResponse<NoResult> = try await route(
            missingAuthRouter,
            #"{"v":1,"id":"disconnect-auth","method":"crossnet.disconnect"}"#
        )
        XCTAssertEqual(missingAuthDisconnectResponse.error?.code, "auth_required")

        let missingTenantRouter = CrossnetControlRouter(runtime: operatorControlTestRuntime(
            authLoaded: true,
            tenantBound: false
        ))
        let missingTenantConnectResponse: WireResponse<NoResult> = try await route(
            missingTenantRouter,
            #"{"v":1,"id":"connect-tenant","method":"crossnet.connect","params":{"code":"ABCDEFGH"}}"#
        )
        XCTAssertEqual(missingTenantConnectResponse.error?.code, "tenant_required")

        let missingTenantDisconnectResponse: WireResponse<NoResult> = try await route(
            missingTenantRouter,
            #"{"v":1,"id":"disconnect-tenant","method":"crossnet.disconnect"}"#
        )
        XCTAssertEqual(missingTenantDisconnectResponse.error?.code, "tenant_required")
    }

    func testMalformedRequestAndUnknownMethodReturnMachineReadableErrors() async throws {
        let router = CrossnetControlRouter(runtime: operatorControlTestRuntime())

        let malformedResponse: WireResponse<NoResult> = try await route(
            router,
            #"{"v":2,"id":"bad-version","method":"crossnet.hello"}"#
        )
        XCTAssertEqual(malformedResponse.ok, false)
        XCTAssertEqual(malformedResponse.error?.code, "protocol_version_mismatch")

        let unknownResponse: WireResponse<NoResult> = try await route(
            router,
            #"{"v":1,"id":"unknown-1","method":"crossnet.reboot"}"#
        )
        XCTAssertEqual(unknownResponse.ok, false)
        XCTAssertEqual(unknownResponse.id, "unknown-1")
        XCTAssertEqual(unknownResponse.error?.code, "method_not_found")
    }

    func testSessionRefRedactsRawIdentifier() {
        let redacted = CrossnetControlSessionRef.redacted("raw-session-secret")

        XCTAssertTrue(redacted.hasPrefix("sha256:"))
        XCTAssertFalse(redacted.contains("raw-session-secret"))
        XCTAssertEqual(redacted.count, "sha256:".count + 16)
    }

    func testErrorResponsesDoNotEchoSensitiveRequestParameters() async throws {
        let router = CrossnetControlRouter(runtime: operatorControlTestRuntime())
        let sensitiveValue = "session-token-secret"
        let invalidConnectData = await router.handleLine(Data(
            #"{"v":1,"id":"connect-redaction","method":"crossnet.connect","params":{"code":"session-token-secret"}}"#.utf8
        ))
        let invalidConnectResponse = try JSONDecoder().decode(WireResponse<NoResult>.self, from: invalidConnectData)

        XCTAssertEqual(invalidConnectResponse.ok, false)
        XCTAssertEqual(invalidConnectResponse.error?.code, "invalid_code")
        XCTAssertFalse(String(decoding: invalidConnectData, as: UTF8.self).contains(sensitiveValue))

        let sensitivePath = "/tmp/session-token-secret"
        let settingsMutationData = await router.handleLine(Data(
            #"{"v":1,"id":"settings-redaction","method":"crossnet.settings.set","params":{"id":"/tmp/session-token-secret","value":"session-token-secret"}}"#.utf8
        ))
        let settingsMutationResponse = try JSONDecoder().decode(WireResponse<NoResult>.self, from: settingsMutationData)
        let settingsMutationRawResponse = String(decoding: settingsMutationData, as: UTF8.self)

        XCTAssertEqual(settingsMutationResponse.ok, false)
        // A path-shaped id is simply not an allowlisted setting. The mutation
        // handler is enabled now, so the honest rejection is setting_not_found
        // rather than method_not_enabled — and it must still not echo the id or
        // the attempted value.
        XCTAssertEqual(settingsMutationResponse.error?.code, "setting_not_found")
        XCTAssertFalse(settingsMutationRawResponse.contains(sensitivePath))
        XCTAssertFalse(settingsMutationRawResponse.contains(sensitiveValue))
    }

    private func route<Result: Decodable>(
        _ router: CrossnetControlRouter,
        _ request: String
    ) async throws -> WireResponse<Result> {
        let data = try await routeData(router, request)
        return try JSONDecoder().decode(WireResponse<Result>.self, from: data)
    }

    /// Returns the raw response bytes, for assertions about what the wire must
    /// *not* contain.
    private func routeData(
        _ router: CrossnetControlRouter,
        _ request: String
    ) async throws -> Data {
        await router.handleLine(Data(request.utf8))
    }

    private func assertSettingsProjectionFailure(
        _ snapshot: CrossnetControlSettingsSnapshotResult,
        reason: String,
        absentFragments: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let router = CrossnetControlRouter(runtime: operatorControlTestRuntime(settingsSnapshot: snapshot))
        let data = await router.handleLine(Data(
            #"{"v":1,"id":"settings-projection","method":"crossnet.settings.snapshot"}"#.utf8
        ))
        let response = try JSONDecoder().decode(WireResponse<NoResult>.self, from: data)
        let rawResponse = String(decoding: data, as: UTF8.self)

        XCTAssertEqual(response.ok, false, file: file, line: line)
        XCTAssertEqual(response.id, "settings-projection", file: file, line: line)
        XCTAssertEqual(response.error?.code, "internal", file: file, line: line)
        XCTAssertTrue(response.error?.message.contains(reason) ?? false, file: file, line: line)
        for fragment in absentFragments {
            XCTAssertFalse(rawResponse.contains(fragment), file: file, line: line)
        }
    }
}

final class OperatorControlRuntimeProjectionTests: XCTestCase {
    func testHelloProjectionUsesAuthStateWithoutRuntimeReads() {
        let result = CrossnetControlRuntimeProjection.hello(
            engineVersion: "1.2.3+456",
            auth: CrossnetControlAuthState(authLoaded: true, tenantBound: false)
        )

        XCTAssertEqual(result.engineVersion, "1.2.3+456")
        XCTAssertEqual(result.proto, 1)
        XCTAssertEqual(result.authLoaded, true)
        XCTAssertEqual(result.tenantBound, false)
    }

    func testStatusProjectionRedactsHandshakeSessionAndMapsHealth() {
        let rawSessionID = "raw-session-secret"

        let result = CrossnetControlRuntimeProjection.status(
            auth: CrossnetControlAuthState(authLoaded: true, tenantBound: false),
            connection: CrossnetControlConnectionRuntimeSnapshot(
                connectionStatus: .connected,
                readiness: .handshakeComplete(
                    sessionId: rawSessionID,
                    negotiatedSuite: "ML-KEM-768+ECDH"
                ),
                activeSessionSnapshot: nil,
                currentConnectionID: nil,
                signalingHealth: .degradedRecoverable
            )
        )

        XCTAssertEqual(result.connectionStatus, "connected")
        XCTAssertEqual(result.readiness, "handshake_complete")
        XCTAssertEqual(result.sessionPresent, true)
        XCTAssertEqual(result.sessionRef, CrossnetControlSessionRef.redacted(rawSessionID))
        XCTAssertFalse(result.sessionRef?.contains(rawSessionID) ?? true)
        XCTAssertEqual(result.suite, "ML-KEM-768+ECDH")
        XCTAssertEqual(result.signalingHealth, "degraded_recoverable")
        XCTAssertEqual(result.authLoaded, true)
        XCTAssertEqual(result.tenantBound, false)
    }

    func testStatusProjectionHandshakeSuiteWinsOverStaleSnapshotSuite() {
        let staleSnapshot = ActiveSessionSnapshot(
            sessionId: "stale-session-secret",
            source: .reused,
            phase: .handshakeComplete,
            negotiatedSuite: "stale-suite"
        )

        let result = CrossnetControlRuntimeProjection.status(
            auth: CrossnetControlAuthState(authLoaded: true, tenantBound: true),
            connection: CrossnetControlConnectionRuntimeSnapshot(
                connectionStatus: .connected,
                readiness: .handshakeComplete(
                    sessionId: "active-session-secret",
                    negotiatedSuite: "ML-KEM-768+ECDH"
                ),
                activeSessionSnapshot: staleSnapshot,
                currentConnectionID: nil,
                signalingHealth: .healthy
            )
        )

        XCTAssertEqual(result.suite, "ML-KEM-768+ECDH")
        XCTAssertFalse(result.sessionRef?.contains("active-session-secret") ?? true)
        XCTAssertFalse(result.sessionRef?.contains("stale-session-secret") ?? true)
    }

    func testStatusProjectionReportsWaitingPresenceWithoutRawCode() {
        let result = CrossnetControlRuntimeProjection.status(
            auth: CrossnetControlAuthState(authLoaded: false, tenantBound: false),
            connection: CrossnetControlConnectionRuntimeSnapshot(
                connectionStatus: .waiting(code: "ABCDEFGH"),
                readiness: .idle,
                activeSessionSnapshot: nil,
                currentConnectionID: nil,
                signalingHealth: .degradedFatal
            )
        )

        XCTAssertEqual(result.connectionStatus, "waiting")
        XCTAssertEqual(result.readiness, "idle")
        XCTAssertEqual(result.sessionPresent, true)
        XCTAssertNil(result.sessionRef)
        XCTAssertNil(result.suite)
        XCTAssertEqual(result.signalingHealth, "degraded_fatal")
        XCTAssertEqual(result.authLoaded, false)
        XCTAssertEqual(result.tenantBound, false)
    }

    func testStatusProjectionFailedStateDoesNotExposeFailureReason() {
        let secretFailure = "session-token-secret"

        let result = CrossnetControlRuntimeProjection.status(
            auth: CrossnetControlAuthState(authLoaded: true, tenantBound: true),
            connection: CrossnetControlConnectionRuntimeSnapshot(
                connectionStatus: .failed(secretFailure),
                readiness: .idle,
                activeSessionSnapshot: nil,
                currentConnectionID: nil,
                signalingHealth: .healthy
            )
        )

        XCTAssertEqual(result.connectionStatus, "failed")
        XCTAssertEqual(result.sessionPresent, false)
        XCTAssertNil(result.sessionRef)
        XCTAssertNil(result.suite)
        XCTAssertEqual(result.failureCode, .runtimeFailed)
        XCTAssertEqual(result.failureClass, .runtimeFailure)
        XCTAssertFalse(result.failureCode?.rawValue.contains(secretFailure) ?? true)
        XCTAssertFalse(result.failureClass?.rawValue.contains(secretFailure) ?? true)
        XCTAssertFalse(result.connectionStatus.contains(secretFailure))
    }

    func testStatusProjectionTransportReadyUsesSnapshotSuiteButRedactsTransportSession() {
        let rawSessionID = "transport-session-secret"
        let activeSnapshot = ActiveSessionSnapshot(
            sessionId: "snapshot-session-secret",
            source: .p2p,
            phase: .transportReady,
            negotiatedSuite: "ML-KEM-768+ECDH"
        )

        let result = CrossnetControlRuntimeProjection.status(
            auth: CrossnetControlAuthState(authLoaded: true, tenantBound: true),
            connection: CrossnetControlConnectionRuntimeSnapshot(
                connectionStatus: .connecting,
                readiness: .transportReady(sessionId: rawSessionID),
                activeSessionSnapshot: activeSnapshot,
                currentConnectionID: nil,
                signalingHealth: .healthy
            )
        )

        XCTAssertEqual(result.readiness, "transport_ready")
        XCTAssertEqual(result.sessionPresent, true)
        XCTAssertEqual(result.sessionRef, CrossnetControlSessionRef.redacted(rawSessionID))
        XCTAssertEqual(result.suite, "ML-KEM-768+ECDH")
        XCTAssertFalse(result.sessionRef?.contains(rawSessionID) ?? true)
    }

    func testStatusProjectionUsesActiveSnapshotForIdleSessionAndSuite() {
        let rawSessionID = "snapshot-session-secret"
        let activeSnapshot = ActiveSessionSnapshot(
            sessionId: rawSessionID,
            source: .code,
            phase: .handshakeComplete,
            negotiatedSuite: "ML-KEM-1024+ECDH"
        )

        let result = CrossnetControlRuntimeProjection.status(
            auth: CrossnetControlAuthState(authLoaded: true, tenantBound: true),
            connection: CrossnetControlConnectionRuntimeSnapshot(
                connectionStatus: .idle,
                readiness: .idle,
                activeSessionSnapshot: activeSnapshot,
                currentConnectionID: nil,
                signalingHealth: .healthy
            )
        )

        XCTAssertEqual(result.connectionStatus, "idle")
        XCTAssertEqual(result.readiness, "idle")
        XCTAssertEqual(result.sessionPresent, true)
        XCTAssertEqual(result.sessionRef, CrossnetControlSessionRef.redacted(rawSessionID))
        XCTAssertEqual(result.suite, "ML-KEM-1024+ECDH")
        XCTAssertEqual(result.signalingHealth, "healthy")
    }

    func testStatusProjectionDoesNotTreatConnectionCodeLengthIDAsSessionRef() {
        let codeLengthResult = CrossnetControlRuntimeProjection.status(
            auth: CrossnetControlAuthState(authLoaded: true, tenantBound: true),
            connection: CrossnetControlConnectionRuntimeSnapshot(
                connectionStatus: .idle,
                readiness: .idle,
                activeSessionSnapshot: nil,
                currentConnectionID: "ABCDEFGH",
                signalingHealth: .healthy
            )
        )

        XCTAssertEqual(codeLengthResult.sessionPresent, false)
        XCTAssertNil(codeLengthResult.sessionRef)

        let rawSessionID = "runtime-session-secret"
        let runtimeSessionResult = CrossnetControlRuntimeProjection.status(
            auth: CrossnetControlAuthState(authLoaded: true, tenantBound: true),
            connection: CrossnetControlConnectionRuntimeSnapshot(
                connectionStatus: .idle,
                readiness: .idle,
                activeSessionSnapshot: nil,
                currentConnectionID: rawSessionID,
                signalingHealth: .healthy
            )
        )

        XCTAssertEqual(runtimeSessionResult.sessionPresent, true)
        XCTAssertEqual(runtimeSessionResult.sessionRef, CrossnetControlSessionRef.redacted(rawSessionID))
        XCTAssertFalse(runtimeSessionResult.sessionRef?.contains(rawSessionID) ?? true)
    }

    func testSettingsProjectionBuildsAllowlistedReadOnlyMacSnapshot() throws {
        let snapshot = CrossnetControlRuntimeProjection.settingsSnapshot(
            CrossnetControlSettingsRuntimeSnapshot(
                enableVerboseLogging: true,
                logLevel: "Info",
                showRealtimeFPS: false,
                showTopBarIPLocation: true,
                showTopBarNetworkSpeed: false,
                showTopBarNetworkLatency: true,
                preferXWingHybrid: true,
                pqcSignatureAlgorithm: "ML-DSA-65"
            )
        )

        XCTAssertEqual(snapshot.runtimeTarget, "mac_app_runtime")
        XCTAssertEqual(snapshot.controlEffect, "read_only")
        XCTAssertEqual(
            snapshot.settings.map(\.id),
            [
                "logging.verbose",
                "logging.level",
                "ui.show_realtime_fps",
                "ui.top_bar_ip_location",
                "ui.top_bar_network_speed",
                "ui.top_bar_network_latency",
                "pqc.prefer_xwing_hybrid",
                "pqc.signature_algorithm"
            ]
        )
        XCTAssertTrue(snapshot.settings.allSatisfy { $0.mutable == false })
        XCTAssertEqual(snapshot.settings.first { $0.id == "logging.verbose" }?.valueType, "bool")
        XCTAssertEqual(snapshot.settings.first { $0.id == "logging.verbose" }?.value, .bool(true))
        XCTAssertEqual(snapshot.settings.first { $0.id == "logging.level" }?.valueType, "string")
        XCTAssertEqual(snapshot.settings.first { $0.id == "logging.level" }?.value, .string("Info"))
        XCTAssertEqual(
            snapshot.settings.first { $0.id == "pqc.signature_algorithm" }?.note,
            "policy_preference_not_runtime_proof"
        )
        XCTAssertEqual(
            snapshot.settings.first { $0.id == "pqc.prefer_xwing_hybrid" }?.note,
            "policy_preference_not_runtime_proof"
        )
        XCTAssertNoThrow(try CrossnetControlSettingsProjectionPolicy.validate(snapshot))
    }
}

final class OperatorControlRuntimeFactorySourceContractTests: XCTestCase {
    func testMacFactoryDelegatesWireProjectionToCoreProjector() throws {
        let source = try String(
            contentsOfFile: "Sources/SkyBridgeCompassApp/Services/OperatorControlRuntimeFactory.swift",
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("CrossnetControlRuntimeProjection.hello("))
        XCTAssertTrue(source.contains("CrossnetControlRuntimeProjection.status("))
        XCTAssertTrue(source.contains("CrossnetControlRuntimeProjection.settingsSnapshot("))
        XCTAssertTrue(source.contains("CrossnetControlConnectionRuntimeSnapshot("))
        XCTAssertTrue(source.contains("CrossnetControlSettingsRuntimeSnapshot("))
        XCTAssertFalse(source.contains("private static func connectionStatusString"))
        XCTAssertFalse(source.contains("private static func readinessString"))
        XCTAssertFalse(source.contains("private static func signalingHealthString"))
        XCTAssertFalse(source.contains("private static func sessionIdentifier"))
        XCTAssertFalse(source.contains("private static func negotiatedSuite"))
        XCTAssertFalse(source.contains("private static func setting("))
    }
}

#if os(macOS)
final class OperatorControlServerRoundTripTests: XCTestCase {
    func testServerHelloRoundTripOverUnixSocket() async throws {
        try await withStartedServer { socketURL in
            let response: WireResponse<CrossnetControlHelloResult> = try sendRequest(
                #"{"v":1,"id":"hello-socket","method":"crossnet.hello"}"# + "\n",
                to: socketURL
            )

            XCTAssertEqual(response.v, 1)
            XCTAssertEqual(response.id, "hello-socket")
            XCTAssertEqual(response.ok, true)
            XCTAssertEqual(response.result?.engineVersion, "test-engine")
            XCTAssertEqual(response.result?.authLoaded, true)
            XCTAssertEqual(response.result?.tenantBound, true)
            XCTAssertNil(response.error)
        }
    }

    func testServerReturnsRequestTooLargeForOversizedRequest() async throws {
        try await withStartedServer { socketURL in
            var request = Data(repeating: UInt8(ascii: "x"), count: CrossnetControlWire.maxLineByteCount + 1)
            request.append(0x0A)

            let response: WireResponse<NoResult> = try sendRequest(request, to: socketURL)

            XCTAssertEqual(response.ok, false)
            XCTAssertNil(response.id)
            XCTAssertEqual(response.error?.code, "request_too_large")
            XCTAssertNil(response.result)
        }
    }

    func testServerRejectsEOFWithoutTrailingNewline() async throws {
        try await withStartedServer { socketURL in
            let response: WireResponse<NoResult> = try sendRequest(
                #"{"v":1,"id":"unterminated","method":"crossnet.hello"}"#,
                to: socketURL,
                halfCloseWrite: true
            )

            XCTAssertEqual(response.ok, false)
            XCTAssertNil(response.id)
            XCTAssertEqual(response.error?.code, "malformed_request")
            XCTAssertTrue(response.error?.message.contains("newline terminator") ?? false)
            XCTAssertNil(response.result)
        }
    }

    func testStartStopAreIdempotentAndUnlinkSocket() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let socketURL = root.appendingPathComponent("crossnet-control.sock", isDirectory: false)
        let server = OperatorControlServer(
            socketURL: socketURL,
            router: CrossnetControlRouter(runtime: operatorControlTestRuntime())
        )

        try await server.start()
        try await server.start()
        XCTAssertTrue(socketPathIsSocket(socketURL.path))

        try await server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketURL.path))

        try await server.start()
        XCTAssertTrue(socketPathIsSocket(socketURL.path))

        try await server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketURL.path))
    }

    private func withStartedServer(
        _ body: (URL) async throws -> Void
    ) async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let socketURL = root.appendingPathComponent("crossnet-control.sock", isDirectory: false)
        let server = OperatorControlServer(
            socketURL: socketURL,
            router: CrossnetControlRouter(runtime: operatorControlTestRuntime())
        )

        try await server.start()
        do {
            try await body(socketURL)
            try await server.stop()
        } catch {
            try? await server.stop()
            throw error
        }
    }

    private func sendRequest<Result: Decodable>(
        _ request: String,
        to socketURL: URL,
        halfCloseWrite: Bool = false
    ) throws -> WireResponse<Result> {
        try sendRequest(Data(request.utf8), to: socketURL, halfCloseWrite: halfCloseWrite)
    }

    private func sendRequest<Result: Decodable>(
        _ request: Data,
        to socketURL: URL,
        halfCloseWrite: Bool = false
    ) throws -> WireResponse<Result> {
        let descriptor = try connectUnixSocket(path: socketURL.path)
        defer { close(descriptor) }

        try writeAll(request, to: descriptor)
        if halfCloseWrite {
            guard shutdown(descriptor, SHUT_WR) == 0 else {
                throw TestSocketError.posix(operation: "shutdown SHUT_WR", errno: errno)
            }
        }

        let response = try readResponseLine(from: descriptor)
        return try JSONDecoder().decode(WireResponse<Result>.self, from: response)
    }

    private func connectUnixSocket(path: String) throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw TestSocketError.posix(operation: "socket", errno: errno)
        }

        do {
            var address = sockaddr_un()
            let pathBytes = Array(path.utf8)
            let maxPathBytes = MemoryLayout.size(ofValue: address.sun_path) - 1
            guard pathBytes.count <= maxPathBytes else {
                throw TestSocketError.pathTooLong(pathBytes.count)
            }

            address.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutablePointer(to: &address.sun_path) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: maxPathBytes + 1) { destination in
                    for index in 0..<pathBytes.count {
                        destination[index] = CChar(bitPattern: pathBytes[index])
                    }
                    destination[pathBytes.count] = 0
                }
            }

            let length = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count + 1)
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
                    Darwin.connect(descriptor, socketPointer, length)
                }
            }
            guard result == 0 else {
                throw TestSocketError.posix(operation: "connect", errno: errno)
            }
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if written > 0 {
                    offset += written
                    continue
                }
                if written < 0, errno == EINTR {
                    continue
                }
                throw TestSocketError.posix(operation: "write", errno: errno)
            }
        }
    }

    private func readResponseLine(from descriptor: Int32) throws -> Data {
        var buffer = [UInt8]()
        buffer.reserveCapacity(1024)

        while true {
            var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let pollResult = poll(&pollDescriptor, 1, 3_000)
            guard pollResult > 0 else {
                if pollResult == 0 {
                    throw TestSocketError.timeout("timed out waiting for control response")
                }
                if errno == EINTR {
                    continue
                }
                throw TestSocketError.posix(operation: "poll", errno: errno)
            }

            if (pollDescriptor.revents & Int16(POLLIN)) != 0 {
                var byte = UInt8()
                let count = Darwin.read(descriptor, &byte, 1)
                if count == 1 {
                    if byte == 0x0A {
                        return Data(buffer)
                    }
                    buffer.append(byte)
                    if buffer.count > CrossnetControlWire.maxLineByteCount {
                        throw TestSocketError.responseTooLarge
                    }
                    continue
                }
                if count == 0 {
                    throw TestSocketError.eofBeforeResponse
                }
                if errno == EINTR {
                    continue
                }
                throw TestSocketError.posix(operation: "read", errno: errno)
            }

            if (pollDescriptor.revents & Int16(POLLERR | POLLHUP | POLLNVAL)) != 0 {
                throw TestSocketError.eofBeforeResponse
            }
        }
    }

    private func socketPathIsSocket(_ path: String) -> Bool {
        var status = stat()
        guard lstat(path, &status) == 0 else { return false }
        return (status.st_mode & S_IFMT) == S_IFSOCK
    }

    private func temporaryRoot() -> URL {
        let suffix = String(UUID().uuidString.prefix(8))
        return URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("sbc-\(suffix)", isDirectory: true)
    }
}

final class OperatorControlSocketPathPolicyTests: XCTestCase {
    func testDefaultSocketURLMatchesRustClientContractPath() throws {
        let socketURL = try OperatorControlSocketPathPolicy.defaultSocketURL()

        XCTAssertTrue(
            socketURL.path.hasSuffix("/Library/Application Support/SkyBridge/crossnet-control.sock"),
            "Swift server and Rust client must resolve the same default crossnet-control socket path"
        )
        XCTAssertFalse(socketURL.path.contains("SkyBridgeCompass/OperatorControl"))
    }

    func testPrepareSocketURLCreatesPrivateParentDirectory() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let socketURL = root
            .appendingPathComponent("control", isDirectory: true)
            .appendingPathComponent("crossnet-control.sock", isDirectory: false)

        try OperatorControlSocketPathPolicy.prepareSocketURL(socketURL)

        let attributes = try FileManager.default.attributesOfItem(
            atPath: socketURL.deletingLastPathComponent().path
        )
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o777, 0o700)
    }

    func testPrepareSocketURLRejectsExistingNonSocketPath() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let socketURL = root
            .appendingPathComponent("control", isDirectory: true)
            .appendingPathComponent("crossnet-control.sock", isDirectory: false)
        try FileManager.default.createDirectory(
            at: socketURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Data("not a socket".utf8).write(to: socketURL)

        XCTAssertThrowsError(try OperatorControlSocketPathPolicy.prepareSocketURL(socketURL)) { error in
            XCTAssertEqual(
                error as? OperatorControlServerError,
                .unsafeSocketPath("existing path is not a socket")
            )
        }
    }

    func testPrepareSocketURLRejectsSymlinkParent() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let realDirectory = root.appendingPathComponent("real", isDirectory: true)
        let symlinkDirectory = root.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createDirectory(
            at: realDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        XCTAssertEqual(symlink(realDirectory.path, symlinkDirectory.path), 0)

        let socketURL = symlinkDirectory.appendingPathComponent("crossnet-control.sock")
        XCTAssertThrowsError(try OperatorControlSocketPathPolicy.prepareSocketURL(socketURL)) { error in
            XCTAssertEqual(
                error as? OperatorControlServerError,
                .unsafeSocketPath("control socket parent is a symlink")
            )
        }
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("skybridge-operator-control-\(UUID().uuidString)", isDirectory: true)
    }
}
#endif

private func operatorControlTestRuntime(
    authLoaded: Bool = true,
    tenantBound: Bool = true,
    settingsSnapshot: CrossnetControlSettingsSnapshotResult? = nil,
    applySetting: (
        @Sendable (CrossnetControlSettingsMutationRequest) async throws
            -> CrossnetControlSettingsMutationResult
    )? = nil
) -> CrossnetControlRuntime {
    CrossnetControlRuntime(
        hello: {
            CrossnetControlHelloResult(
                engineVersion: "test-engine",
                authLoaded: authLoaded,
                tenantBound: tenantBound
            )
        },
        status: {
            CrossnetControlRuntimeProjection.status(
                auth: CrossnetControlAuthState(
                    authLoaded: authLoaded,
                    tenantBound: tenantBound
                ),
                connection: CrossnetControlConnectionRuntimeSnapshot(
                    connectionStatus: .connected,
                    readiness: .handshakeComplete(
                        sessionId: "raw-session-secret",
                        negotiatedSuite: "ML-KEM-768+ECDH"
                    ),
                    activeSessionSnapshot: nil,
                    currentConnectionID: nil,
                    signalingHealth: .healthy
                )
            )
        },
        settingsSnapshot: {
            settingsSnapshot ?? operatorControlDefaultSettingsSnapshot()
        },
        applySetting: applySetting ?? CrossnetControlRuntime.unavailableSettingsMutation
    )
}

/// Simulates a Mac runtime that stores whatever it is given and reads the same
/// value back, unless `observedOverride` forces a divergent read-back.
private func operatorControlEchoingSettingsMutation(
    observedOverride: CrossnetControlJSONValue? = nil,
    runtimeApplied: Bool = true
) -> @Sendable (CrossnetControlSettingsMutationRequest) async throws
    -> CrossnetControlSettingsMutationResult {
    { request in
        CrossnetControlSettingsMutationResult(
            id: request.id,
            valueType: request.value.valueType,
            requestedValue: request.value,
            observedValue: observedOverride ?? request.value,
            runtimeApplied: runtimeApplied
        )
    }
}

private func operatorControlDefaultSettingsSnapshot() -> CrossnetControlSettingsSnapshotResult {
    CrossnetControlSettingsSnapshotResult(settings: [
        operatorControlSetting(
            id: "logging.verbose",
            valueType: "bool",
            value: .bool(true),
            mutable: false
        ),
        operatorControlSetting(
            id: "logging.level",
            valueType: "string",
            value: .string("Debug"),
            mutable: false
        ),
        operatorControlSetting(
            id: "ui.show_realtime_fps",
            valueType: "bool",
            value: .bool(false),
            mutable: false
        ),
        operatorControlSetting(
            id: "ui.top_bar_ip_location",
            valueType: "bool",
            value: .bool(true),
            mutable: false
        ),
        operatorControlSetting(
            id: "ui.top_bar_network_speed",
            valueType: "bool",
            value: .bool(true),
            mutable: false
        ),
        operatorControlSetting(
            id: "ui.top_bar_network_latency",
            valueType: "bool",
            value: .bool(true),
            mutable: false
        ),
        operatorControlSetting(
            id: "pqc.prefer_xwing_hybrid",
            valueType: "bool",
            value: .bool(false),
            mutable: false,
            note: "policy_preference_not_runtime_proof"
        ),
        operatorControlSetting(
            id: "pqc.signature_algorithm",
            valueType: "string",
            value: .string("ML-DSA-65"),
            mutable: false,
            note: "policy_preference_not_runtime_proof"
        )
    ])
}

private func operatorControlSetting(
    id: String,
    valueType: String,
    value: CrossnetControlJSONValue,
    mutable: Bool,
    note: String? = nil
) -> CrossnetControlSettingSnapshot {
    CrossnetControlSettingSnapshot(
        id: id,
        valueType: valueType,
        value: value,
        mutable: mutable,
        note: note
    )
}

private struct WireResponse<Result: Decodable>: Decodable {
    let v: Int
    let id: String?
    let ok: Bool
    let result: Result?
    let error: WireError?
}

private struct WireError: Decodable {
    let code: String
    let message: String
}

private struct NoResult: Decodable {}

#if os(macOS)
private enum TestSocketError: Error, LocalizedError {
    case pathTooLong(Int)
    case posix(operation: String, errno: Int32)
    case timeout(String)
    case responseTooLarge
    case eofBeforeResponse

    var errorDescription: String? {
        switch self {
        case .pathTooLong(let byteCount):
            return "test Unix socket path is too long: \(byteCount) bytes"
        case .posix(let operation, let rawErrno):
            return "\(operation) failed with errno \(rawErrno)"
        case .timeout(let message):
            return message
        case .responseTooLarge:
            return "test control response line exceeded the protocol limit"
        case .eofBeforeResponse:
            return "control socket closed before a newline-framed response"
        }
    }
}
#endif
