import Foundation
import XCTest

final class FreeRDPRuntimeHardeningSourceContractTests: XCTestCase {
    func testOnlyBundledCoreImageIsLoadedAndEveryRequiredSymbolIsOriginChecked() throws {
        let source = try repositorySource("Sources/FreeRDPBridge/CBFreeRDPClient.m")

        XCTAssertTrue(source.contains("libfreerdp3.dylib"))
        XCTAssertTrue(source.contains("NSDictionary<NSString *, NSValue *> *criticalCoreSymbols"))
        XCTAssertTrue(source.contains("CBSymbolOriginMatchesImage(value.pointerValue, coreLibraryPath)"))
        XCTAssertFalse(source.contains("_clientLibraryHandle"))
        XCTAssertFalse(source.contains("libfreerdp-client3.dylib"))
        XCTAssertFalse(source.contains("freerdp_set_connection_type"))
    }

    func testReleaseRDPRequiresRenderingEventPumpAndInputSymbols() throws {
        let source = try repositorySource("Sources/FreeRDPBridge/CBFreeRDPClient.m")

        for requiredSymbol in [
            "freerdp_input_send_mouse_event",
            "freerdp_input_send_keyboard_event",
            "gdi_init",
            "gdi_free",
            "freerdp_check_event_handles"
        ] {
            XCTAssertTrue(
                source.contains("[missingSymbols addObject:@\"\(requiredSymbol)\"]"),
                "Release RDP must fail closed when \(requiredSymbol) is absent."
            )
        }
        XCTAssertTrue(source.contains("if (!gdiReady || !context->gdi || !context->update->EndPaint)"))
        XCTAssertTrue(source.contains("if (!context->input || !context->update || !self.frameCallback)"))
        XCTAssertTrue(source.contains("15 * NSEC_PER_SEC"))
        XCTAssertTrue(source.contains("FreeRDP \u{9996}\u{5e27}\u{5728}\u{53d1}\u{5e03}\u{7ea7}\u{65f6}\u{9650}\u{5185}\u{672a}\u{5230}\u{8fbe}"))
        XCTAssertTrue(source.contains("self.state = CBFreeRDPClientStateConnected;"))
        XCTAssertTrue(source.contains("FreeRDP \u{4f20}\u{8f93}\u{5df2}\u{5efa}\u{7acb}\u{ff0c}\u{6b63}\u{5728}\u{7b49}\u{5f85}\u{9996}\u{5e27}"))
        XCTAssertFalse(source.contains("\u{5df2}\u{8fde}\u{63a5}\u{4f46}\u{65e0}\u{753b}\u{9762}"))
    }

    func testDeallocationDrainsWorkerBeforeClosingDynamicLibraries() throws {
        let source = try repositorySource("Sources/FreeRDPBridge/CBFreeRDPClient.m")
        let deallocStart = try XCTUnwrap(source.range(of: "- (void)dealloc"))
        let connectStart = try XCTUnwrap(
            source.range(of: "- (BOOL)connectWithError:", range: deallocStart.upperBound..<source.endIndex)
        )
        let deallocBody = String(source[deallocStart.lowerBound..<connectStart.lowerBound])

        XCTAssertTrue(deallocBody.contains("dispatch_sync(_workerQueue, teardown)"))
        XCTAssertTrue(deallocBody.contains("[unsafeSelf teardownConnectionResources]"))
        XCTAssertTrue(deallocBody.contains("[unsafeSelf unloadLibraries]"))
        XCTAssertFalse(deallocBody.contains("[self disconnect]"))
        XCTAssertLessThan(
            try XCTUnwrap(deallocBody.range(of: "teardownConnectionResources")).lowerBound,
            try XCTUnwrap(deallocBody.range(of: "unloadLibraries")).lowerBound
        )
    }

