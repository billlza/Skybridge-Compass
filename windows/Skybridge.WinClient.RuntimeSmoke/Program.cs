using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Skybridge.WinClient.Services;

var opts = ParseArgs(args);
try
{
    await RunAsync(opts).ConfigureAwait(false);
    return 0;
}
catch (Exception ex)
{
    Console.Error.WriteLine($"windows-runtime-smoke failed: {ex.Message}");
    return 1;
}

static async Task RunAsync(Dictionary<string, string> opts)
{
    var profile = opts.GetValueOrDefault("profile", "session");
    var evidenceOut = Required(opts, "evidence-out");
    var timeout = TimeSpan.FromSeconds(ReadPositiveInt(opts, "timeout-seconds", 180));
    if (string.Equals(profile, "signaling-bound", StringComparison.OrdinalIgnoreCase))
    {
        await RunSignalingBoundProfileAsync(opts, evidenceOut, timeout).ConfigureAwait(false);
        return;
    }

    if (string.Equals(profile, "admission-register-bound", StringComparison.OrdinalIgnoreCase))
    {
        await RunAdmissionRegisterBoundProfileAsync(opts, evidenceOut, timeout).ConfigureAwait(false);
        return;
    }

    if (string.Equals(profile, "current-path-bridge-contract", StringComparison.OrdinalIgnoreCase))
    {
        await RunCurrentPathBridgeContractProfileAsync(opts, evidenceOut, timeout).ConfigureAwait(false);
        return;
    }

    var helperPath = Required(opts, "helper-path");
    var signalingDir = Required(opts, "signaling-dir");
    var offerFile = opts.GetValueOrDefault("offer-file", "skybridge-webrtc-offer.json");
    var answerFile = opts.GetValueOrDefault("answer-file", "skybridge-webrtc-answer.json");
    var bindAddress = Required(opts, "bind-address");
    var peerDeviceId = Required(opts, "peer-device-id");
    var peerFingerprint = Required(opts, "peer-fingerprint");

    if (!IsLowerHex(peerFingerprint, 64))
    {
        throw new InvalidOperationException("--peer-fingerprint must be 64 lowercase hex characters.");
    }

    var launchOptions = new WebRtcHelperLaunchOptions(
        helperPath,
        signalingDir,
        offerFileName: offerFile,
        answerFileName: answerFile,
        bindAddress: bindAddress,
        launchTimeout: timeout);

    var adapterRequest = BuildAdapterRequest(peerDeviceId, peerFingerprint);
    if (string.Equals(profile, "session", StringComparison.OrdinalIgnoreCase))
    {
        await RunSessionProfileAsync(launchOptions, adapterRequest, evidenceOut, timeout).ConfigureAwait(false);
        return;
    }

    if (string.Equals(profile, "product-control", StringComparison.OrdinalIgnoreCase))
    {
        await RunProductControlProfileAsync(launchOptions, adapterRequest, evidenceOut, timeout).ConfigureAwait(false);
        return;
    }

    if (string.Equals(profile, "current-path-product-control-transport", StringComparison.OrdinalIgnoreCase))
    {
        await RunCurrentPathProductControlTransportProfileAsync(
                launchOptions,
                adapterRequest,
                opts,
                evidenceOut,
                timeout,
                requireAppControlProof: false)
            .ConfigureAwait(false);
        return;
    }

    if (string.Equals(profile, "current-path-product-control-appcontrol", StringComparison.OrdinalIgnoreCase))
    {
        await RunCurrentPathProductControlTransportProfileAsync(
                launchOptions,
                adapterRequest,
                opts,
                evidenceOut,
                timeout,
                requireAppControlProof: true)
            .ConfigureAwait(false);
        return;
    }

    throw new InvalidOperationException(
        "--profile must be admission-register-bound, signaling-bound, current-path-bridge-contract, current-path-product-control-appcontrol, current-path-product-control-transport, session, or product-control.");
}

static async Task RunSignalingBoundProfileAsync(
    Dictionary<string, string> opts,
    string evidenceOut,
    TimeSpan timeout)
{
    var origin = Required(opts, "signaling-server-origin");
    var wsPath = Required(opts, "ws-path");
    var sessionId = Required(opts, "session-id");
    var sessionToken = RequiredSecretFromEnvironment(opts, "session-token", "session-token-env");
    var localDeviceId = Required(opts, "local-device-id");
    var clientVersion = opts.GetValueOrDefault("client-version", CurrentPathSignalServerClient.DefaultClientVersion);
    var protocolVersion = opts.GetValueOrDefault("protocol-version", CurrentPathSignalServerClient.DefaultProtocolVersion);
    var lifecycle = new List<CurrentPathSignalingLifecycleEvent>();
    var businessSendCount = 0;

    CurrentPathWebSocketSignalingClientOptions? clientOptions = null;
    CurrentPathWebSocketSignalingClient? client = null;
    try
    {
        clientOptions = new CurrentPathWebSocketSignalingClientOptions(
            origin,
            wsPath,
            sessionId,
            sessionToken,
            localDeviceId,
            clientVersion,
            protocolVersion,
            connectTimeout: timeout);
        client = new CurrentPathWebSocketSignalingClient(clientOptions);
        client.LifecycleChanged += lifecycle.Add;

        Console.WriteLine("windows-current-path-signaling-bound: connect");
        await client.ConnectAndBindAsync().ConfigureAwait(false);
        await WriteSignalingBoundEvidenceAsync(
                evidenceOut,
                clientOptions,
                lifecycle,
                client,
                status: "bound",
                failureCode: null,
                failureClass: null,
                businessSendCount)
            .ConfigureAwait(false);
        Console.WriteLine($"windows-current-path-signaling-bound: evidence={Path.GetFullPath(evidenceOut)}");
        Console.WriteLine("windows-current-path-signaling-bound: ok");
    }
    catch (Exception ex)
    {
        if (clientOptions is not null)
        {
            var failureCode = ex is CurrentPathWebSocketSignalingException signalingException
                ? signalingException.ErrorCode
                : "unexpected_error";
            string? failureClass = ex is CurrentPathWebSocketSignalingException classifiedException
                ? FailureClassWire(classifiedException.FailureClass)
                : null;
            await WriteSignalingBoundEvidenceAsync(
                    evidenceOut,
                    clientOptions,
                    lifecycle,
                    client,
                    status: "failed",
                    failureCode,
                    failureClass,
                    businessSendCount)
                .ConfigureAwait(false);
        }

        throw;
    }
    finally
    {
        if (client is not null)
        {
            await client.DisposeAsync().ConfigureAwait(false);
        }
    }
}

static async Task RunAdmissionRegisterBoundProfileAsync(
    Dictionary<string, string> opts,
    string evidenceOut,
    TimeSpan timeout)
{
    var baseUrl = opts.GetValueOrDefault("signal-server-base-url", CurrentPathSignalServerClient.DefaultBaseUrl);
    var localDeviceId = Required(opts, "local-device-id");
    var deviceName = ValidateDeviceName(opts.GetValueOrDefault("device-name", "Windows RuntimeSmoke"));

    var bearerToken = RequiredSecretFromEnvironment(opts, "bearer-token", "bearer-token-env");
    var tenantId = RequiredSecretFromEnvironment(opts, "tenant-id", "tenant-id-env");
    var privateKeyBase64 = RequiredSecretFromEnvironment(
        opts,
        "mldsa65-private-key-base64",
        "mldsa65-private-key-base64-env");
    var privateKeyBytes = DecodeBase64Secret(privateKeyBase64, "current-path ML-DSA-65 private key");
    var clientVersion = opts.GetValueOrDefault("client-version", CurrentPathSignalServerClient.DefaultClientVersion);
    var protocolVersion = opts.GetValueOrDefault("protocol-version", CurrentPathSignalServerClient.DefaultProtocolVersion);
    var ttlSeconds = ReadPositiveInt(opts, "ttl-seconds", 300);
    var lifecycle = new List<CurrentPathSignalingLifecycleEvent>();
    var steps = new SortedDictionary<string, bool>(StringComparer.Ordinal)
    {
        ["AdmissionChallenge"] = false,
        ["AdmissionLease"] = false,
        ["RegisterCode"] = false,
        ["LookupCode"] = false,
        ["SignalingBound"] = false,
    };

    CurrentPathProtocolIdentityBinding? binding = null;
    CurrentPathAdmissionLease? admissionLease = null;
    CurrentPathConnectionCodeLease? lease = null;
    CurrentPathConnectionCodeLookup? lookup = null;
    CurrentPathWebSocketSignalingClientOptions? clientOptions = null;
    CurrentPathWebSocketSignalingClient? client = null;
    string? failureCode = null;
    string? failureClass = null;

    try
    {
        using var signer = CurrentPathMldsa65AdmissionSigner.ImportPrivateKey(privateKeyBytes);
        binding = signer.CreateBinding(localDeviceId);
        using var timeoutCts = new CancellationTokenSource(timeout);
        using var httpClient = new HttpClient { Timeout = timeout };
        var signalClient = new CurrentPathSignalServerClient(
            httpClient,
            new CurrentPathSignalServerClientOptions(
                baseUrl: baseUrl,
                bearerTokenProvider: _ => Task.FromResult(bearerToken),
                tenantIdProvider: _ => Task.FromResult(tenantId),
                clientVersion: clientVersion,
                protocolVersion: protocolVersion));

        Console.WriteLine("windows-current-path-admission-register-bound: request-admission-challenge");
        var challenge = await signalClient.RequestAdmissionChallengeAsync(binding, timeoutCts.Token)
            .ConfigureAwait(false);
        steps["AdmissionChallenge"] = true;

        var signature = signer.SignAdmissionChallenge(challenge, binding);
        Console.WriteLine("windows-current-path-admission-register-bound: complete-admission");
        admissionLease = await signalClient.CompleteAdmissionAsync(
                challenge,
                binding,
                signature,
                timeoutCts.Token)
            .ConfigureAwait(false);
        ValidateAdmissionLeaseReady(admissionLease);
        steps["AdmissionLease"] = true;

        Console.WriteLine("windows-current-path-admission-register-bound: register-code");
        lease = await signalClient.RegisterConnectionCodeAsync(
                admissionLease.Token,
                deviceName,
                TimeSpan.FromSeconds(ttlSeconds),
                timeoutCts.Token)
            .ConfigureAwait(false);
        steps["RegisterCode"] = true;

        Console.WriteLine("windows-current-path-admission-register-bound: lookup-code");
        lookup = await signalClient.LookupConnectionCodeAsync(admissionLease.Token, lease.Code, timeoutCts.Token)
            .ConfigureAwait(false);
        ValidateLookupMatchesLease(binding, lease, lookup);
        steps["LookupCode"] = true;

        clientOptions = new CurrentPathWebSocketSignalingClientOptions(
            lease.SignalingServerOrigin,
            lease.WsPath,
            lease.SessionId,
            lease.SessionToken,
            localDeviceId,
            clientVersion,
            protocolVersion,
            connectTimeout: timeout);
        client = new CurrentPathWebSocketSignalingClient(clientOptions);
        client.LifecycleChanged += lifecycle.Add;

        Console.WriteLine("windows-current-path-admission-register-bound: connect-signaling");
        await client.ConnectAndBindAsync(timeoutCts.Token).ConfigureAwait(false);
        steps["SignalingBound"] = true;
        await WriteAdmissionRegisterBoundEvidenceAsync(
                evidenceOut,
                "bound",
                binding,
                admissionLease,
                lease,
                lookup,
                clientOptions,
                lifecycle,
                client,
                steps,
                failureCode: null,
                failureClass: null)
            .ConfigureAwait(false);
        Console.WriteLine($"windows-current-path-admission-register-bound: evidence={Path.GetFullPath(evidenceOut)}");
        Console.WriteLine("windows-current-path-admission-register-bound: ok");
    }
    catch (Exception ex)
    {
        failureCode = ex switch
        {
            CurrentPathSignalServerException => "signal_server_rejected",
            CurrentPathWebSocketSignalingException signalingException => signalingException.ErrorCode,
            OperationCanceledException => "timeout",
            HttpRequestException => "http_request_failed",
            _ => "unexpected_error",
        };
        failureClass = ex is CurrentPathWebSocketSignalingException classifiedException
            ? FailureClassWire(classifiedException.FailureClass)
            : null;
        if (binding is not null)
        {
            await WriteAdmissionRegisterBoundEvidenceAsync(
                    evidenceOut,
                    "failed",
                    binding,
                    admissionLease,
                    lease,
                    lookup,
                    clientOptions,
                    lifecycle,
                    client,
                    steps,
                    failureCode,
                    failureClass)
                .ConfigureAwait(false);
        }

        throw;
    }
    finally
    {
        CryptographicOperations.ZeroMemory(privateKeyBytes);
        if (client is not null)
        {
            await client.DisposeAsync().ConfigureAwait(false);
        }
    }
}

