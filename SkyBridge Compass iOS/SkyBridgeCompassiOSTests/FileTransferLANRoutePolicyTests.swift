import Foundation
import CryptoKit
import Network
import class SkyBridgeProtocolCore.ClassicTransferOutboundFileReadSession
import class SkyBridgeProtocolCore.ClassicTransferZlibCompressionWorker
import class SkyBridgeProtocolCore.ClassicTransferZlibDecompressionWorker
import enum SkyBridgeProtocolCore.ClassicTransferCanonicalTranscript
import enum SkyBridgeProtocolCore.ClassicTransferChunkContract
import enum SkyBridgeProtocolCore.ClassicTransferChunkContractError
import enum SkyBridgeProtocolCore.ClassicTransferInboundPolicy
import enum SkyBridgeProtocolCore.ClassicTransferMetadataContract
import enum SkyBridgeProtocolCore.ClassicTransferZlibDecompressionError
import struct SkyBridgeProtocolCore.ClassicTransferInboundAdmission
import XCTest
@testable import SkyBridgeCompass_iOS

@MainActor
final class FileTransferLANRoutePolicyTests: XCTestCase {
    func testReceiptWaitTransportAmbiguityIsTypedWithoutMaskingSecurityFailures() {
        let headerTimeout = ClassicTransferDeliveryConfirmationPolicy.normalizedReceiptWaitError(
            FileTransferError.receiptWaitFailed(stage: .headerTimeout, details: nil)
        )
        let connectionClosed = ClassicTransferDeliveryConfirmationPolicy.normalizedReceiptWaitError(
            FileTransferError.networkStageFailed(
                stage: "receipt_payload_connection_closed",
                endpoint: nil,
                details: "closed"
            )
        )
        let authFailure = ClassicTransferDeliveryConfirmationPolicy.normalizedReceiptWaitError(
            FileTransferError.receiptWaitFailed(stage: .authFailed, details: nil)
        )
        let receiverRejection = ClassicTransferDeliveryConfirmationPolicy.normalizedReceiptWaitError(
            FileTransferError.receiptWaitFailed(stage: .receiverRejected, details: "rejected")
        )

        XCTAssertTrue(ClassicTransferDeliveryConfirmationPolicy.isUnknown(headerTimeout))
        XCTAssertTrue(ClassicTransferDeliveryConfirmationPolicy.isUnknown(connectionClosed))
        guard case FileTransferError.receiptWaitFailed(.authFailed, _) = authFailure else {
            return XCTFail("Authentication failure must not become transport ambiguity")
        }
        guard case FileTransferError.receiptWaitFailed(.receiverRejected, _) = receiverRejection else {
            return XCTFail("Receiver rejection must remain explicit")
        }
    }

    func testReceiptDeliveryStatusSurvivesFileTransferHistoryCoding() throws {
        let transfer = FileTransfer(
            id: "receipt-unknown",
            fileName: "archive.bin",
            fileSize: 1,
            status: .completed,
            isIncoming: true,
            remotePeer: "peer",
            localPath: "/tmp/archive.bin",
            receiptDeliveryStatus: .unknown
        )

        let decoded = try JSONDecoder().decode(
            FileTransfer.self,
            from: JSONEncoder().encode(transfer)
        )

        XCTAssertEqual(decoded.receiptDeliveryStatus, .unknown)
        XCTAssertEqual(decoded.localPath, transfer.localPath)
    }

    func testOperationalWarningSurvivesFileTransferHistoryCoding() throws {
        let transfer = FileTransfer(
            id: "committed-release-warning",
            fileName: "archive.bin",
            fileSize: 1,
            status: .completed,
            isIncoming: true,
            remotePeer: "peer",
            localPath: "/tmp/archive.bin",
            receiptDeliveryStatus: .delivered,
            operationalWarning: .committedFileReleaseFailed
        )

        let decoded = try JSONDecoder().decode(
            FileTransfer.self,
            from: JSONEncoder().encode(transfer)
        )

        XCTAssertEqual(decoded.operationalWarning, .committedFileReleaseFailed)
        XCTAssertEqual(decoded.receiptDeliveryStatus, .delivered)
    }

    func testWebRTCCompletionPolicySeparatesAmbiguityAndRejection() {
        for error in [
            CrossNetworkWebRTCManager.FileTransferWaitError.timeout,
            CrossNetworkWebRTCManager.FileTransferWaitError.transportClosed
        ] {
            let normalized = WebRTCCompletionConfirmationPolicy.normalizedWaitError(error)
            guard let transferError = normalized as? FileTransferError,
                  case .deliveryConfirmationUnknown = transferError else {
                return XCTFail("Terminal WebRTC transport ambiguity must remain explicit")
            }
        }

        let rejection = FileTransferError.transferFailed("receiver rejected")
        guard case FileTransferError.transferFailed(let reason) =
                WebRTCCompletionConfirmationPolicy.normalizedWaitError(rejection) else {
            return XCTFail("Receiver rejection must not become transport ambiguity")
        }
        XCTAssertEqual(reason, "receiver rejected")

        let cancellation = WebRTCCompletionConfirmationPolicy.normalizedWaitError(
            CancellationError()
        )
        guard let transferError = cancellation as? FileTransferError,
              case .deliveryConfirmationUnknown = transferError else {
            return XCTFail("Terminal cancellation must remain commit ambiguity")
        }
    }