    func testContextIsRequiredAndFreedBeforeTheOuterInstance() throws {
        let source = try repositorySource("Sources/FreeRDPBridge/CBFreeRDPClient.m")
        let teardownStart = try XCTUnwrap(source.range(of: "- (void)teardownConnectionResources\n{"))
        let unloadStart = try XCTUnwrap(
            source.range(of: "- (void)unloadLibraries\n{", range: teardownStart.upperBound..<source.endIndex)
        )
        let teardownBody = String(source[teardownStart.lowerBound..<unloadStart.lowerBound])

        XCTAssertTrue(source.contains("freerdp_context_free_fn _contextFree"))
        XCTAssertTrue(source.contains("dlsym(_libraryHandle, \"freerdp_context_free\")"))
        XCTAssertTrue(source.contains("[missingSymbols addObject:@\"freerdp_context_free\"]"))
        XCTAssertTrue(source.contains("@\"freerdp_context_free\": [NSValue valueWithPointer:(void *)_contextFree]"))
        XCTAssertLessThan(
            try XCTUnwrap(teardownBody.range(of: "_gdiFree(instance)")).lowerBound,
            try XCTUnwrap(teardownBody.range(of: "_contextFree(instance)")).lowerBound
        )
        XCTAssertLessThan(
            try XCTUnwrap(teardownBody.range(of: "_clientDisconnect(instance)")).lowerBound,
            try XCTUnwrap(teardownBody.range(of: "_contextFree(instance)")).lowerBound
        )
        XCTAssertLessThan(
            try XCTUnwrap(teardownBody.range(of: "_contextFree(instance)")).lowerBound,
            try XCTUnwrap(teardownBody.range(of: "_clientFree(instance)")).lowerBound
        )
    }

    func testConnectionInputsAreBoundedAndLogsDoNotPublishIdentity() throws {
        let source = try repositorySource("Sources/FreeRDPBridge/CBFreeRDPClient.m")

        XCTAssertTrue(source.contains("CBValidateRDPTextField(self.targetHost, @\"\u{4e3b}\u{673a}\u{540d}\", 255"))
        XCTAssertTrue(source.contains("CBValidateRDPTextField(self.username, @\"\u{7528}\u{6237}\u{540d}\", 256"))
        XCTAssertTrue(source.contains("CBValidateRDPTextField(self.domain ?: @\"\", @\"\u{57df}\u{540d}\", 255"))
        XCTAssertTrue(source.contains("[NSCharacterSet controlCharacterSet]"))
        XCTAssertTrue(source.contains("whitespaceAndNewlineCharacterSet"))
        XCTAssertFalse(source.contains("\u{76ee}\u{6807}: %@:%hu"))
        XCTAssertFalse(source.contains("%{public}@:%hu"))
    }

    func testVersionAndPendingSettingsFailClosed() throws {
        let source = try repositorySource("Sources/FreeRDPBridge/CBFreeRDPClient.m")
        let header = try repositorySource("Sources/FreeRDPBridge/include/CBFreeRDPClient.h")
        let manager = try repositorySource("Sources/SkyBridgeCore/RemoteDesktopManager.swift")
        let view = try repositorySource("Sources/SkyBridgeCompassApp/RemoteDesktopView.swift")

        XCTAssertTrue(source.contains("[versionString isEqualToString:CBFreeRDPRequiredVersionString]"))
        XCTAssertFalse(source.contains("CBFreeRDPVersionComponents"))
        XCTAssertTrue(source.contains("CBFreeRDPPendingConfiguration _pendingConfiguration"))
        XCTAssertTrue(source.contains("- (BOOL)applyPendingConfiguration"))
        XCTAssertTrue(source.contains("[strongSelf applyPendingConfiguration]"))
        XCTAssertTrue(header.contains("- (BOOL)applyAllSettings:"))
        XCTAssertTrue(header.contains("error:(NSError * _Nullable * _Nullable)error"))
        XCTAssertTrue(manager.contains("try client.applyAllSettings(dict)"))
        XCTAssertTrue(manager.contains("public func reapplyCurrentSettingsToActiveSessions() throws"))
        XCTAssertTrue(view.contains("try remoteDesktopManager.reapplyCurrentSettingsToActiveSessions()"))
        XCTAssertTrue(view.contains("settingsApplyError = error.localizedDescription"))
        XCTAssertFalse(header.contains("configureInteractionSettings"))
        XCTAssertFalse(source.contains("\u{6240}\u{6709}\u{8fdc}\u{7a0b}\u{684c}\u{9762}\u{8bbe}\u{7f6e}\u{5df2}\u{6210}\u{529f}\u{5e94}\u{7528}"))
    }

    func testConnectionTypeCannotReenableExcludedCodecs() throws {
        let source = try repositorySource("Sources/FreeRDPBridge/CBFreeRDPClient.m")
        let pending = try XCTUnwrap(source.range(of: "[strongSelf applyPendingConfiguration]"))
        let codecPolicy = try XCTUnwrap(
            source.range(
                of: "[strongSelf applyConnectionIdentitySettings]",
                range: pending.upperBound..<source.endIndex
            )
        )

        XCTAssertLessThan(pending.lowerBound, codecPolicy.lowerBound)
        XCTAssertTrue(source.contains("FreeRDP_SupportGraphicsPipeline, FALSE"))
        XCTAssertTrue(source.contains("FreeRDP_RemoteFxCodec, FALSE"))
        XCTAssertTrue(source.contains("- (BOOL)applyConnectionType:(UINT32)type"))
        for profile in [
            "CONNECTION_TYPE_MODEM",
            "CONNECTION_TYPE_BROADBAND_LOW",
            "CONNECTION_TYPE_SATELLITE",
            "CONNECTION_TYPE_BROADBAND_HIGH",
            "CONNECTION_TYPE_WAN",
            "CONNECTION_TYPE_LAN",
            "CONNECTION_TYPE_AUTODETECT"
        ] {
            XCTAssertTrue(source.contains("case \(profile):"))
        }
        XCTAssertFalse(source.contains("type - 1"))
    }