static async Task RunSessionProfileAsync(
    WebRtcHelperLaunchOptions launchOptions,
    WindowsTransportAdapterRequest adapterRequest,
    string evidenceOut,
    TimeSpan timeout)
{
    await using var adapter = new WebRtcSessionTransportAdapterClient(
        new WebRtcHelperLaunchClient(launchOptions),
        new WebRtcSessionTransportAdapterOptions(
            asAnswerer: false,
            preferredIpcPort: 0,
            timestampWindowMs: 15_000));

    Console.WriteLine("windows-product-data-plane-smoke: prepare-webrtc-session-adapter");
    var snapshot = await adapter.PrepareAsync(adapterRequest).ConfigureAwait(false);
    var launchRequest = new ConnectionLaunchRequest(
        adapterRequest.PairingMaterial,
        new ConnectionPreflightSnapshot(
            DateTimeOffset.UtcNow,
            BuildLaunchPlan(adapterRequest.DiscoveredPeer, adapterRequest.PairingMaterial, snapshot),
            Array.Empty<ConnectionPreflightFact>()));
    var context = adapter.RequireLiveSession(launchRequest);

    Console.WriteLine("windows-product-data-plane-smoke: run-control-smoke");
    var smoke = new WebRtcControlSmokeClient(new WebRtcControlSmokeOptions(timeout, evidenceOut));
    await smoke.StartAsync(context, launchRequest).ConfigureAwait(false);
    Console.WriteLine($"windows-product-data-plane-smoke: evidence={Path.GetFullPath(evidenceOut)}");
    Console.WriteLine("windows-product-data-plane-smoke: ok");
}

static async Task RunProductControlProfileAsync(
    WebRtcHelperLaunchOptions launchOptions,
    WindowsTransportAdapterRequest adapterRequest,
    string evidenceOut,
    TimeSpan timeout)
{
    await using var provider = new WebRtcProductControlTransportProvider(
        new WebRtcHelperLaunchClient(launchOptions),
        new WebRtcProductControlTransportOptions(
            asAnswerer: false,
            preferredIpcPort: 0,
            timestampWindowMs: 15_000));

    Console.WriteLine("windows-product-control-smoke: prepare-product-control-transport");
    var context = await provider.PrepareAsync(adapterRequest).ConfigureAwait(false);

    Console.WriteLine("windows-product-control-smoke: run-raw-control-smoke");
    var smoke = new WebRtcProductControlSmokeClient(new WebRtcProductControlSmokeOptions(timeout, evidenceOut));
    await smoke.StartAsync(context).ConfigureAwait(false);
    Console.WriteLine($"windows-product-control-smoke: evidence={Path.GetFullPath(evidenceOut)}");
    Console.WriteLine("windows-product-control-smoke: ok");
}