    func testWebRTCChunkAcknowledgmentRetriesOnlyTimeouts() {
        XCTAssertTrue(
            WebRTCChunkAcknowledgmentRetryPolicy.shouldRetry(
                after: CrossNetworkWebRTCManager.FileTransferWaitError.timeout
            )
        )
        XCTAssertFalse(
            WebRTCChunkAcknowledgmentRetryPolicy.shouldRetry(
                after: CrossNetworkWebRTCManager.FileTransferWaitError.transportClosed
            )
        )
        XCTAssertFalse(
            WebRTCChunkAcknowledgmentRetryPolicy.shouldRetry(
                after: FileTransferError.transferFailed("integrity rejected")
            )
        )
        XCTAssertFalse(
            WebRTCChunkAcknowledgmentRetryPolicy.shouldRetry(after: CancellationError())
        )
    }

    func testExternalInboundTokenRejectsStaleSameIdentifierCallbacks() async throws {
        let manager = FileTransferManager.instance
        let transferID = "ios-external-token-\(UUID().uuidString)"
        let firstToken = try XCTUnwrap(manager.beginExternalInboundTransfer(
            transferId: transferID,
            fileName: "first.bin",
            fileSize: 100,
            fromPeerName: "Peer"
        ))
        manager.completeExternalInboundTransfer(
            token: firstToken,
            success: false,
            error: "first failed"
        )

        let currentToken = try XCTUnwrap(manager.beginExternalInboundTransfer(
            transferId: transferID,
            fileName: "second.bin",
            fileSize: 100,
            fromPeerName: "Peer"
        ))
        await manager.updateExternalInboundProgress(
            token: firstToken,
            transferredBytes: 100,
            totalBytes: 100
        )
        manager.completeExternalInboundTransfer(
            token: firstToken,
            success: true,
            destinationURL: URL(fileURLWithPath: "/tmp/stale.bin")
        )

        let current = try XCTUnwrap(manager.activeTransfers.first(where: { $0.id == transferID }))
        XCTAssertEqual(current.fileName, "second.bin")
        XCTAssertEqual(current.status, .pending)
        XCTAssertEqual(current.progress, 0)
        XCTAssertNil(current.localPath)

        manager.completeExternalInboundTransfer(
            token: currentToken,
            success: false,
            error: "test cleanup"
        )
        XCTAssertFalse(manager.activeTransfers.contains(where: { $0.id == transferID }))
    }

    func testClassifiesRouteAddressesAndPeerToPeerPreference() {
        let lanHost = NWEndpoint.hostPort(host: "192.168.31.20", port: 8080)
        let linkLocalHost = NWEndpoint.hostPort(host: "fe80::1%en0", port: 8080)
        let bonjour = NWEndpoint.service(
            name: "Mac",
            type: DiscoveredDevice.fileTransferServiceType,
            domain: "local",
            interface: nil
        )

        XCTAssertEqual(FileTransferLANRoutePolicy.routeAddressClass(for: lanHost), "lan-direct")
        XCTAssertEqual(FileTransferLANRoutePolicy.routeAddressClass(for: bonjour), "bonjour-service")
        XCTAssertEqual(FileTransferLANRoutePolicy.routeAddressClass(for: nil), "unresolved")
        XCTAssertFalse(FileTransferLANRoutePolicy.shouldIncludePeerToPeer(for: lanHost))
        XCTAssertTrue(FileTransferLANRoutePolicy.shouldIncludePeerToPeer(for: linkLocalHost))
        XCTAssertTrue(FileTransferLANRoutePolicy.routePrefersPeerToPeer(for: linkLocalHost))
        XCTAssertEqual(
            FileTransferLANRoutePolicy.statusToken("host 192.168.31.20"),
            "host_192.168.31.20"
        )
    }

    func testRejectsUnverifiedBonjourAndPeerToPeerRoutes() {
        let bonjour = NWEndpoint.service(
            name: "Mac",
            type: DiscoveredDevice.fileTransferServiceType,
            domain: "local",
            interface: nil
        )
        let routableHost = NWEndpoint.hostPort(host: "192.168.31.20", port: 8080)
        let linkLocalHost = NWEndpoint.hostPort(host: "fe80::1%en0", port: 8080)

        XCTAssertNil(
            FileTransferLANRoutePolicy.resolvedRouteRejection(
                requestedEndpoint: routableHost,
                resolvedEndpoint: routableHost
            )
        )
        XCTAssertEqual(
            FileTransferLANRoutePolicy.resolvedRouteRejection(
                requestedEndpoint: linkLocalHost,
                resolvedEndpoint: linkLocalHost
            ),
            "requested peer-to-peer file-transfer route rejected: requested=\(String(describing: linkLocalHost))"
        )
        XCTAssertEqual(
            FileTransferLANRoutePolicy.resolvedRouteRejection(
                requestedEndpoint: bonjour,
                resolvedEndpoint: nil
            ),
            "unverified Bonjour file-transfer route rejected: requested=\(String(describing: bonjour))"
        )
        XCTAssertEqual(
            FileTransferLANRoutePolicy.resolvedRouteRejection(
                requestedEndpoint: bonjour,
                resolvedEndpoint: linkLocalHost
            ),
            "resolved peer-to-peer file-transfer route rejected: requested=\(String(describing: bonjour)) resolved=\(String(describing: linkLocalHost))"
        )
    }

    func testClassicInboundAdmissionAndChunkContractFailClosed() throws {
        var admission = ClassicTransferInboundAdmission(limit: 1)
        XCTAssertTrue(admission.reserve(connectionID: "connection-a"))
        XCTAssertFalse(admission.reserve(connectionID: "connection-b"))
        admission.release(connectionID: "connection-a")
        XCTAssertTrue(admission.reserve(connectionID: "connection-b"))

        XCTAssertEqual(
            try ClassicTransferChunkContract.decompressedOutputLimit(
                declaredChunkSize: 4,
                receivedBytes: 6,
                declaredFileSize: 10,
                negotiatedChunkSize: 8,
                maximumChunkSize: 8
            ),
            4
        )
        XCTAssertThrowsError(
            try ClassicTransferChunkContract.decompressedOutputLimit(
                declaredChunkSize: 5,
                receivedBytes: 6,
                declaredFileSize: 10,
                negotiatedChunkSize: 8,
                maximumChunkSize: 8
            )
        ) { error in
            XCTAssertEqual(
                error as? ClassicTransferChunkContractError,
                .chunkExceedsRemainingFileSize
            )
        }
        XCTAssertThrowsError(
            try ClassicTransferChunkContract.validateCompletion(
                receivedBytes: 9,
                declaredFileSize: 10
            )
        ) { error in
            XCTAssertEqual(
                error as? ClassicTransferChunkContractError,
                .completedFileSizeMismatch
            )
        }
    }

