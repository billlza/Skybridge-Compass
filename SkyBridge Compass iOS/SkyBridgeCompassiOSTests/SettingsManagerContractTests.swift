import XCTest
@testable import SkyBridgeCompass_iOS
import SkyBridgeProtocolCore

@MainActor
final class SettingsManagerContractTests: XCTestCase {
    private func isolatedDefaults() throws -> UserDefaults {
        let suiteName = "com.skybridge.tests.settings.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    func testFreshDefaultsMatchDeclaredContractWithoutWritingKeys() throws {
        let defaults = try isolatedDefaults()
        let manager = SettingsManager(defaults: defaults)

        XCTAssertTrue(manager.autoReconnect)
        XCTAssertTrue(manager.endToEndEncryption)
        XCTAssertTrue(manager.discoveryEnabled)
        XCTAssertTrue(manager.enableRealTimeWeather)
        XCTAssertTrue(manager.clipboardSyncFileURLs)
        XCTAssertEqual(manager.maxConcurrentConnections, 2)
        XCTAssertEqual(
            manager.clipboardMaxContentSize,
            P2PControlFramePolicy.maximumInlineClipboardByteCount
        )
        XCTAssertNil(defaults.object(forKey: "auto_reconnect"))
        XCTAssertNil(defaults.object(forKey: "e2e_encryption"))
        XCTAssertNil(defaults.object(forKey: "discovery_enabled"))
    }

    func testExplicitFalseOverridesTrueDefaults() throws {
        let defaults = try isolatedDefaults()
        defaults.set(false, forKey: "auto_reconnect")
        defaults.set(false, forKey: "e2e_encryption")
        defaults.set(false, forKey: "discovery_enabled")
        defaults.set(false, forKey: "enable_real_time_weather")
        defaults.set(false, forKey: "clipboard_sync_file_urls")

        let manager = SettingsManager(defaults: defaults)

        XCTAssertFalse(manager.autoReconnect)
        XCTAssertFalse(manager.endToEndEncryption)
        XCTAssertFalse(manager.discoveryEnabled)
        XCTAssertFalse(manager.enableRealTimeWeather)
        XCTAssertFalse(manager.clipboardSyncFileURLs)
    }

    func testMutationsPersistToInjectedDefaultsOnly() throws {
        let defaults = try isolatedDefaults()
        let manager = SettingsManager(defaults: defaults)

        manager.autoReconnect = false
        manager.endToEndEncryption = false
        manager.clipboardMaxContentSize = 4096

        XCTAssertEqual(defaults.object(forKey: "auto_reconnect") as? Bool, false)
        XCTAssertEqual(defaults.object(forKey: "e2e_encryption") as? Bool, false)
        XCTAssertEqual(defaults.object(forKey: "clipboard_max_content_size") as? Int, 4096)
    }

    func testLegacyOversizedClipboardSettingMigratesToWireSafeMaximum() throws {
        let defaults = try isolatedDefaults()
        defaults.set(10 * 1024 * 1024, forKey: "clipboard_max_content_size")

        let manager = SettingsManager(defaults: defaults)

        XCTAssertEqual(
            manager.clipboardMaxContentSize,
            P2PControlFramePolicy.maximumInlineClipboardByteCount
        )
        XCTAssertTrue(manager.clipboardContentSizeWasMigrated)
        XCTAssertEqual(
            defaults.object(forKey: "clipboard_max_content_size") as? Int,
            P2PControlFramePolicy.maximumInlineClipboardByteCount
        )
    }

    func testLegacyInvalidBonjourServiceLabelsMigrateWithoutDuplicates() throws {
        let defaults = try isolatedDefaults()
        defaults.set(
            [
                BonjourInteropProtocolContract.legacyFileTransferServiceType,
                BonjourInteropProtocolContract.fileTransferServiceType,
                BonjourInteropProtocolContract.legacyRemoteControlServiceType
            ],
            forKey: "discovery_custom_services"
        )

        let manager = SettingsManager(defaults: defaults)
        let expected = [
            BonjourInteropProtocolContract.fileTransferServiceType,
            BonjourInteropProtocolContract.remoteControlServiceType
        ]

        XCTAssertEqual(manager.discoveryCustomServiceTypes, expected)
        XCTAssertEqual(
            defaults.stringArray(forKey: "discovery_custom_services"),
            expected
        )
    }