static async Task RunCurrentPathProductControlTransportProfileAsync(
    WebRtcHelperLaunchOptions launchOptions,
    WindowsTransportAdapterRequest adapterRequest,
    Dictionary<string, string> opts,
    string evidenceOut,
    TimeSpan timeout,
    bool requireAppControlProof)
{
    var profileName = requireAppControlProof
        ? "current-path-product-control-appcontrol"
        : "current-path-product-control-transport";
    var baseUrl = opts.GetValueOrDefault("signal-server-base-url", CurrentPathSignalServerClient.DefaultBaseUrl);
    var localDeviceId = CurrentPathProtocolIdentityBinding.NormalizeDeviceId(Required(opts, "local-device-id"));
    var deviceName = ValidateDeviceName(opts.GetValueOrDefault("device-name", "Windows RuntimeSmoke"));
    var connectionCode = NormalizeConnectionCode(
        RequiredSecretFromEnvironment(opts, "connection-code", "connection-code-env"));
    var bearerToken = RequiredSecretFromEnvironment(opts, "bearer-token", "bearer-token-env");
    var tenantId = RequiredSecretFromEnvironment(opts, "tenant-id", "tenant-id-env");
    var privateKeyBase64 = RequiredSecretFromEnvironment(
        opts,
        "mldsa65-private-key-base64",
        "mldsa65-private-key-base64-env");
    var privateKeyBytes = DecodeBase64Secret(privateKeyBase64, "current-path ML-DSA-65 private key");
    var peerMlKem768PublicKeyBase64 = requireAppControlProof
        ? RequiredSecretFromEnvironment(
            opts,
            "peer-mlkem768-public-key-base64",
            "peer-mlkem768-public-key-base64-env")
        : null;
    var peerMlKem768PublicKey = peerMlKem768PublicKeyBase64 is null
        ? null
        : DecodeBase64Bytes(peerMlKem768PublicKeyBase64, "peer ML-KEM-768 public key");
    if (peerMlKem768PublicKey is not null &&
        peerMlKem768PublicKey.Length != MLKemAlgorithm.MLKem768.EncapsulationKeySizeInBytes)
    {
        throw new InvalidOperationException(
            $"peer ML-KEM-768 public key must be {MLKemAlgorithm.MLKem768.EncapsulationKeySizeInBytes} bytes.");
    }

    var clientVersion = opts.GetValueOrDefault("client-version", CurrentPathSignalServerClient.DefaultClientVersion);
    var protocolVersion = opts.GetValueOrDefault("protocol-version", CurrentPathSignalServerClient.DefaultProtocolVersion);
    var signalFileTimeoutSeconds = ReadPositiveInt(opts, "signal-file-timeout-seconds", 30);
    var remoteAnswerTimeoutSeconds = ReadPositiveInt(opts, "remote-answer-timeout-seconds", Math.Max(1, (int)timeout.TotalSeconds));
    var lifecycle = new List<CurrentPathSignalingLifecycleEvent>();
    var steps = new SortedDictionary<string, bool>(StringComparer.Ordinal)
    {
        ["AdmissionChallenge"] = false,
        ["AdmissionLease"] = false,
        ["LookupCode"] = false,
        ["SignalingBound"] = false,
        ["ProductControlTransport"] = false,
    };
    if (requireAppControlProof)
    {
        steps["ProductHandshake"] = false;
        steps["AppControlPingPong"] = false;
    }

    CurrentPathProtocolIdentityBinding? binding = null;
    CurrentPathAdmissionLease? admissionLease = null;
    CurrentPathConnectionCodeLookup? lookup = null;
    CurrentPathWebSocketSignalingClientOptions? clientOptions = null;
    LiveWebRtcProductControlContext? context = null;
    WebRtcProductHandshakeInitiatorResult? handshakeResult = null;
    WebRtcAppControlBootstrapResult? appControlResult = null;

    try
    {
        using var signer = CurrentPathMldsa65AdmissionSigner.ImportPrivateKey(privateKeyBytes);
        binding = signer.CreateBinding(localDeviceId);
        using var timeoutCts = new CancellationTokenSource(timeout);
        using var httpClient = new HttpClient { Timeout = timeout };
        var signalClient = new CurrentPathSignalServerClient(
            httpClient,
            new CurrentPathSignalServerClientOptions(
                baseUrl: baseUrl,
                bearerTokenProvider: _ => Task.FromResult(bearerToken),
                tenantIdProvider: _ => Task.FromResult(tenantId),
                clientVersion: clientVersion,
                protocolVersion: protocolVersion));

        Console.WriteLine($"{profileName}: request-admission-challenge");
        var challenge = await signalClient.RequestAdmissionChallengeAsync(binding, timeoutCts.Token)
            .ConfigureAwait(false);
        steps["AdmissionChallenge"] = true;

        Console.WriteLine($"{profileName}: complete-admission");
        admissionLease = await signalClient.CompleteAdmissionAsync(
                challenge,
                binding,
                signer.SignAdmissionChallenge(challenge, binding),
                timeoutCts.Token)
            .ConfigureAwait(false);
        ValidateAdmissionLeaseReady(admissionLease);
        steps["AdmissionLease"] = true;

        Console.WriteLine($"{profileName}: lookup-code");
        lookup = await signalClient.LookupConnectionCodeAsync(admissionLease.Token, connectionCode, timeoutCts.Token)
            .ConfigureAwait(false);
        ValidateLookupMatchesExpectedPeer(binding, adapterRequest, lookup);
        steps["LookupCode"] = true;

        clientOptions = new CurrentPathWebSocketSignalingClientOptions(
            lookup.SignalingServerOrigin,
            lookup.WsPath,
            lookup.SessionId,
            lookup.SessionToken,
            localDeviceId,
            clientVersion,
            protocolVersion,
            connectTimeout: timeout);
        await using var wsClient = new CurrentPathWebSocketSignalingClient(clientOptions);
        wsClient.LifecycleChanged += lifecycle.Add;

        Console.WriteLine($"{profileName}: connect-signaling");
        await wsClient.ConnectAndBindAsync(timeoutCts.Token).ConfigureAwait(false);
        steps["SignalingBound"] = true;

        var connector = new CurrentPathWebRtcProductControlSessionConnector(
            new WebRtcHelperLaunchClient(launchOptions),
            wsClient,
            new CurrentPathWebRtcHelperSignalingBridge(),
            new CurrentPathWebRtcProductControlSessionConnectorOptions(
                lookup.SessionId,
                localDeviceId,
                lookup.InitiatorDeviceId,
                lookup.InitiatorProtocolPublicKeyFingerprint,
                lookup.InitiatorProtocolSigningAlgorithm,
                TimeSpan.FromSeconds(signalFileTimeoutSeconds),
                TimeSpan.FromSeconds(remoteAnswerTimeoutSeconds)));
        await using var provider = new WebRtcProductControlTransportProvider(
            connector,
            new WebRtcProductControlTransportOptions(
                asAnswerer: false,
                preferredIpcPort: 0,
                timestampWindowMs: 15_000));

        Console.WriteLine($"{profileName}: prepare-product-control-transport");
        context = await provider.PrepareAsync(adapterRequest, timeoutCts.Token).ConfigureAwait(false);
        steps["ProductControlTransport"] = true;
        var evidenceContext = context;

        if (requireAppControlProof)
        {
            if (peerMlKem768PublicKey is null)
            {
                throw new InvalidOperationException(
                    "current-path product-control AppControl proof requires peer ML-KEM-768 public key material.");
            }

            var sessionStore = new WebRtcProductSecureSessionStore();
            using var cryptoProvider = new WebRtcProductPqcHandshakeCryptoProvider(
                new WebRtcProductPqcHandshakeCryptoProviderOptions(
                    privateKeyBytes,
                    peerMlKem768PublicKey));
            var handshakeDriver = new WebRtcProductHandshakeDriver(
                cryptoProvider,
                sessionStore,
                new WebRtcProductHandshakeDriverOptions(timeout));

            Console.WriteLine($"{profileName}: start-product-handshake");
            handshakeResult = await handshakeDriver
                .StartInitiatorWithResultAsync(context, timeoutCts.Token)
                .ConfigureAwait(false);
            steps["ProductHandshake"] = true;
            evidenceContext = handshakeResult.EstablishedContext;

            var appControlClient = new WebRtcAppControlBootstrapClient(
                sessionStore,
                new WebRtcAppControlBootstrapOptions(timeout));
            Console.WriteLine($"{profileName}: exchange-appcontrol-ping");
            appControlResult = await appControlClient
                .ExchangePingAsync(
                    evidenceContext,
                    handshakeResult.SelectedSuiteWireId,
                    timeoutCts.Token)
                .ConfigureAwait(false);
            steps["AppControlPingPong"] = true;
        }

        await WriteCurrentPathProductControlTransportEvidenceAsync(
                evidenceOut,
                requireAppControlProof ? "appControlPong" : "transportOpen",
                profileName,
                binding,
                admissionLease,
                lookup,
                clientOptions,
                wsClient,
                lifecycle,
                steps,
                evidenceContext,
                handshakeResult,
                appControlResult,
                connectionCode,
                failureCode: null,
                failureClass: null)
            .ConfigureAwait(false);
        Console.WriteLine($"{profileName}: evidence={Path.GetFullPath(evidenceOut)}");
        Console.WriteLine($"{profileName}: ok");
    }
    finally
    {
        CryptographicOperations.ZeroMemory(privateKeyBytes);
        if (peerMlKem768PublicKey is not null)
        {
            CryptographicOperations.ZeroMemory(peerMlKem768PublicKey);
        }

        if (binding is not null && clientOptions is not null)
        {
            ValidateEvidenceDoesNotContain(
                File.Exists(evidenceOut) ? File.ReadAllText(evidenceOut) : string.Empty,
                bearerToken,
                tenantId,
                privateKeyBase64,
                peerMlKem768PublicKeyBase64,
                connectionCode,
                admissionLease?.Token,
                lookup?.SessionToken,
                lookup?.TurnAdmissionToken,
                lookup?.MediaAdmissionToken,
                clientOptions.Headers.TryGetValue(CurrentPathSignalingWebSocketPolicy.SessionTokenHeader, out var sessionToken)
                    ? sessionToken
                    : null);
        }
    }
}