    func testChannelPluginsRemainUnregisteredAndCoreDefaultsAreDisabled() throws {
        let source = try repositorySource("Sources/FreeRDPBridge/CBFreeRDPClient.m")

        XCTAssertTrue(source.contains("connectionRef->LoadChannels = NULL;"))
        for disabledSetting in [
            "FreeRDP_DeviceRedirection",
            "FreeRDP_RedirectDrives",
            "FreeRDP_RedirectHomeDrive",
            "FreeRDP_RedirectSmartCards",
            "FreeRDP_RedirectWebAuthN",
            "FreeRDP_RedirectPrinters",
            "FreeRDP_RedirectSerialPorts",
            "FreeRDP_RedirectParallelPorts",
            "FreeRDP_RedirectClipboard",
            "FreeRDP_AudioPlayback",
            "FreeRDP_AudioCapture",
            "FreeRDP_RemoteApplicationMode",
            "FreeRDP_SupportDisplayControl"
        ] {
            XCTAssertTrue(source.contains(disabledSetting))
        }
        XCTAssertTrue(source.contains("disabledChannelSettings[index], FALSE"))
    }

    func testCertificatePolicyAndProductCopyRemainFailClosedAndScopeExact() throws {
        let source = try repositorySource("Sources/FreeRDPBridge/CBFreeRDPClient.m")
        let systemTrust = try repositorySource("Sources/FreeRDPBridge/CBRDPSystemTrust.m")
        let view = try repositorySource("Sources/SkyBridgeCompassApp/RemoteDesktopView.swift")
        let readme = try repositorySource("README.md")
        let discoveryDesign = try repositorySource("Docs/CrossPlatformDiscoveryDesign.md")

        let unknownCallback = try sourceSlice(
            from: "static DWORD CBRejectUnknownCertificate(",
            to: "static DWORD CBRejectChangedCertificate(",
            in: source
        )
        let changedCallback = try sourceSlice(
            from: "static DWORD CBRejectChangedCertificate(",
            to: "@interface CBFreeRDPClient ()",
            in: source
        )
        for callback in [unknownCallback, changedCallback] {
            XCTAssertTrue(callback.contains("return 0;"))
            XCTAssertFalse(callback.contains("return 1;"))
            XCTAssertFalse(callback.contains("return 2;"))
        }
        XCTAssertTrue(source.contains("connectionRef->VerifyCertificateEx = CBRejectUnknownCertificate"))
        XCTAssertTrue(source.contains("connectionRef->VerifyChangedCertificateEx = CBRejectChangedCertificate"))
        XCTAssertTrue(source.contains("connectionRef->VerifyX509Certificate = CBVerifySystemCertificateChain"))
        XCTAssertTrue(source.contains("FreeRDP_IgnoreCertificate, FALSE"))
        XCTAssertTrue(source.contains("FreeRDP_AutoAcceptCertificate, FALSE"))
        XCTAssertTrue(source.contains("FreeRDP_AutoDenyCertificate, TRUE"))
        XCTAssertTrue(source.contains("FreeRDP_ExternalCertificateManagement, TRUE"))
        XCTAssertTrue(source.contains("CBRDPVerifySystemCertificateChain(data, length, hostname"))
        XCTAssertTrue(systemTrust.contains("SecPolicyCreateSSL(true, (__bridge CFStringRef)serverName)"))
        XCTAssertTrue(systemTrust.contains("SecTrustSetNetworkFetchAllowed(trust, false)"))
        XCTAssertTrue(systemTrust.contains("SecTrustEvaluateWithError(trust, &evaluationError)"))
        XCTAssertTrue(systemTrust.contains("verificationFlags != 0"))
        XCTAssertTrue(systemTrust.contains("return 2;"))

        let package = try repositorySource("Package.swift")
        let bridgeTarget = try sourceSlice(
            from: ".target(\n            name: \"FreeRDPBridge\"",
            to: ".target(\n            name: \"SkyBridgeSmokeSupport\"",
            in: package
        )
        XCTAssertTrue(bridgeTarget.contains(".linkedFramework(\"Security\")"))

        XCTAssertTrue(view.contains("if selectedProtocol == .rdp"))
        XCTAssertTrue(view.contains("remote.form.rdp.certificateNotice"))
        for language in ["en", "ja", "zh-Hans"] {
            let localization = try repositorySource(
                "Sources/SkyBridgeCore/Resources/\(language).lproj/Localizable.strings"
            )
            XCTAssertTrue(localization.contains("\"remote.form.rdp.certificateNotice\" ="))
            XCTAssertFalse(localization.localizedCaseInsensitiveContains("RDP — stable across networks"))
            XCTAssertFalse(localization.contains("远距 RDP - 跨网稳定"))
            XCTAssertFalse(localization.contains("遠距離 RDP — ネットワークを跨いでも安定"))
        }

        XCTAssertTrue(readme.contains("本版本没有 TOFU、指纹登记或连接时忽略证书的通道"))
        XCTAssertTrue(readme.contains("真实 Windows 端点验证"))
        XCTAssertFalse(discoveryDesign.contains("macOS 远程桌面**已能**"))
        XCTAssertTrue(discoveryDesign.contains("真实 Windows 端点验收前不得描述为完整或稳定的跨网能力"))
    }