    func testClassicZlibWorkersEnforceNegotiatedBounds() async throws {
        let original = Data(repeating: 0x5A, count: 4_096)
        let compressed = try await ClassicTransferZlibCompressionWorker.shared.compress(
            original,
            maximumInputSize: original.count
        )
        let decoded = try await ClassicTransferZlibDecompressionWorker.shared.decompress(
            compressed,
            maximumOutputSize: original.count
        )
        XCTAssertEqual(decoded, original)

        do {
            _ = try await ClassicTransferZlibDecompressionWorker.shared.decompress(
                compressed,
                maximumOutputSize: original.count - 1
            )
            XCTFail("The decoder must enforce its cap while expanding zlib data")
        } catch let error as ClassicTransferZlibDecompressionError {
            XCTAssertEqual(error, .outputLimitExceeded)
        }
    }

    func testClassicV2TranscriptAndFilenamePolicyMatchMacContract() throws {
        let receipt = try ClassicTransferCanonicalTranscript.receipt(
            transferID: "t",
            success: true,
            receivedBytes: 0,
            fileHash: nil,
            error: nil,
            securityVersion: 2
        )
        XCTAssertEqual(
            receipt.map { String(format: "%02x", $0) }.joined(),
            "536b79427269646765436c61737369635472616e736665720002000000020005000b7472616e736665725f69640100000000000000017400077375636365737301000000000000000131000e72656365697665645f627974657301000000000000000130000966696c655f6861736800000000000000000000056572726f72000000000000000000"
        )
        for version in [-1, 0, 1, 3, Int.max] {
            XCTAssertThrowsError(
                try ClassicTransferCanonicalTranscript.receipt(
                    transferID: "t",
                    success: true,
                    receivedBytes: 0,
                    fileHash: nil,
                    error: nil,
                    securityVersion: version
                )
            )
        }
        for name in ["a\u{202E}b", "a\u{29F5}b", "a\u{29F9}b", "a\u{FE68}b", "a\u{FF3C}b"] {
            XCTAssertThrowsError(try ClassicTransferMetadataContract.validateFileName(name))
        }
    }

    func testClassicPeerResolutionPrefersCanonicalIdentityAndRejectsAliasAmbiguity() {
        let canonical = ClassicTransferAuthenticatedPeerCandidate(
            matchDeviceId: "id:canonical",
            resolvedPeerDeviceId: "id:canonical",
            aliases: ["id:canonical"],
            endpointHostOrIP: nil,
            capabilities: []
        )
        let aliasOnly = ClassicTransferAuthenticatedPeerCandidate(
            matchDeviceId: "id:alias-only",
            resolvedPeerDeviceId: "id:alias-only",
            aliases: ["id:canonical", "shared-alias"],
            endpointHostOrIP: nil,
            capabilities: []
        )
        let exactContext = FileTransferPeerContext(
            declaredSenderDeviceId: "id:canonical",
            endpointHostOrIP: nil,
            peerLabel: nil,
            transferId: "exact"
        )
        for peers in [[aliasOnly, canonical], [canonical, aliasOnly]] {
            XCTAssertEqual(
                FileTransferClassicPeerResolutionPolicy.resolvePeer(
                    peerContext: exactContext,
                    authenticatedPeers: peers
                )?.resolvedPeerDeviceId,
                "id:canonical"
            )
        }

        let secondAlias = ClassicTransferAuthenticatedPeerCandidate(
            matchDeviceId: "id:second",
            resolvedPeerDeviceId: "id:second",
            aliases: ["shared-alias"],
            endpointHostOrIP: nil,
            capabilities: []
        )
        XCTAssertNil(
            FileTransferClassicPeerResolutionPolicy.resolvePeer(
                peerContext: .init(
                    declaredSenderDeviceId: "shared-alias",
                    endpointHostOrIP: nil,
                    peerLabel: nil,
                    transferId: "ambiguous"
                ),
                authenticatedPeers: [aliasOnly, secondAlias]
            )
        )

        let duplicateSession = ClassicTransferAuthenticatedPeerCandidate(
            matchDeviceId: "id:canonical-session-2",
            resolvedPeerDeviceId: "id:canonical",
            aliases: ["same-peer-endpoint"],
            endpointHostOrIP: "192.0.2.20",
            capabilities: []
        )
        let firstSession = ClassicTransferAuthenticatedPeerCandidate(
            matchDeviceId: "id:canonical-session-1",
            resolvedPeerDeviceId: "id:canonical",
            aliases: ["same-peer-endpoint"],
            endpointHostOrIP: "192.0.2.20",
            capabilities: []
        )
        XCTAssertEqual(
            FileTransferClassicPeerResolutionPolicy.resolvePeer(
                peerContext: .init(
                    declaredSenderDeviceId: nil,
                    endpointHostOrIP: "same-peer-endpoint",
                    peerLabel: nil,
                    transferId: "same-peer"
                ),
                authenticatedPeers: [duplicateSession, firstSession]
            )?.resolvedPeerDeviceId,
            "id:canonical"
        )
    }