static async Task RunCurrentPathBridgeContractProfileAsync(
    Dictionary<string, string> opts,
    string evidenceOut,
    TimeSpan timeout)
{
    var signalingDir = Required(opts, "signaling-dir");
    var sessionId = CurrentPathWebRtcSignalingEnvelope.NormalizeSessionId(
        opts.GetValueOrDefault("session-id", "bridge-contract-session-1"));
    var localDeviceId = CurrentPathProtocolIdentityBinding.NormalizeDeviceId(
        opts.GetValueOrDefault("local-device-id", "windows-device-01"));
    var remoteDeviceId = CurrentPathProtocolIdentityBinding.NormalizeDeviceId(
        opts.GetValueOrDefault("remote-device-id", "mac-device-00001"));
    var clientVersion = opts.GetValueOrDefault("client-version", CurrentPathSignalServerClient.DefaultClientVersion);
    var protocolVersion = opts.GetValueOrDefault("protocol-version", CurrentPathSignalServerClient.DefaultProtocolVersion);

    var profileDir = Path.Combine(
        Path.GetFullPath(signalingDir),
        "current-path-bridge-contract-" + Guid.NewGuid().ToString("N"));
    Directory.CreateDirectory(profileDir);
    var offererLocalOfferPath = Path.Combine(profileDir, "offerer-local-offer.json");
    var offererRemoteAnswerPath = Path.Combine(profileDir, "offerer-remote-answer.json");

    WebRtcSignalDocument.Write(
        offererLocalOfferPath,
        "offer",
        "v=0\r\na=fingerprint:sha-256 11:22:33\r\n",
        new[]
        {
            new WebRtcSignalDocument.SignalCandidate
            {
                Candidate = "candidate:1111 1 udp 2113937663 192.168.0.105 56176 typ host generation 0",
                SdpMid = "0",
                SdpMLineIndex = 0,
                UsernameFragment = "WIN1"
            }
        });

    var offererTransport = new RecordingCurrentPathWebSocketTransport();
    offererTransport.EnqueueReceive(CurrentPathWebSocketReceiveResult.TextMessage(
        $"{{\"type\":\"bound\",\"sessionId\":\"{sessionId}\",\"role\":\"initiator\",\"clientId\":\"client-bridge-contract\"}}"));
    offererTransport.EnqueueReceive(CurrentPathWebSocketReceiveResult.TextMessage(
        CurrentPathSignalingFrameCodec.EncodeEnvelope(new CurrentPathWebRtcSignalingEnvelope(
            sessionId,
            remoteDeviceId,
            localDeviceId,
            CurrentPathWebRtcSignalingMessageType.IceCandidate,
            new CurrentPathWebRtcSignalingPayload(
                candidate: "candidate:2222 1 udp 2113937663 192.168.0.101 51490 typ host generation 0",
                sdpMid: "0",
                sdpMLineIndex: 0),
            sentAt: 1_700_100_001d))));
    offererTransport.EnqueueReceive(CurrentPathWebSocketReceiveResult.TextMessage(
        CurrentPathSignalingFrameCodec.EncodeEnvelope(new CurrentPathWebRtcSignalingEnvelope(
            sessionId,
            remoteDeviceId,
            localDeviceId,
            CurrentPathWebRtcSignalingMessageType.Answer,
            new CurrentPathWebRtcSignalingPayload(sdp: "v=0\r\na=fingerprint:sha-256 44:55:66\r\n"),
            sentAt: 1_700_100_002d))));

    CurrentPathWebSocketSignalingClientOptions? clientOptions = null;
    CurrentPathWebRtcHelperSignalingBridgeResult? offererResult = null;
    CurrentPathWebRtcHelperSignalingBridgeResult? answererResult = null;
    WebRtcSignalDocument? writtenAnswer = null;
    WebRtcSignalDocument? writtenOffer = null;
    IReadOnlyList<CurrentPathWebRtcSignalingEnvelope> offererSentEnvelopes = Array.Empty<CurrentPathWebRtcSignalingEnvelope>();
    IReadOnlyList<CurrentPathWebRtcSignalingEnvelope> answererSentEnvelopes = Array.Empty<CurrentPathWebRtcSignalingEnvelope>();
    try
    {
        clientOptions = new CurrentPathWebSocketSignalingClientOptions(
            "https://api.nebula-technologies.net",
            "/ws/current",
            sessionId,
            "session-token",
            localDeviceId,
            clientVersion,
            protocolVersion,
            connectTimeout: timeout);
        await using var offererWsClient = new CurrentPathWebSocketSignalingClient(offererTransport, clientOptions);

        Console.WriteLine("windows-current-path-bridge-contract: bind-fake-signaling");
        await offererWsClient.ConnectAndBindAsync().ConfigureAwait(false);

        Console.WriteLine("windows-current-path-bridge-contract: exchange-offerer-sdp-ice");
        offererResult = await new CurrentPathWebRtcHelperSignalingBridge().ExchangeOffererAsync(
                offererWsClient,
                new CurrentPathWebRtcHelperSignalingBridgeOptions(
                    sessionId,
                    localDeviceId,
                    remoteDeviceId,
                    offererLocalOfferPath,
                    offererRemoteAnswerPath,
                    signalFileTimeout: TimeSpan.FromSeconds(1),
                    remoteAnswerTimeout: TimeSpan.FromSeconds(Math.Max(1, timeout.TotalSeconds))),
                CancellationToken.None)
            .ConfigureAwait(false);

        offererSentEnvelopes = offererTransport.SentTexts.Select(CurrentPathSignalingFrameCodec.DecodeEnvelope).ToArray();
        ValidateBridgeContractOffererExchange(offererResult, offererSentEnvelopes, localDeviceId, remoteDeviceId);
        writtenAnswer = WebRtcSignalDocument.Read(offererRemoteAnswerPath, "answer");

        var answererLocalAnswerPath = Path.Combine(profileDir, "answerer-local-answer.json");
        var answererRemoteOfferPath = Path.Combine(profileDir, "answerer-remote-offer.json");
        var helperAnswerTask = SimulateAnswererHelperAsync(
            answererRemoteOfferPath,
            answererLocalAnswerPath,
            CancellationToken.None);
        var answererTransport = new RecordingCurrentPathWebSocketTransport();
        answererTransport.EnqueueReceive(CurrentPathWebSocketReceiveResult.TextMessage(
            $"{{\"type\":\"bound\",\"sessionId\":\"{sessionId}\",\"role\":\"responder\",\"clientId\":\"client-bridge-contract-answerer\"}}"));
        answererTransport.EnqueueReceive(CurrentPathWebSocketReceiveResult.TextMessage(
            CurrentPathSignalingFrameCodec.EncodeEnvelope(new CurrentPathWebRtcSignalingEnvelope(
                sessionId,
                remoteDeviceId,
                localDeviceId,
                CurrentPathWebRtcSignalingMessageType.IceCandidate,
                new CurrentPathWebRtcSignalingPayload(
                    candidate: "candidate:4444 1 udp 2113937663 192.168.0.101 51491 typ host generation 0",
                    sdpMid: "0",
                    sdpMLineIndex: 0),
                sentAt: 1_700_100_003d))));
        answererTransport.EnqueueReceive(CurrentPathWebSocketReceiveResult.TextMessage(
            CurrentPathSignalingFrameCodec.EncodeEnvelope(new CurrentPathWebRtcSignalingEnvelope(
                sessionId,
                remoteDeviceId,
                localDeviceId,
                CurrentPathWebRtcSignalingMessageType.Offer,
                new CurrentPathWebRtcSignalingPayload(sdp: "v=0\r\na=fingerprint:sha-256 55:66:77\r\n"),
                sentAt: 1_700_100_004d))));

        await using var answererWsClient = new CurrentPathWebSocketSignalingClient(answererTransport, clientOptions);
        Console.WriteLine("windows-current-path-bridge-contract: bind-fake-answerer-signaling");
        await answererWsClient.ConnectAndBindAsync().ConfigureAwait(false);

        Console.WriteLine("windows-current-path-bridge-contract: exchange-answerer-sdp-ice");
        answererResult = await new CurrentPathWebRtcHelperSignalingBridge().ExchangeAnswererAsync(
                answererWsClient,
                new CurrentPathWebRtcHelperSignalingBridgeOptions(
                    sessionId,
                    localDeviceId,
                    remoteDeviceId,
                    answererLocalAnswerPath,
                    answererRemoteOfferPath,
                    signalFileTimeout: TimeSpan.FromSeconds(1),
                    remoteAnswerTimeout: TimeSpan.FromSeconds(Math.Max(1, timeout.TotalSeconds))),
                CancellationToken.None)
            .ConfigureAwait(false);
        await helperAnswerTask.ConfigureAwait(false);

        answererSentEnvelopes = answererTransport.SentTexts.Select(CurrentPathSignalingFrameCodec.DecodeEnvelope).ToArray();
        ValidateBridgeContractAnswererExchange(answererResult, answererSentEnvelopes, localDeviceId, remoteDeviceId);
        writtenOffer = WebRtcSignalDocument.Read(answererRemoteOfferPath, "offer");

        await WriteCurrentPathBridgeContractEvidenceAsync(
                evidenceOut,
                clientOptions,
                offererTransport,
                answererTransport,
                offererResult,
                writtenAnswer,
                offererSentEnvelopes,
                answererResult,
                writtenOffer,
                answererSentEnvelopes)
            .ConfigureAwait(false);
        Console.WriteLine($"windows-current-path-bridge-contract: evidence={Path.GetFullPath(evidenceOut)}");
        Console.WriteLine("windows-current-path-bridge-contract: ok");
    }
    finally
    {
        if (clientOptions is not null)
        {
            ValidateEvidenceDoesNotContain(
                File.Exists(evidenceOut) ? File.ReadAllText(evidenceOut) : string.Empty,
                clientOptions.Headers.TryGetValue(CurrentPathSignalingWebSocketPolicy.SessionTokenHeader, out var sessionToken)
                    ? sessionToken
                    : null);
        }
    }
}

static async Task SimulateAnswererHelperAsync(
    string remoteOfferPath,
    string localAnswerPath,
    CancellationToken cancellationToken)
{
    while (!File.Exists(remoteOfferPath))
    {
        await Task.Delay(TimeSpan.FromMilliseconds(25), cancellationToken).ConfigureAwait(false);
    }

    var remoteOffer = WebRtcSignalDocument.Read(remoteOfferPath, "offer");
    _ = remoteOffer.Fingerprint();
    _ = remoteOffer.FirstEndpoint();
    WebRtcSignalDocument.Write(
        localAnswerPath,
        "answer",
        "v=0\r\na=fingerprint:sha-256 77:88:99\r\n",
        new[]
        {
            new WebRtcSignalDocument.SignalCandidate
            {
                Candidate = "candidate:3333 1 udp 2113937663 192.168.0.105 56177 typ host generation 0",
                SdpMid = "0",
                SdpMLineIndex = 0,
                UsernameFragment = "WIN2"
            }
        });
}

static void ValidateBridgeContractOffererExchange(
    CurrentPathWebRtcHelperSignalingBridgeResult result,
    IReadOnlyList<CurrentPathWebRtcSignalingEnvelope> sentEnvelopes,
    string localDeviceId,
    string remoteDeviceId)
{
    if (result.LocalCandidateCount != 1 || result.RemoteCandidateCount != 1)
    {
        throw new InvalidDataException("Current-path bridge contract expected exactly one local and one remote ICE candidate.");
    }

    if (!string.Equals(result.RemoteDeviceId, remoteDeviceId, StringComparison.Ordinal))
    {
        throw new InvalidDataException("Current-path bridge contract returned the wrong remote device.");
    }

    ValidateBridgeContractSentEnvelopes(
        sentEnvelopes,
        new[]
        {
            CurrentPathWebRtcSignalingMessageType.Join,
            CurrentPathWebRtcSignalingMessageType.Offer,
            CurrentPathWebRtcSignalingMessageType.IceCandidate,
        },
        localDeviceId,
        remoteDeviceId,
        "offerer");
}

static void ValidateBridgeContractAnswererExchange(
    CurrentPathWebRtcHelperSignalingBridgeResult result,
    IReadOnlyList<CurrentPathWebRtcSignalingEnvelope> sentEnvelopes,
    string localDeviceId,
    string remoteDeviceId)
{
    if (result.LocalCandidateCount != 1 || result.RemoteCandidateCount != 1)
    {
        throw new InvalidDataException("Current-path answerer bridge contract expected exactly one local and one remote ICE candidate.");
    }

    if (!string.Equals(result.RemoteDeviceId, remoteDeviceId, StringComparison.Ordinal))
    {
        throw new InvalidDataException("Current-path answerer bridge contract returned the wrong remote device.");
    }

    ValidateBridgeContractSentEnvelopes(
        sentEnvelopes,
        new[]
        {
            CurrentPathWebRtcSignalingMessageType.Join,
            CurrentPathWebRtcSignalingMessageType.Answer,
            CurrentPathWebRtcSignalingMessageType.IceCandidate,
        },
        localDeviceId,
        remoteDeviceId,
        "answerer");
}

