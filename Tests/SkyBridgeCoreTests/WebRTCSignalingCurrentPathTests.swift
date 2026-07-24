import Foundation
import Testing
import SkyBridgeProtocolCore
@testable import SkyBridgeCore

@Suite("Current WebRTC signaling tests")
struct WebRTCSignalingCurrentPathTests {
    @Test("WebSocket 信令客户端会识别服务端 error frame")
    func parseServerErrorFrame() {
        let raw = #"{"type":"error","error":"room_full","sessionId":"ABCD1234"}"#
        let parsed = WebSocketSignalingClient.parseInboundText(raw)

        switch parsed {
        case .serverFrame(let frame):
            #expect(frame.type == "error")
            #expect(frame.error == "room_full")
            #expect(frame.sessionId == "ABCD1234")
            #expect(frame.isError)
        default:
            Issue.record("Expected signaling server frame, got \(parsed)")
        }
    }

    @Test("WebSocket 信令客户端会识别服务端 bound frame 并脱敏 URL")
    func parseBoundFrameAndRedactURL() {
        let raw = #"{"type":"bound","sessionId":"ROOM1234","role":"initiator","clientId":"client-1"}"#
        let parsed = WebSocketSignalingClient.parseInboundText(raw)

        switch parsed {
        case .serverFrame(let frame):
            #expect(frame.type == "bound")
            #expect(frame.sessionId == "ROOM1234")
            #expect(!frame.isError)
        default:
            Issue.record("Expected signaling bound frame, got \(parsed)")
        }

        let url = URL(string: "wss://api.example.com/ws?shard=ROOM1234&st=secret-token&cv=1.0&pv=1")!
        let redacted = WebSocketSignalingClient.redactedURLString(url)
        #expect(!redacted.contains("secret-token"))
        #expect(!redacted.contains("ROOM1234"))
        #expect(redacted.contains("st=%3Credacted%3E") || redacted.contains("st=<redacted>"))
        #expect(redacted.contains("shard=%3Credacted%3E") || redacted.contains("shard=<redacted>"))
    }

    @Test("Signaling server-frame handlers expose stable failure code/class instead of raw reason")
    func signalingServerFrameHandlersDoNotExposeRawServerReason() throws {
        let macSource = try String(
            contentsOfFile: "Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift",
            encoding: .utf8
        )
        let iosSource = try String(
            contentsOfFile: "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/CrossNetworkWebRTCManager.swift",
            encoding: .utf8
        )

        for source in [macSource, iosSource] {
            #expect(!source.contains("Signaling error: \\(reason)"))
            #expect(!source.contains("error=\\(reason"))
            #expect(!source.contains("error=\\(frame.error"))
            #expect(source.contains("failure_code=\\(failureCode"))
            #expect(source.contains("failure_class=\\(publicFailureClass"))
        }
    }

    @Test("SignalServerClient 的当前 WebRTC 端点与编解码逻辑保持稳定")
    func signalServerClientCurrentEndpointContracts() throws {
        #expect(SignalServerClient.registerCodePath == "/api/webrtc/register-code")
        #expect(SignalServerClient.registerSessionPath == "/api/webrtc/register-session")
        #expect(SignalServerClient.redeemSessionPath == "/api/webrtc/redeem-session")
        #expect(SignalServerClient.lookupCodePath(for: "ABCDEFGH") == "/api/webrtc/lookup/ABCDEFGH")

        let binding = try ProtocolIdentityBinding(
            deviceId: "12345678-1234-1234-1234-1234567890ab",
            protocolSigningAlgorithm: .ed25519,
            protocolPublicKeyBytes: Data(repeating: 0x11, count: 32)
        )

        let registerCodeBody = SignalServerClient.makeRegisterCodeRequestBody(
            binding: binding,
            deviceName: "SkyBridge Mac",
            ttlSeconds: 600
        )
        let registerCodeJSON = try XCTJSON.decode(JSONEncoder().encode(registerCodeBody))
        #expect(registerCodeJSON["deviceId"] as? String == binding.deviceId)
        #expect(registerCodeJSON["deviceName"] as? String == "SkyBridge Mac")
        #expect(registerCodeJSON["protocolSigningAlgorithm"] as? String == ProtocolSigningAlgorithm.ed25519.rawValue)
        #expect(registerCodeJSON["protocolPublicKeyFingerprint"] as? String == binding.protocolPublicKeyFingerprint)
        #expect(registerCodeJSON["ttlSeconds"] as? Int == 600)

        let registerCodeLease = try SignalServerClient.decodeRegisterCodeResponse(
            from: try JSONSerialization.data(
                withJSONObject: [
                    "code": "ABCDEFGH",
                    "sessionId": "ABCDEFGH",
                    "initiatorToken": "init-token",
                    "turnAdmissionToken": "turn-token",
                    "expiresIn": 600,
                    "signalingServerOrigin": "https://api.example.com",
                    "wsPath": "/tenant/ws"
                ],
                options: [.sortedKeys]
            )
        )
        #expect(registerCodeLease.code == "ABCDEFGH")
        #expect(registerCodeLease.sessionID == "ABCDEFGH")
        #expect(registerCodeLease.initiatorToken == "init-token")
        #expect(registerCodeLease.signalingServerOrigin == "https://api.example.com")
        #expect(registerCodeLease.wsPath == "/tenant/ws")

        let lookup = try SignalServerClient.decodeLookupCodeResponse(
            from: try JSONSerialization.data(
                withJSONObject: [
                    "found": true,
                    "sessionId": "OPAQUE-SESSION-123",
                    "responderToken": "resp-token",
                    "turnAdmissionToken": "turn-token",
                    "expiresIn": 540,
                    "signalingServerOrigin": "https://api.example.com",
                    "wsPath": "/tenant/ws",
                    "initiatorDeviceId": binding.deviceId,
                    "initiatorProtocolSigningAlgorithm": ProtocolSigningAlgorithm.ed25519.rawValue,
                    "initiatorProtocolPublicKeyFingerprint": binding.protocolPublicKeyFingerprint,
                    "initiatorDeviceName": "SkyBridge Mac"
                ],
                options: [.sortedKeys]
            )
        )
        #expect(lookup.sessionID == "OPAQUE-SESSION-123")
        #expect(lookup.responderToken == "resp-token")
        #expect(lookup.wsPath == "/tenant/ws")
        #expect(lookup.initiatorDeviceId == binding.deviceId)
        #expect(lookup.initiatorProtocolPublicKeyFingerprint == binding.protocolPublicKeyFingerprint)

        let registerSessionBody = SignalServerClient.makeRegisterSessionRequestBody(
            sessionId: "session-123",
            binding: binding,
            ttlSeconds: 300
        )
        let registerSessionJSON = try XCTJSON.decode(JSONEncoder().encode(registerSessionBody))
        #expect(registerSessionJSON["sessionId"] as? String == "session-123")
        #expect(registerSessionJSON["deviceId"] as? String == binding.deviceId)
        #expect(registerSessionJSON["protocolSigningAlgorithm"] as? String == ProtocolSigningAlgorithm.ed25519.rawValue)
        #expect(registerSessionJSON["protocolPublicKeyFingerprint"] as? String == binding.protocolPublicKeyFingerprint)
        #expect(registerSessionJSON["ttlSeconds"] as? Int == 300)

        let sessionLease = try SignalServerClient.decodeRegisterSessionResponse(
            from: try JSONSerialization.data(
                withJSONObject: [
                    "sessionId": "session-123",
                    "initiatorSignalingToken": "qr-token",
                    "qrBootstrapToken": "bootstrap-token",
                    "turnAdmissionToken": "turn-token",
                    "expiresIn": 300,
                    "signalingServerOrigin": "https://api.example.com",
                    "wsPath": "/tenant/ws"
                ],
                options: [.sortedKeys]
            )
        )
        #expect(sessionLease.sessionID == "session-123")
        #expect(sessionLease.signalingToken == "qr-token")
        #expect(sessionLease.qrBootstrapToken == "bootstrap-token")
        #expect(sessionLease.signalingServerOrigin == "https://api.example.com")
        #expect(sessionLease.wsPath == "/tenant/ws")
    }