    func testIOSDoesNotAdvertiseUnsupportedClassicResumeAndUsesCanonicalProtocolModule() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let networkSource = try readRepositorySourceForSourceShapeTests(
            at: root.appendingPathComponent(
                "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Core/FileTransfer/FileTransferNetworkService.swift"
            )
        )
        let projectYAML = try readRepositorySourceForSourceShapeTests(
            at: root.appendingPathComponent("SkyBridge Compass iOS/project.yml")
        )
        let rootPackageManifest = try readRepositorySourceForSourceShapeTests(
            at: root.appendingPathComponent("Package.swift")
        )
        let iosPackageManifest = try readRepositorySourceForSourceShapeTests(
            at: root.appendingPathComponent("SkyBridge Compass iOS/Package.swift")
        )

        XCTAssertTrue(
            networkSource.contains("BonjourInteropProtocolContract.canonicalAdvertisementFields(")
        )
        XCTAssertTrue(networkSource.contains("role: .dedicatedService"))
        XCTAssertFalse(networkSource.contains("\"capabilities\": Data("))
        XCTAssertFalse(networkSource.contains("\"transferPort\": Data("))
        XCTAssertFalse(networkSource.contains("ClassicTransferCapability.classicResume)\".utf8"))
        XCTAssertTrue(networkSource.contains("case .resumeRequest:"))
        XCTAssertTrue(networkSource.contains("return .failure(.unsupportedResumeRequest)"))
        let appTargetStart = try XCTUnwrap(projectYAML.range(of: "  SkyBridgeCompass-iOS:\n"))
        let appTargetEnd = try XCTUnwrap(
            projectYAML.range(
                of: "  SkyBridgeCompass-Widgets:\n",
                range: appTargetStart.upperBound..<projectYAML.endIndex
            )
        )
        let appTarget = String(projectYAML[appTargetStart.lowerBound..<appTargetEnd.lowerBound])
        XCTAssertFalse(appTarget.contains("product: SkyBridgeProtocolCore"))
        XCTAssertTrue(appTarget.contains("product: SkyBridgeWebRTCRuntime"))

