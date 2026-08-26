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

    /// A build that wires no push source must keep refusing watch — silently
    /// downgrading to a one-shot answer would let a monitoring script hang on a
    /// stream that never comes.
    func testStatusWatchFailsClosedWhenNoPushSourceIsWired() async throws {
        let router = CrossnetControlRouter(runtime: operatorControlTestRuntime())

        let response: WireResponse<NoResult> = try await route(
            router,
            #"{"v":1,"id":"watch-1","method":"crossnet.status","params":{"watch":true}}"#
        )

        XCTAssertEqual(response.ok, false)
        XCTAssertEqual(response.id, "watch-1")
        XCTAssertEqual(response.error?.code, "watch_not_supported")
        XCTAssertNil(response.result)

        // The streaming entry point must agree with the one-shot one.
        let outcome = await router.handleLineStreaming(
            Data(#"{"v":1,"id":"watch-2","method":"crossnet.status","params":{"watch":true}}"#.utf8)
        )
        guard case .response(let data) = outcome else {
            return XCTFail("unwired watch must not produce a stream")
        }
        let decoded = try JSONDecoder().decode(WireResponse<NoResult>.self, from: data)
        XCTAssertEqual(decoded.error?.code, "watch_not_supported")
    }

    func testStatusWatchStreamsInitialResponseThenCoalescedEvents() async throws {
        let router = CrossnetControlRouter(runtime: operatorControlTestRuntime(
            statusEvents: {
                AsyncStream { continuation in
                    continuation.yield(operatorControlWatchSnapshot(readiness: "transport_ready"))
                    continuation.yield(operatorControlWatchSnapshot(readiness: "handshake_complete"))
                    continuation.finish()
                }
            }
        ))

        let outcome = await router.handleLineStreaming(
            Data(#"{"v":1,"id":"watch-live","method":"crossnet.status","params":{"watch":true}}"#.utf8)
        )
        guard case .stream(let initial, let events) = outcome else {
            return XCTFail("wired watch must produce a stream")
        }

        let initialResponse = try JSONDecoder().decode(
            WireResponse<CrossnetControlStatusResult>.self,
            from: initial
        )
        XCTAssertEqual(initialResponse.ok, true)
        XCTAssertEqual(initialResponse.id, "watch-live")

        var seen: [String] = []
        for await frame in events {
            let event = try JSONDecoder().decode(WatchEventFrame.self, from: frame)
            XCTAssertEqual(event.event, "status")
            seen.append(event.data.readiness)
        }
        XCTAssertEqual(seen, ["transport_ready", "handshake_complete"])
    }

    func testStatusWatchStreamRequiresTheWatchFlag() async throws {
        // A plain status request on a wired runtime must stay one-shot.
        let router = CrossnetControlRouter(runtime: operatorControlTestRuntime(
            statusEvents: { AsyncStream { $0.finish() } }
        ))
        let outcome = await router.handleLineStreaming(
            Data(#"{"v":1,"id":"status-oneshot","method":"crossnet.status"}"#.utf8)
        )
        guard case .response(let data) = outcome else {
            return XCTFail("a non-watch status must not stream")
        }
        let decoded = try JSONDecoder().decode(
            WireResponse<CrossnetControlStatusResult>.self,
            from: data
        )
        XCTAssertEqual(decoded.ok, true)
    }

    func testNavigateAppliesDestinationAndReportsUIConfirmedReadBack() async throws {
        let router = CrossnetControlRouter(runtime: operatorControlTestRuntime(
            navigate: { destination in
                CrossnetControlNavigateResult(
                    destination: destination.rawValue,
                    presentedDestination: destination.rawValue,
                    runtimeApplied: true
                )
            }
        ))

        let response: WireResponse<CrossnetControlNavigateResult> = try await route(
            router,
            #"{"v":1,"id":"nav-1","method":"crossnet.navigate","params":{"destination":"settings"}}"#
        )
        XCTAssertEqual(response.ok, true)
        XCTAssertEqual(response.result?.destination, "settings")
        XCTAssertEqual(response.result?.presentedDestination, "settings")
        XCTAssertEqual(response.result?.controlEffect, "mac_ui_navigation")
    }

    func testNavigateFailsClosedForUnwiredRuntimeInvalidAndUnconfirmed() async throws {
        // Unwired runtime keeps the previous refusal.
        let unwired = CrossnetControlRouter(runtime: operatorControlTestRuntime())
        let refused: WireResponse<NoResult> = try await route(
            unwired,
            #"{"v":1,"id":"nav-unwired","method":"crossnet.navigate","params":{"destination":"settings"}}"#
        )
        XCTAssertEqual(refused.ok, false)
        XCTAssertEqual(refused.error?.code, "method_not_enabled")

        // Unknown destination is rejected before auth or the runtime run.
        let wired = CrossnetControlRouter(runtime: operatorControlTestRuntime(
            navigate: { _ in
                XCTFail("an invalid destination must never reach the runtime")
                throw CrossnetControlFailure.internalError("unreachable")
            }
        ))
        let invalid: WireResponse<NoResult> = try await route(
            wired,
            #"{"v":1,"id":"nav-bad","method":"crossnet.navigate","params":{"destination":"about_box"}}"#
        )
        XCTAssertEqual(invalid.ok, false)
        XCTAssertEqual(invalid.error?.code, "navigation_destination_invalid")

        // A run the UI did not confirm must not be reported as applied.
        let unconfirmed = CrossnetControlRouter(runtime: operatorControlTestRuntime(
            navigate: { destination in
                CrossnetControlNavigateResult(
                    destination: destination.rawValue,
                    presentedDestination: "dashboard",
                    runtimeApplied: true
                )
            }
        ))
        let mismatch: WireResponse<NoResult> = try await route(
            unconfirmed,
            #"{"v":1,"id":"nav-mismatch","method":"crossnet.navigate","params":{"destination":"settings"}}"#
        )
        XCTAssertEqual(mismatch.ok, false)
        XCTAssertEqual(mismatch.error?.code, "navigation_apply_failed")
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

    func testRemoteDesktopCaptureSettingsMutateWithNextCaptureCaveat() async throws {
        let router = CrossnetControlRouter(runtime: operatorControlTestRuntime(
            applySetting: operatorControlEchoingSettingsMutation()
        ))

        let fpsResponse: WireResponse<CrossnetControlSettingsMutationResult> = try await route(
            router,
            #"{"v":1,"id":"set-fps","method":"crossnet.settings.set","params":{"id":"remote_desktop.target_fps","value":120}}"#
        )
        XCTAssertEqual(fpsResponse.ok, true)
        XCTAssertEqual(fpsResponse.result?.valueType, "int")
        XCTAssertEqual(fpsResponse.result?.observedValue, .int(120))

        let resolutionResponse: WireResponse<CrossnetControlSettingsMutationResult> = try await route(
            router,
            #"{"v":1,"id":"set-res","method":"crossnet.settings.set","params":{"id":"remote_desktop.resolution","value":"2560x1440"}}"#
        )
        XCTAssertEqual(resolutionResponse.ok, true)
        XCTAssertEqual(resolutionResponse.result?.observedValue, .string("2560x1440"))

        // A frame rate outside the declared contract must be refused, not clamped.
        let outOfDomain: WireResponse<NoResult> = try await route(
            router,
            #"{"v":1,"id":"set-fps-bad","method":"crossnet.settings.set","params":{"id":"remote_desktop.target_fps","value":45}}"#
        )
        XCTAssertEqual(outOfDomain.ok, false)
        XCTAssertEqual(outOfDomain.error?.code, "setting_invalid_value")

        // A preset the CLI contract knows but `ResolutionSetting` cannot express
        // must be refused rather than silently coerced to `auto`.
        let unrepresentable: WireResponse<NoResult> = try await route(
            router,
            #"{"v":1,"id":"set-res-bad","method":"crossnet.settings.set","params":{"id":"remote_desktop.resolution","value":"2056x1329"}}"#
        )
        XCTAssertEqual(unrepresentable.ok, false)
        XCTAssertEqual(unrepresentable.error?.code, "setting_invalid_value")

        // Wrong wire type for an int setting is a rejection, not a coercion.
        let wrongType: WireResponse<NoResult> = try await route(
            router,
            #"{"v":1,"id":"set-fps-string","method":"crossnet.settings.set","params":{"id":"remote_desktop.target_fps","value":"60"}}"#
        )
        XCTAssertEqual(wrongType.ok, false)
        XCTAssertEqual(wrongType.error?.code, "setting_invalid_value")
    }

    func testDevicesListIsAuthGatedRedactedAndFailClosedWhenUnwired() async throws {
        // Unwired runtime keeps the previous refusal.
        let unwired = CrossnetControlRouter(runtime: operatorControlTestRuntime())
        let refused: WireResponse<NoResult> = try await route(
            unwired,
            #"{"v":1,"id":"devices-unwired","method":"crossnet.devices"}"#
        )
        XCTAssertEqual(refused.error?.code, "method_not_enabled")

        // A projection leaking an unredacted reference must be rejected whole.
        let leaky = CrossnetControlRouter(runtime: operatorControlTestRuntime(
            listOnlineDevices: {
                CrossnetControlDevicesResult(devices: [
                    CrossnetControlDeviceEntry(
                        deviceRef: "raw-device-id",
                        name: "iPad",
                        platform: "iPadOS",
                        online: true
                    )
                ])
            }
        ))
        let leaked: WireResponse<NoResult> = try await route(
            leaky,
            #"{"v":1,"id":"devices-leaky","method":"crossnet.devices"}"#
        )
        XCTAssertEqual(leaked.ok, false)
        XCTAssertEqual(leaked.error?.code, "internal")

        // Honest projection round-trips.
        let router = CrossnetControlRouter(runtime: operatorControlTestRuntime(
            listOnlineDevices: {
                CrossnetControlDevicesResult(devices: [
                    CrossnetControlDeviceEntry(
                        deviceRef: CrossnetControlSessionRef.redacted("ipad-unique-id"),
                        name: "Ziang iPad",
                        platform: "iPadOS",
                        online: true
                    )
                ])
            }
        ))
        let response: WireResponse<CrossnetControlDevicesResult> = try await route(
            router,
            #"{"v":1,"id":"devices-live","method":"crossnet.devices"}"#
        )
        XCTAssertEqual(response.ok, true)
        XCTAssertEqual(response.result?.devices.count, 1)
        XCTAssertEqual(response.result?.devices.first?.name, "Ziang iPad")
        XCTAssertEqual(
            response.result?.devices.first?.deviceRef.hasPrefix("sha256:"),
            true
        )

        // Auth gate applies to the read too: account device names are account
        // data.
        let unauthenticated = CrossnetControlRouter(runtime: operatorControlTestRuntime(
            authLoaded: true,
            tenantBound: false,
            listOnlineDevices: {
                XCTFail("device list must not be produced without a bound tenant")
                return CrossnetControlDevicesResult(devices: [])
            }
        ))
        let gated: WireResponse<NoResult> = try await route(
            unauthenticated,
            #"{"v":1,"id":"devices-gated","method":"crossnet.devices"}"#
        )
        XCTAssertEqual(gated.error?.code, "tenant_required")
    }

    func testConnectDeviceHonestReadBackAndFailClosedPaths() async throws {
        let goodRef = CrossnetControlSessionRef.redacted("ipad-unique-id")

        // Unwired refusal.
        let unwired = CrossnetControlRouter(runtime: operatorControlTestRuntime())
        let refused: WireResponse<NoResult> = try await route(
            unwired,
            #"{"v":1,"id":"cd-unwired","method":"crossnet.connect_device","params":{"device_ref":"\(goodRef)"}}"#
                .replacingOccurrences(of: "\\(goodRef)", with: goodRef)
        )
        XCTAssertEqual(refused.error?.code, "method_not_enabled")

        // Malformed reference is rejected before auth or the runtime.
        let router = CrossnetControlRouter(runtime: operatorControlTestRuntime(
            connectOnlineDevice: { _ in
                XCTFail("malformed refs must never reach the runtime")
                throw CrossnetControlFailure.internalError("unreachable")
            }
        ))
        let malformed: WireResponse<NoResult> = try await route(
            router,
            #"{"v":1,"id":"cd-malformed","method":"crossnet.connect_device","params":{"device_ref":"raw-id"}}"#
        )
        XCTAssertEqual(malformed.error?.code, "malformed_request")

        // Unknown reference surfaces as device_not_found.
        let missing = CrossnetControlRouter(runtime: operatorControlTestRuntime(
            connectOnlineDevice: { _ in throw CrossnetControlFailure.deviceNotFound }
        ))
        let notFound: WireResponse<NoResult> = try await route(
            missing,
            "{\"v\":1,\"id\":\"cd-missing\",\"method\":\"crossnet.connect_device\",\"params\":{\"device_ref\":\"\(goodRef)\"}}"
        )
        XCTAssertEqual(notFound.error?.code, "device_not_found")

        // A dial the manager does not read back as connected is refused.
        let unconfirmed = CrossnetControlRouter(runtime: operatorControlTestRuntime(
            connectOnlineDevice: { deviceRef in
                CrossnetControlConnectDeviceResult(
                    deviceRef: deviceRef,
                    name: "Ziang iPad",
                    connected: false
                )
            }
        ))
        let failed: WireResponse<NoResult> = try await route(
            unconfirmed,
            "{\"v\":1,\"id\":\"cd-unconfirmed\",\"method\":\"crossnet.connect_device\",\"params\":{\"device_ref\":\"\(goodRef)\"}}"
        )
        XCTAssertEqual(failed.error?.code, "session_runtime_apply_failed")

        // Honest join round-trips.
        let joined = CrossnetControlRouter(runtime: operatorControlTestRuntime(
            connectOnlineDevice: { deviceRef in
                CrossnetControlConnectDeviceResult(
                    deviceRef: deviceRef,
                    name: "Ziang iPad",
                    connected: true
                )
            }
        ))
        let success: WireResponse<CrossnetControlConnectDeviceResult> = try await route(
            joined,
            "{\"v\":1,\"id\":\"cd-live\",\"method\":\"crossnet.connect_device\",\"params\":{\"device_ref\":\"\(goodRef)\"}}"
        )
        XCTAssertEqual(success.ok, true)
        XCTAssertEqual(success.result?.connected, true)
        XCTAssertEqual(success.result?.deviceRef, goodRef)
    }

    // MARK: - Wired session plane
    //
    // The tests above cover the fail-closed default runtime, which is still a
    // real deployment state (a host that does not grant session authority).
    // These cover the opposite: a runtime that DOES wire the verbs up.

    func testHostIssuesCodeAndReportsRedactedSessionRefAndAppliedLease() async throws {
        let router = CrossnetControlRouter(runtime: operatorControlTestRuntime(
            hostSession: { leaseMode in
                CrossnetControlHostResult(
                    code: "K7M2QP4X",
                    sessionRef: CrossnetControlSessionRef.redacted("raw-host-session"),
                    expiresAt: "2026-08-25T12:00:00Z",
                    leaseMode: leaseMode
                )
            }
        ))

        let response: WireResponse<CrossnetControlHostResult> = try await route(
            router,
            #"{"v":1,"id":"host-live","method":"crossnet.host","params":{"lease_mode":"long"}}"#
        )
        XCTAssertEqual(response.ok, true)
        XCTAssertEqual(response.error?.code, nil)
        XCTAssertEqual(response.result?.code, "K7M2QP4X")
        XCTAssertEqual(response.result?.leaseMode, .long)
        XCTAssertEqual(response.result?.expiresAt, "2026-08-25T12:00:00Z")
        // The raw session id must never reach the wire.
        XCTAssertEqual(response.result?.sessionRef?.hasPrefix("sha256:"), true)
        XCTAssertEqual(response.result?.sessionRef?.contains("raw-host-session"), false)
    }

    func testHostRejectsLeaseDowngradeAndMissingSessionRef() async throws {
        // A runtime that quietly issues a short lease for a long request must
        // not be reported as having honoured the request.
        let downgradeRouter = CrossnetControlRouter(runtime: operatorControlTestRuntime(
            hostSession: { _ in
                CrossnetControlHostResult(
                    code: "K7M2QP4X",
                    sessionRef: CrossnetControlSessionRef.redacted("raw-host-session"),
                    expiresAt: nil,
                    leaseMode: .short
                )
            }
        ))
        let downgraded: WireResponse<NoResult> = try await route(
            downgradeRouter,
            #"{"v":1,"id":"host-downgrade","method":"crossnet.host","params":{"lease_mode":"long"}}"#
        )
        XCTAssertEqual(downgraded.ok, false)
        XCTAssertEqual(downgraded.error?.code, "internal")

        let rawRefRouter = CrossnetControlRouter(runtime: operatorControlTestRuntime(
            hostSession: { leaseMode in
                CrossnetControlHostResult(
                    code: "K7M2QP4X",
                    sessionRef: "raw-host-session",
                    expiresAt: nil,
                    leaseMode: leaseMode
                )
            }
        ))
        let rawRef: WireResponse<NoResult> = try await route(
            rawRefRouter,
            #"{"v":1,"id":"host-raw-ref","method":"crossnet.host","params":{"lease_mode":"short"}}"#
        )
        XCTAssertEqual(rawRef.ok, false)
        XCTAssertEqual(rawRef.error?.code, "internal")
    }

    func testConnectReportsRedactedSessionRefAndHonestReadiness() async throws {
        // `connectWithCode` returns before the peer answers, so an honest
        // result reports the readiness actually observed, not "connected".
        let router = CrossnetControlRouter(runtime: operatorControlTestRuntime(
            connectSession: { _ in
                CrossnetControlConnectResult(
                    sessionRef: CrossnetControlSessionRef.redacted("raw-connect-session"),
                    remoteDeviceName: "Studio Mac",
                    readiness: "transport_ready",
                    connectionStatus: "connecting"
                )
            }
        ))

        let response: WireResponse<CrossnetControlConnectResult> = try await route(
            router,
            #"{"v":1,"id":"connect-live","method":"crossnet.connect","params":{"code":"K7M2QP4X"}}"#
        )
        XCTAssertEqual(response.ok, true)
        XCTAssertEqual(response.result?.readiness, "transport_ready")
        XCTAssertEqual(response.result?.connectionStatus, "connecting")
        XCTAssertEqual(response.result?.remoteDeviceName, "Studio Mac")
        XCTAssertEqual(response.result?.controlEffect, "mac_session_mutation")
        XCTAssertEqual(response.result?.sessionRef.hasPrefix("sha256:"), true)
        XCTAssertEqual(response.result?.sessionRef.contains("raw-connect-session"), false)
    }

    func testConnectRefusesUnsupportableReadinessAndFailedRuntime() async throws {
        // `handshake_complete` is the one readiness an operator would treat as
        // proof of a live secure session, so it may only be reported when the
        // app's own connection status agrees.
        let unsupportedRouter = CrossnetControlRouter(runtime: operatorControlTestRuntime(
            connectSession: { _ in
                CrossnetControlConnectResult(
                    sessionRef: CrossnetControlSessionRef.redacted("raw-connect-session"),
                    remoteDeviceName: nil,
                    readiness: "handshake_complete",
                    connectionStatus: "connecting"
                )
            }
        ))
        let unsupported: WireResponse<NoResult> = try await route(
            unsupportedRouter,
            #"{"v":1,"id":"connect-unsupported","method":"crossnet.connect","params":{"code":"K7M2QP4X"}}"#
        )
        XCTAssertEqual(unsupported.ok, false)
        XCTAssertEqual(unsupported.error?.code, "session_runtime_apply_failed")

        let failedRouter = CrossnetControlRouter(runtime: operatorControlTestRuntime(
            connectSession: { _ in
                CrossnetControlConnectResult(
                    sessionRef: CrossnetControlSessionRef.redacted("raw-connect-session"),
                    remoteDeviceName: nil,
                    readiness: "idle",
                    connectionStatus: "failed"
                )
            }
        ))
        let failed: WireResponse<NoResult> = try await route(
            failedRouter,
            #"{"v":1,"id":"connect-failed","method":"crossnet.connect","params":{"code":"K7M2QP4X"}}"#
        )
        XCTAssertEqual(failed.ok, false)
        XCTAssertEqual(failed.error?.code, "session_runtime_apply_failed")
    }

    func testDisconnectReportsTeardownAndRefusesSurvivingSession() async throws {
        let tornDownRouter = CrossnetControlRouter(runtime: operatorControlTestRuntime(
            disconnectSession: {
                CrossnetControlDisconnectResult(
                    disconnected: true,
                    sessionPresentBefore: true,
                    sessionPresentAfter: false,
                    connectionStatus: "idle"
                )
            }
        ))
        let tornDown: WireResponse<CrossnetControlDisconnectResult> = try await route(
            tornDownRouter,
            #"{"v":1,"id":"disconnect-live","method":"crossnet.disconnect"}"#
        )
        XCTAssertEqual(tornDown.ok, true)
        XCTAssertEqual(tornDown.result?.disconnected, true)
        XCTAssertEqual(tornDown.result?.sessionPresentAfter, false)

        // Nothing to tear down is a successful, honest `false`.
        let idleRouter = CrossnetControlRouter(runtime: operatorControlTestRuntime(
            disconnectSession: {
                CrossnetControlDisconnectResult(
                    disconnected: false,
                    sessionPresentBefore: false,
                    sessionPresentAfter: false,
                    connectionStatus: "idle"
                )
            }
        ))
        let idle: WireResponse<CrossnetControlDisconnectResult> = try await route(
            idleRouter,
            #"{"v":1,"id":"disconnect-idle","method":"crossnet.disconnect"}"#
        )
        XCTAssertEqual(idle.ok, true)
        XCTAssertEqual(idle.result?.disconnected, false)

        // A runtime that still holds the session after disconnect must not be
        // reported as having torn it down.
        let survivingRouter = CrossnetControlRouter(runtime: operatorControlTestRuntime(
            disconnectSession: {
                CrossnetControlDisconnectResult(
                    disconnected: true,
                    sessionPresentBefore: true,
                    sessionPresentAfter: true,
                    connectionStatus: "connected"
                )
            }
        ))
        let surviving: WireResponse<NoResult> = try await route(
            survivingRouter,
            #"{"v":1,"id":"disconnect-surviving","method":"crossnet.disconnect"}"#
        )
        XCTAssertEqual(surviving.ok, false)
        XCTAssertEqual(surviving.error?.code, "session_runtime_apply_failed")
    }

    func testDisconnectRefusesAClaimItsOwnReadBackDoesNotSupport() async throws {
        // Claiming a teardown when nothing was there is a fabricated mutation
        // even though the post-state looks clean.
        let overclaimRouter = CrossnetControlRouter(runtime: operatorControlTestRuntime(
            disconnectSession: {
                CrossnetControlDisconnectResult(
                    disconnected: true,
                    sessionPresentBefore: false,
                    sessionPresentAfter: false,
                    connectionStatus: "idle"
                )
            }
        ))
        let overclaimed: WireResponse<NoResult> = try await route(
            overclaimRouter,
            #"{"v":1,"id":"disconnect-overclaim","method":"crossnet.disconnect"}"#
        )
        XCTAssertEqual(overclaimed.ok, false)
        XCTAssertEqual(overclaimed.error?.code, "internal")

        // A runtime left in a non-idle status has not proven teardown, even if
        // it reports no surviving session object.
        let nonIdleRouter = CrossnetControlRouter(runtime: operatorControlTestRuntime(
            disconnectSession: {
                CrossnetControlDisconnectResult(
                    disconnected: true,
                    sessionPresentBefore: true,
                    sessionPresentAfter: false,
                    connectionStatus: "connecting"
                )
            }
        ))
        let nonIdle: WireResponse<NoResult> = try await route(
            nonIdleRouter,
            #"{"v":1,"id":"disconnect-non-idle","method":"crossnet.disconnect"}"#
        )
        XCTAssertEqual(nonIdle.ok, false)
        XCTAssertEqual(nonIdle.error?.code, "session_runtime_apply_failed")
    }

    func testConcurrentSessionMutationsAreRefusedRatherThanInterleaved() async throws {
        // The server handles every client on its own detached task and these
        // verbs suspend between mutating and re-reading, so a second concurrent
        // call must be refused instead of racing the first one's read-back.
        let started = AsyncStreamGate()
        let router = CrossnetControlRouter(runtime: operatorControlTestRuntime(
            disconnectSession: {
                await started.signal()
                try? await Task.sleep(nanoseconds: 200_000_000)
                return CrossnetControlDisconnectResult(
                    disconnected: true,
                    sessionPresentBefore: true,
                    sessionPresentAfter: false,
                    connectionStatus: "idle"
                )
            }
        ))

        // Driven through `router.handleLine` directly so the concurrent task
        // captures only the Sendable router, not the test case.
        let first = Task { () -> Data in
            await router.handleLine(
                Data(#"{"v":1,"id":"disconnect-a","method":"crossnet.disconnect"}"#.utf8)
            )
        }
        await started.wait()
        let second: WireResponse<NoResult> = try await route(
            router,
            #"{"v":1,"id":"disconnect-b","method":"crossnet.disconnect"}"#
        )
        XCTAssertEqual(second.ok, false)
        XCTAssertEqual(second.error?.code, "session_mutation_rejected")

        let firstResponse = try JSONDecoder().decode(
            WireResponse<CrossnetControlDisconnectResult>.self,
            from: await first.value
        )
        XCTAssertEqual(firstResponse.ok, true)
        XCTAssertEqual(firstResponse.result?.disconnected, true)
    }

    func testWiredSessionVerbsStillRequireAuthAndTenant() async throws {
        // Wiring the runtime must not bypass the operator context gate.
        let router = CrossnetControlRouter(runtime: operatorControlTestRuntime(
            authLoaded: true,
            tenantBound: false,
            hostSession: { leaseMode in
                XCTFail("host runtime must not run without a bound tenant")
                return CrossnetControlHostResult(
                    code: "K7M2QP4X",
                    sessionRef: CrossnetControlSessionRef.redacted("raw"),
                    expiresAt: nil,
                    leaseMode: leaseMode
                )
            },
            connectSession: { _ in
                XCTFail("connect runtime must not run without a bound tenant")
                return CrossnetControlConnectResult(
                    sessionRef: CrossnetControlSessionRef.redacted("raw"),
                    remoteDeviceName: nil,
                    readiness: "idle",
                    connectionStatus: "idle"
                )
            },
            disconnectSession: {
                XCTFail("disconnect runtime must not run without a bound tenant")
                return CrossnetControlDisconnectResult(
                    disconnected: false,
                    sessionPresentBefore: false,
                    sessionPresentAfter: false,
                    connectionStatus: "idle"
                )
            }
        ))

        for (id, method, params) in [
            ("host-gate", "crossnet.host", #"{"lease_mode":"short"}"#),
            ("connect-gate", "crossnet.connect", #"{"code":"K7M2QP4X"}"#),
            ("disconnect-gate", "crossnet.disconnect", "{}")
        ] {
            let response: WireResponse<NoResult> = try await route(
                router,
                #"{"v":1,"id":"\#(id)","method":"\#(method)","params":\#(params)}"#
            )
            XCTAssertEqual(response.ok, false, method)
            XCTAssertEqual(response.error?.code, "tenant_required", method)
        }
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
                pqcSignatureAlgorithm: "ML-DSA-65",
                remoteDesktopTargetFrameRate: 60,
                remoteDesktopResolution: "1920x1080"
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
                "pqc.signature_algorithm",
                "remote_desktop.target_fps",
                "remote_desktop.resolution"
            ]
        )
        // Capture parameters are read only when a stream starts, so the
        // projection must carry that caveat rather than implying a live retune.
        XCTAssertEqual(
            snapshot.settings.first { $0.id == "remote_desktop.target_fps" }?.valueType,
            "int"
        )
        XCTAssertEqual(
            snapshot.settings.first { $0.id == "remote_desktop.target_fps" }?.value,
            .int(60)
        )
        XCTAssertEqual(
            snapshot.settings.first { $0.id == "remote_desktop.target_fps" }?.note,
            "applies_at_next_capture_start"
        )
        XCTAssertEqual(
            snapshot.settings.first { $0.id == "remote_desktop.resolution" }?.value,
            .string("1920x1080")
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

    /// End-to-end proof that the session verbs are live over the real socket,
    /// not just at the router API.
    ///
    /// This is the strongest evidence obtainable without a signed app and a
    /// real peer: the actual `OperatorControlServer`, the actual wire framing,
    /// and the actual router, driven over a real AF_UNIX connection.
    func testServerHostAndDisconnectRoundTripOverUnixSocket() async throws {
        let runtime = operatorControlTestRuntime(
            hostSession: { leaseMode in
                CrossnetControlHostResult(
                    code: "K7M2QP4X",
                    sessionRef: CrossnetControlSessionRef.redacted("raw-host-session"),
                    expiresAt: "2026-08-25T12:00:00Z",
                    leaseMode: leaseMode
                )
            },
            disconnectSession: {
                CrossnetControlDisconnectResult(
                    disconnected: true,
                    sessionPresentBefore: true,
                    sessionPresentAfter: false,
                    connectionStatus: "idle"
                )
            }
        )

        try await withStartedServer(runtime: runtime) { socketURL in
            let hosted: WireResponse<CrossnetControlHostResult> = try sendRequest(
                #"{"v":1,"id":"host-socket","method":"crossnet.host","params":{"lease_mode":"long"}}"# + "\n",
                to: socketURL
            )
            XCTAssertEqual(hosted.ok, true)
            XCTAssertEqual(hosted.id, "host-socket")
            XCTAssertEqual(hosted.result?.code, "K7M2QP4X")
            XCTAssertEqual(hosted.result?.leaseMode, .long)
            XCTAssertNil(hosted.error)

            let torn: WireResponse<CrossnetControlDisconnectResult> = try sendRequest(
                #"{"v":1,"id":"disconnect-socket","method":"crossnet.disconnect"}"# + "\n",
                to: socketURL
            )
            XCTAssertEqual(torn.ok, true)
            XCTAssertEqual(torn.result?.disconnected, true)
            XCTAssertEqual(torn.result?.sessionPresentAfter, false)
        }
    }

    /// A build that does not wire the session runtime must still answer
    /// `method_not_enabled` over the socket, so an older app cannot be mistaken
    /// for a capable one.
    func testServerKeepsUnwiredSessionVerbsDisabledOverUnixSocket() async throws {
        try await withStartedServer { socketURL in
            let hosted: WireResponse<NoResult> = try sendRequest(
                #"{"v":1,"id":"host-unwired","method":"crossnet.host"}"# + "\n",
                to: socketURL
            )
            XCTAssertEqual(hosted.ok, false)
            XCTAssertEqual(hosted.error?.code, "method_not_enabled")
        }
    }

    /// End-to-end: the real server streams the initial response plus events
    /// over a genuine AF_UNIX connection, then closes when the source ends.
    func testServerStreamsWatchFramesOverUnixSocket() async throws {
        let runtime = operatorControlTestRuntime(
            statusEvents: {
                AsyncStream { continuation in
                    continuation.yield(operatorControlWatchSnapshot(readiness: "transport_ready"))
                    continuation.yield(
                        operatorControlWatchSnapshot(readiness: "handshake_complete")
                    )
                    continuation.finish()
                }
            }
        )

        try await withStartedServer(runtime: runtime) { socketURL in
            let descriptor = try connectUnixSocket(path: socketURL.path)
            defer { close(descriptor) }
            try writeAll(
                Data(
                    (#"{"v":1,"id":"watch-socket","method":"crossnet.status","params":{"watch":true}}"#
                        + "\n").utf8
                ),
                to: descriptor
            )

            let initial = try readResponseLine(from: descriptor)
            let initialResponse = try JSONDecoder().decode(
                WireResponse<CrossnetControlStatusResult>.self,
                from: initial
            )
            XCTAssertEqual(initialResponse.ok, true)
            XCTAssertEqual(initialResponse.id, "watch-socket")

            let firstEvent = try JSONDecoder().decode(
                WatchEventFrame.self,
                from: try readResponseLine(from: descriptor)
            )
            XCTAssertEqual(firstEvent.event, "status")
            XCTAssertEqual(firstEvent.data.readiness, "transport_ready")

            let secondEvent = try JSONDecoder().decode(
                WatchEventFrame.self,
                from: try readResponseLine(from: descriptor)
            )
            XCTAssertEqual(secondEvent.data.readiness, "handshake_complete")
        }
    }

    /// A client that writes a request and closes before reading the response
    /// must not be able to kill the host process.
    ///
    /// Without `SO_NOSIGPIPE` on the accepted descriptor, `Darwin.write` to the
    /// closed peer raises SIGPIPE and the default disposition terminates the
    /// whole Mac app. The assertion is that the server is still serving
    /// afterwards.
    func testServerSurvivesClientThatClosesBeforeReadingTheResponse() async throws {
        try await withStartedServer { socketURL in
            // Reuse the same connect helper the other socket tests use.
            let descriptor = try connectUnixSocket(path: socketURL.path)
            try writeAll(
                Data((#"{"v":1,"id":"abandoned","method":"crossnet.hello"}"# + "\n").utf8),
                to: descriptor
            )
            // Close immediately, before the server has written its reply.
            close(descriptor)

            // The server must still answer a fresh client.
            let followUp: WireResponse<CrossnetControlHelloResult> = try sendRequest(
                #"{"v":1,"id":"after-abandon","method":"crossnet.hello"}"# + "\n",
                to: socketURL
            )
            XCTAssertEqual(followUp.ok, true)
            XCTAssertEqual(followUp.result?.engineVersion, "test-engine")
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
        runtime: CrossnetControlRuntime? = nil,
        _ body: (URL) async throws -> Void
    ) async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let socketURL = root.appendingPathComponent("crossnet-control.sock", isDirectory: false)
        let server = OperatorControlServer(
            socketURL: socketURL,
            router: CrossnetControlRouter(runtime: runtime ?? operatorControlTestRuntime())
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
    )? = nil,
    hostSession: (
        @Sendable (CrossnetControlHostLeaseMode) async throws -> CrossnetControlHostResult
    )? = nil,
    connectSession: (
        @Sendable (String) async throws -> CrossnetControlConnectResult
    )? = nil,
    disconnectSession: (
        @Sendable () async throws -> CrossnetControlDisconnectResult
    )? = nil,
    navigate: (
        @Sendable (CrossnetControlNavigationDestination) async throws
            -> CrossnetControlNavigateResult
    )? = nil,
    listOnlineDevices: (
        @Sendable () async throws -> CrossnetControlDevicesResult
    )? = nil,
    connectOnlineDevice: (
        @Sendable (String) async throws -> CrossnetControlConnectDeviceResult
    )? = nil,
    statusEvents: (@Sendable () -> AsyncStream<CrossnetControlStatusResult>)? = nil
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
        applySetting: applySetting ?? CrossnetControlRuntime.unavailableSettingsMutation,
        hostSession: hostSession ?? CrossnetControlRuntime.unavailableHostSession,
        connectSession: connectSession ?? CrossnetControlRuntime.unavailableConnectSession,
        disconnectSession: disconnectSession
            ?? CrossnetControlRuntime.unavailableDisconnectSession,
        navigate: navigate ?? CrossnetControlRuntime.unavailableNavigation,
        listOnlineDevices: listOnlineDevices
            ?? CrossnetControlRuntime.unavailableListOnlineDevices,
        connectOnlineDevice: connectOnlineDevice
            ?? CrossnetControlRuntime.unavailableConnectOnlineDevice,
        statusEvents: statusEvents
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

/// One-shot async signal used to prove the session gate is actually held while
/// the first mutation is suspended.
private actor AsyncStreamGate {
    private var signalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        guard !signalled else { return }
        signalled = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }

    func wait() async {
        if signalled { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

/// Builds a distinct status snapshot for watch streaming tests.
private func operatorControlWatchSnapshot(readiness: String) -> CrossnetControlStatusResult {
    CrossnetControlStatusResult(
        connectionStatus: "connecting",
        readiness: readiness,
        sessionPresent: true,
        sessionRef: CrossnetControlSessionRef.redacted("watch-session"),
        suite: nil,
        signalingHealth: "healthy",
        failureCode: nil,
        failureClass: nil,
        authLoaded: true,
        tenantBound: true
    )
}

private struct WatchEventFrame: Decodable {
    let v: Int
    let event: String
    let data: CrossnetControlStatusResult
}

@MainActor
final class OperatorNavigationCoordinatorTests: XCTestCase {
    func testRequestConfirmAndAwaitRoundTrip() async {
        let coordinator = OperatorNavigationCoordinator()
        coordinator.requestNavigation(to: "settings")
        XCTAssertEqual(coordinator.requestedDestination, "settings")

        // The owning view applies the request and confirms from its own
        // selection change.
        coordinator.confirmPresented("settings")
        XCTAssertNil(coordinator.requestedDestination)
        XCTAssertEqual(coordinator.presentedDestination, "settings")

        let confirmed = await coordinator.awaitPresentation(
            of: "settings",
            timeout: .milliseconds(200)
        )
        XCTAssertTrue(confirmed)
    }

    func testAwaitFailsClosedWhenNoViewConfirms() async {
        let coordinator = OperatorNavigationCoordinator()
        coordinator.requestNavigation(to: "settings")
        // Nothing confirms — the timeout is the honest "no mounted view" answer.
        let confirmed = await coordinator.awaitPresentation(
            of: "settings",
            timeout: .milliseconds(120)
        )
        XCTAssertFalse(confirmed)
    }

    func testSupersededRequestIsNotReportedAsPresented() async {
        let coordinator = OperatorNavigationCoordinator()
        coordinator.requestNavigation(to: "settings")
        // A user (or second operator call) drives the UI elsewhere instead.
        coordinator.confirmPresented("dashboard")
        let confirmed = await coordinator.awaitPresentation(
            of: "settings",
            timeout: .milliseconds(120)
        )
        XCTAssertFalse(confirmed)
        XCTAssertEqual(coordinator.presentedDestination, "dashboard")
    }

    func testUserDrivenChangesKeepReadBackCurrent() {
        let coordinator = OperatorNavigationCoordinator()
        // No operator request at all: user clicks are still confirmed, so a
        // later navigate to the already-current destination reads back honestly.
        coordinator.confirmPresented("remote_desktop")
        XCTAssertEqual(coordinator.presentedDestination, "remote_desktop")
        XCTAssertNil(coordinator.requestedDestination)
    }
}