    @Test("authenticated requests use one immutable bearer and tenant snapshot across a tenant switch")
    func authenticatedRequestUsesOneSnapshotAcrossTenantSwitch() async throws {
        let provider = SignalAuthenticationContextProbe(
            context: SignalServerClient.AuthenticatedRequestContext(
                bearerToken: "token-tenant-a",
                tenantID: "tenant-a",
                userID: "user-a"
            )
        )
        defer { Task { await provider.release() } }
        let urlSession = makeSignalBoundaryURLSession()
        defer { urlSession.invalidateAndCancel() }
        let client = SignalServerClient(
            urlSession: urlSession,
            baseURLProvider: { "https://signal-boundary.invalid" },
            apiKeyProvider: { "snapshot" },
            authenticatedRequestContextProvider: {
                await provider.capturedContext()
            },
            tenantIDProvider: { "must-not-be-used-for-authenticated-request" }
        )
        let binding = try ProtocolIdentityBinding(
            deviceId: "12345678-1234-1234-1234-1234567890ab",
            protocolSigningAlgorithm: .ed25519,
            protocolPublicKeyBytes: Data(repeating: 0x11, count: 32)
        )

        let requestTask = Task {
            try await client.requestAdmissionChallenge(binding: binding)
        }
        try await waitForSignalAuthenticationCapture(provider)
        await provider.update(
            SignalServerClient.AuthenticatedRequestContext(
                bearerToken: "token-tenant-b",
                tenantID: "tenant-b",
                userID: "user-b"
            )
        )
        await provider.release()

        let challenge = try await requestTask.value
        let request = try #require(SignalBoundaryURLProtocol.request(for: "snapshot"))
        #expect(await provider.captureCount() == 1)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token-tenant-a")
        #expect(request.value(forHTTPHeaderField: "X-SkyBridge-Tenant-Id") == "tenant-a")
        #expect(challenge.tenantID == "tenant-a")
    }

    @Test("Current-device registration rejects an auth-scope switch before network I/O")
    func currentDeviceRegistrationRejectsScopeSwitchBeforeNetwork() async throws {
        let mode = "register-scope-mismatch-\(UUID().uuidString)"
        let provider = SignalAuthenticationContextProbe(
            context: SignalServerClient.AuthenticatedRequestContext(
                bearerToken: "token-tenant-a",
                tenantID: "tenant-a",
                userID: "user-a"
            )
        )
        defer { Task { await provider.release() } }
        let urlSession = makeSignalBoundaryURLSession()
        defer { urlSession.invalidateAndCancel() }
        let client = SignalServerClient(
            urlSession: urlSession,
            baseURLProvider: { "https://signal-boundary.invalid" },
            apiKeyProvider: { mode },
            authenticatedRequestContextProvider: {
                await provider.capturedContext()
            }
        )
        let binding = try makeSignalBoundaryBinding()
        let task = Task {
            try await client.registerCurrentDevice(
                binding: binding,
                deviceName: "Mac",
                expectedScope: SignalServerClient.IdentityRotationAuthenticationScope(
                    tenantID: "tenant-b",
                    userID: "user-b"
                )
            )
        }
        try await waitForSignalAuthenticationCapture(provider)
        await provider.release()

        do {
            _ = try await task.value
            Issue.record("Expected authenticationSessionChanged")
        } catch SignalServerClient.ClientError.authenticationSessionChanged {
            // Exact fail-closed result.
        } catch {
            Issue.record("Expected authenticationSessionChanged, got \(error)")
        }
        #expect(await provider.captureCount() == 1)
        #expect(SignalBoundaryURLProtocol.request(for: mode) == nil)
    }

    @Test("Rotation challenge rejects an auth-scope switch before network I/O")
    func rotationChallengeRejectsScopeSwitchBeforeNetwork() async throws {
        let mode = "rotation-challenge-scope-mismatch-\(UUID().uuidString)"
        let urlSession = makeSignalBoundaryURLSession()
        defer { urlSession.invalidateAndCancel() }
        let client = makeSignalBoundaryClient(mode: mode, urlSession: urlSession)
        let oldIdentity = try makeSignalBoundaryBinding()
        let newIdentity = try ProtocolIdentityBinding(
            deviceId: oldIdentity.deviceId,
            protocolSigningAlgorithm: .ed25519,
            protocolPublicKeyBytes: Data(repeating: 0x22, count: 32)
        )

        do {
            _ = try await client.requestIdentityRotationChallenge(
                oldIdentity: oldIdentity,
                newIdentity: newIdentity,
                idempotencyKey: UUID().uuidString.lowercased(),
                expectedScope: SignalServerClient.IdentityRotationAuthenticationScope(
                    tenantID: "other-tenant",
                    userID: "other-user"
                )
            )
            Issue.record("Expected authenticationSessionChanged")
        } catch SignalServerClient.ClientError.authenticationSessionChanged {
            // Exact fail-closed result.
        } catch {
            Issue.record("Expected authenticationSessionChanged, got \(error)")
        }
        #expect(SignalBoundaryURLProtocol.request(for: mode) == nil)
    }

    @Test("Rotation commit rejects a transcript from another auth scope before network I/O")
    func rotationCommitRejectsTranscriptScopeBeforeNetwork() async throws {
        let mode = "rotation-commit-scope-mismatch-\(UUID().uuidString)"
        let urlSession = makeSignalBoundaryURLSession()
        defer { urlSession.invalidateAndCancel() }
        let client = makeSignalBoundaryClient(mode: mode, urlSession: urlSession)
        let oldIdentity = try makeSignalBoundaryBinding()
        let newIdentity = try ProtocolIdentityBinding(
            deviceId: oldIdentity.deviceId,
            protocolSigningAlgorithm: .ed25519,
            protocolPublicKeyBytes: Data(repeating: 0x22, count: 32)
        )
        let transcript = try DeviceIdentityRotationTranscript(
            rotationID: "11111111-2222-4333-8444-555555555555",
            nonce: Data(0..<32),
            expiresAtMilliseconds: 2_000_000_060_000,
            tenantID: "transcript-tenant",
            userID: "transcript-user",
            deviceID: oldIdentity.deviceId,
            oldGeneration: 4,
            oldIdentity: oldIdentity,
            newIdentity: newIdentity
        )
        let challenge = try SignalServerClient.IdentityRotationChallenge(
            transcript: transcript,
            issuedAtMilliseconds: 2_000_000_000_000,
            clientVersion: "1.0.0",
            protocolVersion: "1"
        )

        do {
            _ = try await client.commitIdentityRotation(
                challenge: challenge,
                oldSignature: Data(repeating: 0x31, count: 64),
                newSignature: Data(repeating: 0x32, count: 64),
                expectedScope: SignalServerClient.IdentityRotationAuthenticationScope(
                    tenantID: "boundary-tenant",
                    userID: "boundary-user"
                )
            )
            Issue.record("Expected authenticationSessionChanged")
        } catch SignalServerClient.ClientError.authenticationSessionChanged {
            // Exact fail-closed result.
        } catch {
            Issue.record("Expected authenticationSessionChanged, got \(error)")
        }
        #expect(SignalBoundaryURLProtocol.request(for: mode) == nil)
    }