        let testTargetStart = try XCTUnwrap(projectYAML.range(of: "  SkyBridgeCompassiOSTests:\n"))
        let testTargetEnd = try XCTUnwrap(
            projectYAML.range(
                of: "\nschemes:\n",
                range: testTargetStart.upperBound..<projectYAML.endIndex
            )
        )
        let testTarget = String(projectYAML[testTargetStart.lowerBound..<testTargetEnd.lowerBound])
        XCTAssertTrue(testTarget.contains("product: SkyBridgeWebRTCRuntime"))
        XCTAssertFalse(testTarget.contains("product: SkyBridgeProtocolCore"))
        XCTAssertTrue(iosPackageManifest.contains("product(name: \"SkyBridgeWebRTCRuntime\""))
        XCTAssertFalse(iosPackageManifest.contains("product(name: \"SkyBridgeProtocolCore\""))
        XCTAssertTrue(
            rootPackageManifest.contains(
                "targets: [\"SkyBridgeProtocolCore\", \"SkyBridgeWebRTCRuntime\"]"
            )
        )
        let runtimeTargetStart = try XCTUnwrap(
            rootPackageManifest.range(
                of: ".target(\n            name: \"SkyBridgeWebRTCRuntime\""
            )
        )
        let runtimeTargetEnd = try XCTUnwrap(
            rootPackageManifest.range(
                of: "name: \"CSkyBridgeOpusShim\"",
                range: runtimeTargetStart.upperBound..<rootPackageManifest.endIndex
            )
        )
        let runtimeTarget = String(
            rootPackageManifest[runtimeTargetStart.lowerBound..<runtimeTargetEnd.lowerBound]
        )
        XCTAssertTrue(runtimeTarget.contains("\"SkyBridgeProtocolCore\""))
        XCTAssertFalse(
            projectYAML.contains(
                "../Sources/SkyBridgeProtocolCore/RemoteConnection/WebRTC/InboundFileTransferIOActor.swift"
            )
        )
    }

    func testClassicInboundSourceKeepsAuthenticationCleanupAndResourceBoundaries() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let managerSource = try readRepositorySourceForSourceShapeTests(
            at: root.appendingPathComponent(
                "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/FileTransferManager.swift"
            )
        )
        let networkSource = try readRepositorySourceForSourceShapeTests(
            at: root.appendingPathComponent(
                "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Core/FileTransfer/FileTransferNetworkService.swift"
            )
        )
        let ioActorSource = try readRepositorySourceForSourceShapeTests(
            at: root.appendingPathComponent(
                "Sources/SkyBridgeProtocolCore/RemoteConnection/WebRTC/InboundFileTransferIOActor.swift"
            )
        )

        let receiveStart = try XCTUnwrap(managerSource.range(of: "    func receiveFile(\n"))
        let receiveEnd = try XCTUnwrap(
            managerSource.range(
                of: "    /// 取消传输",
                range: receiveStart.upperBound..<managerSource.endIndex
            )
        )
        let receiveBody = String(managerSource[receiveStart.lowerBound..<receiveEnd.lowerBound])
        let authentication = try XCTUnwrap(
            receiveBody.range(of: "guard isValidAuthenticationTag(")
        )
        let publication = try XCTUnwrap(
            receiveBody.range(of: "activeTransfers.append(transfer)")
        )
        let slotAcquisition = try XCTUnwrap(
            receiveBody.range(of: "try await acquireTransferSlot()")
        )
        XCTAssertLessThan(authentication.lowerBound, publication.lowerBound)
        XCTAssertLessThan(authentication.lowerBound, slotAcquisition.lowerBound)
        XCTAssertLessThan(slotAcquisition.lowerBound, publication.lowerBound)

        let prePublication = String(receiveBody[..<publication.lowerBound])
        XCTAssertFalse(prePublication.contains("postInAppTransferEvent("))
        XCTAssertFalse(prePublication.contains("postLocalFileTransferNotification("))
        XCTAssertFalse(prePublication.contains("completeTransfer("))
        XCTAssertTrue(prePublication.contains("authenticationBoundary=pre_authentication"))

        let cleanupStart = try XCTUnwrap(ioActorSource.range(of: "    public func discard("))
        let cleanupEnd = try XCTUnwrap(
            ioActorSource.range(
                of: "    public func activeTransferCount()",
                range: cleanupStart.upperBound..<ioActorSource.endIndex
            )
        )
        let cleanupBody = String(ioActorSource[cleanupStart.lowerBound..<cleanupEnd.lowerBound])
        let close = try XCTUnwrap(cleanupBody.range(of: "try writer.close()"))
        let remove = try XCTUnwrap(
            cleanupBody.range(of: "try Self.removeIdentityBoundFileIfPresent(")
        )
        XCTAssertLessThan(close.lowerBound, remove.lowerBound)
        XCTAssertTrue(receiveBody.contains("InboundFileTransferIOActor.shared.createTemporaryFile"))
        XCTAssertTrue(receiveBody.contains("InboundFileTransferIOActor.shared.discard"))
        XCTAssertTrue(receiveBody.contains("InboundFileTransferIOActor.shared.commit"))
        XCTAssertTrue(cleanupBody.contains("throw InboundFileTransferIOError.cleanupFailed"))
        XCTAssertTrue(ioActorSource.contains("O_CREAT | O_EXCL | O_NOFOLLOW"))
        XCTAssertTrue(ioActorSource.contains("AT_SYMLINK_NOFOLLOW"))
        XCTAssertTrue(ioActorSource.contains("renameatx_np"))
        XCTAssertFalse(managerSource.contains("FileHandle(forWritingAtPath:"))

        XCTAssertTrue(networkSource.contains("inboundAdmission.reserve(connectionID: connectionId)"))
        XCTAssertTrue(networkSource.contains("ClassicTransferInboundPolicy.initialHeaderTimeoutSeconds"))
        XCTAssertTrue(networkSource.contains("ClassicTransferInboundPolicy.metadataPayloadTimeoutSeconds"))
        XCTAssertTrue(networkSource.contains("inboundAdmission.release(connectionID: connectionId)"))
        XCTAssertTrue(networkSource.contains("inboundHandlerTasks.removeValue(forKey: connectionId)?.cancel()"))
        XCTAssertTrue(networkSource.contains("catch is CancellationError"))
        XCTAssertTrue(networkSource.contains("deadline task failed; rejecting connection"))
        XCTAssertTrue(managerSource.contains("ClassicTransferZlibCompressionWorker.shared.compress"))
        XCTAssertTrue(managerSource.contains("ClassicTransferZlibDecompressionWorker.shared.decompress"))
        XCTAssertTrue(managerSource.contains("ClassicTransferChunkContract.validateCompletion"))
        XCTAssertFalse(managerSource.contains(".decompressed(using: .zlib)"))
        XCTAssertFalse(managerSource.contains("WebRTCOutboundFileReadSession"))
        XCTAssertTrue(managerSource.contains("ClassicTransferOutboundFileReadSession.open"))
    }

    func testWebRTCOutboundReaderProducesTheCompletionSHA256UsedByIOS() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("ios-webrtc-reader-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { XCTAssertNoThrow(try fileManager.removeItem(at: directory)) }
        let fileURL = directory.appendingPathComponent("payload.bin", isDirectory: false)
        let payload = Data((0..<1_025).map { UInt8($0 % 251) })
        try payload.write(to: fileURL, options: [.withoutOverwriting])

        let reader = try await ClassicTransferOutboundFileReadSession.open(
            url: fileURL,
            tracksSHA256: true
        )
        let firstChunk = try await reader.read(offset: 0, length: 512)
        let secondChunk = try await reader.read(offset: 512, length: payload.count - 512)
        let completionDigest = try await reader.finalizeAndClose()

        XCTAssertEqual(firstChunk + secondChunk, payload)
        XCTAssertEqual(completionDigest, Data(SHA256.hash(data: payload)))
    }

    func testIOSRemoteFileTransferStatusNormalizationIsBoundedAndControlSafe() {
        let exactBoundary = String(repeating: "a", count: 509) + "界"
        XCTAssertEqual(
            CrossNetworkWebRTCManager.normalizedRemoteFileTransferStatusMessage(
                exactBoundary,
                fallback: "fallback"
            ),
            exactBoundary
        )

        let overflowingScalar = String(repeating: "a", count: 510) + "界"
        let truncated = CrossNetworkWebRTCManager.normalizedRemoteFileTransferStatusMessage(
            overflowingScalar,
            fallback: "fallback"
        )
        XCTAssertEqual(truncated, String(repeating: "a", count: 510))
        XCTAssertLessThanOrEqual(truncated.utf8.count, 512)

        let controlSafe = CrossNetworkWebRTCManager.normalizedRemoteFileTransferStatusMessage(
            "denied\u{0000}retry\nlater\t\u{007F}",
            fallback: "fallback"
        )
        XCTAssertEqual(controlSafe, "denied retry later")
        XCTAssertFalse(
            controlSafe.unicodeScalars.contains {
                CharacterSet.controlCharacters.contains($0)
            }
        )
        XCTAssertEqual(
            CrossNetworkWebRTCManager.normalizedRemoteFileTransferStatusMessage(
                "\u{0000}\n\t\u{007F}",
                fallback: "fallback"
            ),
            "fallback"
        )
    }

    func testIOSWebRTCHeartbeatCarriesOnlyAuthenticatedFileTransferCapability() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let managerSource = try readRepositorySourceForSourceShapeTests(
            at: root.appendingPathComponent(
                "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/CrossNetworkWebRTCManager.swift"
            )
        )

        let heartbeatStart = try XCTUnwrap(
            managerSource.range(of: "    public func startRemoteDesktopHeartbeat()")
        )
        let heartbeatEnd = try XCTUnwrap(
            managerSource.range(
                of: "    private func shouldAutoStartRemoteDesktopHeartbeat()",
                range: heartbeatStart.upperBound..<managerSource.endIndex
            )
        )
        let heartbeatBody = String(
            managerSource[heartbeatStart.lowerBound..<heartbeatEnd.lowerBound]
        )
        XCTAssertTrue(
            heartbeatBody.contains("let fileTransferReady = FileTransferRuntime.shared.isReady")
        )
        XCTAssertTrue(
            heartbeatBody.contains(
                "capabilities: fileTransferReady ? [\"file_transfer\"] : []"
            )
        )
        XCTAssertTrue(
            heartbeatBody.contains(
                "fileTransferPort: fileTransferReady ? FileTransferConstants.defaultPort : nil"
            )
        )
        XCTAssertTrue(heartbeatBody.contains("remoteControlPort: nil"))
        XCTAssertFalse(heartbeatBody.contains("classic_resume"))
        XCTAssertFalse(heartbeatBody.contains("capabilities: [\"remote"))
        XCTAssertFalse(heartbeatBody.contains("capabilities: [\"clipboard"))
        XCTAssertTrue(heartbeatBody.contains("self.sendAppMessageOverWebRTC("))
        XCTAssertTrue(managerSource.contains("return currentRole != nil"))
        XCTAssertFalse(managerSource.contains("return currentRole == .answerer"))

        let secureSendStart = try XCTUnwrap(
            managerSource.range(of: "    func sendAppMessageOverWebRTC(")
        )
        let secureSendEnd = try XCTUnwrap(
            managerSource.range(
                of: "func sendPairingIdentityExchangeOverWebRTC(",
                range: secureSendStart.upperBound..<managerSource.endIndex
            )
        )
        let secureSendBody = String(
            managerSource[secureSendStart.lowerBound..<secureSendEnd.lowerBound]
        )
        XCTAssertTrue(secureSendBody.contains("let payload = try JSONEncoder().encode(message)"))
        XCTAssertTrue(
            secureSendBody.contains(
                "encrypt(plaintext: payload, with: keys, packetType: .appControl)"
            )
        )
        XCTAssertTrue(secureSendBody.contains("try await sendFramed(padded, over: session)"))
    }

    func testClassicFileTransferDefaultPortRemains8080() {
        XCTAssertEqual(FileTransferConstants.defaultPort, 8080)
    }

    func testIOSWebRTCProductionPathTracksCompletionHashAndDispatchesThroughTransferLanes() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fileTransferManagerSource = try readRepositorySourceForSourceShapeTests(
            at: root.appendingPathComponent(
                "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/FileTransferManager.swift"
            )
        )
        let webRTCManagerSource = try readRepositorySourceForSourceShapeTests(
            at: root.appendingPathComponent(
                "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/CrossNetworkWebRTCManager.swift"
            )
        )
        let fileTransferExtensionSource = try readRepositorySourceForSourceShapeTests(
            at: root.appendingPathComponent(
                "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/CrossNetworkWebRTCManager+FileTransfer.swift"
            )
        )

        let sendStart = try XCTUnwrap(
            fileTransferManagerSource.range(of: "    private func sendFileOverWebRTC(")
        )
        let sendEnd = try XCTUnwrap(
            fileTransferManagerSource.range(
                of: "    private func ensureWebRTCTransferMayContinue(",
                range: sendStart.upperBound..<fileTransferManagerSource.endIndex
            )
        )
        let sendBody = String(
            fileTransferManagerSource[sendStart.lowerBound..<sendEnd.lowerBound]
        )
        XCTAssertTrue(sendBody.contains("ClassicTransferOutboundFileReadSession.open("))
        XCTAssertTrue(sendBody.contains("tracksSHA256: true"))
        XCTAssertTrue(sendBody.contains("let fileSha256 = try await reader.finalizeAndClose()"))
        XCTAssertTrue(sendBody.contains("fileSha256: fileSha256"))

        let decodeStart = try XCTUnwrap(
            webRTCManagerSource.range(of: "    private func handleDecodedControlPlaintext(")
        )
        let decodeEnd = try XCTUnwrap(
            webRTCManagerSource.range(
                of: "    private func hasActiveHandshakeDriver()",
                range: decodeStart.upperBound..<webRTCManagerSource.endIndex
            )
        )
        let decodeBody = String(webRTCManagerSource[decodeStart.lowerBound..<decodeEnd.lowerBound])
        XCTAssertTrue(decodeBody.contains("await dispatchInboundFileTransferFromMac("))
        XCTAssertFalse(decodeBody.contains("await handleInboundFileTransferFromMac("))
        XCTAssertTrue(
            fileTransferExtensionSource.contains(
                "queuedInboundFileTransferOperationsByTransferID[message.transferId, default: []]"
            )
        )
        XCTAssertTrue(
            fileTransferExtensionSource.contains(
                "CrossNetworkCancelledTaskTeardownJoiner.joinCancelledTask("
            )
        )
        XCTAssertTrue(
            fileTransferExtensionSource.contains(
                "CrossNetworkExactOwnerDictionary.removeValue("
            )
        )
        XCTAssertFalse(fileTransferExtensionSource.contains("await operationWorker.value"))
    }
}