static void ValidateBridgeContractSentEnvelopes(
    IReadOnlyList<CurrentPathWebRtcSignalingEnvelope> sentEnvelopes,
    IReadOnlyList<CurrentPathWebRtcSignalingMessageType> expectedTypes,
    string localDeviceId,
    string remoteDeviceId,
    string role)
{
    if (sentEnvelopes.Count != expectedTypes.Count)
    {
        throw new InvalidDataException($"Current-path {role} bridge contract sent an unexpected number of signaling envelopes.");
    }

    for (var index = 0; index < expectedTypes.Count; index++)
    {
        var envelope = sentEnvelopes[index];
        if (envelope.Type != expectedTypes[index])
        {
            throw new InvalidDataException($"Current-path {role} bridge contract sent signaling envelopes in the wrong order.");
        }

        if (!string.Equals(envelope.From, localDeviceId, StringComparison.Ordinal) ||
            !string.Equals(envelope.To, remoteDeviceId, StringComparison.Ordinal))
        {
            throw new InvalidDataException($"Current-path {role} bridge contract sent an envelope outside the expected device scope.");
        }

        if (envelope.AuthToken is not null)
        {
            throw new InvalidDataException($"Current-path {role} bridge contract must not send authToken in business envelopes.");
        }
    }
}

static void ValidateLookupMatchesLease(
    CurrentPathProtocolIdentityBinding binding,
    CurrentPathConnectionCodeLease lease,
    CurrentPathConnectionCodeLookup lookup)
{
    if (!string.Equals(lease.SessionId, lookup.SessionId, StringComparison.Ordinal))
    {
        throw new InvalidDataException("Current-path lookup sessionId does not match the registered lease.");
    }

    if (!string.Equals(lease.SignalingServerOrigin, lookup.SignalingServerOrigin, StringComparison.Ordinal))
    {
        throw new InvalidDataException("Current-path lookup signaling origin does not match the registered lease.");
    }

    if (!string.Equals(lease.WsPath, lookup.WsPath, StringComparison.Ordinal))
    {
        throw new InvalidDataException("Current-path lookup websocket path does not match the registered lease.");
    }

    if (!string.Equals(binding.DeviceId, lookup.InitiatorDeviceId, StringComparison.Ordinal))
    {
        throw new InvalidDataException("Current-path lookup initiator deviceId does not match the local binding.");
    }

    if (lookup.InitiatorProtocolSigningAlgorithm != binding.ProtocolSigningAlgorithm)
    {
        throw new InvalidDataException("Current-path lookup initiator signing algorithm does not match the local binding.");
    }

    if (!string.Equals(
            binding.ProtocolPublicKeyFingerprint,
            lookup.InitiatorProtocolPublicKeyFingerprint,
            StringComparison.Ordinal))
    {
        throw new InvalidDataException("Current-path lookup initiator fingerprint does not match the local binding.");
    }
}

static void ValidateLookupMatchesExpectedPeer(
    CurrentPathProtocolIdentityBinding binding,
    WindowsTransportAdapterRequest request,
    CurrentPathConnectionCodeLookup lookup)
{
    if (string.Equals(binding.DeviceId, lookup.InitiatorDeviceId, StringComparison.Ordinal))
    {
        throw new InvalidDataException("Current-path product-control lookup resolved a self-registered code; expected a Mac product peer code.");
    }

    if (!string.Equals(request.PairingMaterial.DeviceId, lookup.InitiatorDeviceId, StringComparison.Ordinal) ||
        !string.Equals(request.DiscoveredPeer.DeviceId, lookup.InitiatorDeviceId, StringComparison.Ordinal))
    {
        throw new InvalidDataException("Current-path product-control lookup initiator deviceId does not match the expected paired peer.");
    }

    if (!string.Equals(
            request.PairingMaterial.PublicKeyFingerprint,
            lookup.InitiatorProtocolPublicKeyFingerprint,
            StringComparison.Ordinal) ||
        !string.Equals(
            request.DiscoveredPeer.PublicKeyFingerprint,
            lookup.InitiatorProtocolPublicKeyFingerprint,
            StringComparison.Ordinal))
    {
        throw new InvalidDataException("Current-path product-control lookup initiator fingerprint does not match the expected paired peer.");
    }

    if (lookup.InitiatorProtocolSigningAlgorithm != CurrentPathProtocolSigningAlgorithm.MLDsa65)
    {
        throw new InvalidDataException("Current-path product-control lookup requires an ML-DSA-65 peer identity.");
    }
}

static void ValidateAdmissionLeaseReady(CurrentPathAdmissionLease lease)
{
    if (!IsAdmissionReadyState(lease.State))
    {
        throw new InvalidDataException(
            $"Current-path admission lease state '{lease.State}' is not allowed for connection-code registration.");
    }
}

static bool IsAdmissionReadyState(string state) =>
    string.Equals(state, "admitted", StringComparison.OrdinalIgnoreCase) ||
    string.Equals(state, "active", StringComparison.OrdinalIgnoreCase);

static WindowsTransportAdapterRequest BuildAdapterRequest(string peerDeviceId, string peerFingerprint)
{
    var discoveredPeer = new DiscoveredPeer(
        CoreDiscoveryServiceKind.QuicPrimary,
        peerDeviceId,
        "Mac live helper peer",
        CorePeerPlatform.Apple,
        "macOS",
        peerFingerprint,
        "webrtc,tcp",
        "runtime-smoke",
        PeerCapabilities.Apple());
    var pairingMaterial = new PairingMaterial(
        peerDeviceId,
        "Mac live helper peer",
        "macOS",
        peerFingerprint,
        SHA256.HashData(Encoding.UTF8.GetBytes($"runtime-smoke-peer-key:{peerFingerprint}")),
        VerifiedAgainstDiscoveryFingerprint: true,
        Source: "runtime-smoke");

    return new WindowsTransportAdapterRequest(
        discoveredPeer,
        pairingMaterial,
        CoreTransportKind.WebRtcDataChannel,
        CoreTransportAuditCode.WebRtcInterop,
        RelayRequired: false,
        RelayAllowed: true,
        PeerCapabilities.Windows(),
        PeerCapabilities.Apple(),
        NetworkPath.CrossNatPath());
}

static ConnectionPreflightPlan BuildLaunchPlan(
    DiscoveredPeer peer,
    PairingMaterial pairingMaterial,
    WindowsTransportAdapterSnapshot snapshot)
{
    var mappings = new[]
    {
        Mapping(CoreChannelKind.Control),
        Mapping(CoreChannelKind.File),
        Mapping(CoreChannelKind.Clipboard),
        Mapping(CoreChannelKind.Telemetry),
        Mapping(CoreChannelKind.Realtime),
    };
    var bindingDigest = SHA256.HashData(Encoding.UTF8.GetBytes(
        $"runtime-smoke-binding:{snapshot.AdapterBinding}:{snapshot.LocalEndpoint}:{snapshot.RemoteEndpoint}:{snapshot.SelectedCandidatePair}"));

    return new ConnectionPreflightPlan(
        peer.DeviceId,
        pairingMaterial.PublicKeyFingerprint,
        CoreTransportKind.WebRtcDataChannel,
        CoreTransportAuditCode.WebRtcInterop,
        RelayRequired: false,
        RelayAllowed: true,
        CoreCryptoSuiteKind.X25519Ed25519,
        SelectedSuiteWireId: 0x1001,
        CoreCryptoSuiteAuditCode.ClassicPolicyFallback,
        Sbp2Enabled: true,
        Sbp2FixedPayloadLen: 512,
        FrameHeaderLen: 20,
        mappings,
        bindingDigest,
        snapshot.AdapterKind,
        snapshot.IsLiveAdapterReady,
        snapshot.AdapterBinding,
        snapshot.LocalEndpoint,
        snapshot.RemoteEndpoint,
        snapshot.SelectedCandidatePair,
        snapshot.RelayId,
        snapshot.TimestampWindowMs);
}

static ChannelMapping Mapping(CoreChannelKind channel) =>
    new(
        channel,
        CoreReliabilityKind.ReliableOrdered,
        MaxRetransmits: 0,
        CoreAdapterBindingKind.WebRtcDataChannel,
        HeadOfLineIsolated: false);

static int ReadPositiveInt(Dictionary<string, string> opts, string key, int defaultValue)
{
    if (!opts.TryGetValue(key, out var raw) || string.IsNullOrWhiteSpace(raw))
    {
        return defaultValue;
    }

    if (int.TryParse(raw, out var value) && value > 0)
    {
        return value;
    }

    throw new InvalidOperationException($"--{key} must be a positive integer.");
}