    func testBridgeUsesTheReviewedWinPRSurfaceWithoutWarningSuppressions() throws {
        let package = try repositorySource("Package.swift")
        let implementation = try repositorySource("Sources/FreeRDPBridge/CBFreeRDPClient.m")
        let publicConstants = try repositorySource(
            "Sources/FreeRDPBridge/include/CBFreeRDPConstants.h"
        )

        XCTAssertTrue(package.contains(".define(\"WITHOUT_WINPR_3x_DEPRECATED\", to: \"1\")"))
        XCTAssertTrue(package.contains(".define(\"WITHOUT_FREERDP_3x_DEPRECATED\", to: \"1\")"))
        XCTAssertFalse(package.contains("-Wno-deprecated-declarations"))
        XCTAssertFalse(package.contains("-Wno-macro-redefined"))

        for macro in [
            "E_UNEXPECTED",
            "E_ACCESSDENIED",
            "E_HANDLE",
            "E_OUTOFMEMORY",
            "E_INVALIDARG",
            "E_NOTIMPL",
            "E_NOINTERFACE",
            "E_POINTER",
            "E_ABORT",
            "E_FAIL",
            "HRESULT_CODE",
            "HRESULT_FACILITY",
            "SUCCEEDED",
            "FAILED",
            "IS_ERROR",
            "MAKE_HRESULT",
            "S_OK",
            "S_FALSE"
        ] {
            XCTAssertTrue(
                implementation.contains("#undef \(macro)"),
                "The bridge must explicitly resolve the Apple/WinPR macro collision for \(macro)."
            )
            XCTAssertFalse(
                publicConstants.contains("#undef \(macro)"),
                "The private HRESULT boundary must not mutate public-header consumers."
            )
        }
    }

    func testUnwiredVideoToolboxDecoderWasRemoved() throws {
        let source = try repositorySource("Sources/FreeRDPBridge/CBFreeRDPClient.m")
        let header = try repositorySource("Sources/FreeRDPBridge/include/CBFreeRDPClient.h")
        let package = try repositorySource("Package.swift")
        let bridgeTarget = try sourceSlice(
            from: ".target(\n            name: \"FreeRDPBridge\"",
            to: ".target(\n            name: \"SkyBridgeSmokeSupport\"",
            in: package
        )

        for forbidden in [
            "VideoToolbox",
            "AppleSiliconDecoder",
            "videoToolboxDecompressionCallback",
            "createDecompressionSessionWithWidth",
            "initializeAppleSiliconDecoder",
            "configureAppleSiliconSettings"
        ] {
            XCTAssertFalse(source.contains(forbidden))
            XCTAssertFalse(header.contains(forbidden))
        }
        XCTAssertFalse(bridgeTarget.contains(".linkedFramework(\"CoreVideo\")"))
        XCTAssertFalse(bridgeTarget.contains(".linkedFramework(\"VideoToolbox\")"))
        XCTAssertFalse(bridgeTarget.contains(".linkedFramework(\"CoreMedia\")"))
    }

    private func repositorySource(_ relativePath: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func sourceSlice(from start: String, to end: String, in source: String) throws -> String {
        let startRange = try XCTUnwrap(source.range(of: start))
        let endRange = try XCTUnwrap(
            source.range(of: end, range: startRange.upperBound..<source.endIndex)
        )
        return String(source[startRange.lowerBound..<endRange.lowerBound])
    }
}