private final class BlockingFileTransferHistoryPersistence: @unchecked Sendable {
    private enum InjectedError: Error {
        case loadTimedOut
    }

    private let lock = NSLock()
    private let loadRelease = DispatchSemaphore(value: 0)
    private var loadStarted = false
    private var storedHistory: [FileTransfer]?

    init(storedHistory: [FileTransfer]?) {
        self.storedHistory = storedHistory
    }

    var persistence: FileTransferHistoryPersistence {
        FileTransferHistoryPersistence(
            load: { [self] in try load() },
            save: { [self] in save($0) },
            remove: { [self] in remove() }
        )
    }

    func hasStartedLoading() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return loadStarted
    }

    func releaseLoad() {
        loadRelease.signal()
    }

    func persistedIDs() -> [String]? {
        lock.lock()
        defer { lock.unlock() }
        return storedHistory?.map(\.id)
    }

    private func load() throws -> [FileTransfer]? {
        lock.lock()
        loadStarted = true
        lock.unlock()

        guard loadRelease.wait(timeout: .now() + 5) == .success else {
            throw InjectedError.loadTimedOut
        }

        lock.lock()
        defer { lock.unlock() }
        return storedHistory
    }

    private func save(_ history: [FileTransfer]) {
        lock.lock()
        storedHistory = history
        lock.unlock()
    }

    private func remove() {
        lock.lock()
        storedHistory = nil
        lock.unlock()
    }
}