    @Test("Existing active-device registration remains a successful idempotent renewal")
    func existingCurrentDeviceRegistrationRemainsSuccessful() async throws {
        let mode = "register-existing-\(UUID().uuidString)"
        let urlSession = makeSignalBoundaryURLSession()
        defer { urlSession.invalidateAndCancel() }
        let client = makeSignalBoundaryClient(mode: mode, urlSession: urlSession)
        let binding = try makeSignalBoundaryBinding()
        let registered = try await client.registerCurrentDevice(
            binding: binding,
            deviceName: "Mac",
            expectedScope: SignalServerClient.IdentityRotationAuthenticationScope(
                tenantID: "boundary-tenant",
                userID: "boundary-user"
            )
        )

        #expect(registered.status == "active")
        #expect(registered.deviceId == binding.deviceId)
        #expect(registered.protocolPublicKeyFingerprint
            == binding.protocolPublicKeyFingerprint)
        #expect(SignalBoundaryURLProtocol.request(for: mode) != nil)
    }

    @Test("Current-device registration rejects a substituted response authority")
    func currentDeviceRegistrationRejectsResponseAuthoritySubstitution() async throws {
        let mode = "register-substitution-\(UUID().uuidString)"
        let urlSession = makeSignalBoundaryURLSession()
        defer { urlSession.invalidateAndCancel() }
        let client = makeSignalBoundaryClient(mode: mode, urlSession: urlSession)
        let binding = try makeSignalBoundaryBinding()

        do {
            _ = try await client.registerCurrentDevice(
                binding: binding,
                deviceName: "Mac",
                expectedScope: SignalServerClient.IdentityRotationAuthenticationScope(
                    tenantID: "boundary-tenant",
                    userID: "boundary-user"
                )
            )
            Issue.record("Expected malformedResponse for substituted authority")
        } catch SignalServerClient.ClientError.malformedResponse {
            // Exact fail-closed result.
        } catch {
            Issue.record("Expected malformedResponse, got \(error)")
        }
        #expect(SignalBoundaryURLProtocol.request(for: mode) != nil)
    }

    @Test("Rotation commit rejects a non-contiguous server generation")
    func rotationCommitRejectsGenerationJump() async throws {
        let mode = "rotation-generation-jump-\(UUID().uuidString)"
        let urlSession = makeSignalBoundaryURLSession()
        defer { urlSession.invalidateAndCancel() }
        let client = makeSignalBoundaryClient(mode: mode, urlSession: urlSession)
        let oldIdentity = try makeSignalBoundaryBinding()
        let newIdentity = try ProtocolIdentityBinding(
            deviceId: oldIdentity.deviceId,
            protocolSigningAlgorithm: .ed25519,
            protocolPublicKeyBytes: Data(repeating: 0x22, count: 32)
        )
        let transcript = try DeviceIdentityRotationTranscript(
            rotationID: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            nonce: Data(0..<32),
            expiresAtMilliseconds: 2_000_000_060_000,
            tenantID: "boundary-tenant",
            userID: "boundary-user",
            deviceID: oldIdentity.deviceId,
            oldGeneration: 4,
            oldIdentity: oldIdentity,
            newIdentity: newIdentity
        )
        let challenge = try SignalServerClient.IdentityRotationChallenge(
            transcript: transcript,
            issuedAtMilliseconds: 2_000_000_000_000,
            clientVersion: "1.0.0",
            protocolVersion: "1"
        )

        do {
            _ = try await client.commitIdentityRotation(
                challenge: challenge,
                oldSignature: Data(repeating: 0x41, count: 64),
                newSignature: Data(repeating: 0x42, count: 64),
                expectedScope: SignalServerClient.IdentityRotationAuthenticationScope(
                    tenantID: "boundary-tenant",
                    userID: "boundary-user"
                )
            )
            Issue.record("Expected malformedResponse for a generation jump")
        } catch SignalServerClient.ClientError.malformedResponse {
            // Exact fail-closed result.
        } catch {
            Issue.record("Expected malformedResponse, got \(error)")
        }
        #expect(SignalBoundaryURLProtocol.request(for: mode) != nil)
    }

    @Test("CrossNetworkConnectionManager wires authenticated signaling through one authority snapshot")
    func crossNetworkManagerUsesOneAuthenticatedSignalingSnapshot() throws {
        let source = try String(
            contentsOfFile: "Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift",
            encoding: .utf8
        )
        let factory = try #require(
            sourceSection(
                in: source,
                from: "static func makeAuthenticatedSignalServerClient()",
                to: "public init() {"
            )
        )
        let initializer = try #require(
            sourceSection(
                in: source,
                from: "public init() {",
                to: "public var isTransportReady"
            )
        )
        let contextHelper = try #require(
            sourceSection(
                in: source,
                from: "private static func currentAuthenticatedSignalServerRequestContext()",
                to: "static func currentAuthenticatedIdentityRotationScope()"
            )
        )
        #expect(factory.contains("authenticatedRequestContextProvider: { @MainActor in"))
        #expect(factory.contains("currentAuthenticatedSignalServerRequestContext()"))
        #expect(factory.contains("makeAuthenticatedSignalServerClientSnapshot()"))
        #expect(contextHelper.contains("_ = try await AuthenticationService.shared.validAccessToken()"))
        #expect(contextHelper.contains("let snapshot = currentSignalServerAuthoritySnapshot()"))
        #expect(contextHelper.contains("SignalServerClient.AuthenticatedRequestContext("))
        #expect(contextHelper.contains("userID: identity.userID"))
        #expect(!factory.contains("bearerTokenProvider:"))
        #expect(initializer.contains("self.signalServer = Self.makeAuthenticatedSignalServerClient()"))
        #expect(!initializer.contains("authenticatedRequestContextProvider:"))
    }

    @Test("SignalServerClient rejects an oversized response before decoding")
    func signalServerClientRejectsOversizedResponse() async throws {
        let urlSession = makeSignalBoundaryURLSession()
        defer { urlSession.invalidateAndCancel() }
        let client = makeSignalBoundaryClient(
            mode: "oversized",
            urlSession: urlSession,
            maximumResponseBytes: 128
        )

        do {
            _ = try await client.requestAdmissionChallenge(binding: makeSignalBoundaryBinding())
            Issue.record("Expected an oversized signaling response to fail closed")
        } catch SignalServerClient.ClientError.responseTooLarge(let path, let limitBytes) {
            #expect(path == SignalServerClient.admissionChallengePath)
            #expect(limitBytes == 128)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("SignalServerClient rejects invalid response limits before network I/O")
    func signalServerClientRejectsInvalidResponseLimits() async throws {
        let urlSession = makeSignalBoundaryURLSession()
        defer { urlSession.invalidateAndCancel() }
        let client = makeSignalBoundaryClient(
            mode: "invalid-limits",
            urlSession: urlSession,
            maximumResponseBytes: 0
        )

        do {
            _ = try await client.requestAdmissionChallenge(binding: makeSignalBoundaryBinding())
            Issue.record("Expected invalid signaling limits to fail closed")
        } catch SignalServerClient.ClientError.invalidRequestLimits {
            #expect(SignalBoundaryURLProtocol.request(for: "invalid-limits") == nil)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("SignalServerClient maps URL request timeout explicitly")
    func signalServerClientMapsRequestTimeout() async throws {
        let urlSession = makeSignalBoundaryURLSession()
        defer { urlSession.invalidateAndCancel() }
        let client = makeSignalBoundaryClient(mode: "request-timeout", urlSession: urlSession)

        do {
            _ = try await client.requestAdmissionChallenge(binding: makeSignalBoundaryBinding())
            Issue.record("Expected a timed-out signaling request to fail closed")
        } catch SignalServerClient.ClientError.requestTimedOut(let path) {
            #expect(path == SignalServerClient.admissionChallengePath)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("SignalServerClient enforces a hard total resource deadline")
    func signalServerClientEnforcesResourceDeadline() async throws {
        let urlSession = makeSignalBoundaryURLSession()
        defer { urlSession.invalidateAndCancel() }
        let client = makeSignalBoundaryClient(
            mode: "resource-timeout",
            urlSession: urlSession,
            requestTimeoutSeconds: 2,
            resourceTimeoutSeconds: 0.05
        )

        do {
            _ = try await client.requestAdmissionChallenge(binding: makeSignalBoundaryBinding())
            Issue.record("Expected a signaling resource deadline to fail closed")
        } catch SignalServerClient.ClientError.resourceDeadlineExceeded(let path) {
            #expect(path == SignalServerClient.admissionChallengePath)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        try await waitForSignalBoundaryCancellation(mode: "resource-timeout")
    }

    @Test("SignalServerClient legacy response decoders fail closed on missing fields")
    func signalServerClientLegacyDecodersRejectIncompleteResponses() throws {
        func jsonData(_ object: [String: Any]) throws -> Data {
            try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        }

        try expectSignalServerMalformedResponse("register code missing token") {
            _ = try SignalServerClient.decodeRegisterCodeResponse(
                from: jsonData([
                    "code": "ABCDEFGH",
                    "sessionId": "ABCDEFGH",
                    "turnAdmissionToken": "turn-token",
                    "expiresIn": 600,
                    "signalingServerOrigin": "https://api.example.com"
                ])
            )
        }
        try expectSignalServerMalformedResponse("register session missing origin") {
            _ = try SignalServerClient.decodeRegisterSessionResponse(
                from: jsonData([
                    "sessionId": "session-123",
                    "initiatorSignalingToken": "qr-token",
                    "qrBootstrapToken": "bootstrap-token",
                    "turnAdmissionToken": "turn-token",
                    "expiresIn": 300,
                    "signalingServerOrigin": "   "
                ])
            )
        }
        try expectSignalServerMalformedResponse("lookup zero expiry") {
            _ = try SignalServerClient.decodeLookupCodeResponse(
                from: jsonData([
                    "found": true,
                    "sessionId": "ABCDEFGH",
                    "responderToken": "resp-token",
                    "turnAdmissionToken": "turn-token",
                    "expiresIn": 0,
                    "signalingServerOrigin": "https://api.example.com",
                    "initiatorDeviceId": "device-1",
                    "initiatorProtocolSigningAlgorithm": ProtocolSigningAlgorithm.ed25519.rawValue,
                    "initiatorProtocolPublicKeyFingerprint": String(repeating: "a", count: 64)
                ])
            )
        }
        try expectSignalServerMalformedResponse("lookup unknown signing algorithm") {
            _ = try SignalServerClient.decodeLookupCodeResponse(
                from: jsonData([
                    "found": true,
                    "sessionId": "ABCDEFGH",
                    "responderToken": "resp-token",
                    "turnAdmissionToken": "turn-token",
                    "expiresIn": 540,
                    "signalingServerOrigin": "https://api.example.com",
                    "initiatorDeviceId": "device-1",
                    "initiatorProtocolSigningAlgorithm": "P-256-ECDSA",
                    "initiatorProtocolPublicKeyFingerprint": String(repeating: "a", count: 64)
                ])
            )
        }
    }

    @Test("Current-path WebSocket URL follows server origin and wsPath")
    func currentPathWebSocketURLFollowsLeaseEndpoint() throws {
        let url = try #require(CrossNetworkConnectionManager.currentPathSignalingWebSocketURL(
            signalingServerOrigin: "https://api.example.com",
            wsPath: "/tenant/ws",
            sessionID: "abc123",
            sessionToken: "token-1",
            clientVersion: "1.2.3",
            protocolVersion: "2"
        ))
        #expect(url.scheme == "wss")
        #expect(url.host == "api.example.com")
        #expect(url.path == "/tenant/ws")

        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })
        #expect(query["shard"] == "ABC123")
 // 静态 builder 保持 header-only(不含 st);st 由实例层 signalingWebSocketURL 组装,见该方法注释。
        #expect(query["st"] == nil)
        #expect(query["cv"] == "1.2.3")
        #expect(query["pv"] == "2")
        #expect(!url.absoluteString.contains("token-1"))

        let headers = try #require(CrossNetworkConnectionManager.currentPathSignalingWebSocketHeaders(
            sessionID: "abc123",
            sessionToken: "token-1",
            clientVersion: "1.2.3",
            protocolVersion: "2"
        ))
        #expect(headers["X-SkyBridge-Session-Id"] == "ABC123")
        #expect(headers["X-SkyBridge-Session"] == "token-1")
        #expect(headers["X-SkyBridge-Client-Version"] == "1.2.3")
        #expect(headers["X-SkyBridge-Protocol-Version"] == "2")

        let defaultPathURL = CrossNetworkConnectionManager.currentPathSignalingWebSocketURL(
            signalingServerOrigin: "http://localhost:8787",
            wsPath: "bad?path",
            sessionID: "room",
            sessionToken: "token-2",
            clientVersion: "1.2.3",
            protocolVersion: "2"
        )
        #expect(defaultPathURL == nil)

        let missingPathURL = CrossNetworkConnectionManager.currentPathSignalingWebSocketURL(
            signalingServerOrigin: "http://localhost:8787",
            wsPath: nil,
            sessionID: "room",
            sessionToken: "token-2",
            clientVersion: "1.2.3",
            protocolVersion: "2"
        )
        #expect(missingPathURL == nil)
    }

    @Test("WebRTC JOIN bootstrap payload carries Q-Periapt platform metadata")
    func webRTCJoinBootstrapPayloadCarriesQPeriaptPlatformMetadata() throws {
        let payload = WebRTCSignalingEnvelope.Payload(
            protocolSigningAlgorithm: .mlDSA65,
            protocolPublicKeyFingerprint: String(repeating: "a", count: 64),
            protocolPublicKeyBytes: Data(repeating: 0x44, count: 1_952),
            kemPublicKeys: [
                .init(
                    suiteWireId: CryptoSuite.qperiaptABI2PolicyBound.wireId,
                    publicKey: Data(repeating: 0x55, count: QPeriaptPlatformPolicy.publicKeyLength)
                )
            ],
            platform: "macOS",
            osVersion: "macOS 26.0"
        )

        let decoded = try JSONDecoder().decode(
            WebRTCSignalingEnvelope.Payload.self,
            from: try JSONEncoder().encode(payload)
        )

        #expect(decoded.platform == "macOS")
        #expect(decoded.osVersion == "macOS 26.0")
        #expect(decoded.kemPublicKeys?.count == 1)
        #expect(decoded.kemPublicKeys?.first?.suiteWireId == CryptoSuite.qperiaptABI2PolicyBound.wireId)
        #expect(decoded.kemPublicKeys?.first?.publicKey.count == QPeriaptPlatformPolicy.publicKeyLength)
    }

    @Test("Current-path signaling policy accepts only explicit safe WebSocket paths")
    func currentPathSignalingPolicyValidatesWebSocketPaths() throws {
        #expect(try CurrentPathSignalingWebSocketPolicy.validatedWebSocketPath(" /tenant/ws ") == "/tenant/ws")
        #expect(try CurrentPathSignalingWebSocketPolicy.validatedWebSocketPath("/current-path/ws") == "/current-path/ws")

        let invalidPaths: [String?] = [
            nil,
            "",
            "/",
            "tenant/ws",
            "/ws?x=1",
            "/ws#x",
            "/../ws",
            "/tenant/../ws",
            "/tenant//ws",
            "/tenant\\ws",
            "/%2e%2e/ws",
            "/tenant/%2F/ws",
            "/tenant/%5C/ws",
            "/tenant/%00/ws",
            "/ten ant/ws",
            "/租户/ws",
            "/" + String(repeating: "a", count: CurrentPathSignalingWebSocketPolicy.maxWebSocketPathLength)
        ]
        for path in invalidPaths {
            #expect(throws: CurrentPathSignalingWebSocketPolicy.PolicyError.invalidWebSocketPath) {
                _ = try CurrentPathSignalingWebSocketPolicy.validatedWebSocketPath(path)
            }
        }
    }

    @Test("Current-path signaling policy separates header and query-token credential transport")
    func currentPathSignalingPolicySeparatesCredentialTransportModes() throws {
        let headerURL = try #require(CurrentPathSignalingWebSocketPolicy.webSocketURL(
            signalingServerOrigin: "https://api.example.com",
            wsPath: "/tenant/ws",
            sessionID: "abc123",
            sessionToken: "token-1",
            clientVersion: "1.2.3",
            protocolVersion: "2",
            credentialTransport: .headers
        ))
        let headerQuery = queryDictionary(for: headerURL)
        #expect(headerURL.scheme == "wss")
        #expect(headerQuery["shard"] == "ABC123")
        #expect(headerQuery["cv"] == "1.2.3")
        #expect(headerQuery["pv"] == "2")
        #expect(headerQuery["st"] == nil)

        let headerModeHeaders = try #require(CurrentPathSignalingWebSocketPolicy.webSocketHeaders(
            sessionID: "abc123",
            sessionToken: "token-1",
            clientVersion: "1.2.3",
            protocolVersion: "2",
            credentialTransport: .headers
        ))
        #expect(headerModeHeaders[CurrentPathSignalingWebSocketPolicy.sessionIDHeader] == "ABC123")
        #expect(headerModeHeaders[CurrentPathSignalingWebSocketPolicy.sessionTokenHeader] == "token-1")

        let queryURL = try #require(CurrentPathSignalingWebSocketPolicy.webSocketURL(
            signalingServerOrigin: "https://api.example.com",
            wsPath: "/tenant/ws",
            sessionID: "abc123",
            sessionToken: "token-1",
            clientVersion: "1.2.3",
            protocolVersion: "2",
            credentialTransport: .queryToken
        ))
        let queryModeQuery = queryDictionary(for: queryURL)
        #expect(queryModeQuery["shard"] == "ABC123")
        #expect(queryModeQuery["st"] == "token-1")
        #expect(queryModeQuery["cv"] == "1.2.3")
        #expect(queryModeQuery["pv"] == "2")

        let queryModeHeaders = try #require(CurrentPathSignalingWebSocketPolicy.webSocketHeaders(
            sessionID: "abc123",
            sessionToken: "token-1",
            clientVersion: "1.2.3",
            protocolVersion: "2",
            credentialTransport: .queryToken
        ))
        #expect(queryModeHeaders[CurrentPathSignalingWebSocketPolicy.sessionIDHeader] == nil)
        #expect(queryModeHeaders[CurrentPathSignalingWebSocketPolicy.sessionTokenHeader] == nil)
        #expect(queryModeHeaders[CurrentPathSignalingWebSocketPolicy.clientVersionHeader] == "1.2.3")
        #expect(queryModeHeaders[CurrentPathSignalingWebSocketPolicy.protocolVersionHeader] == "2")
    }

    @Test("Current-path signaling policy rejects bad credential values")
    func currentPathSignalingPolicyRejectsBadCredentials() {
        let badValues = [
            "",
            "line\r\nbreak",
            "nul\u{0}byte",
            "delete\u{7F}",
            "comma,value"
        ]

        for value in badValues {
            #expect(CurrentPathSignalingWebSocketPolicy.webSocketHeaders(
                sessionID: value,
                sessionToken: "token-1",
                clientVersion: "1.2.3",
                protocolVersion: "2"
            ) == nil)
            #expect(CurrentPathSignalingWebSocketPolicy.webSocketURL(
                signalingServerOrigin: "https://api.example.com",
                wsPath: "/tenant/ws",
                sessionID: "abc123",
                sessionToken: value,
                clientVersion: "1.2.3",
                protocolVersion: "2",
                credentialTransport: .queryToken
            ) == nil)
        }

        #expect(CurrentPathSignalingWebSocketPolicy.webSocketHeaders(
            sessionID: String(repeating: "A", count: CurrentPathSignalingWebSocketPolicy.maxSessionIDLength + 1),
            sessionToken: "token-1",
            clientVersion: "1.2.3",
            protocolVersion: "2"
        ) == nil)
        #expect(CurrentPathSignalingWebSocketPolicy.webSocketHeaders(
            sessionID: "abc123",
            sessionToken: String(repeating: "a", count: CurrentPathSignalingWebSocketPolicy.maxSessionTokenLength + 1),
            clientVersion: "1.2.3",
            protocolVersion: "2"
        ) == nil)
        #expect(CurrentPathSignalingWebSocketPolicy.webSocketHeaders(
            sessionID: "abc123",
            sessionToken: "token-1",
            clientVersion: String(repeating: "1", count: CurrentPathSignalingWebSocketPolicy.maxVersionLength + 1),
            protocolVersion: "2"
        ) == nil)
    }

    @Test("Current-path WebSocket URL rejects public cleartext origins but keeps loopback compatibility")
    func currentPathWebSocketURLRejectsPublicCleartextOrigins() throws {
        #expect(throws: CurrentPathSecurityError.self) {
            _ = try CurrentPathOriginPolicy.canonicalOrigin("http://signal.example.com")
        }

        let loopback = try #require(CrossNetworkConnectionManager.currentPathSignalingWebSocketURL(
            signalingServerOrigin: "http://127.0.0.1:8787",
            wsPath: "/tenant/ws",
            sessionID: "local-room",
            sessionToken: "token",
            clientVersion: "1.2.3",
            protocolVersion: "2"
        ))
        #expect(loopback.scheme == "ws")
        #expect(loopback.host == "127.0.0.1")

        let ipv6Loopback = try CurrentPathOriginPolicy.canonicalOrigin("http://[::1]:8787")
        #expect(ipv6Loopback == "http://[::1]:8787")

        let publicCleartext = CrossNetworkConnectionManager.currentPathSignalingWebSocketURL(
            signalingServerOrigin: "http://signal.example.com",
            wsPath: "/tenant/ws",
            sessionID: "room",
            sessionToken: "token",
            clientVersion: "1.2.3",
            protocolVersion: "2"
        )
        #expect(publicCleartext == nil)
    }

    @Test("Current-path tooling does not synthesize /ws or config WebSocket fallbacks")
    func currentPathToolingDoesNotSynthesizeFallbackWebSocketRoutes() throws {
        let managerSource = try String(contentsOfFile: "Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift")
        #expect(!managerSource.contains("return \"/ws\""))
        #expect(!managerSource.contains("return URL(string: SkyBridgeServerConfig.signalingWebSocketURL)"))
        #expect(!managerSource.contains("URLQueryItem(name: \"st\""))
        #expect(managerSource.contains("credentialTransport: .headers"))
        #expect(!managerSource.contains("credentialTransport: .queryToken"))

        let policySource = try String(contentsOfFile: "Sources/SkyBridgeProtocolCore/RemoteConnection/CurrentPathSignalingWebSocketPolicy.swift")
        #expect(policySource.contains("case queryToken"))
        #expect(policySource.contains(#"URLQueryItem(name: "st", value: sessionToken)"#))

        let probeSource = try String(contentsOfFile: "Sources/CurrentPathProbe/main.swift")
        #expect(!probeSource.contains("?? \"/ws\""))
        #expect(!probeSource.contains("URLQueryItem(name: \"st\""))

        let iOSManagerSource = try String(contentsOfFile: "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/CrossNetworkWebRTCManager.swift")
        #expect(!iOSManagerSource.contains("URLQueryItem(name: \"st\""))
        #expect(!iOSManagerSource.contains("headers.removeValue(forKey: \"X-SkyBridge-Session-Id\")"))
        #expect(!iOSManagerSource.contains("headers.removeValue(forKey: \"X-SkyBridge-Session\")"))
        #expect(iOSManagerSource.contains("CurrentPathSignalingWebSocketPolicyCompat.webSocketURL("))
        #expect(iOSManagerSource.contains("CurrentPathSignalingWebSocketPolicyCompat.webSocketHeaders("))
        #expect(iOSManagerSource.contains("credentialTransport: .headers"))
        #expect(!iOSManagerSource.contains("credentialTransport: .queryToken"))

        let iOSPolicySource = try String(contentsOfFile: "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Core/RemoteConnection/WebRTC/CrossNetworkWebRTCSignalingPolicy.swift")
        #expect(iOSPolicySource.contains("enum CurrentPathSignalingWebSocketPolicyCompat"))
        #expect(iOSPolicySource.contains(#"URLQueryItem(name: "st", value: sessionToken)"#))
        #expect(iOSPolicySource.contains("scalar == \",\""))

        let serverSource = try String(contentsOfFile: "Server/skybridge-signaling/server.js")
        #expect(serverSource.contains("SIGNALING_WEBSOCKET_PATH"))
        #expect(!serverSource.contains("wsPath: '/ws'"))
        #expect(!serverSource.contains("path: '/ws'"))

        let localCompatServerSource = try String(contentsOfFile: "Server/skybridge-signaling/local_compat_server.js")
        #expect(localCompatServerSource.contains("SIGNALING_WEBSOCKET_PATH"))
        #expect(!localCompatServerSource.contains("wsPath: '/ws'"))
        #expect(!localCompatServerSource.contains("path: '/ws'"))
    }

    @Test("Current-path identity authority waits for committed configuration and signs the advertised slot")
    func currentPathIdentityAuthorityUsesOneCommittedSnapshot() throws {
        let settingsSource = try String(
            contentsOfFile: "Sources/SkyBridgeCore/Settings/SettingsManager.swift",
            encoding: .utf8
        )
        #expect(settingsSource.contains("protocolIdentityRestorationTask"))
        #expect(settingsSource.contains("committedProtocolIdentityConfiguration()"))
        #expect(settingsSource.contains("await protocolIdentityRestorationTask?.value"))

        let snapshotSource = try String(
            contentsOfFile: "Sources/SkyBridgeCore/P2P/CommittedLocalProtocolIdentitySnapshot.swift",
            encoding: .utf8
        )
        #expect(snapshotSource.contains(".committedProtocolIdentityConfiguration()"))
        #expect(!snapshotSource.contains("SettingsManager.shared.activeProtocolSigningAlgorithm"))
        #expect(!snapshotSource.contains("SettingsManager.shared.activeProtocolSigningKeyProtection"))

        let activationSource = try String(
            contentsOfFile: "Sources/SkyBridgeCompassApp/Services/CurrentPathDeviceActivationCoordinator.swift",
            encoding: .utf8
        )
        #expect(activationSource.contains("CommittedLocalProtocolIdentitySnapshot.loadActive()"))
        #expect(activationSource.contains("protocolSigningAlgorithm: identity.algorithm"))
        #expect(activationSource.contains("protocolPublicKeyBytes: identity.publicKey"))
        #expect(!activationSource.contains("let algorithm: ProtocolSigningAlgorithm = .ed25519"))

        let probeSource = try String(
            contentsOfFile: "Sources/CurrentPathProbe/main.swift",
            encoding: .utf8
        )
        #expect(probeSource.contains("CommittedLocalProtocolIdentitySnapshot.loadActive()"))
        #expect(probeSource.contains("signingKeyHandle: identity.keyHandle"))
        #expect(probeSource.contains("key: signingKeyHandle"))
        #expect(!probeSource.contains("getProtocolSigningKeyHandle(for: binding.protocolSigningAlgorithm)"))

        let securitySourcePaths = [
            "Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift",
            "Sources/SkyBridgeCore/RemoteControl/RemoteControlManager.swift",
            "Sources/SkyBridgeCore/P2P/P2PModels.swift",
            "Sources/SkyBridgeCore/P2P/InboundProtocolIdentitySelection.swift",
            "Sources/SkyBridgeCore/QuantumSecure/EnhancedPostQuantumCrypto.swift"
        ]
        for path in securitySourcePaths {
            let source = try String(contentsOfFile: path, encoding: .utf8)
            #expect(!source.contains("SettingsManager.shared.activeProtocolSigningAlgorithm"))
            #expect(!source.contains("SettingsManager.shared.activeProtocolSigningKeyProtection"))
        }
    }

    @Test("iOS QR redeem uses a stable idempotency key")
    func iOSQRCodeRedeemUsesStableIdempotencyKey() throws {
        let clientSource = try String(contentsOfFile: "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Core/RemoteConnection/WebRTC/CrossNetworkSignalServerClient.swift")
        #expect(clientSource.contains("\"Idempotency-Key\": normalizedIdempotencyKey"))
        #expect(clientSource.contains("case missingIdempotencyKey"))

        let managerSource = try String(contentsOfFile: "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/CrossNetworkWebRTCManager.swift")
        #expect(managerSource.contains(#"idempotencyKey: "qr-redeem-\(qr.sessionID)-\(localBinding.deviceId)""#))
    }

    @Test("macOS runtime signaling URL construction preserves endpoint errors")
    func macOSRuntimeSignalingURLConstructionPreservesEndpointErrors() throws {
        let managerSource = try String(contentsOfFile: "Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift")
        #expect(managerSource.contains("private func signalingWebSocketURL(shardKey: String? = nil) throws -> URL"))
        #expect(managerSource.contains("invalidSignalingEndpoint(\"missing current-path signaling origin\")"))
        #expect(managerSource.contains("invalidSignalingEndpoint(error.localizedDescription)"))
        #expect(managerSource.contains("let url = try signalingWebSocketURL(shardKey: sessionID)"))
    }

    @Test("Current-path artifacts validate endpoint before caching tokens")
    func currentPathArtifactsValidateEndpointBeforeCachingTokens() throws {
        let managerSource = try String(contentsOfFile: "Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift")

        assertEndpointValidationPrecedesTokenCaching(
            in: managerSource,
            sectionStart: "public func generateDynamicQRCode",
            sectionEnd: "public func scanDynamicQRCode",
            endpointVariable: "let signalingEndpoint = try validatedCurrentPathSignalingEndpoint(\n                origin: sessionLease.signalingServerOrigin,\n                wsPath: sessionLease.wsPath\n            )",
            tokenWrite: "webrtcSignalingAuthTokenBySessionId[sessionLease.sessionID] = sessionLease.sessionToken"
        )
        assertEndpointValidationPrecedesTokenCaching(
            in: managerSource,
            sectionStart: "public func scanDynamicQRCode",
            sectionEnd: "public func connectToCloudDevice",
            endpointVariable: "let signalingEndpoint = try validatedCurrentPathSignalingEndpoint(\n                origin: redeemed.signalingServerOrigin,\n                wsPath: redeemed.wsPath\n            )",
            tokenWrite: "webrtcSignalingAuthTokenBySessionId[qrData.sessionID] = redeemed.sessionToken"
        )
        assertEndpointValidationPrecedesTokenCaching(
            in: managerSource,
            sectionStart: "public func generateConnectionCode",
            sectionEnd: "private func scheduleConnectionCodeLeaseInvalidation",
            endpointVariable: "let signalingEndpoint = try validatedCurrentPathSignalingEndpoint(\n                origin: lease.signalingServerOrigin,\n                wsPath: lease.wsPath\n            )",
            tokenWrite: "webrtcSignalingAuthTokenBySessionId[lease.sessionID] = lease.sessionToken"
        )
        assertEndpointValidationPrecedesTokenCaching(
            in: managerSource,
            sectionStart: "public func connectWithCode",
            sectionEnd: "private func scanServerBackedQRCodeInvite",
            endpointVariable: "let signalingEndpoint = try validatedCurrentPathSignalingEndpoint(\n                origin: lookup.signalingServerOrigin,\n                wsPath: lookup.wsPath\n            )",
            tokenWrite: "webrtcSignalingAuthTokenBySessionId[lookup.sessionID] = lookup.sessionToken"
        )
        assertEndpointValidationPrecedesTokenCaching(
            in: managerSource,
            sectionStart: "private func scanServerBackedQRCodeInvite",
            sectionEnd: "private func establishP2PConnection",
            endpointVariable: "let signalingEndpoint = try validatedCurrentPathSignalingEndpoint(\n            origin: redeemed.signalingServerOrigin,\n            wsPath: redeemed.wsPath\n        )",
            tokenWrite: "webrtcSignalingAuthTokenBySessionId[invite.sessionID] = redeemed.sessionToken"
        )
    }

    @Test("Connection-code lookup uses the server session identifier as authority")
    func connectionCodeLookupUsesAuthoritativeServerSessionID() throws {
        let managerSource = try String(
            contentsOfFile: "Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift",
            encoding: .utf8
        )
        let section = try #require(sourceSection(
            in: managerSource,
            from: "public func connectWithCode",
            to: "private func scheduleConnectionCodeLeaseInvalidation"
        ))

        #expect(section.contains("let sessionID = lookup.sessionID"))
        #expect(!section.contains("let sessionID = normalized"))
        #expect(section.contains("ensureSignalingConnected(shardKey: sessionID)"))
        #expect(section.contains("WebRTCSession(sessionId: sessionID"))
    }

    @Test("WebRTC signaling envelope 保留 authToken 字段")
    func signalingEnvelopePreservesAuthToken() throws {
        let envelope = WebRTCSignalingEnvelope(
            sessionId: "session-123",
            from: "device-A",
            type: .offer,
            payload: .init(sdp: "v=0"),
            authToken: "secure-token"
        )

        let decoded = try JSONDecoder().decode(
            WebRTCSignalingEnvelope.self,
            from: JSONEncoder().encode(envelope)
        )

        #expect(decoded.authToken == "secure-token")
        #expect(decoded.sessionId == "session-123")
        #expect(decoded.type == .offer)
    }

    @Test("Control-plane client API key remains non-empty by default")
    func controlPlaneClientAPIKeyDefaultIsPresent() {
        #expect(!SkyBridgeServerConfig.clientAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}

private func queryDictionary(for url: URL) -> [String: String] {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
        return [:]
    }
    return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
        item.value.map { (item.name, $0) }
    })
}

