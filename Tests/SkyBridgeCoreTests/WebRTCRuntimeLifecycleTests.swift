#if canImport(WebRTC)
import Foundation
import XCTest
import SkyBridgeWebRTCRuntime
#if os(iOS)
@testable import SkyBridgeCompass_iOS
#else
@testable import SkyBridgeCore
#endif

final class WebRTCRuntimeLifecycleTests: XCTestCase {
    func testConcurrentInitializationRunsNativeInitializerExactlyOnce() {
        let initializationCount = LockedValue(0)
        let failures = LockedValue<[WebRTCRuntimeLifecycleError]>([])
        let unexpectedFailures = LockedValue<[String]>([])
        let lifecycle = WebRTCProcessRuntimeLifecycle {
            initializationCount.withLock { $0 += 1 }
            return true
        }

        DispatchQueue.concurrentPerform(iterations: 128) { _ in
            do {
                try lifecycle.ensureInitialized()
            } catch let error as WebRTCRuntimeLifecycleError {
                failures.withLock { $0.append(error) }
            } catch {
                unexpectedFailures.withLock { $0.append(String(describing: error)) }
            }
        }

        XCTAssertEqual(initializationCount.snapshot, 1)
        XCTAssertEqual(failures.snapshot, [])
        XCTAssertEqual(unexpectedFailures.snapshot, [])
    }

    func testFailedInitializationThrowsTypedErrorAndRemainsFailed() {
        let initializationCount = LockedValue(0)
        let lifecycle = WebRTCProcessRuntimeLifecycle {
            initializationCount.withLock { $0 += 1 }
            return false
        }

        for _ in 0..<2 {
            XCTAssertThrowsError(try lifecycle.ensureInitialized()) { error in
                XCTAssertEqual(
                    error as? WebRTCRuntimeLifecycleError,
                    .sslInitializationFailed
                )
            }
        }

        XCTAssertEqual(
            initializationCount.snapshot,
            1,
            "A failed process-wide SSL initialization must fail closed instead of retrying implicitly"
        )
    }

    func testFactoryProviderReturnsTheSameProcessLifetimeFactory() throws {
        let first = try WebRTCPeerConnectionFactoryProvider.factory(useCustomAudioDevice: false)
        let second = try WebRTCPeerConnectionFactoryProvider.factory(useCustomAudioDevice: false)

        XCTAssertTrue(first === second)
    }

    func testRepeatedSessionCreateCloseKeepsSharedFactoryUsable() throws {
        let factoryBefore = try WebRTCPeerConnectionFactoryProvider.factory(useCustomAudioDevice: false)

        for index in 0..<16 {
            let session = WebRTCSession(
                sessionId: "runtime-lifecycle-\(index)",
                localDeviceId: "runtime-lifecycle-test",
                role: .answerer,
                ice: .init(
                    stunURL: "stun:127.0.0.1:3478",
                    turnURLs: [],
                    turnUsername: "",
                    turnPassword: ""
                )
            )
            try session.start()
            session.close()
            session.close()
        }

        let factoryAfter = try WebRTCPeerConnectionFactoryProvider.factory(useCustomAudioDevice: false)
        XCTAssertTrue(factoryBefore === factoryAfter)
    }

    func testAppleSessionsUseOneSharedRuntimeOwnerWithoutReleaseCounter() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let runtimeSource = try readWebRTCRuntimeSourceShape(
            at: root.appendingPathComponent(
                "Sources/SkyBridgeWebRTCRuntime/WebRTCSessionRuntimeSupport.swift"
            )
        )
        let macSessionSource = try readWebRTCRuntimeSourceShape(
            at: root.appendingPathComponent(
                "Sources/SkyBridgeCore/RemoteConnection/WebRTC/WebRTCSession.swift"
            )
        )
        let iosSessionSource = try readWebRTCRuntimeSourceShape(
            at: root.appendingPathComponent(
                "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Core/RemoteConnection/WebRTC/WebRTCSession.swift"
            )
        )
        let iosProjectSpec = try readWebRTCRuntimeSourceShape(
            at: root.appendingPathComponent("SkyBridge Compass iOS/project.yml")
        )
        let iosPackageManifest = try readWebRTCRuntimeSourceShape(
            at: root.appendingPathComponent("SkyBridge Compass iOS/Package.swift")
        )
        let rootPackageManifest = try readWebRTCRuntimeSourceShape(
            at: root.appendingPathComponent("Package.swift")
        )