final class FileTransferHistoryRepositoryTests: XCTestCase {
    private enum InMemoryFailure: Error {
        case load
    }

    private final class InMemoryStore: @unchecked Sendable {
        private let lock = NSLock()
        private var history: [FileTransfer]?

        init(history: [FileTransfer]? = nil) {
            self.history = history
        }

        var persistence: FileTransferHistoryPersistence {
            FileTransferHistoryPersistence(
                load: { [self] in load() },
                save: { [self] in save($0) },
                remove: { [self] in remove() }
            )
        }

        func persistedIDs() -> [String]? {
            lock.lock()
            defer { lock.unlock() }
            return history?.map(\.id)
        }

        private func load() -> [FileTransfer]? {
            lock.lock()
            defer { lock.unlock() }
            return history
        }

        private func save(_ replacement: [FileTransfer]) {
            lock.lock()
            history = replacement
            lock.unlock()
        }

        private func remove() {
            lock.lock()
            history = nil
            lock.unlock()
        }
    }

    private func transfer(id: String) -> FileTransfer {
        FileTransfer(
            id: id,
            fileName: "\(id).bin",
            fileSize: 1,
            fileType: .other,
            progress: 1,
            speed: 0,
            status: .completed,
            isIncoming: true,
            remotePeer: "peer"
        )
    }

    private func waitUntilLoadStarts(
        _ persistence: BlockingFileTransferHistoryPersistence
    ) async -> Bool {
        for _ in 0..<10_000 {
            if persistence.hasStartedLoading() {
                return true
            }
            await Task.yield()
        }
        return false
    }

    func testMissingHistoryAppendAndClearRemainCanonical() async {
        let store = InMemoryStore()
        let repository = FileTransferHistoryRepository(persistence: store.persistence)

        let bootstrap = await repository.apply(.bootstrap, generation: 1)
        XCTAssertTrue(bootstrap.history.isEmpty)
        XCTAssertNil(bootstrap.failure)

        let appended = await repository.apply(.prepend(transfer(id: "new")), generation: 2)
        XCTAssertEqual(appended.history.map(\.id), ["new"])
        XCTAssertEqual(store.persistedIDs(), ["new"])

        let cleared = await repository.apply(.clear, generation: 3)
        XCTAssertTrue(cleared.history.isEmpty)
        XCTAssertNil(cleared.failure)
        XCTAssertNil(store.persistedIDs())
    }

    func testBootstrapThenAppendDoesNotLoseEitherAuthorityAndDoesNotBlockMainActor() async {
        let store = BlockingFileTransferHistoryPersistence(
            storedHistory: [transfer(id: "persisted")]
        )
        let repository = FileTransferHistoryRepository(persistence: store.persistence)
        let bootstrapTask = Task {
            await repository.apply(.bootstrap, generation: 1)
        }

        guard await waitUntilLoadStarts(store) else {
            store.releaseLoad()
            _ = await bootstrapTask.value
            XCTFail("Expected repository load to start")
            return
        }

        let appendedTransfer = transfer(id: "appended")
        let appendTask = Task {
            await repository.apply(.prepend(appendedTransfer), generation: 2)
        }
        let mainActorHeartbeat = await MainActor.run { true }
        XCTAssertTrue(mainActorHeartbeat)

        store.releaseLoad()
        let bootstrap = await bootstrapTask.value
        let appended = await appendTask.value
        XCTAssertEqual(bootstrap.history.map(\.id), ["persisted"])
        XCTAssertEqual(appended.history.map(\.id), ["appended", "persisted"])
        XCTAssertEqual(store.persistedIDs(), ["appended", "persisted"])
    }

    func testBootstrapThenClearCannotResurrectLoadedHistory() async {
        let store = BlockingFileTransferHistoryPersistence(
            storedHistory: [transfer(id: "persisted")]
        )
        let repository = FileTransferHistoryRepository(persistence: store.persistence)
        let bootstrapTask = Task {
            await repository.apply(.bootstrap, generation: 1)
        }

        guard await waitUntilLoadStarts(store) else {
            store.releaseLoad()
            _ = await bootstrapTask.value
            XCTFail("Expected repository load to start")
            return
        }

        let clearTask = Task {
            await repository.apply(.clear, generation: 2)
        }
        store.releaseLoad()
        _ = await bootstrapTask.value
        let cleared = await clearTask.value
        XCTAssertTrue(cleared.history.isEmpty)
        XCTAssertNil(store.persistedIDs())
    }