private func assertEndpointValidationPrecedesTokenCaching(
    in source: String,
    sectionStart: String,
    sectionEnd: String,
    endpointVariable: String,
    tokenWrite: String,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    guard let startRange = source.range(of: sectionStart),
          let endRange = source.range(of: sectionEnd, range: startRange.upperBound..<source.endIndex) else {
        Issue.record("Missing source section \(sectionStart)", sourceLocation: sourceLocation)
        return
    }
    let section = source[startRange.lowerBound..<endRange.lowerBound]
    guard let endpointRange = section.range(of: endpointVariable),
          let tokenRange = section.range(of: tokenWrite) else {
        Issue.record("Missing endpoint validation or token write in \(sectionStart)", sourceLocation: sourceLocation)
        return
    }
    #expect(endpointRange.lowerBound < tokenRange.lowerBound, sourceLocation: sourceLocation)
}

private func sourceSection(
    in source: String,
    from startMarker: String,
    to endMarker: String
) -> Substring? {
    guard let start = source.range(of: startMarker),
          let end = source.range(of: endMarker, range: start.upperBound..<source.endIndex) else {
        return nil
    }
    return source[start.lowerBound..<end.lowerBound]
}

private func expectSignalServerMalformedResponse(
    _ label: String,
    sourceLocation: SourceLocation = #_sourceLocation,
    operation: () throws -> Void
) rethrows {
    do {
        try operation()
        Issue.record("Expected malformed response for \(label)", sourceLocation: sourceLocation)
    } catch SignalServerClient.ClientError.malformedResponse {
        return
    } catch {
        Issue.record("Expected malformed response for \(label), got \(error)", sourceLocation: sourceLocation)
    }
}

