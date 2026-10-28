import Foundation
import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, *)
@MainActor
final class QPeriaptRuntimeFailureTests: XCTestCase {
    func testPeerAwareFactoriesPreserveRequestedAdmittedQSession() async throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Native Q admission requires macOS 26 or newer.")
        }
        let previous = ProcessInfo.processInfo.environment["SB_ENABLE_QPERIAPT"]
        XCTAssertEqual(setenv("SB_ENABLE_QPERIAPT", "1", 1), 0)
        QPeriaptPlatformPolicy.resetRuntimeSessionForTesting()
        defer {
            if let previous {
                XCTAssertEqual(setenv("SB_ENABLE_QPERIAPT", previous, 1), 0)
            } else {
                XCTAssertEqual(unsetenv("SB_ENABLE_QPERIAPT"), 0)
            }
            QPeriaptPlatformPolicy.resetRuntimeSessionForTesting()
        }
        _ = try await QPeriaptPlatformPolicy.prepareLocalRuntimeSupport()
        let providers = [
            CryptoProviderFactory.makeInboundPQCResponderProvider(
                policy: .requirePQC, peerSupportedSuites: [.qperiaptABI2PolicyBound]
            ),
            CryptoProviderFactory.makeOutboundPQCInitiatorProvider(
                policy: .requirePQC, peerAdvertisedSuites: [.qperiaptABI2PolicyBound]
            )
        ]
        for provider in providers {
            XCTAssertTrue(provider is QPeriaptCryptoProvider)
            XCTAssertEqual(provider.tier, .qperiaptPQC)
            XCTAssertEqual(CryptoProviderFactory.handshakeOfferedPQCSuites(using: provider), [.qperiaptABI2PolicyBound])
            let context = try await HandshakeContext.create(
                role: .responder,
                cryptoProvider: provider,
                protocolSignatureProvider: PQCSignatureProvider(backend: .oqs),
                cryptoPolicy: HandshakeCryptoPolicyResolver.policy(for: [.qperiaptABI2PolicyBound]),
                offeredSuites: CryptoProviderFactory.handshakeOfferedPQCSuites(using: provider),
                activeProtocolSigningAlgorithm: .mlDSA65
            )
            await context.zeroize()
        }
    }

    func testPeerAwareFactoriesDoNotFallBackWhenRequestedQIsUnadmitted() {
        let previous = ProcessInfo.processInfo.environment["SB_ENABLE_QPERIAPT"]
        XCTAssertEqual(setenv("SB_ENABLE_QPERIAPT", "1", 1), 0)
        QPeriaptPlatformPolicy.resetRuntimeSessionForTesting()
        defer {
            if let previous {
                XCTAssertEqual(setenv("SB_ENABLE_QPERIAPT", previous, 1), 0)
            } else {
                XCTAssertEqual(unsetenv("SB_ENABLE_QPERIAPT"), 0)
            }
            QPeriaptPlatformPolicy.resetRuntimeSessionForTesting()
        }
        for policy in [CryptoProviderFactory.SelectionPolicy.preferPQC, .requirePQC] {
            let providers = [
                CryptoProviderFactory.makeInboundPQCResponderProvider(
                    policy: policy, peerSupportedSuites: [.qperiaptABI2PolicyBound, .xwingMLDSA]
                ),
                CryptoProviderFactory.makeOutboundPQCInitiatorProvider(
                    policy: policy, peerAdvertisedSuites: [.qperiaptABI2PolicyBound, .mlkem768MLDSA65]
                )
            ]
            for provider in providers {
                XCTAssertTrue(provider is UnavailablePQCProvider)
                XCTAssertTrue(CryptoProviderFactory.handshakeOfferedPQCSuites(using: provider).isEmpty)
            }
        }
    }

    func testPreparationFailurePreservesQChoiceAndExplicitRetryRecovers() async throws {
        let domain = "QPeriaptRuntimeFailureTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(true, forKey: SettingsStorageKeys.preferQPeriaptBeta)
        let preparation = PreparationSequence()
        let environment = EnvironmentChanges()
        let settings = makeSettings(defaults, environment: environment) {
            try preparation.prepare()
        }

        await settings.waitForStartupTasksForTesting()

        XCTAssertTrue(settings.preferQPeriaptBeta)
        XCTAssertTrue(defaults.bool(forKey: SettingsStorageKeys.preferQPeriaptBeta))
        XCTAssertFalse(settings.qPeriaptRuntimeSupported)
        XCTAssertFalse(settings.isPreparingQPeriaptRuntime)
        XCTAssertEqual(
            settings.qPeriaptRuntimePreparationError,
            QPeriaptProductionRuntimeError.rootFingerprintMismatch.localizedDescription
        )
        XCTAssertEqual(environment.values, [true])

        settings.retryQPeriaptRuntimePreparation()
        settings.retryQPeriaptRuntimePreparation()
        await settings.waitForStartupTasksForTesting()

        XCTAssertEqual(preparation.calls, 2, "A pending retry must not create another preparation task")
        XCTAssertTrue(settings.qPeriaptRuntimeSupported)
        XCTAssertTrue(settings.preferQPeriaptBeta)
        XCTAssertTrue(defaults.bool(forKey: SettingsStorageKeys.preferQPeriaptBeta))
        XCTAssertNil(settings.qPeriaptRuntimePreparationError)
        XCTAssertEqual(environment.values, [true, true])
    }

    func testUnprovisionedResultPreservesQChoiceAndIsVisible() async throws {
        let domain = "QPeriaptRuntimeFailureTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(true, forKey: SettingsStorageKeys.preferQPeriaptBeta)
        let environment = EnvironmentChanges()
        let settings = makeSettings(defaults, environment: environment) { .unprovisioned }

        await settings.waitForStartupTasksForTesting()

        XCTAssertTrue(defaults.bool(forKey: SettingsStorageKeys.preferQPeriaptBeta))
        XCTAssertTrue(settings.preferQPeriaptBeta)
        XCTAssertFalse(settings.qPeriaptRuntimeSupported)
        XCTAssertNotNil(settings.qPeriaptRuntimePreparationError)
        XCTAssertEqual(environment.values, [true])
    }

    func testDefaultOffDoesNotRewriteAnExternalQEnvironmentRequest() async throws {
        let domain = "QPeriaptRuntimeFailureTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let environment = EnvironmentChanges()
        let settings = makeSettings(defaults, environment: environment) {
            throw QPeriaptProductionRuntimeError.unsupportedOS
        }

        await settings.waitForStartupTasksForTesting()

        XCTAssertFalse(settings.preferQPeriaptBeta)
        XCTAssertFalse(defaults.bool(forKey: SettingsStorageKeys.preferQPeriaptBeta))
        XCTAssertFalse(settings.qPeriaptRuntimeSupported)
        XCTAssertNotNil(settings.qPeriaptRuntimePreparationError)
        XCTAssertTrue(environment.values.isEmpty)
    }

    func testRequestedQCannotCreateAnOrdinaryInitiatorOrResponder() async throws {
        let previous = ProcessInfo.processInfo.environment["SB_ENABLE_QPERIAPT"]
        XCTAssertEqual(setenv("SB_ENABLE_QPERIAPT", "1", 1), 0)
        defer {
            if let previous {
                XCTAssertEqual(setenv("SB_ENABLE_QPERIAPT", previous, 1), 0)
            } else {
                XCTAssertEqual(unsetenv("SB_ENABLE_QPERIAPT"), 0)
            }
            QPeriaptPlatformPolicy.resetRuntimeSessionForTesting()
        }
        QPeriaptPlatformPolicy.resetRuntimeSessionForTesting()
        for role in [HandshakeRole.initiator, .responder] {
            do {
                let context = try await HandshakeContext.create(
                    role: role,
                    cryptoProvider: ClassicProvider(),
                    offeredSuites: [.x25519Ed25519]
                )
                await context.zeroize()
                XCTFail("An unadmitted Q request created an ordinary handshake")
            } catch let error as CryptoProviderError {
                guard case .providerNotAvailable(.qPeriapt) = error else {
                    XCTFail("Unexpected rejection: \(error)")
                    continue
                }
            }
        }
    }

    func testAdmittedQRequestRejectsIncompatibleIdentityAndMissingQOfferForBothRoles() async throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Native Q admission requires macOS 26 or newer.")
        }
        let previous = ProcessInfo.processInfo.environment["SB_ENABLE_QPERIAPT"]
        XCTAssertEqual(setenv("SB_ENABLE_QPERIAPT", "1", 1), 0)
        QPeriaptPlatformPolicy.resetRuntimeSessionForTesting()
        defer {
            if let previous {
                XCTAssertEqual(setenv("SB_ENABLE_QPERIAPT", previous, 1), 0)
            } else {
                XCTAssertEqual(unsetenv("SB_ENABLE_QPERIAPT"), 0)
            }
            QPeriaptPlatformPolicy.resetRuntimeSessionForTesting()
        }
        let outcome = try await QPeriaptPlatformPolicy.prepareLocalRuntimeSupport()
        XCTAssertEqual(outcome, .activated)
        XCTAssertTrue(QPeriaptPlatformPolicy.isLocalRuntimeSupported)
        let configurations: [(ProtocolSigningAlgorithm?, [CryptoSuite]?, String)] = [
            (
                .mlDSA87,
                [.qperiaptABI2PolicyBound, .mlkem768MLDSA65],
                "Requested Q-Periapt ABI2 requires ML-DSA-65; current identity uses ML-DSA-87"
            ),
            (
                .mlDSA65,
                [.mlkem768MLDSA65],
                "Requested Q-Periapt ABI2 is absent from the handshake offer and no session-bound Q provider was supplied"
            ),
            (
                nil,
                [.qperiaptABI2PolicyBound, .mlkem768MLDSA65],
                "Requested Q-Periapt ABI2 has no frozen protocol signing identity"
            ),
            (
                .mlDSA65,
                nil,
                "Requested Q-Periapt ABI2 is absent from the handshake offer and no session-bound Q provider was supplied"
            )
        ]
        for role in [HandshakeRole.initiator, .responder] {
            for (algorithm, offeredSuites, expectedReason) in configurations {
                do {
                    let context = try await HandshakeContext.create(
                        role: role,
                        cryptoProvider: ClassicProvider(),
                        offeredSuites: offeredSuites,
                        activeProtocolSigningAlgorithm: algorithm
                    )
                    await context.zeroize()
                    XCTFail("An admitted Q request created an ordinary context for \(role), \(String(describing: algorithm))")
                } catch let error as HandshakeError {
                    guard case .invalidState(let reason) = error else {
                        XCTFail("Unexpected Q identity/offer rejection: \(error)")
                        continue
                    }
                    XCTAssertEqual(reason, expectedReason)
                }
            }
        }
    }

    private func makeSettings(
        _ defaults: UserDefaults,
        environment: EnvironmentChanges,
        prepare: @escaping @MainActor @Sendable () async throws -> QPeriaptProductionPreparationResult
    ) -> SettingsManager {
        SettingsManager(
            testingUserDefaults: defaults,
            existingOnlyIdentityRuntime: false,
            startsProtocolIdentityRestoration: false,
            qPeriaptRuntimeSupportPreparer: prepare,
            qPeriaptEnvironmentPreferenceApplier: { environment.values.append($0) }
        )
    }

    @MainActor
    private final class PreparationSequence {
        var calls = 0

        func prepare() throws -> QPeriaptProductionPreparationResult {
            calls += 1
            if calls == 1 { throw QPeriaptProductionRuntimeError.rootFingerprintMismatch }
            return .activated
        }
    }

    @MainActor
    private final class EnvironmentChanges {
        var values: [Bool] = []
    }
}