        XCTAssertTrue(runtimeSource.contains("guard initializeSSL() else"))
        XCTAssertTrue(runtimeSource.contains("private static let processRuntime"))
        XCTAssertFalse(runtimeSource.contains("RTCCleanupSSL"))
        XCTAssertFalse(runtimeSource.contains("refCount"))
        XCTAssertFalse(runtimeSource.contains("max(0"))

        for sessionSource in [macSessionSource, iosSessionSource] {
            XCTAssertFalse(sessionSource.contains("WebRTCSSL"))
            XCTAssertFalse(sessionSource.contains("sslHeld"))
            XCTAssertFalse(sessionSource.contains("RTCCleanupSSL"))
        }
        XCTAssertFalse(iosSessionSource.contains("private enum WebRTCPeerConnectionFactoryProvider"))
        XCTAssertFalse(iosSessionSource.contains("private actor WebRTCOutboundFrameGate"))
        XCTAssertTrue(macSessionSource.contains("import SkyBridgeWebRTCRuntime"))
        XCTAssertTrue(iosSessionSource.contains("import SkyBridgeWebRTCRuntime"))
        let runtimeProductName = try XCTUnwrap(
            rootPackageManifest.range(of: "name: \"SkyBridgeWebRTCRuntime\"")
        )
        let runtimeProductStart = try XCTUnwrap(
            rootPackageManifest[..<runtimeProductName.lowerBound]
                .range(of: ".library(", options: .backwards)
        )
        let runtimeProductEnd = try XCTUnwrap(
            rootPackageManifest.range(
                of: "),",
                range: runtimeProductName.upperBound..<rootPackageManifest.endIndex
            )
        )
        let runtimeProduct = String(
            rootPackageManifest[runtimeProductStart.lowerBound..<runtimeProductEnd.upperBound]
        )
        XCTAssertTrue(runtimeProduct.contains("type: .static"))
        XCTAssertTrue(
            runtimeProduct.contains(
                "targets: [\"SkyBridgeProtocolCore\", \"SkyBridgeWebRTCRuntime\"]"
            )
        )
        XCTAssertTrue(iosPackageManifest.contains(".product(name: \"SkyBridgeWebRTCRuntime\""))
        XCTAssertFalse(iosPackageManifest.contains(".product(name: \"SkyBridgeProtocolCore\""))
        XCTAssertTrue(iosPackageManifest.contains(".package(name: \"SkyBridgeCameraKit\""))
        XCTAssertTrue(iosPackageManifest.contains(".product(name: \"SkyBridgeCameraKit\""))
        XCTAssertTrue(iosProjectSpec.contains("product: SkyBridgeWebRTCRuntime"))
        XCTAssertTrue(iosProjectSpec.contains("product: SkyBridgeCameraKit"))
        XCTAssertFalse(iosProjectSpec.contains("WebRTCSessionRuntimeSupport.swift"))
    }
}

private func readWebRTCRuntimeSourceShape(at sourceURL: URL) throws -> String {
    #if os(iOS)
    return try readRepositorySourceForSourceShapeTests(at: sourceURL)
    #else
    return try String(contentsOf: sourceURL, encoding: .utf8)
    #endif
}

private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withLock<Result>(_ operation: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return operation(&value)
    }

    var snapshot: Value {
        withLock { $0 }
    }
}
#endif