private enum XCTJSON {
    static func decode(_ data: Data?) throws -> [String: Any] {
        guard let data else { throw URLError(.cannotDecodeContentData) }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotDecodeContentData)
        }
        return object
    }
}

private func makeSignalBoundaryBinding() throws -> ProtocolIdentityBinding {
    try ProtocolIdentityBinding(
        deviceId: "12345678-1234-1234-1234-1234567890ab",
        protocolSigningAlgorithm: .ed25519,
        protocolPublicKeyBytes: Data(repeating: 0x11, count: 32)
    )
}

private func makeSignalBoundaryURLSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SignalBoundaryURLProtocol.self]
    return URLSession(configuration: configuration)
}

private func makeSignalBoundaryClient(
    mode: String,
    urlSession: URLSession,
    requestTimeoutSeconds: TimeInterval = 2,
    resourceTimeoutSeconds: TimeInterval = 2,
    maximumResponseBytes: Int = 256 * 1_024
) -> SignalServerClient {
    SignalServerClient(
        urlSession: urlSession,
        baseURLProvider: { "https://signal-boundary.invalid" },
        apiKeyProvider: { mode },
        authenticatedRequestContextProvider: {
            SignalServerClient.AuthenticatedRequestContext(
                bearerToken: "boundary-token",
                tenantID: "boundary-tenant",
                userID: "boundary-user"
            )
        },
        tenantIDProvider: { "boundary-tenant" },
        requestTimeoutSeconds: requestTimeoutSeconds,
        resourceTimeoutSeconds: resourceTimeoutSeconds,
        maximumResponseBytes: maximumResponseBytes
    )
}