static async Task WriteAdmissionRegisterBoundEvidenceAsync(
    string evidenceOut,
    string status,
    CurrentPathProtocolIdentityBinding binding,
    CurrentPathAdmissionLease? admission,
    CurrentPathConnectionCodeLease? lease,
    CurrentPathConnectionCodeLookup? lookup,
    CurrentPathWebSocketSignalingClientOptions? options,
    IReadOnlyList<CurrentPathSignalingLifecycleEvent> lifecycle,
    CurrentPathWebSocketSignalingClient? client,
    IReadOnlyDictionary<string, bool> steps,
    string? failureCode,
    string? failureClass)
{
    var outputPath = Path.GetFullPath(evidenceOut);
    var outputDir = Path.GetDirectoryName(outputPath);
    if (!string.IsNullOrEmpty(outputDir))
    {
        Directory.CreateDirectory(outputDir);
    }

    var evidence = new SortedDictionary<string, object?>(StringComparer.Ordinal)
    {
        ["EvidenceVersion"] = 1,
        ["Profile"] = "admission-register-bound",
        ["EvidenceScope"] = "AdmissionRegisterLookupSignalingBound",
        ["Status"] = status,
        ["Phase"] = client is null ? "failed" : PhaseWire(client.Phase),
        ["Steps"] = steps.OrderBy(item => item.Key, StringComparer.Ordinal)
            .ToDictionary(item => item.Key, item => item.Value, StringComparer.Ordinal),
        ["ProtocolSigningAlgorithm"] = binding.ProtocolSigningAlgorithmWireName,
        ["ProtocolPublicKeyFingerprint"] = binding.ProtocolPublicKeyFingerprint,
        ["LocalDeviceIdSha256"] = Sha256Hex(binding.DeviceId),
        ["AdmissionCredentialPlacement"] = "bearer-and-tenant-env",
        ["PrivateKeyPlacement"] = "mldsa65-private-key-base64-env",
        ["WebSocketCredentialPlacement"] = options is null ? null : "headers",
        ["HeaderValuesCaptured"] = false,
        ["SecretInputsCaptured"] = false,
        ["ConnectionCodeCaptured"] = false,
        ["AdmissionState"] = admission?.State,
        ["AdmissionIssuedAt"] = admission?.IssuedAt.ToString("O"),
        ["AdmissionExpiresAt"] = admission?.ExpiresAt.ToString("O"),
        ["LeaseExpiresIn"] = lease?.ExpiresIn,
        ["TurnAdmissionTokenPresent"] = !string.IsNullOrWhiteSpace(lease?.TurnAdmissionToken),
        ["MediaAdmissionTokenPresent"] = !string.IsNullOrWhiteSpace(lease?.MediaAdmissionToken),
        ["LookupMode"] = lookup is null ? null : "selfRegisteredCode",
        ["SessionIdSha256"] = lease is null ? null : Sha256Hex(lease.SessionId),
        ["RegisteredCode"] = lease is not null,
        ["LookupCode"] = lookup is not null,
        ["LookupSessionMatches"] = lease is not null && lookup is not null &&
            string.Equals(lease.SessionId, lookup.SessionId, StringComparison.Ordinal),
        ["LookupOriginMatches"] = lease is not null && lookup is not null &&
            string.Equals(lease.SignalingServerOrigin, lookup.SignalingServerOrigin, StringComparison.Ordinal),
        ["LookupWsPathMatches"] = lease is not null && lookup is not null &&
            string.Equals(lease.WsPath, lookup.WsPath, StringComparison.Ordinal),
        ["LookupInitiatorDeviceMatches"] = lookup is not null &&
            string.Equals(binding.DeviceId, lookup.InitiatorDeviceId, StringComparison.Ordinal),
        ["LookupInitiatorFingerprintMatches"] = lookup is not null &&
            string.Equals(
                binding.ProtocolPublicKeyFingerprint,
                lookup.InitiatorProtocolPublicKeyFingerprint,
                StringComparison.Ordinal),
        ["SocketOpen"] = lifecycle.Any(item => item.Phase == CurrentPathSignalingLifecyclePhase.SocketOpen),
        ["Bound"] = client?.IsBound ?? false,
        ["BoundSessionMatches"] = client?.IsBound ?? false,
        ["BoundRole"] = client?.BoundRole,
        ["BoundClientIdPresent"] = !string.IsNullOrWhiteSpace(client?.BoundClientId),
        ["QueryTokenPresent"] = options?.WebSocketUri.Query.Contains("st=", StringComparison.Ordinal) ?? false,
        ["HeadersPresent"] = options?.Headers.Keys.OrderBy(item => item, StringComparer.Ordinal).ToArray(),
        ["BusinessSendCount"] = 0,
        ["FailureCode"] = failureCode,
        ["FailureClass"] = failureClass,
        ["SignalingServerOrigin"] = options?.WebSocketUri.GetLeftPart(UriPartial.Authority) ?? lease?.SignalingServerOrigin,
        ["WebSocketPath"] = options?.WebSocketUri.AbsolutePath ?? lease?.WsPath,
        ["WebSocketScheme"] = options?.WebSocketUri.Scheme,
        ["ClientVersion"] = options?.ClientVersion,
        ["ProtocolVersion"] = options?.ProtocolVersion,
        ["NotTransportProof"] = true,
        ["NotHandshakeProof"] = true,
        ["NotAppControlProof"] = true,
        ["NotMacProductAppProof"] = true,
        ["LifecycleEvents"] = lifecycle.Select(LifecycleEventEvidence).ToArray(),
        ["RecordedAt"] = DateTimeOffset.UtcNow.ToString("O"),
    };

    var tempPath = outputPath + ".tmp-" + Guid.NewGuid().ToString("N");
    var json = JsonSerializer.Serialize(evidence, new JsonSerializerOptions { WriteIndented = true });
    ValidateEvidenceDoesNotContain(
        json,
        admission?.Token,
        lease?.Code,
        lease?.SessionToken,
        lease?.TurnAdmissionToken,
        lease?.MediaAdmissionToken,
        lookup?.SessionToken,
        lookup?.TurnAdmissionToken,
        lookup?.MediaAdmissionToken);
    await File.WriteAllTextAsync(tempPath, json).ConfigureAwait(false);
    File.Move(tempPath, outputPath, overwrite: true);
}

static async Task WriteSignalingBoundEvidenceAsync(
    string evidenceOut,
    CurrentPathWebSocketSignalingClientOptions options,
    IReadOnlyList<CurrentPathSignalingLifecycleEvent> lifecycle,
    CurrentPathWebSocketSignalingClient? client,
    string status,
    string? failureCode,
    string? failureClass,
    int businessSendCount)
{
    var outputPath = Path.GetFullPath(evidenceOut);
    var outputDir = Path.GetDirectoryName(outputPath);
    if (!string.IsNullOrEmpty(outputDir))
    {
        Directory.CreateDirectory(outputDir);
    }

    var evidence = new SortedDictionary<string, object?>(StringComparer.Ordinal)
    {
        ["EvidenceVersion"] = 1,
        ["Profile"] = "signaling-bound",
        ["EvidenceScope"] = "SignalingBound",
        ["Status"] = status,
        ["Phase"] = client is null ? "failed" : PhaseWire(client.Phase),
        ["SocketOpen"] = lifecycle.Any(item => item.Phase == CurrentPathSignalingLifecyclePhase.SocketOpen),
        ["Bound"] = client?.IsBound ?? false,
        ["BoundSessionMatches"] = client?.IsBound ?? false,
        ["BoundRole"] = client?.BoundRole,
        ["BoundClientIdPresent"] = !string.IsNullOrWhiteSpace(client?.BoundClientId),
        ["CredentialPlacement"] = "headers",
        ["QueryTokenPresent"] = options.WebSocketUri.Query.Contains("st=", StringComparison.Ordinal),
        ["HeadersPresent"] = options.Headers.Keys.OrderBy(item => item, StringComparer.Ordinal).ToArray(),
        ["HeaderValuesCaptured"] = false,
        ["BusinessSendCount"] = businessSendCount,
        ["FailureCode"] = failureCode,
        ["FailureClass"] = failureClass,
        ["SignalingServerOrigin"] = options.WebSocketUri.GetLeftPart(UriPartial.Authority),
        ["WebSocketPath"] = options.WebSocketUri.AbsolutePath,
        ["WebSocketScheme"] = options.WebSocketUri.Scheme,
        ["SessionIdSha256"] = Sha256Hex(options.SessionId),
        ["LocalDeviceIdSha256"] = Sha256Hex(options.LocalDeviceId),
        ["ClientVersion"] = options.ClientVersion,
        ["ProtocolVersion"] = options.ProtocolVersion,
        ["NotTransportProof"] = true,
        ["NotHandshakeProof"] = true,
        ["NotAppControlProof"] = true,
        ["LifecycleEvents"] = lifecycle.Select(LifecycleEventEvidence).ToArray(),
        ["RecordedAt"] = DateTimeOffset.UtcNow.ToString("O"),
    };

    var tempPath = outputPath + ".tmp-" + Guid.NewGuid().ToString("N");
    var json = JsonSerializer.Serialize(evidence, new JsonSerializerOptions { WriteIndented = true });
    ValidateEvidenceDoesNotContain(
        json,
        options.Headers.TryGetValue(CurrentPathSignalingWebSocketPolicy.SessionTokenHeader, out var sessionToken)
            ? sessionToken
            : null);
    await File.WriteAllTextAsync(tempPath, json).ConfigureAwait(false);
    File.Move(tempPath, outputPath, overwrite: true);
}