    func testHistoryIsTrimmedToOneHundredInMemoryAndOnDisk() async {
        let initialHistory = (0..<120).map { transfer(id: "item-\($0)") }
        let store = InMemoryStore(history: initialHistory)
        let repository = FileTransferHistoryRepository(persistence: store.persistence)

        let bootstrap = await repository.apply(.bootstrap, generation: 1)
        XCTAssertEqual(bootstrap.history.count, 100)
        XCTAssertEqual(store.persistedIDs()?.count, 100)

        let appended = await repository.apply(.prepend(transfer(id: "newest")), generation: 2)
        XCTAssertEqual(appended.history.count, 100)
        XCTAssertEqual(appended.history.first?.id, "newest")
        XCTAssertEqual(store.persistedIDs()?.count, 100)
    }

    func testCorruptPrimaryCannotFallBackOrBeOverwrittenUntilExplicitClear() async throws {
        let suiteName = "FileTransferHistoryRepositoryTests.\(UUID().uuidString)"
        let legacyKey = "legacy.file-transfer-history"
        let rootDirectoryName = "FileTransferHistoryTests-\(UUID().uuidString)"
        let relativePath = "FileTransfer/history.json"
        let corruptData = Data("not-json".utf8)
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Expected isolated UserDefaults suite")
            return
        }

        let fileManager = FileManager.default
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.skybridge.compass"
        let rootURL = applicationSupport
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent(rootDirectoryName, isDirectory: true)
        let primaryURL = rootURL.appendingPathComponent(relativePath, isDirectory: false)
        try fileManager.createDirectory(
            at: primaryURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try corruptData.write(to: primaryURL, options: .atomic)
        defaults.set(
            try JSONEncoder().encode([transfer(id: "stale-legacy")]),
            forKey: legacyKey
        )
        defer {
            if fileManager.fileExists(atPath: rootURL.path) {
                XCTAssertNoThrow(try fileManager.removeItem(at: rootURL))
            }
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = CodablePersistenceStore<[FileTransfer]>(
            location: .protectedApplicationSupport(
                path: relativePath,
                legacyUserDefaultsKey: legacyKey
            ),
            rootDirectoryName: rootDirectoryName,
            defaults: defaults,
            fileManager: fileManager,
            maximumPayloadBytes: 1 * 1024 * 1024
        )
        let repository = FileTransferHistoryRepository(
            persistence: FileTransferHistoryPersistence(store: store)
        )

        let bootstrap = await repository.apply(.bootstrap, generation: 1)
        XCTAssertEqual(bootstrap.failure?.presentationToken, "SkyBridge.FileTransferHistory.Persistence:1")
        XCTAssertFalse(bootstrap.failure?.presentationToken.contains(rootURL.path) ?? true)

        let appendWhileBlocked = await repository.apply(
            .prepend(transfer(id: "must-not-overwrite-corruption")),
            generation: 2
        )
        XCTAssertEqual(appendWhileBlocked.history.map(\.id), ["must-not-overwrite-corruption"])
        XCTAssertEqual(try Data(contentsOf: primaryURL), corruptData)
        XCTAssertNotNil(defaults.data(forKey: legacyKey))

        let cleared = await repository.apply(.clear, generation: 3)
        XCTAssertTrue(cleared.history.isEmpty)
        XCTAssertNil(cleared.failure)
        XCTAssertFalse(fileManager.fileExists(atPath: primaryURL.path))
        XCTAssertNil(defaults.data(forKey: legacyKey))

        let recovered = await repository.apply(
            .prepend(transfer(id: "recovered")),
            generation: 4
        )
        XCTAssertEqual(recovered.history.map(\.id), ["recovered"])
        XCTAssertEqual(try store.loadOrThrow()?.map(\.id), ["recovered"])
    }

    func testOversizedPayloadIsRejectedBeforeDecode() throws {
        let suiteName = "FileTransferHistoryPayloadTests.\(UUID().uuidString)"
        let rootDirectoryName = "FileTransferHistoryPayloadTests-\(UUID().uuidString)"
        let relativePath = "FileTransfer/history.json"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Expected isolated UserDefaults suite")
            return
        }

        let fileManager = FileManager.default
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.skybridge.compass"
        let rootURL = applicationSupport
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent(rootDirectoryName, isDirectory: true)
        let primaryURL = rootURL.appendingPathComponent(relativePath, isDirectory: false)
        try fileManager.createDirectory(
            at: primaryURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0x20, count: (1 * 1024 * 1024) + 1).write(
            to: primaryURL,
            options: .atomic
        )
        defer {
            if fileManager.fileExists(atPath: rootURL.path) {
                XCTAssertNoThrow(try fileManager.removeItem(at: rootURL))
            }
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = CodablePersistenceStore<[FileTransfer]>(
            location: .protectedApplicationSupport(path: relativePath),
            rootDirectoryName: rootDirectoryName,
            defaults: defaults,
            fileManager: fileManager,
            maximumPayloadBytes: 1 * 1024 * 1024
        )

        XCTAssertThrowsError(try store.loadOrThrow()) { error in
            XCTAssertEqual(
                (error as NSError).domain,
                CodablePersistenceStoreError.errorDomain
            )
            XCTAssertEqual((error as NSError).code, 1)
        }
    }

    func testOutOfOrderGenerationIsRejectedWithoutMutatingCanonicalHistory() async {
        let store = InMemoryStore()
        let repository = FileTransferHistoryRepository(persistence: store.persistence)

        _ = await repository.apply(.bootstrap, generation: 1)
        let rejected = await repository.apply(.prepend(transfer(id: "late")), generation: 3)

        XCTAssertTrue(rejected.history.isEmpty)
        XCTAssertEqual(rejected.failure?.code, .invalidGeneration)
        XCTAssertNil(store.persistedIDs())
    }
}