    func testIOSClipboardWorstCaseBase64FitsSharedBudget() throws {
        let data = Data(
            repeating: 0xff,
            count: P2PControlFramePolicy.maximumInlineClipboardByteCount
        )
        let message = AppMessage.clipboard(
            .init(
                mimeType: P2PClipboardMIMEPolicy.uriList,
                dataBase64: data.base64EncodedString(),
                sentAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        )

        let encoded = try P2PControlJSONEncoder.encode(message)
        XCTAssertFalse(try XCTUnwrap(String(data: encoded, encoding: .utf8)).contains("\\/"))
        XCTAssertLessThanOrEqual(
            encoded.count + 28 + 8,
            P2PControlFramePolicy.maximumBodyByteCount
        )
    }

    func testIOSFixedPaddingRejectsUnboundedConfigurationBeforeAllocation() {
        let configuration = TrafficPaddingConfig(
            enabled: true,
            debugLog: false,
            mode: .fixed,
            fixedSizeBytes: Int.max,
            bucketSizesBytes: []
        )

        XCTAssertThrowsError(
            try TrafficPadding.wrapForP2PControlFrame(
                Data([0x01]),
                configuration: configuration
            )
        ) { error in
            XCTAssertEqual(
                error as? P2PControlFramePolicyError,
                .invalidPaddingTarget(
                    actual: Int.max,
                    maximum: P2PControlFramePolicy.maximumBodyByteCount
                )
            )
        }
    }

    func testLegacyMacFileURLMIMECanonicalizesToURIList() {
        XCTAssertEqual(
            P2PClipboardMIMEPolicy.canonicalWireValue(
                for: P2PClipboardMIMEPolicy.legacySkyBridgeFileURL
            ),
            P2PClipboardMIMEPolicy.uriList
        )
    }

    func testIOSClipboardStableSnapshotRejectsContentReadAcrossGenerations() {
        var changeCount = 41

        let result = P2PClipboardSnapshotPolicy.read(
            changeCount: { changeCount },
            value: {
                changeCount = 42
                return "stale-value"
            }
        )

        guard case .changed = result else {
            return XCTFail("A value read across pasteboard generations must not create a submission lease")
        }
    }

    func testIOSClipboardStableSnapshotBindsValueToOneGeneration() {
        let result = P2PClipboardSnapshotPolicy.read(
            changeCount: { 19 },
            value: { "stable-value" }
        )

        guard case .stable(let value, let changeCount) = result else {
            return XCTFail("Expected a stable clipboard snapshot")
        }
        XCTAssertEqual(value, "stable-value")
        XCTAssertEqual(changeCount, 19)
    }

    func testIOSClipboardCommittedHashDoesNotResubmitWithoutDeliveryDebt() {
        let convergence = P2PClipboardDeliveryConvergence()
        XCTAssertFalse(
            convergence.requiresSubmission(
                contentHash: "A",
                committedHash: "A",
                remoteOriginHash: nil
            )
        )
    }

    func testIOSClipboardSuspendedRouteMarksCommittedHashForCompensation() async throws {
        let convergence = P2PClipboardDeliveryConvergence()
        let (entered, enteredContinuation) = AsyncStream.makeStream(of: Void.self)
        let (release, releaseContinuation) = AsyncStream.makeStream(of: Void.self)
        let routeAttempt = Task { @MainActor in
            try await convergence.attemptRoute {
                enteredContinuation.yield(())
                enteredContinuation.finish()
                for await _ in release {
                    break
                }
                try Task.checkCancellation()
            }
        }

        for await _ in entered {
            break
        }
        XCTAssertTrue(
            convergence.requiresSubmission(
                contentHash: "A",
                committedHash: "A",
                remoteOriginHash: "A"
            ),
            "An authoritative inbound A must compensate for a possibly delivered B without becoming a normal echo"
        )
        let retryStart = ContinuousClock.now
        XCTAssertTrue(
            convergence.authoritativeInboundApplied(
                generation: 27,
                now: retryStart
            ),
            "Inbound generation must remain uncommitted while an older route can still deliver afterward"
        )
        XCTAssertFalse(
            convergence.mayAttempt(
                generation: 27,
                now: retryStart.advanced(by: .milliseconds(999))
            )
        )

        routeAttempt.cancel()
        releaseContinuation.yield(())
        releaseContinuation.finish()
        do {
            try await routeAttempt.value
            XCTFail("A superseded route must observe cancellation")
        } catch is CancellationError {
            // Expected: cancellation does not erase possible-delivery state.
        }
        XCTAssertTrue(
            convergence.requiresSubmission(
                contentHash: "A",
                committedHash: "A",
                remoteOriginHash: "A"
            )
        )

        XCTAssertTrue(
            convergence.mayAttempt(
                generation: 27,
                now: retryStart.advanced(by: .seconds(1))
            )
        )
        XCTAssertTrue(
            convergence.fullySubmitted(
                generation: 27,
                now: retryStart.advanced(by: .seconds(1))
            )
        )
        XCTAssertFalse(
            convergence.requiresSubmission(
                contentHash: "A",
                committedHash: "A",
                remoteOriginHash: "A"
            )
        )
    }

    func testIOSClipboardFailedGenerationUsesCappedBackoffAndNewGenerationPreempts() throws {
        let convergence = try P2PClipboardDeliveryConvergence(
            initialRetryDelay: 1,
            maximumRetryDelay: 4
        )
        let start = ContinuousClock.now

        convergence.recordFailure(generation: 11, now: start)
        XCTAssertFalse(
            convergence.mayAttempt(
                generation: 11,
                now: start.advanced(by: .milliseconds(999))
            )
        )
        XCTAssertTrue(
            convergence.mayAttempt(
                generation: 11,
                now: start.advanced(by: .seconds(1))
            )
        )

        convergence.recordFailure(
            generation: 11,
            now: start.advanced(by: .seconds(1))
        )
        XCTAssertFalse(
            convergence.mayAttempt(
                generation: 11,
                now: start.advanced(by: .milliseconds(2_999))
            )
        )
        XCTAssertTrue(
            convergence.mayAttempt(generation: 11, now: start.advanced(by: .seconds(3)))
        )
        convergence.recordFailure(
            generation: 11,
            now: start.advanced(by: .seconds(3))
        )
        XCTAssertFalse(
            convergence.mayAttempt(
                generation: 11,
                now: start.advanced(by: .milliseconds(6_999))
            )
        )
        XCTAssertTrue(
            convergence.mayAttempt(generation: 11, now: start.advanced(by: .seconds(7)))
        )
        convergence.recordFailure(
            generation: 11,
            now: start.advanced(by: .seconds(7))
        )
        XCTAssertFalse(
            convergence.mayAttempt(
                generation: 11,
                now: start.advanced(by: .milliseconds(10_999))
            ),
            "Retry delay must remain capped at four seconds"
        )
        XCTAssertTrue(
            convergence.mayAttempt(generation: 11, now: start.advanced(by: .seconds(11)))
        )

        XCTAssertTrue(
            convergence.mayAttempt(
                generation: 12,
                now: start.advanced(by: .milliseconds(7_100))
            ),
            "A newer pasteboard generation must not inherit the old generation's backoff"
        )
        XCTAssertTrue(
            convergence.mayAttempt(
                generation: 11,
                now: start.advanced(by: .milliseconds(7_100))
            )
        )
    }

    func testIOSClipboardAuthoritativeInboundClearsLocalConvergenceDebt() async {
        let convergence = P2PClipboardDeliveryConvergence()
        do {
            try await convergence.attemptRoute {
                throw CancellationError()
            }
        } catch is CancellationError {
            // The potentially delivered route remains dirty until an authority wins.
        } catch {
            XCTFail("Unexpected route error: \(error)")
        }
        XCTAssertFalse(
            convergence.authoritativeInboundApplied(
                generation: 31,
                now: ContinuousClock.now
            )
        )

        XCTAssertFalse(convergence.deliveryMayHaveOccurred)
        XCTAssertFalse(
            convergence.requiresSubmission(
                contentHash: "remote",
                committedHash: "remote",
                remoteOriginHash: "remote"
            )
        )
    }

    func testInvalidRemoteClipboardNeverCreatesSuccessHistory() {
        let clipboard = ClipboardManager.shared
        let sessionID = UUID()
        clipboard.clearHistory()
        clipboard.enable(for: sessionID)
        clipboard.syncImages = true
        clipboard.maxContentSizeBytes = P2PControlFramePolicy.maximumInlineClipboardByteCount
        defer {
            clipboard.disable(for: sessionID)
            clipboard.clearHistory()
        }

        XCTAssertEqual(
            clipboard.setRemoteClipboard(
                data: Data([0xff]),
                mimeType: P2PClipboardMIMEPolicy.plainText
            ),
            .invalidContent
        )
        XCTAssertEqual(
            clipboard.setRemoteClipboard(
                data: Data("<b>unsupported</b>".utf8),
                mimeType: P2PClipboardMIMEPolicy.html
            ),
            .unsupportedMIMEType
        )
        XCTAssertEqual(
            clipboard.setRemoteClipboard(
                data: Data(
                    repeating: 0,
                    count: P2PControlFramePolicy.maximumInlineClipboardByteCount + 1
                ),
                mimeType: P2PClipboardMIMEPolicy.plainText
            ),
            .contentTooLarge(
                actual: P2PControlFramePolicy.maximumInlineClipboardByteCount + 1,
                maximum: P2PControlFramePolicy.maximumInlineClipboardByteCount
            )
        )
        XCTAssertTrue(clipboard.history.isEmpty)
    }
}