private func waitForSignalAuthenticationCapture(
    _ provider: SignalAuthenticationContextProbe
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while await provider.captureCount() == 0 {
        guard clock.now < deadline else {
            throw SignalBoundaryTestError.timedOutWaitingForAuthenticationCapture
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}

private func waitForSignalBoundaryCancellation(mode: String) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while !SignalBoundaryURLProtocol.wasStopped(mode: mode) {
        guard clock.now < deadline else {
            throw SignalBoundaryTestError.timedOutWaitingForRequestCancellation
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}

private actor SignalAuthenticationContextProbe {
    private var context: SignalServerClient.AuthenticatedRequestContext
    private var captures = 0
    private var isReleased = false

    init(context: SignalServerClient.AuthenticatedRequestContext) {
        self.context = context
    }

    func capturedContext() async -> SignalServerClient.AuthenticatedRequestContext {
        let captured = context
        captures += 1
        while !isReleased {
            await Task.yield()
        }
        return captured
    }

    func update(_ context: SignalServerClient.AuthenticatedRequestContext) {
        self.context = context
    }

    func release() {
        isReleased = true
    }

    func captureCount() -> Int {
        captures
    }
}

private enum SignalBoundaryTestError: Error {
    case timedOutWaitingForAuthenticationCapture
    case timedOutWaitingForRequestCancellation
}

private final class SignalBoundaryURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var requestsByMode: [String: URLRequest] = [:]
    nonisolated(unsafe) private static var stoppedModes: Set<String> = []

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let mode = request.value(forHTTPHeaderField: "X-API-Key") ?? "success"
        Self.lock.lock()
        Self.requestsByMode[mode] = request
        Self.lock.unlock()

        if mode == "request-timeout" {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            return
        }

        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let headers = ["Content-Type": "application/json"]
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)

        if mode == "resource-timeout" {
            return
        }
        if mode == "oversized" {
            client?.urlProtocol(self, didLoad: Data(repeating: 0x41, count: 1_024))
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        let tenantID = request.value(forHTTPHeaderField: "X-SkyBridge-Tenant-Id") ?? "missing"
        let body: [String: Any]
        if mode.hasPrefix("register-existing-")
            || mode.hasPrefix("register-substitution-") {
            let binding = try? makeSignalBoundaryBinding()
            let registeredUserID = mode.hasPrefix("register-substitution-")
                ? "substituted-user"
                : "boundary-user"
            body = [
                "registered": true,
                "activated": false,
                "device": [
                    "tenant_id": tenantID,
                    "user_id": registeredUserID,
                    "device_id": binding?.deviceId ?? "missing",
                    "protocol_signing_algorithm": ProtocolSigningAlgorithm.ed25519.rawValue,
                    "protocol_public_key_fingerprint":
                        binding?.protocolPublicKeyFingerprint ?? "missing",
                    "device_name": "Mac",
                    "status": "active",
                    "approval_method": "existing"
                ]
            ]
        } else if mode.hasPrefix("rotation-generation-jump-") {
            let oldIdentity = try? makeSignalBoundaryBinding()
            let newIdentity = try? ProtocolIdentityBinding(
                deviceId: oldIdentity?.deviceId ?? "missing",
                protocolSigningAlgorithm: .ed25519,
                protocolPublicKeyBytes: Data(repeating: 0x22, count: 32)
            )
            body = [
                "committed": true,
                "rotationId": "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
                "state": "committed",
                "committedAt": 2_000_000_001_000 as Int64,
                "generation": 6,
                "deviceId": oldIdentity?.deviceId ?? "missing",
                "oldIdentity": [
                    "protocolSigningAlgorithm": ProtocolSigningAlgorithm.ed25519.rawValue,
                    "protocolPublicKeyFingerprint":
                        oldIdentity?.protocolPublicKeyFingerprint ?? "missing",
                    "state": "grace",
                    "graceExpiresAt": 2_000_000_061_000 as Int64
                ],
                "newIdentity": [
                    "protocolSigningAlgorithm": ProtocolSigningAlgorithm.ed25519.rawValue,
                    "protocolPublicKeyFingerprint":
                        newIdentity?.protocolPublicKeyFingerprint ?? "missing",
                    "state": "active"
                ]
            ]
        } else {
            body = [
                "challengeId": "challenge-123",
                "nonce": "nonce-123",
                "tenantId": tenantID,
                "userId": "user-123",
                "deviceId": "12345678-1234-1234-1234-1234567890ab",
                "clientIpHash": "client-ip-hash",
                "clientVersion": "1.0.0",
                "protocolVersion": "1",
                "state": "pending",
                "issuedAt": 2_000_000_000_000 as Int64,
                "expiresAt": 2_000_000_060_000 as Int64
            ]
        }
        do {
            client?.urlProtocol(
                self,
                didLoad: try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            )
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {
        let mode = request.value(forHTTPHeaderField: "X-API-Key") ?? "success"
        Self.lock.lock()
        Self.stoppedModes.insert(mode)
        Self.lock.unlock()
    }

    static func request(for mode: String) -> URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return requestsByMode[mode]
    }

    static func wasStopped(mode: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stoppedModes.contains(mode)
    }
}