static async Task WriteCurrentPathProductControlTransportEvidenceAsync(
    string evidenceOut,
    string status,
    string profileName,
    CurrentPathProtocolIdentityBinding binding,
    CurrentPathAdmissionLease admission,
    CurrentPathConnectionCodeLookup lookup,
    CurrentPathWebSocketSignalingClientOptions options,
    CurrentPathWebSocketSignalingClient client,
    IReadOnlyList<CurrentPathSignalingLifecycleEvent> lifecycle,
    IReadOnlyDictionary<string, bool> steps,
    LiveWebRtcProductControlContext context,
    WebRtcProductHandshakeInitiatorResult? handshakeResult,
    WebRtcAppControlBootstrapResult? appControlResult,
    string connectionCode,
    string? failureCode,
    string? failureClass)
{
    var outputPath = Path.GetFullPath(evidenceOut);
    var outputDir = Path.GetDirectoryName(outputPath);
    if (!string.IsNullOrEmpty(outputDir))
    {
        Directory.CreateDirectory(outputDir);
    }

    var evidence = new SortedDictionary<string, object?>(StringComparer.Ordinal)
    {
        ["EvidenceVersion"] = 1,
        ["Profile"] = profileName,
        ["EvidenceScope"] = appControlResult is null
            ? "AdmissionLookupBoundSdpIceProductControlTransportOpen"
            : "AdmissionLookupBoundSdpIceProductControlHandshakeAppControlPong",
        ["Status"] = status,
        ["Steps"] = steps,
        ["CredentialPlacement"] = "bearer-tenant-env-and-websocket-headers",
        ["WebSocketCredentialPlacement"] = "headers",
        ["HeaderValuesCaptured"] = false,
        ["SecretInputsCaptured"] = false,
        ["ConnectionCodeCaptured"] = false,
        ["QueryTokenPresent"] = options.WebSocketUri.Query.Contains("st=", StringComparison.Ordinal),
        ["HeadersPresent"] = options.Headers.Keys.OrderBy(item => item, StringComparer.Ordinal).ToArray(),
        ["AdmissionState"] = admission.State,
        ["AdmissionIssuedAt"] = admission.IssuedAt.ToString("O"),
        ["AdmissionExpiresAt"] = admission.ExpiresAt.ToString("O"),
        ["ProtocolSigningAlgorithm"] = binding.ProtocolSigningAlgorithmWireName,
        ["ProtocolPublicKeyFingerprint"] = binding.ProtocolPublicKeyFingerprint,
        ["LookupMode"] = "peerConnectionCode",
        ["LookupInitiatorDeviceMatchesPeer"] = true,
        ["LookupInitiatorFingerprintMatchesPeer"] = true,
        ["TurnAdmissionTokenPresent"] = !string.IsNullOrWhiteSpace(lookup.TurnAdmissionToken),
        ["MediaAdmissionTokenPresent"] = !string.IsNullOrWhiteSpace(lookup.MediaAdmissionToken),
        ["SocketOpen"] = lifecycle.Any(item => item.Phase == CurrentPathSignalingLifecyclePhase.SocketOpen),
        ["Bound"] = client.IsBound,
        ["BoundSessionMatches"] = client.IsBound,
        ["BoundRole"] = client.BoundRole,
        ["BoundClientIdPresent"] = !string.IsNullOrWhiteSpace(client.BoundClientId),
        ["SignalingServerOrigin"] = options.WebSocketUri.GetLeftPart(UriPartial.Authority),
        ["WebSocketPath"] = options.WebSocketUri.AbsolutePath,
        ["WebSocketScheme"] = options.WebSocketUri.Scheme,
        ["SessionIdSha256"] = Sha256Hex(options.SessionId),
        ["LocalDeviceIdSha256"] = Sha256Hex(options.LocalDeviceId),
        ["RemoteDeviceIdSha256"] = Sha256Hex(lookup.InitiatorDeviceId),
        ["RuntimeProfile"] = WebRtcProductControlTransportProvider.TransportProfile,
        ["ProductControlTransportProfile"] = context.TransportProfile,
        ["SecureSessionState"] = context.SecureSessionState.ToString(),
        ["DataChannelLabel"] = context.DataChannelLabel,
        ["Role"] = context.Role,
        ["AdapterBinding"] = context.AdapterBinding,
        ["LocalEndpoint"] = context.LocalEndpoint,
        ["RemoteEndpoint"] = context.RemoteEndpoint,
        ["SelectedCandidatePair"] = context.SelectedCandidatePair,
        ["TransportBindingDigestHex"] = context.TransportBindingDigestHex,
        ["TimestampWindowMs"] = context.TimestampWindowMs,
        ["ProductSendCount"] = appControlResult is null ? 0 : 1,
        ["ProductReceiveCount"] = appControlResult is null ? 0 : 1,
        ["PeerMlKem768PublicKeyInputPresent"] = handshakeResult is not null,
        ["PeerMlKem768PublicKeyCaptured"] = false,
        ["HandshakeRole"] = handshakeResult is null ? null : "initiator",
        ["NegotiatedSuiteWireId"] = handshakeResult is null ? null : FormatSuiteWireId(handshakeResult.SelectedSuiteWireId),
        ["PolicyRequirePqc"] = handshakeResult is null ? null : true,
        ["PolicyAllowClassicFallback"] = handshakeResult is null ? null : false,
        ["HandshakeSessionIdSha256"] = handshakeResult is null ? null : Sha256Hex(handshakeResult.SessionId),
        ["HandshakeSessionHash"] = handshakeResult?.SessionHash,
        ["HandshakeTranscriptPrefix"] = handshakeResult?.TranscriptPrefix,
        ["MessageABytes"] = handshakeResult?.MessageABytes,
        ["MessageASha256"] = handshakeResult?.MessageASha256,
        ["MessageBBytes"] = handshakeResult?.MessageBBytes,
        ["MessageBSha256"] = handshakeResult?.MessageBSha256,
        ["ResponderIdentityFingerprintVerified"] = handshakeResult?.ResponderIdentityFingerprintVerified,
        ["ResponderSignatureVerified"] = handshakeResult?.ResponderSignatureVerified,
        ["ResponderFinishedVerified"] = handshakeResult?.ResponderFinishedVerified,
        ["InitiatorFinishedSent"] = handshakeResult?.InitiatorFinishedSent,
        ["AppControlPacketType"] = appControlResult is null ? null : "AppControl",
        ["AppControlReceivedMessageKind"] = appControlResult?.ReceivedMessageKind,
        ["AppControlPingId"] = appControlResult?.PingId,
        ["AppControlPongIdMatches"] = appControlResult is null ? null : true,
        ["AppControlOutboundCounter"] = appControlResult?.OutboundCounter,
        ["AppControlInboundCounter"] = appControlResult?.InboundCounter,
        ["AppControlSessionHash"] = appControlResult?.SessionHash,
        ["AppControlTranscriptPrefix"] = appControlResult?.TranscriptPrefix,
        ["FailureCode"] = failureCode,
        ["FailureClass"] = failureClass,
        ["NotHandshakeProof"] = handshakeResult is null,
        ["NotAppControlProof"] = appControlResult is null,
        ["NotMacProductAppProof"] = appControlResult is null,
        ["LifecycleEvents"] = lifecycle.Select(LifecycleEventEvidence).ToArray(),
        ["RecordedAt"] = DateTimeOffset.UtcNow.ToString("O"),
    };

    var tempPath = outputPath + ".tmp-" + Guid.NewGuid().ToString("N");
    var json = JsonSerializer.Serialize(evidence, new JsonSerializerOptions { WriteIndented = true });
    ValidateEvidenceDoesNotContain(
        json,
        connectionCode,
        admission.Token,
        lookup.SessionToken,
        lookup.TurnAdmissionToken,
        lookup.MediaAdmissionToken,
        options.Headers.TryGetValue(CurrentPathSignalingWebSocketPolicy.SessionTokenHeader, out var sessionToken)
            ? sessionToken
            : null);
    await File.WriteAllTextAsync(tempPath, json).ConfigureAwait(false);
    File.Move(tempPath, outputPath, overwrite: true);
}

static async Task WriteCurrentPathBridgeContractEvidenceAsync(
    string evidenceOut,
    CurrentPathWebSocketSignalingClientOptions options,
    RecordingCurrentPathWebSocketTransport offererTransport,
    RecordingCurrentPathWebSocketTransport answererTransport,
    CurrentPathWebRtcHelperSignalingBridgeResult offererResult,
    WebRtcSignalDocument writtenAnswer,
    IReadOnlyList<CurrentPathWebRtcSignalingEnvelope> offererSentEnvelopes,
    CurrentPathWebRtcHelperSignalingBridgeResult answererResult,
    WebRtcSignalDocument writtenOffer,
    IReadOnlyList<CurrentPathWebRtcSignalingEnvelope> answererSentEnvelopes)
{
    var outputPath = Path.GetFullPath(evidenceOut);
    var outputDir = Path.GetDirectoryName(outputPath);
    if (!string.IsNullOrEmpty(outputDir))
    {
        Directory.CreateDirectory(outputDir);
    }

    var evidence = new SortedDictionary<string, object?>(StringComparer.Ordinal)
    {
        ["EvidenceVersion"] = 1,
        ["Profile"] = "current-path-bridge-contract",
        ["EvidenceScope"] = "CurrentPathWebRtcHelperBidirectionalSdpIceBridgeContract",
        ["Status"] = "ok",
        ["ExchangeRoles"] = new[] { "offerer", "answerer" },
        ["CredentialPlacement"] = "headers",
        ["HeaderValuesCaptured"] = false,
        ["SecretInputsCaptured"] = false,
        ["QueryTokenPresent"] =
            (offererTransport.ConnectedUri?.Query.Contains("st=", StringComparison.Ordinal) ?? false) ||
            (answererTransport.ConnectedUri?.Query.Contains("st=", StringComparison.Ordinal) ?? false),
        ["HeadersPresent"] = offererTransport.HeaderNames,
        ["SessionIdSha256"] = Sha256Hex(options.SessionId),
        ["LocalDeviceIdSha256"] = Sha256Hex(options.LocalDeviceId),
        ["RemoteDeviceIdSha256"] = Sha256Hex(offererResult.RemoteDeviceId),
        ["WebSocketScheme"] = offererTransport.ConnectedUri?.Scheme,
        ["WebSocketPath"] = offererTransport.ConnectedUri?.AbsolutePath,
        ["Bound"] = offererTransport.Connected && answererTransport.Connected,
        ["SocketOpen"] = offererTransport.Connected && answererTransport.Connected,
        ["OutboundFrameCount"] = offererSentEnvelopes.Count + answererSentEnvelopes.Count,
        ["OutboundTypes"] = offererSentEnvelopes
            .Concat(answererSentEnvelopes)
            .Select(item => CurrentPathWebRtcSignalingMessageTypes.ToWireName(item.Type))
            .ToArray(),
        ["BusinessSendCount"] = offererSentEnvelopes.Count + answererSentEnvelopes.Count,
        ["OffererOutboundFrameCount"] = offererSentEnvelopes.Count,
        ["OffererOutboundTypes"] = offererSentEnvelopes
            .Select(item => CurrentPathWebRtcSignalingMessageTypes.ToWireName(item.Type))
            .ToArray(),
        ["AnswererOutboundFrameCount"] = answererSentEnvelopes.Count,
        ["AnswererOutboundTypes"] = answererSentEnvelopes
            .Select(item => CurrentPathWebRtcSignalingMessageTypes.ToWireName(item.Type))
            .ToArray(),
        ["LocalCandidateCount"] = offererResult.LocalCandidateCount,
        ["RemoteCandidateCount"] = offererResult.RemoteCandidateCount,
        ["AnswerFingerprint"] = writtenAnswer.Fingerprint(),
        ["RemoteEndpoint"] = writtenAnswer.FirstEndpoint(),
        ["RemoteCandidateLabel"] = writtenAnswer.FirstCandidateLabel(),
        ["RemoteSignalWritten"] = File.Exists(offererResult.WroteRemoteSignalPath),
        ["AnswererLocalCandidateCount"] = answererResult.LocalCandidateCount,
        ["AnswererRemoteCandidateCount"] = answererResult.RemoteCandidateCount,
        ["OfferFingerprint"] = writtenOffer.Fingerprint(),
        ["AnswererRemoteEndpoint"] = writtenOffer.FirstEndpoint(),
        ["AnswererRemoteCandidateLabel"] = writtenOffer.FirstCandidateLabel(),
        ["AnswererRemoteSignalWritten"] = File.Exists(answererResult.WroteRemoteSignalPath),
        ["NotTransportProof"] = true,
        ["NotHandshakeProof"] = true,
        ["NotAppControlProof"] = true,
        ["NotMacProductAppProof"] = true,
        ["RecordedAt"] = DateTimeOffset.UtcNow.ToString("O"),
    };

    var tempPath = outputPath + ".tmp-" + Guid.NewGuid().ToString("N");
    var json = JsonSerializer.Serialize(evidence, new JsonSerializerOptions { WriteIndented = true });
    ValidateEvidenceDoesNotContain(
        json,
        options.Headers.TryGetValue(CurrentPathSignalingWebSocketPolicy.SessionTokenHeader, out var sessionToken)
            ? sessionToken
            : null);
    await File.WriteAllTextAsync(tempPath, json).ConfigureAwait(false);
    File.Move(tempPath, outputPath, overwrite: true);
}

static SortedDictionary<string, object?> LifecycleEventEvidence(CurrentPathSignalingLifecycleEvent item) =>
    new(StringComparer.Ordinal)
    {
        ["Phase"] = PhaseWire(item.Phase),
        ["Generation"] = item.Generation,
        ["ServerFrameType"] = item.ServerFrameType,
        ["FailureClass"] = item.FailureClass.HasValue ? FailureClassWire(item.FailureClass.Value) : null,
        ["ErrorDescription"] = item.ErrorDescription,
        ["OccurredAt"] = (item.OccurredAt ?? DateTimeOffset.UtcNow).ToString("O"),
    };

static string PhaseWire(CurrentPathSignalingLifecyclePhase phase) =>
    phase switch
    {
        CurrentPathSignalingLifecyclePhase.Idle => "idle",
        CurrentPathSignalingLifecyclePhase.Connecting => "connecting",
        CurrentPathSignalingLifecyclePhase.SocketOpen => "socketOpen",
        CurrentPathSignalingLifecyclePhase.Bound => "bound",
        CurrentPathSignalingLifecyclePhase.Closing => "closing",
        CurrentPathSignalingLifecyclePhase.Closed => "closed",
        CurrentPathSignalingLifecyclePhase.Failed => "failed",
        _ => throw new InvalidOperationException($"Unknown current-path signaling phase: {phase}.")
    };

static string FailureClassWire(CurrentPathSignalingFailureClass failureClass) =>
    failureClass switch
    {
        CurrentPathSignalingFailureClass.AuthBindRejected => "authBindRejected",
        CurrentPathSignalingFailureClass.InvalidShardOrSessionMismatch => "invalidShardOrSessionMismatch",
        CurrentPathSignalingFailureClass.TokenExpired => "tokenExpired",
        CurrentPathSignalingFailureClass.TransientNetwork => "transientNetwork",
        CurrentPathSignalingFailureClass.TransientServer => "transientServer",
        CurrentPathSignalingFailureClass.ProtocolViolation => "protocolViolation",
        _ => throw new InvalidOperationException($"Unknown current-path signaling failure class: {failureClass}.")
    };

static string Required(Dictionary<string, string> opts, string key)
{
    if (opts.TryGetValue(key, out var value) && !string.IsNullOrWhiteSpace(value))
    {
        return value.Trim();
    }

    throw new InvalidOperationException($"Missing required --{key}.");
}

static string RequiredSecretFromEnvironment(Dictionary<string, string> opts, string valueKey, string envKey)
{
    if (opts.TryGetValue(valueKey, out var value) && !string.IsNullOrWhiteSpace(value))
    {
        throw new InvalidOperationException($"--{valueKey} is not supported because secrets must not be passed through argv; use --{envKey}.");
    }

    var hasEnv = opts.TryGetValue(envKey, out var envName) && !string.IsNullOrWhiteSpace(envName);
    if (hasEnv)
    {
        var normalizedEnvName = envName!.Trim();
        if (normalizedEnvName.Any(ch => !(char.IsLetterOrDigit(ch) || ch == '_')))
        {
            throw new InvalidOperationException($"--{envKey} must name an environment variable using letters, digits, or underscores.");
        }

        var envValue = Environment.GetEnvironmentVariable(normalizedEnvName);
        if (!string.IsNullOrWhiteSpace(envValue))
        {
            return envValue.Trim();
        }

        throw new InvalidOperationException($"Environment variable named by --{envKey} is missing or empty.");
    }

    throw new InvalidOperationException($"Missing required --{envKey}.");
}

static bool IsLowerHex(string value, int length) =>
    value.Length == length && value.All(ch => (ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f'));

static string Sha256Hex(string value) =>
    Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(value))).ToLowerInvariant();

static string FormatSuiteWireId(ushort suiteWireId) =>
    "0x" + suiteWireId.ToString("x4");

static string ValidateDeviceName(string raw)
{
    if (string.IsNullOrWhiteSpace(raw))
    {
        throw new InvalidOperationException("--device-name must not be empty.");
    }

    var value = raw.Trim();
    if (value.Length > 128 || value.Any(ch => ch < 0x20 || ch == 0x7F))
    {
        throw new InvalidOperationException("--device-name is invalid.");
    }

    return value;
}

static string NormalizeConnectionCode(string raw)
{
    if (!CrossNetworkConnectionCodePolicy.TryNormalize(raw, out var normalized))
    {
        throw new InvalidOperationException(
            CrossNetworkConnectionCodePolicy.BuildInvalidMessage("Current-path connection code"));
    }

    return normalized;
}

static void ValidateEvidenceDoesNotContain(string json, params string?[] values)
{
    foreach (var value in values)
    {
        if (!string.IsNullOrWhiteSpace(value) && json.Contains(value, StringComparison.Ordinal))
        {
            throw new InvalidOperationException("RuntimeSmoke evidence serialization attempted to include a raw secret or connection code.");
        }
    }
}

static byte[] DecodeBase64Secret(string base64, string label)
{
    try
    {
        return Convert.FromBase64String(base64);
    }
    catch (FormatException ex)
    {
        throw new InvalidOperationException($"{label} must be base64 encoded.", ex);
    }
}

static byte[] DecodeBase64Bytes(string base64, string label)
{
    try
    {
        return Convert.FromBase64String(base64);
    }
    catch (FormatException ex)
    {
        throw new InvalidOperationException($"{label} must be base64 encoded.", ex);
    }
}

static Dictionary<string, string> ParseArgs(string[] args)
{
    var parsed = new Dictionary<string, string>(StringComparer.Ordinal);
    for (var i = 0; i < args.Length; i++)
    {
        var arg = args[i];
        if (!arg.StartsWith("--", StringComparison.Ordinal))
        {
            throw new InvalidOperationException("Unexpected positional argument.");
        }

        var key = arg[2..];
        if (string.IsNullOrWhiteSpace(key))
        {
            throw new InvalidOperationException("Argument names must not be empty.");
        }

        if (i + 1 >= args.Length || args[i + 1].StartsWith("--", StringComparison.Ordinal))
        {
            throw new InvalidOperationException($"Missing value for --{key}.");
        }

        parsed[key] = args[++i];
    }

    return parsed;
}

sealed class RecordingCurrentPathWebSocketTransport : ICurrentPathWebSocketTransport
{
    private readonly Queue<CurrentPathWebSocketReceiveResult> _receiveQueue = new();

    public bool Connected { get; private set; }

    public bool Closed { get; private set; }

    public Uri? ConnectedUri { get; private set; }

    public IReadOnlyList<string> HeaderNames { get; private set; } = Array.Empty<string>();

    public List<string> SentTexts { get; } = new();

    public void EnqueueReceive(CurrentPathWebSocketReceiveResult result) =>
        _receiveQueue.Enqueue(result);

    public Task ConnectAsync(
        Uri uri,
        IReadOnlyDictionary<string, string> headers,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(uri);
        ArgumentNullException.ThrowIfNull(headers);
        if (Connected)
        {
            throw new InvalidOperationException("Recording current-path WebSocket transport was connected twice.");
        }

        ConnectedUri = uri;
        HeaderNames = headers.Keys.OrderBy(item => item, StringComparer.Ordinal).ToArray();
        Connected = true;
        return Task.CompletedTask;
    }

    public Task SendTextAsync(string text, CancellationToken cancellationToken)
    {
        if (!Connected || Closed)
        {
            throw new InvalidOperationException("Recording current-path WebSocket transport is not open.");
        }

        SentTexts.Add(text);
        return Task.CompletedTask;
    }

    public Task<CurrentPathWebSocketReceiveResult> ReceiveAsync(
        int maxMessageBytes,
        CancellationToken cancellationToken)
    {
        if (!Connected || Closed)
        {
            throw new InvalidOperationException("Recording current-path WebSocket transport is not open.");
        }

        if (_receiveQueue.Count == 0)
        {
            throw new InvalidOperationException("Recording current-path WebSocket receive queue is empty.");
        }

        var result = _receiveQueue.Dequeue();
        if (result.ByteCount > maxMessageBytes)
        {
            throw new InvalidDataException("Current-path WebSocket text message exceeded the configured byte limit.");
        }

        return Task.FromResult(result);
    }

    public Task CloseAsync(CancellationToken cancellationToken)
    {
        Closed = true;
        return Task.CompletedTask;
    }

    public ValueTask DisposeAsync()
    {
        Closed = true;
        return ValueTask.CompletedTask;
    }
}
