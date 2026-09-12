using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
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
    var bindAddress = opts.GetValueOrDefault("bind-address", string.Empty);
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
                CurrentPathProductControlRuntimeProof.TransportOnly,
                asAnswerer: false)
            .ConfigureAwait(false);
        return;
    }

    if (string.Equals(profile, "current-path-product-control-answerer-transport", StringComparison.OrdinalIgnoreCase))
    {
        await RunCurrentPathProductControlTransportProfileAsync(
                launchOptions,
                adapterRequest,
                opts,
                evidenceOut,
                timeout,
                CurrentPathProductControlRuntimeProof.TransportOnly,
                asAnswerer: true)
            .ConfigureAwait(false);
        return;
    }

    if (string.Equals(profile, "current-path-product-control-answerer-file-transfer", StringComparison.OrdinalIgnoreCase))
    {
        await RunCurrentPathProductControlTransportProfileAsync(
                launchOptions,
                adapterRequest,
                opts,
                evidenceOut,
                timeout,
                CurrentPathProductControlRuntimeProof.FileTransfer,
                asAnswerer: true)
            .ConfigureAwait(false);
        return;
    }

    if (string.Equals(profile, "current-path-product-control-answerer-appcontrol", StringComparison.OrdinalIgnoreCase))
    {
        await RunCurrentPathProductControlTransportProfileAsync(
                launchOptions,
                adapterRequest,
                opts,
                evidenceOut,
                timeout,
                CurrentPathProductControlRuntimeProof.AppControl,
                asAnswerer: true)
            .ConfigureAwait(false);
        return;
    }

    if (string.Equals(profile, "current-path-product-control-file-transfer", StringComparison.OrdinalIgnoreCase))
    {
        await RunCurrentPathProductControlTransportProfileAsync(
                launchOptions,
                adapterRequest,
                opts,
                evidenceOut,
                timeout,
                CurrentPathProductControlRuntimeProof.FileTransfer,
                asAnswerer: false)
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
                CurrentPathProductControlRuntimeProof.AppControl,
                asAnswerer: false)
            .ConfigureAwait(false);
        return;
    }

    throw new InvalidOperationException(
        "--profile must be admission-register-bound, signaling-bound, current-path-bridge-contract, current-path-product-control-answerer-appcontrol, current-path-product-control-answerer-file-transfer, current-path-product-control-answerer-transport, current-path-product-control-appcontrol, current-path-product-control-file-transfer, current-path-product-control-transport, session, or product-control.");
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
    CurrentPathProductControlRuntimeProof runtimeProof,
    bool asAnswerer)
{
    var requireSecureSessionProof = runtimeProof is
        CurrentPathProductControlRuntimeProof.AppControl or
        CurrentPathProductControlRuntimeProof.FileTransfer;
    var runAppControlProof = runtimeProof == CurrentPathProductControlRuntimeProof.AppControl;
    var runFileTransferProof = runtimeProof == CurrentPathProductControlRuntimeProof.FileTransfer;
    var profileName = runtimeProof switch
    {
        CurrentPathProductControlRuntimeProof.TransportOnly => asAnswerer
            ? "current-path-product-control-answerer-transport"
            : "current-path-product-control-transport",
        CurrentPathProductControlRuntimeProof.AppControl => asAnswerer
            ? "current-path-product-control-answerer-appcontrol"
            : "current-path-product-control-appcontrol",
        CurrentPathProductControlRuntimeProof.FileTransfer => asAnswerer
            ? "current-path-product-control-answerer-file-transfer"
            : "current-path-product-control-file-transfer",
        _ => throw new InvalidOperationException("Unsupported current-path product-control proof mode.")
    };
    var baseUrl = opts.GetValueOrDefault("signal-server-base-url", CurrentPathSignalServerClient.DefaultBaseUrl);
    var localDeviceId = CurrentPathProtocolIdentityBinding.NormalizeDeviceId(Required(opts, "local-device-id"));
    var deviceName = ValidateDeviceName(opts.GetValueOrDefault("device-name", "Windows RuntimeSmoke"));
    var connectionCode = asAnswerer
        ? null
        : NormalizeConnectionCode(RequiredSecretFromEnvironment(opts, "connection-code", "connection-code-env"));
    var bearerToken = RequiredSecretFromEnvironment(opts, "bearer-token", "bearer-token-env");
    var tenantId = RequiredSecretFromEnvironment(opts, "tenant-id", "tenant-id-env");
    var privateKeyBase64 = RequiredSecretFromEnvironment(
        opts,
        "mldsa65-private-key-base64",
        "mldsa65-private-key-base64-env");
    var privateKeyBytes = DecodeBase64Secret(privateKeyBase64, "current-path ML-DSA-65 private key");
    var peerMlKem768PublicKeyBase64 = requireSecureSessionProof
        ? asAnswerer
            ? null
            : RequiredSecretFromEnvironment(
            opts,
            "peer-mlkem768-public-key-base64",
            "peer-mlkem768-public-key-base64-env")
        : null;
    var localMlKem768DecapsulationKeyBase64 = requireSecureSessionProof && asAnswerer
        ? RequiredSecretFromEnvironment(
            opts,
            "local-mlkem768-decapsulation-key-base64",
            "local-mlkem768-decapsulation-key-base64-env")
        : null;
    var localMlKem768EncapsulationKeyBase64 = requireSecureSessionProof && asAnswerer
        ? RequiredSecretFromEnvironment(
            opts,
            "local-mlkem768-encapsulation-key-base64",
            "local-mlkem768-encapsulation-key-base64-env")
        : null;
    var peerMlKem768PublicKey = peerMlKem768PublicKeyBase64 is null
        ? null
        : DecodeBase64Bytes(peerMlKem768PublicKeyBase64, "peer ML-KEM-768 public key");
    var localMlKem768DecapsulationKey = localMlKem768DecapsulationKeyBase64 is null
        ? null
        : DecodeBase64Secret(localMlKem768DecapsulationKeyBase64, "local ML-KEM-768 decapsulation key");
    var localMlKem768EncapsulationKey = localMlKem768EncapsulationKeyBase64 is null
        ? null
        : DecodeBase64Bytes(localMlKem768EncapsulationKeyBase64, "local ML-KEM-768 public key");
    if (peerMlKem768PublicKey is not null &&
        peerMlKem768PublicKey.Length != MLKemAlgorithm.MLKem768.EncapsulationKeySizeInBytes)
    {
        throw new InvalidOperationException(
            $"peer ML-KEM-768 public key must be {MLKemAlgorithm.MLKem768.EncapsulationKeySizeInBytes} bytes.");
    }

    if (localMlKem768DecapsulationKey is not null &&
        localMlKem768DecapsulationKey.Length != MLKemAlgorithm.MLKem768.DecapsulationKeySizeInBytes)
    {
        throw new InvalidOperationException(
            $"local ML-KEM-768 decapsulation key must be {MLKemAlgorithm.MLKem768.DecapsulationKeySizeInBytes} bytes.");
    }

    if (localMlKem768EncapsulationKey is not null &&
        localMlKem768EncapsulationKey.Length != MLKemAlgorithm.MLKem768.EncapsulationKeySizeInBytes)
    {
        throw new InvalidOperationException(
            $"local ML-KEM-768 public key must be {MLKemAlgorithm.MLKem768.EncapsulationKeySizeInBytes} bytes.");
    }

    if (localMlKem768DecapsulationKey is not null && localMlKem768EncapsulationKey is not null)
    {
        VerifyMlKem768KeyPair(localMlKem768EncapsulationKey, localMlKem768DecapsulationKey);
    }

    var clientVersion = opts.GetValueOrDefault("client-version", CurrentPathSignalServerClient.DefaultClientVersion);
    var protocolVersion = opts.GetValueOrDefault("protocol-version", CurrentPathSignalServerClient.DefaultProtocolVersion);
    var ttlSeconds = ReadPositiveInt(opts, "ttl-seconds", 300);
    var signalFileTimeoutSeconds = ReadPositiveInt(opts, "signal-file-timeout-seconds", 30);
    var remoteAnswerTimeoutSeconds = ReadPositiveInt(opts, "remote-answer-timeout-seconds", Math.Max(1, (int)timeout.TotalSeconds));
    var remoteOfferTimeoutSeconds = ReadPositiveInt(opts, "remote-offer-timeout-seconds", remoteAnswerTimeoutSeconds);
    var remoteSignalTimeoutSeconds = asAnswerer ? remoteOfferTimeoutSeconds : remoteAnswerTimeoutSeconds;
    var remoteSignalWaitType = asAnswerer ? "offer" : "answer";
    var fileTransferPayloadBytes = ReadPositiveInt(opts, "file-transfer-payload-bytes", 1024);
    if (fileTransferPayloadBytes > 2048)
    {
        throw new InvalidOperationException("--file-transfer-payload-bytes must be in the range 1..2048.");
    }

    var expectedBoundRole = NormalizeExpectedBoundRole(
        opts.GetValueOrDefault("expected-bound-role", asAnswerer ? "responder" : string.Empty));
    var registeredCodeOut = opts.GetValueOrDefault("registered-code-out", string.Empty);
    if (!asAnswerer && !string.IsNullOrWhiteSpace(registeredCodeOut))
    {
        throw new InvalidOperationException("--registered-code-out is supported only for answerer current-path profiles.");
    }
    var sessionIdOut = opts.GetValueOrDefault("session-id-out", string.Empty);
    if (!runAppControlProof && !string.IsNullOrWhiteSpace(sessionIdOut))
    {
        throw new InvalidOperationException("--session-id-out is supported only for AppControl current-path profiles.");
    }

    var lifecycle = new List<CurrentPathSignalingLifecycleEvent>();
    var steps = new SortedDictionary<string, bool>(StringComparer.Ordinal)
    {
        ["AdmissionChallenge"] = false,
        ["AdmissionLease"] = false,
        ["SignalingBound"] = false,
        ["ProductControlTransport"] = false,
    };
    steps[asAnswerer ? "RegisterCode" : "LookupCode"] = false;
    if (requireSecureSessionProof)
    {
        steps["ProductHandshake"] = false;
        steps[runFileTransferProof ? "FileTransferReceipt" : "AppControlPingPong"] = false;
    }

    CurrentPathProtocolIdentityBinding? binding = null;
    CurrentPathAdmissionLease? admissionLease = null;
    CurrentPathConnectionCodeLease? lease = null;
    CurrentPathConnectionCodeLookup? lookup = null;
    CurrentPathWebSocketSignalingClientOptions? clientOptions = null;
    LiveWebRtcProductControlContext? context = null;
    WebRtcProductHandshakeInitiatorResult? handshakeResult = null;
    WebRtcProductHandshakeResponderResult? responderHandshakeResult = null;
    WebRtcAppControlBootstrapResult? appControlResult = null;
    WebRtcAppControlResponderResult? appControlResponderResult = null;
    WebRtcFileTransferProofResult? fileTransferResult = null;
    WebRtcFileTransferResponderResult? fileTransferResponderResult = null;

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

        if (asAnswerer)
        {
            Console.WriteLine($"{profileName}: register-code");
            lease = await signalClient.RegisterConnectionCodeAsync(
                    admissionLease.Token,
                    deviceName,
                    TimeSpan.FromSeconds(ttlSeconds),
                    timeoutCts.Token)
                .ConfigureAwait(false);
            steps["RegisterCode"] = true;
            if (string.IsNullOrWhiteSpace(registeredCodeOut))
            {
                Console.WriteLine($"{profileName}: connection-code-ready");
            }
            else
            {
                await WriteOperatorSecretFileAsync(
                        registeredCodeOut,
                        lease.Code,
                        "--registered-code-out",
                        "Current-path registered connection code is empty.",
                        "skybridge-current-path-product-control-answerer-code-",
                        "registered code",
                        timeoutCts.Token)
                    .ConfigureAwait(false);
                Console.WriteLine($"{profileName}: connection-code-out={Path.GetFullPath(registeredCodeOut)}");
            }
        }
        else
        {
            Console.WriteLine($"{profileName}: lookup-code");
            lookup = await signalClient.LookupConnectionCodeAsync(admissionLease.Token, connectionCode!, timeoutCts.Token)
                .ConfigureAwait(false);
            ValidateLookupMatchesExpectedPeer(binding, adapterRequest, lookup);
            steps["LookupCode"] = true;
        }

        var signalingServerOrigin = asAnswerer ? lease!.SignalingServerOrigin : lookup!.SignalingServerOrigin;
        var wsPath = asAnswerer ? lease!.WsPath : lookup!.WsPath;
        var sessionId = asAnswerer ? lease!.SessionId : lookup!.SessionId;
        var sessionToken = asAnswerer ? lease!.SessionToken : lookup!.SessionToken;
        var remoteDeviceId = asAnswerer ? adapterRequest.PairingMaterial.DeviceId : lookup!.InitiatorDeviceId;
        var remoteProtocolFingerprint = asAnswerer
            ? adapterRequest.PairingMaterial.PublicKeyFingerprint
            : lookup!.InitiatorProtocolPublicKeyFingerprint;
        var remoteProtocolSigningAlgorithm = asAnswerer
            ? CurrentPathProtocolSigningAlgorithm.MLDsa65
            : lookup!.InitiatorProtocolSigningAlgorithm;

        clientOptions = new CurrentPathWebSocketSignalingClientOptions(
            signalingServerOrigin,
            wsPath,
            sessionId,
            sessionToken,
            localDeviceId,
            clientVersion,
            protocolVersion,
            connectTimeout: timeout);
        await using var wsClient = new CurrentPathWebSocketSignalingClient(clientOptions);
        wsClient.LifecycleChanged += lifecycle.Add;

        Console.WriteLine($"{profileName}: connect-signaling");
        await wsClient.ConnectAndBindAsync(timeoutCts.Token).ConfigureAwait(false);
        if (!string.IsNullOrWhiteSpace(expectedBoundRole) &&
            !string.Equals(wsClient.BoundRole, expectedBoundRole, StringComparison.Ordinal))
        {
            throw new InvalidDataException(
                $"Current-path product-control expected WebSocket bound role '{expectedBoundRole}', got '{wsClient.BoundRole ?? "<null>"}'.");
        }

        steps["SignalingBound"] = true;

        var connector = new CurrentPathWebRtcProductControlSessionConnector(
            new WebRtcHelperLaunchClient(launchOptions),
            wsClient,
            new CurrentPathWebRtcHelperSignalingBridge(),
            new CurrentPathWebRtcProductControlSessionConnectorOptions(
                sessionId,
                localDeviceId,
                remoteDeviceId,
                remoteProtocolFingerprint,
                remoteProtocolSigningAlgorithm,
                TimeSpan.FromSeconds(signalFileTimeoutSeconds),
                TimeSpan.FromSeconds(remoteSignalTimeoutSeconds)));
        await using var provider = new WebRtcProductControlTransportProvider(
            connector,
            new WebRtcProductControlTransportOptions(
                asAnswerer,
                preferredIpcPort: 0,
                timestampWindowMs: 15_000));

        Console.WriteLine($"{profileName}: prepare-product-control-transport");
        context = await provider.PrepareAsync(adapterRequest, timeoutCts.Token).ConfigureAwait(false);
        steps["ProductControlTransport"] = true;
        var evidenceContext = context;

        if (requireSecureSessionProof)
        {
            if (!asAnswerer && peerMlKem768PublicKey is null)
            {
                throw new InvalidOperationException(
                    "current-path product-control secure runtime proof requires peer ML-KEM-768 public key material.");
            }

            if (asAnswerer && localMlKem768DecapsulationKey is null)
            {
                throw new InvalidOperationException(
                    "current-path product-control answerer secure runtime proof requires local ML-KEM-768 decapsulation key material.");
            }

            if (asAnswerer && localMlKem768EncapsulationKey is null)
            {
                throw new InvalidOperationException(
                    "current-path product-control answerer secure runtime proof requires local ML-KEM-768 public key material so the registered answerer key can be audited.");
            }

            var sessionStore = new WebRtcProductSecureSessionStore();
            using var cryptoProvider = new WebRtcProductPqcHandshakeCryptoProvider(
                new WebRtcProductPqcHandshakeCryptoProviderOptions(
                    privateKeyBytes,
                    peerMlKem768PublicKey ?? Array.Empty<byte>(),
                    localMlKem768DecapsulationKey ?? Array.Empty<byte>()));
            var handshakeDriver = new WebRtcProductHandshakeDriver(
                cryptoProvider,
                sessionStore,
                new WebRtcProductHandshakeDriverOptions(timeout));

            Console.WriteLine($"{profileName}: start-product-handshake");
            if (asAnswerer)
            {
                responderHandshakeResult = await handshakeDriver
                    .StartResponderWithResultAsync(context, timeoutCts.Token)
                    .ConfigureAwait(false);
            }
            else
            {
                handshakeResult = await handshakeDriver
                    .StartInitiatorWithResultAsync(context, timeoutCts.Token)
                    .ConfigureAwait(false);
            }

            steps["ProductHandshake"] = true;
            evidenceContext = handshakeResult?.EstablishedContext ?? responderHandshakeResult!.EstablishedContext;

            if (runAppControlProof && asAnswerer)
            {
                var appControlResponder = new WebRtcAppControlResponderHost(
                    sessionStore,
                    new WebRtcAppControlBootstrapOptions(timeout));
                Console.WriteLine($"{profileName}: answer-appcontrol-ping");
                appControlResponderResult = await appControlResponder
                    .AnswerPingAsync(
                        evidenceContext,
                        responderHandshakeResult!.SelectedSuiteWireId,
                        timeoutCts.Token)
                    .ConfigureAwait(false);
                steps["AppControlPingPong"] = true;
            }
            else if (runAppControlProof)
            {
                var appControlClient = new WebRtcAppControlBootstrapClient(
                    sessionStore,
                    new WebRtcAppControlBootstrapOptions(timeout));
                Console.WriteLine($"{profileName}: exchange-appcontrol-ping");
                appControlResult = await appControlClient
                    .ExchangePingAsync(
                        evidenceContext,
                        handshakeResult!.SelectedSuiteWireId,
                        timeoutCts.Token)
                    .ConfigureAwait(false);

                steps["AppControlPingPong"] = true;
            }
            else if (runFileTransferProof && asAnswerer)
            {
                using var fileTransferKeys = sessionStore.RequireEstablishedKeys(
                    evidenceContext,
                    responderHandshakeResult!.SelectedSuiteWireId,
                    WebRtcAppSecureRole.Responder);
                var fileTransferResponder = new WebRtcFileTransferResponderHost(
                    new WebRtcFileTransferProofOptions(timeout, maxFileBytes: fileTransferPayloadBytes));
                Console.WriteLine($"{profileName}: receive-file-transfer");
                fileTransferResponderResult = await fileTransferResponder
                    .ReceiveSingleChunkAndAckAsync(
                        evidenceContext.ControlPlane,
                        fileTransferKeys,
                        timeoutCts.Token)
                    .ConfigureAwait(false);

                steps["FileTransferReceipt"] = true;
            }
            else if (runFileTransferProof)
            {
                using var fileTransferKeys = sessionStore.RequireEstablishedKeys(
                    evidenceContext,
                    handshakeResult!.SelectedSuiteWireId,
                    WebRtcAppSecureRole.Initiator);
                var fileTransferClient = new WebRtcFileTransferProofClient(
                    new WebRtcFileTransferProofOptions(timeout, maxFileBytes: fileTransferPayloadBytes));
                var fileTransferPayload = BuildFileTransferSmokePayload(fileTransferPayloadBytes);
                try
                {
                    Console.WriteLine($"{profileName}: exchange-file-transfer");
                    fileTransferResult = await fileTransferClient
                        .ExchangeSingleChunkAsync(
                            evidenceContext.ControlPlane,
                            fileTransferKeys,
                            fileTransferPayload,
                            timeoutCts.Token)
                        .ConfigureAwait(false);
                }
                finally
                {
                    CryptographicOperations.ZeroMemory(fileTransferPayload);
                }

                steps["FileTransferReceipt"] = true;
            }
        }

        await WriteCurrentPathProductControlTransportEvidenceAsync(
                evidenceOut,
                runFileTransferProof ? "fileTransferReceipt" : runAppControlProof ? "appControlPong" : "transportOpen",
                profileName,
                binding,
                admissionLease,
                lease,
                lookup,
                clientOptions,
                wsClient,
                lifecycle,
                steps,
                evidenceContext,
                handshakeResult,
                responderHandshakeResult,
                appControlResult,
                appControlResponderResult,
                fileTransferResult,
                fileTransferResponderResult,
                asAnswerer,
                expectedBoundRole,
                remoteSignalWaitType,
                remoteSignalTimeoutSeconds,
                connectionCode,
                localMlKem768EncapsulationKey,
                bearerToken,
                tenantId,
                privateKeyBase64,
                peerMlKem768PublicKeyBase64,
                localMlKem768DecapsulationKeyBase64,
                localMlKem768EncapsulationKeyBase64,
                failureCode: null,
                failureClass: null)
            .ConfigureAwait(false);
        if (!string.IsNullOrWhiteSpace(sessionIdOut))
        {
            await WriteOperatorSecretFileAsync(
                    sessionIdOut,
                    sessionId,
                    "--session-id-out",
                    "Current-path product-control session id is empty.",
                    "skybridge-current-path-product-control-session-id-",
                    "session id",
                    timeoutCts.Token)
                .ConfigureAwait(false);
            Console.WriteLine($"{profileName}: session-id-out={Path.GetFullPath(sessionIdOut)}");
        }

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

        if (localMlKem768DecapsulationKey is not null)
        {
            CryptographicOperations.ZeroMemory(localMlKem768DecapsulationKey);
        }

        if (localMlKem768EncapsulationKey is not null)
        {
            CryptographicOperations.ZeroMemory(localMlKem768EncapsulationKey);
        }

        if (binding is not null && clientOptions is not null)
        {
            ValidateEvidenceDoesNotContain(
                File.Exists(evidenceOut) ? File.ReadAllText(evidenceOut) : string.Empty,
                bearerToken,
                tenantId,
                privateKeyBase64,
                peerMlKem768PublicKeyBase64,
                localMlKem768DecapsulationKeyBase64,
                localMlKem768EncapsulationKeyBase64,
                connectionCode,
                admissionLease?.Token,
                lease?.Code,
                lease?.SessionToken,
                lease?.TurnAdmissionToken,
                lease?.MediaAdmissionToken,
                lookup?.SessionToken,
                lookup?.TurnAdmissionToken,
                lookup?.MediaAdmissionToken,
                clientOptions.SessionId,
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
    var sessionId = CurrentPathWebRtcSignalingEnvelope.ValidateSessionId(
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
    var rawPathRequestTargets = await ValidateCurrentPathRawPathContractAsync().ConfigureAwait(false);
    await ValidateCurrentPathSessionIdentityContractAsync().ConfigureAwait(false);
    ValidateCurrentPathSdpLimitContract();
    const int nearLimitSdpHeadroomBytes = 4096;
    var nearLimitSdpTargetBytes = CurrentPathWebRtcSignalingPayload.MaxSdpBytes - nearLimitSdpHeadroomBytes;
    var nearLimitLocalOfferSdp = BuildLargeCurrentPathSdp("11:22:33", nearLimitSdpTargetBytes);
    var nearLimitRemoteAnswerSdp = BuildLargeCurrentPathSdp("44:55:66", nearLimitSdpTargetBytes);
    var nearLimitRemoteOfferSdp = BuildLargeCurrentPathSdp("55:66:77", nearLimitSdpTargetBytes);

    WebRtcSignalDocument.Write(
        offererLocalOfferPath,
        "offer",
        nearLimitLocalOfferSdp,
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
                sdpMLineIndex: 0,
                usernameFragment: "MAC1"),
            sentAt: 1_700_100_001d))));
    offererTransport.EnqueueReceive(CurrentPathWebSocketReceiveResult.TextMessage(
        CurrentPathSignalingFrameCodec.EncodeEnvelope(new CurrentPathWebRtcSignalingEnvelope(
            sessionId,
            remoteDeviceId,
            localDeviceId,
            CurrentPathWebRtcSignalingMessageType.Answer,
            new CurrentPathWebRtcSignalingPayload(sdp: nearLimitRemoteAnswerSdp),
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
                    remoteSignalTimeout: TimeSpan.FromSeconds(Math.Max(1, timeout.TotalSeconds))),
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
                    sdpMLineIndex: 0,
                    usernameFragment: "MAC2"),
                sentAt: 1_700_100_003d))));
        answererTransport.EnqueueReceive(CurrentPathWebSocketReceiveResult.TextMessage(
            CurrentPathSignalingFrameCodec.EncodeEnvelope(new CurrentPathWebRtcSignalingEnvelope(
                sessionId,
                remoteDeviceId,
                localDeviceId,
                CurrentPathWebRtcSignalingMessageType.Offer,
                new CurrentPathWebRtcSignalingPayload(sdp: nearLimitRemoteOfferSdp),
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
                    remoteSignalTimeout: TimeSpan.FromSeconds(Math.Max(1, timeout.TotalSeconds))),
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
                answererSentEnvelopes,
                rawPathRequestTargets)
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

        if (envelope.Type == CurrentPathWebRtcSignalingMessageType.IceCandidate &&
            string.IsNullOrWhiteSpace(envelope.Payload?.UsernameFragment))
        {
            throw new InvalidDataException($"Current-path {role} bridge contract must preserve ICE usernameFragment.");
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

static Task WriteAdmissionRegisterBoundEvidenceAsync(
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
    WebRtcArtifactFileWriter.WriteUtf8TextAtomically(outputPath, json);
    return Task.CompletedTask;
}

static Task WriteSignalingBoundEvidenceAsync(
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

    var json = JsonSerializer.Serialize(evidence, new JsonSerializerOptions { WriteIndented = true });
    ValidateEvidenceDoesNotContain(
        json,
        options.Headers.TryGetValue(CurrentPathSignalingWebSocketPolicy.SessionTokenHeader, out var sessionToken)
            ? sessionToken
            : null);
    WebRtcArtifactFileWriter.WriteUtf8TextAtomically(outputPath, json);
    return Task.CompletedTask;
}

static Task WriteCurrentPathProductControlTransportEvidenceAsync(
    string evidenceOut,
    string status,
    string profileName,
    CurrentPathProtocolIdentityBinding binding,
    CurrentPathAdmissionLease admission,
    CurrentPathConnectionCodeLease? lease,
    CurrentPathConnectionCodeLookup? lookup,
    CurrentPathWebSocketSignalingClientOptions options,
    CurrentPathWebSocketSignalingClient client,
    IReadOnlyList<CurrentPathSignalingLifecycleEvent> lifecycle,
    IReadOnlyDictionary<string, bool> steps,
    LiveWebRtcProductControlContext context,
    WebRtcProductHandshakeInitiatorResult? handshakeResult,
    WebRtcProductHandshakeResponderResult? responderHandshakeResult,
    WebRtcAppControlBootstrapResult? appControlResult,
    WebRtcAppControlResponderResult? appControlResponderResult,
    WebRtcFileTransferProofResult? fileTransferResult,
    WebRtcFileTransferResponderResult? fileTransferResponderResult,
    bool asAnswerer,
    string? expectedBoundRole,
    string remoteSignalWaitType,
    int remoteSignalTimeoutSeconds,
    string? connectionCode,
    byte[]? localMlKem768EncapsulationKey,
    string? bearerToken,
    string? tenantId,
    string? privateKeyBase64,
    string? peerMlKem768PublicKeyBase64,
    string? localMlKem768DecapsulationKeyBase64,
    string? localMlKem768EncapsulationKeyBase64,
    string? failureCode,
    string? failureClass)
{
    var outputPath = Path.GetFullPath(evidenceOut);
    var outputDir = Path.GetDirectoryName(outputPath);
    if (!string.IsNullOrEmpty(outputDir))
    {
        Directory.CreateDirectory(outputDir);
    }

    var hasHandshakeProof = handshakeResult is not null || responderHandshakeResult is not null;
    var hasAppControlProof = appControlResult is not null || appControlResponderResult is not null;
    var hasFileTransferProof = fileTransferResult is not null || fileTransferResponderResult is not null;
    var selectedSuiteWireId = handshakeResult?.SelectedSuiteWireId ?? responderHandshakeResult?.SelectedSuiteWireId;
    var handshakeSessionId = handshakeResult?.SessionId ?? responderHandshakeResult?.SessionId;
    var handshakeSessionHash = handshakeResult?.SessionHash ?? responderHandshakeResult?.SessionHash;
    var handshakeTranscriptPrefix = handshakeResult?.TranscriptPrefix ?? responderHandshakeResult?.TranscriptPrefix;
    var appControlPingId = appControlResult?.PingId ?? appControlResponderResult?.PingId;
    var appControlOutboundCounter = appControlResult?.OutboundCounter ?? appControlResponderResult?.OutboundCounter;
    var appControlInboundCounter = appControlResult?.InboundCounter ?? appControlResponderResult?.InboundCounter;
    var appControlSessionHash = appControlResult?.SessionHash ?? appControlResponderResult?.SessionHash;
    var appControlTranscriptPrefix = appControlResult?.TranscriptPrefix ?? appControlResponderResult?.TranscriptPrefix;
    var appControlPayloadFormat = appControlResult?.PayloadFormat ?? appControlResponderResult?.PayloadFormat;
    var fileTransferSessionIdSha256 = fileTransferResult?.SessionIdSha256 ?? fileTransferResponderResult?.SessionIdSha256;
    var fileTransferTransferIdSha256 = fileTransferResult?.TransferIdSha256 ?? fileTransferResponderResult?.TransferIdSha256;
    var fileTransferBytes = fileTransferResult?.TransferredBytes ?? fileTransferResponderResult?.ReceivedBytes;
    var fileTransferChunkCount = fileTransferResult?.ChunkCount ?? fileTransferResponderResult?.ChunkCount;
    var fileTransferChunkAckCount = fileTransferResult?.ChunkAckCount ?? fileTransferResponderResult?.ChunkAckCount;
    var fileTransferFileSha256Receipt = fileTransferResult?.FileSha256Receipt ?? fileTransferResponderResult?.FileSha256Receipt;
    var fileTransferSentFileSha256 = fileTransferResult?.SentFileSha256 ?? fileTransferResponderResult?.ReceivedFileSha256;
    var fileTransferReceivedFileSha256 = fileTransferResponderResult?.ReceivedFileSha256;
    var fileTransferReceiptMatchesSentHash = fileTransferResult?.ReceiptMatchesSentHash ??
        fileTransferResponderResult?.ReceiptMatchesReceivedHash;
    var fileTransferProductSendCount = fileTransferResult?.ProductSendCount ?? fileTransferResponderResult?.ProductSendCount;
    var fileTransferProductReceiveCount = fileTransferResult?.ProductReceiveCount ?? fileTransferResponderResult?.ProductReceiveCount;
    var usesAppleLegacyAppControl = string.Equals(
        appControlPayloadFormat,
        "AppleLegacyAesGcmCombined",
        StringComparison.Ordinal);
    var appControlSbwcEnvelope = hasAppControlProof ? !usesAppleLegacyAppControl : (bool?)null;

    var evidence = new SortedDictionary<string, object?>(StringComparer.Ordinal)
    {
        ["EvidenceVersion"] = 1,
        ["Profile"] = profileName,
        ["EvidenceScope"] = hasFileTransferProof
            ? asAnswerer
                ? "AdmissionRegisterBoundSdpIceProductControlAnswererHandshakeFileTransferReceipt"
                : "AdmissionLookupBoundSdpIceProductControlHandshakeFileTransferReceipt"
            : hasAppControlProof
            ? asAnswerer
                ? "AdmissionRegisterBoundSdpIceProductControlAnswererHandshakeAppControlPong"
                : "AdmissionLookupBoundSdpIceProductControlHandshakeAppControlPong"
            : asAnswerer
                ? "AdmissionRegisterBoundSdpIceProductControlAnswererTransportOpen"
                : "AdmissionLookupBoundSdpIceProductControlTransportOpen",
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
        ["LookupMode"] = asAnswerer ? "localRegisteredConnectionCode" : "peerConnectionCode",
        ["RegisteredCode"] = lease is not null,
        ["LookupCode"] = lookup is not null,
        ["LookupInitiatorDeviceMatchesPeer"] = lookup is null ? null : true,
        ["LookupInitiatorFingerprintMatchesPeer"] = lookup is null ? null : true,
        ["RegisteredCodeLocalDeviceBound"] = lease is null ? null : true,
        ["RegisteredCodeRemoteInitiatorIdentityPresent"] = lease is null ? null : false,
        ["TurnAdmissionTokenPresent"] = !string.IsNullOrWhiteSpace(lookup?.TurnAdmissionToken ?? lease?.TurnAdmissionToken),
        ["MediaAdmissionTokenPresent"] = !string.IsNullOrWhiteSpace(lookup?.MediaAdmissionToken ?? lease?.MediaAdmissionToken),
        ["SocketOpen"] = lifecycle.Any(item => item.Phase == CurrentPathSignalingLifecyclePhase.SocketOpen),
        ["Bound"] = client.IsBound,
        ["BoundSessionMatches"] = client.IsBound,
        ["BoundRole"] = client.BoundRole,
        ["ExpectedBoundRole"] = string.IsNullOrWhiteSpace(expectedBoundRole) ? null : expectedBoundRole.Trim(),
        ["BoundClientIdPresent"] = !string.IsNullOrWhiteSpace(client.BoundClientId),
        ["SignalingServerOrigin"] = options.WebSocketUri.GetLeftPart(UriPartial.Authority),
        ["WebSocketPath"] = options.WebSocketUri.AbsolutePath,
        ["WebSocketScheme"] = options.WebSocketUri.Scheme,
        ["SessionIdSha256"] = Sha256Hex(options.SessionId),
        ["LocalDeviceIdSha256"] = Sha256Hex(options.LocalDeviceId),
        ["RemoteDeviceIdSha256"] = Sha256Hex(lookup?.InitiatorDeviceId ?? context.PeerDeviceId),
        ["RemoteProtocolPublicKeyFingerprint"] = context.PeerPublicKeyFingerprint,
        ["RemoteIdentitySource"] = asAnswerer
            ? hasHandshakeProof
                ? "operatorExpectedPeerHandshakeVerifiedNotServerAttested"
                : "operatorExpectedPeerNotServerAttested"
            : "connectionCodeLookup",
        ["RemoteIdentityServerAttested"] = !asAnswerer,
        ["NotRemoteIdentityProof"] = asAnswerer && !hasHandshakeProof,
        ["RuntimeProfile"] = WebRtcProductControlTransportProvider.TransportProfile,
        ["ProductControlTransportProfile"] = context.TransportProfile,
        ["SignalingExchangeRole"] = asAnswerer ? "answerer" : "offerer",
        ["HelperMode"] = asAnswerer ? "product-control-answer" : "product-control-offer",
        ["LocalSignalType"] = asAnswerer ? "answer" : "offer",
        ["RemoteSignalType"] = asAnswerer ? "offer" : "answer",
        ["RemoteSignalWaitType"] = remoteSignalWaitType,
        ["RemoteSignalTimeoutSeconds"] = remoteSignalTimeoutSeconds,
        ["TransportOnlyDirection"] = asAnswerer ? "answerer" : "offerer",
        ["SecureSessionState"] = context.SecureSessionState.ToString(),
        ["DataChannelLabel"] = context.DataChannelLabel,
        ["Role"] = context.Role,
        ["AdapterBinding"] = context.AdapterBinding,
        ["LocalEndpoint"] = context.LocalEndpoint,
        ["RemoteEndpoint"] = context.RemoteEndpoint,
        ["SelectedCandidatePair"] = context.SelectedCandidatePair,
        ["LateRemoteIceCandidateRelayCount"] = context.LateRemoteIceCandidateRelayCount,
        ["TransportBindingDigestHex"] = context.TransportBindingDigestHex,
        ["TimestampWindowMs"] = context.TimestampWindowMs,
        ["ProductSendCount"] = hasFileTransferProof ? fileTransferProductSendCount : hasAppControlProof ? 1 : 0,
        ["ProductReceiveCount"] = hasFileTransferProof ? fileTransferProductReceiveCount : hasAppControlProof ? 1 : 0,
        ["ProductPayloadCountSource"] = hasFileTransferProof
            ? "runtime-smoke-filetransfer-exchange"
            : hasAppControlProof
                ? "runtime-smoke-appcontrol-exchange"
                : "none",
        ["PeerMlKem768PublicKeyInputPresent"] = handshakeResult is not null,
        ["PeerMlKem768PublicKeyCaptured"] = false,
        ["PeerMlKem768PublicKeySource"] = handshakeResult is null ? null : "operatorProvidedOutOfBand",
        ["PeerMlKem768PublicKeyServerAttested"] = handshakeResult is null ? null : false,
        ["LocalMlKem768DecapsulationKeyInputPresent"] = responderHandshakeResult is not null,
        ["LocalMlKem768DecapsulationKeyCaptured"] = false,
        ["LocalMlKem768EncapsulationKeyInputPresent"] = responderHandshakeResult is not null,
        ["LocalMlKem768EncapsulationKeyCaptured"] = false,
        ["LocalMlKem768EncapsulationKeySource"] = responderHandshakeResult is null ? null : "operatorProvidedOutOfBand",
        ["LocalMlKem768EncapsulationKeyServerPublished"] = responderHandshakeResult is null ? null : false,
        ["LocalMlKem768EncapsulationKeySha256"] = localMlKem768EncapsulationKey is null ? null : Sha256HexBytes(localMlKem768EncapsulationKey),
        ["LocalMlKem768KeyPairVerified"] = responderHandshakeResult is null ? null : true,
        ["HandshakeRole"] = handshakeResult is not null
            ? "initiator"
            : responderHandshakeResult is not null
                ? "responder"
                : null,
        ["NegotiatedSuiteWireId"] = selectedSuiteWireId.HasValue ? FormatSuiteWireId(selectedSuiteWireId.Value) : null,
        ["PolicyRequirePqc"] = hasHandshakeProof ? true : null,
        ["PolicyAllowClassicFallback"] = hasHandshakeProof ? false : null,
        ["HandshakeSessionIdSha256"] = handshakeSessionId is null ? null : Sha256Hex(handshakeSessionId),
        ["HandshakeSessionHash"] = handshakeSessionHash,
        ["HandshakeTranscriptPrefix"] = handshakeTranscriptPrefix,
        ["MessageABytes"] = handshakeResult?.MessageABytes ?? responderHandshakeResult?.MessageABytes,
        ["MessageASha256"] = handshakeResult?.MessageASha256 ?? responderHandshakeResult?.MessageASha256,
        ["MessageBBytes"] = handshakeResult?.MessageBBytes ?? responderHandshakeResult?.MessageBBytes,
        ["MessageBSha256"] = handshakeResult?.MessageBSha256 ?? responderHandshakeResult?.MessageBSha256,
        ["ResponderIdentityFingerprintVerified"] = handshakeResult?.ResponderIdentityFingerprintVerified,
        ["ResponderSignatureVerified"] = handshakeResult?.ResponderSignatureVerified,
        ["ResponderFinishedVerified"] = handshakeResult?.ResponderFinishedVerified,
        ["InitiatorFinishedSent"] = handshakeResult?.InitiatorFinishedSent,
        ["InitiatorIdentityFingerprintVerified"] = responderHandshakeResult?.InitiatorIdentityFingerprintVerified,
        ["InitiatorSignatureVerified"] = responderHandshakeResult?.InitiatorSignatureVerified,
        ["ResponderFinishedSent"] = responderHandshakeResult?.ResponderFinishedSent,
        ["InitiatorFinishedVerified"] = responderHandshakeResult?.InitiatorFinishedVerified,
        ["AppControlPacketType"] = hasAppControlProof ? "AppControl" : null,
        ["AppControlCryptoFormat"] = appControlPayloadFormat,
        ["AppControlPayloadFormat"] = appControlPayloadFormat,
        ["AppControlSbwcEnvelope"] = appControlSbwcEnvelope,
        ["AppControlSbwcCounterPresent"] = hasAppControlProof
            ? appControlSbwcEnvelope is true && appControlOutboundCounter.HasValue && appControlInboundCounter.HasValue
            : null,
        ["AppControlReplayProtection"] = hasAppControlProof
            ? usesAppleLegacyAppControl
                ? "none-legacy-aes-gcm-combined"
                : "sbwc-replay-window"
            : null,
        ["AppControlLegacyNonceLength"] = usesAppleLegacyAppControl ? 12 : null,
        ["AppControlLegacyTagLength"] = usesAppleLegacyAppControl ? 16 : null,
        ["AppControlLegacyAadLength"] = usesAppleLegacyAppControl ? 0 : null,
        ["AppControlLegacyCombinedLayout"] = usesAppleLegacyAppControl ? "nonce|ciphertext|tag" : null,
        ["AuthenticatedAppControlPingPongProof"] = hasAppControlProof,
        ["AppControlReceivedMessageKind"] = appControlResult?.ReceivedMessageKind ?? appControlResponderResult?.ReceivedMessageKind,
        ["AppControlResponseMessageKind"] = appControlResponderResult?.SentMessageKind,
        ["AppControlPingId"] = appControlPingId,
        ["AppControlPongIdMatches"] = hasAppControlProof ? true : null,
        ["AppControlOutboundCounter"] = appControlOutboundCounter,
        ["AppControlInboundCounter"] = appControlInboundCounter,
        ["AppControlSessionHash"] = appControlSessionHash,
        ["AppControlTranscriptPrefix"] = appControlTranscriptPrefix,
        ["FileTransferPacketType"] = hasFileTransferProof ? "FileTransfer" : null,
        ["SbwcPacketType"] = hasFileTransferProof ? "FileTransfer" : null,
        ["FileTransferSbwcEnvelope"] = hasFileTransferProof ? true : null,
        ["FileTransferReplayProtection"] = hasFileTransferProof ? "sbwc-replay-window" : null,
        ["AuthenticatedFileTransferReceiptProof"] = hasFileTransferProof ? true : null,
        ["TransferRole"] = hasFileTransferProof ? asAnswerer ? "receiver" : "sender" : null,
        ["FileChannelObserved"] = hasFileTransferProof ? true : null,
        ["ManifestFileCount"] = hasFileTransferProof ? 1 : null,
        ["ManifestBytes"] = fileTransferBytes,
        ["TransferredBytes"] = fileTransferBytes,
        ["ReceivedBytes"] = fileTransferResponderResult?.ReceivedBytes,
        ["ChunkCount"] = fileTransferChunkCount,
        ["ChunkAckCount"] = fileTransferChunkAckCount,
        ["CompleteAckReceived"] = fileTransferResult?.CompleteAckReceived,
        ["CompleteAckSent"] = fileTransferResponderResult?.CompleteAckSent,
        ["SentFileSha256"] = fileTransferSentFileSha256,
        ["ReceivedFileSha256"] = fileTransferReceivedFileSha256,
        ["FileSha256Receipt"] = fileTransferFileSha256Receipt,
        ["ReceiptMatchesSentHash"] = fileTransferReceiptMatchesSentHash,
        ["ReceiptMatchesReceivedHash"] = fileTransferResponderResult?.ReceiptMatchesReceivedHash,
        ["FileTransferSessionIdSha256"] = fileTransferSessionIdSha256,
        ["FileTransferTransferIdSha256"] = fileTransferTransferIdSha256,
        ["FileTransferManifestOutboundCounter"] = fileTransferResult?.ManifestOutboundCounter,
        ["FileTransferManifestAckInboundCounter"] = fileTransferResult?.ManifestAckInboundCounter,
        ["FileTransferChunkOutboundCounter"] = fileTransferResult?.ChunkOutboundCounter,
        ["FileTransferChunkAckInboundCounter"] = fileTransferResult?.ChunkAckInboundCounter,
        ["FileTransferCompleteOutboundCounter"] = fileTransferResult?.CompleteOutboundCounter,
        ["FileTransferCompleteAckInboundCounter"] = fileTransferResult?.CompleteAckInboundCounter,
        ["FileTransferManifestInboundCounter"] = fileTransferResponderResult?.ManifestInboundCounter,
        ["FileTransferManifestAckOutboundCounter"] = fileTransferResponderResult?.ManifestAckOutboundCounter,
        ["FileTransferChunkInboundCounter"] = fileTransferResponderResult?.ChunkInboundCounter,
        ["FileTransferChunkAckOutboundCounter"] = fileTransferResponderResult?.ChunkAckOutboundCounter,
        ["FileTransferCompleteInboundCounter"] = fileTransferResponderResult?.CompleteInboundCounter,
        ["FileTransferCompleteAckOutboundCounter"] = fileTransferResponderResult?.CompleteAckOutboundCounter,
        ["FileTransferSessionHash"] = fileTransferResult?.SessionHash ?? fileTransferResponderResult?.SessionHash,
        ["FileTransferTranscriptPrefix"] = fileTransferResult?.TranscriptPrefix ?? fileTransferResponderResult?.TranscriptPrefix,
        ["RawLocalPathCaptured"] = false,
        ["RawRemotePathCaptured"] = false,
        ["RawSignalingCaptured"] = false,
        ["RawSdpCaptured"] = false,
        ["RawIceCredentialCaptured"] = false,
        ["RawPayloadCaptured"] = false,
        ["FailureCode"] = failureCode,
        ["FailureClass"] = failureClass,
        ["NotHandshakeProof"] = !hasHandshakeProof,
        ["NotAppControlProof"] = !hasAppControlProof,
        ["RemoteProductAppObserved"] = false,
        ["PeerTrustPersistenceProof"] = false,
        ["NotMacProductAppProof"] = true,
        ["LifecycleEvents"] = lifecycle.Select(LifecycleEventEvidence).ToArray(),
        ["RecordedAt"] = DateTimeOffset.UtcNow.ToString("O"),
    };

    var json = JsonSerializer.Serialize(evidence, new JsonSerializerOptions { WriteIndented = true });
    ValidateEvidenceDoesNotContain(
        json,
        bearerToken,
        tenantId,
        privateKeyBase64,
        peerMlKem768PublicKeyBase64,
        localMlKem768DecapsulationKeyBase64,
        localMlKem768EncapsulationKeyBase64,
        connectionCode,
        admission.Token,
        lease?.Code,
        lease?.SessionToken,
        lease?.TurnAdmissionToken,
        lease?.MediaAdmissionToken,
        lookup?.SessionToken,
        lookup?.TurnAdmissionToken,
        lookup?.MediaAdmissionToken,
        options.Headers.TryGetValue(CurrentPathSignalingWebSocketPolicy.SessionTokenHeader, out var sessionToken)
            ? sessionToken
            : null);
    WebRtcArtifactFileWriter.WriteUtf8TextAtomically(outputPath, json);
    return Task.CompletedTask;
}

static Task WriteCurrentPathBridgeContractEvidenceAsync(
    string evidenceOut,
    CurrentPathWebSocketSignalingClientOptions options,
    RecordingCurrentPathWebSocketTransport offererTransport,
    RecordingCurrentPathWebSocketTransport answererTransport,
    CurrentPathWebRtcHelperSignalingBridgeResult offererResult,
    WebRtcSignalDocument writtenAnswer,
    IReadOnlyList<CurrentPathWebRtcSignalingEnvelope> offererSentEnvelopes,
    CurrentPathWebRtcHelperSignalingBridgeResult answererResult,
    WebRtcSignalDocument writtenOffer,
    IReadOnlyList<CurrentPathWebRtcSignalingEnvelope> answererSentEnvelopes,
    IReadOnlyList<string> rawPathRequestTargets)
{
    var outputPath = Path.GetFullPath(evidenceOut);

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
        ["MaxWebRtcEnvelopeBytes"] = CurrentPathSignalingWebSocketPolicy.MaxWebRtcEnvelopeBytes,
        ["MaxSdpBytes"] = CurrentPathWebRtcSignalingPayload.MaxSdpBytes,
        ["NearLimitSdpTargetBytes"] = CurrentPathWebRtcSignalingPayload.MaxSdpBytes - 4096,
        ["NearLimitSdpHeadroomBytes"] = 4096,
        ["OversizeSdpRejected"] = true,
        ["SessionIdentityContractCases"] = 7,
        ["RawPathRequestTargets"] = rawPathRequestTargets,
        ["PrintableAsciiPathCases"] = 94,
        ["OutboundSessionIdsMatchOwner"] = offererSentEnvelopes.Concat(answererSentEnvelopes)
            .All(item => string.Equals(item.SessionId, options.SessionId, StringComparison.Ordinal)),
        ["ClientMaxMessageBytes"] = options.MaxMessageBytes,
        ["OutboundMaxFrameBytes"] = offererTransport.SentTexts
            .Concat(answererTransport.SentTexts)
            .Select(Encoding.UTF8.GetByteCount)
            .DefaultIfEmpty(0)
            .Max(),
        ["InboundAnswerSdpBytes"] = Encoding.UTF8.GetByteCount(writtenAnswer.Sdp),
        ["InboundOfferSdpBytes"] = Encoding.UTF8.GetByteCount(writtenOffer.Sdp),
        ["ExceedsLegacy16KiBProbe"] =
            Encoding.UTF8.GetByteCount(writtenAnswer.Sdp) > 16 * 1024 &&
            Encoding.UTF8.GetByteCount(writtenOffer.Sdp) > 16 * 1024,
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

    var json = JsonSerializer.Serialize(evidence, new JsonSerializerOptions { WriteIndented = true });
    ValidateEvidenceDoesNotContain(
        json,
        options.Headers.TryGetValue(CurrentPathSignalingWebSocketPolicy.SessionTokenHeader, out var sessionToken)
            ? sessionToken
            : null);
    WebRtcArtifactFileWriter.WriteUtf8TextAtomically(outputPath, json);
    return Task.CompletedTask;
}

static async Task<IReadOnlyList<string>> ValidateCurrentPathRawPathContractAsync()
{
    const string sessionId = "Raw-Path-Fixture";
    var observedTargets = new List<string>();
    foreach (var path in new[] { "/signal/%41", "/signal/%20", "/signal/%41/%20", "/signal/%25" })
    {
        var listener = new System.Net.Sockets.TcpListener(System.Net.IPAddress.Loopback, 0);
        listener.Start();
        try
        {
            var port = ((System.Net.IPEndPoint)listener.LocalEndpoint).Port;
            var options = new CurrentPathWebSocketSignalingClientOptions(
                $"http://127.0.0.1:{port}", path, sessionId, "session-token", "windows-device-01");
            using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(5));
            await using var transport = new ClientWebSocketCurrentPathTransport();
            var server = CaptureRequestTargetAsync(listener, deadline.Token);
            await Task.WhenAll(server, RequireRejectedUpgradeAsync(transport, options, deadline.Token)).ConfigureAwait(false);
            var target = await server.ConfigureAwait(false);
            observedTargets.Add(target);
            Console.WriteLine($"windows-current-path-bridge-contract: raw-path-fixture request-target={target}");
            var expected = $"{path}?shard=RAW-PATH-FIXTURE&cv={CurrentPathSignalServerClient.DefaultClientVersion}&pv={CurrentPathSignalServerClient.DefaultProtocolVersion}";
            if (!string.Equals(target, expected, StringComparison.Ordinal))
            {
                throw new InvalidOperationException("Current-path WebSocket changed the raw server-selected request path.");
            }
        }
        finally
        {
            listener.Stop();
        }
    }

    const string allowedPchars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~!$&'()*+,;=:@/";
    for (var code = 0x21; code <= 0x7e; code++)
    {
        var character = (char)code;
        var path = "/a" + character + "b";
        var allowed = allowedPchars.Contains(character);
        try
        {
            var uri = CurrentPathSignalingWebSocketPolicy.BuildHeaderCredentialWebSocketUri(
                "https://[::1]:8443", path, sessionId, "session-token", "1", "1");
            if (!allowed || !string.Equals(uri.PathAndQuery, path + "?shard=RAW-PATH-FIXTURE&cv=1&pv=1", StringComparison.Ordinal) ||
                !uri.OriginalString.StartsWith("wss://[::1]:8443/", StringComparison.Ordinal))
            {
                throw new InvalidOperationException("Current-path printable ASCII path contract changed a path or admitted an invalid character.");
            }
        }
        catch (InvalidDataException) when (!allowed)
        {
            // The invalid-character branch is the expected explicit validator rejection.
            continue;
        }
    }

    foreach (var path in new[] { "/a%2fb", "/a%2Fb", "/a%2eb", "/a%5cb", "/a%3fb", "/a%23b", "/a%00b", "/a%1fb", "/a%7fb" })
    {
        try
        {
            _ = CurrentPathSignalingWebSocketPolicy.ValidateWebSocketPath(path);
        }
        catch (InvalidDataException)
        {
            continue;
        }

        throw new InvalidOperationException("Current-path path validation admitted an encoded delimiter or control character.");
    }

    return observedTargets;

    static async Task RequireRejectedUpgradeAsync(
        ClientWebSocketCurrentPathTransport transport,
        CurrentPathWebSocketSignalingClientOptions options,
        CancellationToken cancellationToken)
    {
        try
        {
            await transport.ConnectAsync(options.WebSocketUri, options.Headers, cancellationToken).ConfigureAwait(false);
        }
        catch (System.Net.WebSockets.WebSocketException)
        {
            return; // The loopback fixture intentionally responds with HTTP 400 after recording the request target.
        }

        throw new InvalidOperationException("Raw-path fixture unexpectedly completed a rejected upgrade.");
    }

    static async Task<string> CaptureRequestTargetAsync(System.Net.Sockets.TcpListener listener, CancellationToken cancellationToken)
    {
        using var accepted = await listener.AcceptTcpClientAsync(cancellationToken).ConfigureAwait(false);
        await using var stream = accepted.GetStream();
        using var request = new MemoryStream();
        var buffer = new byte[1024];
        string text;
        do
        {
            var count = await stream.ReadAsync(buffer.AsMemory(), cancellationToken).ConfigureAwait(false);
            if (count == 0) throw new InvalidDataException("Raw-path fixture received an incomplete HTTP request.");
            request.Write(buffer, 0, count);
            if (request.Length > 16 * 1024) throw new InvalidDataException("Raw-path fixture HTTP headers exceeded the limit.");
            text = Encoding.ASCII.GetString(request.ToArray());
        } while (!text.Contains("\r\n\r\n", StringComparison.Ordinal));
        var firstLine = text.Split("\r\n", StringSplitOptions.None)[0].Split(' ');
        if (firstLine.Length != 3 || firstLine[0] != "GET" || firstLine[2] != "HTTP/1.1")
        {
            throw new InvalidDataException("Raw-path fixture expected a WebSocket HTTP upgrade request.");
        }

        await stream.WriteAsync("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"u8.ToArray(), cancellationToken)
            .ConfigureAwait(false);
        return firstLine[1];
    }
}

static async Task ValidateCurrentPathSessionIdentityContractAsync()
{
    const string localId = "windows-device-01";
    const string remoteId = "mac-device-00001";
    const string mixedId = "Room-Mixed_987-Server";
    var wrongCaseId = mixedId.ToUpperInvariant();

    static void Require(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    static CurrentPathWebSocketSignalingClientOptions Options(string sessionId) => new(
        "https://api.nebula-technologies.net", "/ws/current", sessionId, "session-token", localId);

    static string BoundFrame(string sessionId) => JsonSerializer.Serialize(new
    {
        type = "bound", sessionId, role = "initiator", clientId = "identity-contract-client"
    });

    static CurrentPathWebRtcSignalingEnvelope Envelope(string sessionId, string from) => new(
        sessionId, from, null, CurrentPathWebRtcSignalingMessageType.Join, sentAt: 1_700_100_001d);

    static async Task RequireScopeFailure(Func<Task> operation, string expectedCode)
    {
        try
        {
            await operation().ConfigureAwait(false);
        }
        catch (CurrentPathWebSocketSignalingException failure)
        {
            Require(string.Equals(expectedCode, failure.ErrorCode, StringComparison.Ordinal),
                "Current-path identity fixture failed through the wrong protocol branch.");
            Require(failure.FailureClass == CurrentPathSignalingFailureClass.InvalidShardOrSessionMismatch,
                "Current-path identity fixture lost its session-scope failure classification.");
            return;
        }

        throw new InvalidOperationException("Current-path identity fixture admitted a case-only session mismatch.");
    }

    foreach (var sessionId in new[] { mixedId, "server-session-lowercase", "CANONICAL-SESSION-1" })
    {
        var options = Options(sessionId);
        Require(string.Equals(sessionId, options.SessionId, StringComparison.Ordinal),
            "Current-path WebSocket owner must preserve the server-issued session identity.");
        Require(string.Equals(sessionId.ToUpperInvariant(),
                options.Headers[CurrentPathSignalingWebSocketPolicy.SessionIdHeader], StringComparison.Ordinal),
            "Current-path route header must retain its uppercase wire contract.");
        Require(options.WebSocketUri.Query.Contains($"shard={Uri.EscapeDataString(sessionId.ToUpperInvariant())}", StringComparison.Ordinal),
            "Current-path shard must retain its uppercase wire contract.");
        var bridgeOptions = new CurrentPathWebRtcHelperSignalingBridgeOptions(
            sessionId, localId, remoteId, "local-signal.json", "remote-signal.json");
        var connectorOptions = new CurrentPathWebRtcProductControlSessionConnectorOptions(
            sessionId, localId, remoteId, new string('a', 64), CurrentPathProtocolSigningAlgorithm.MLDsa65);
        Require(string.Equals(sessionId, bridgeOptions.SessionId, StringComparison.Ordinal) &&
                string.Equals(sessionId, connectorOptions.SessionId, StringComparison.Ordinal),
            "Current-path bridge and connector must preserve the server-issued session identity.");
        var encoded = CurrentPathSignalingFrameCodec.EncodeEnvelope(Envelope(sessionId, localId));
        using (var document = JsonDocument.Parse(encoded))
        {
            Require(string.Equals(sessionId, document.RootElement.GetProperty("sessionId").GetString(), StringComparison.Ordinal),
                "Current-path outbound JSON must preserve the server-issued session identity.");
        }

        var transport = new RecordingCurrentPathWebSocketTransport();
        transport.EnqueueReceive(CurrentPathWebSocketReceiveResult.TextMessage(BoundFrame(sessionId)));
        transport.EnqueueReceive(CurrentPathWebSocketReceiveResult.TextMessage(
            CurrentPathSignalingFrameCodec.EncodeEnvelope(Envelope(sessionId, remoteId))));
        transport.EnqueueReceive(CurrentPathWebSocketReceiveResult.TextMessage(BoundFrame(sessionId)));
        await using var client = new CurrentPathWebSocketSignalingClient(transport, options);
        await client.ConnectAndBindAsync().ConfigureAwait(false);
        await client.SendAsync(Envelope(sessionId, localId)).ConfigureAwait(false);
        var inbound = await client.ReceiveNextAsync().ConfigureAwait(false);
        Require(string.Equals(sessionId, inbound.Envelope?.SessionId, StringComparison.Ordinal),
            "Current-path inbound JSON must preserve the exact session identity.");
        _ = await client.ReceiveNextAsync().ConfigureAwait(false);
        Require(client.IsBound && transport.SentTexts.Count == 1,
            "Current-path canonical identity exchange did not stay bound.");
    }

    foreach (var branch in new[] { "bind", "send", "inbound", "server-frame" })
    {
        var transport = new RecordingCurrentPathWebSocketTransport();
        transport.EnqueueReceive(CurrentPathWebSocketReceiveResult.TextMessage(
            BoundFrame(branch == "bind" ? wrongCaseId : mixedId)));
        await using var client = new CurrentPathWebSocketSignalingClient(transport, Options(mixedId));
        if (branch == "bind")
        {
            await RequireScopeFailure(() => client.ConnectAndBindAsync(), "bound_session_mismatch").ConfigureAwait(false);
            Require(!client.IsBound, "A case-only bound mismatch must not claim a signaling session.");
            continue;
        }

        await client.ConnectAndBindAsync().ConfigureAwait(false);
        if (branch == "send")
        {
            await RequireScopeFailure(() => client.SendAsync(Envelope(wrongCaseId, localId)), "envelope_scope_violation")
                .ConfigureAwait(false);
            Require(transport.SentTexts.Count == 0, "A wrong-owner envelope reached the transport.");
            await client.SendAsync(Envelope(mixedId, localId)).ConfigureAwait(false);
            Require(client.IsBound && transport.SentTexts.Count == 1, "The exact owner must remain usable after caller rejection.");
        }
        else
        {
            transport.EnqueueReceive(CurrentPathWebSocketReceiveResult.TextMessage(branch == "inbound"
                ? CurrentPathSignalingFrameCodec.EncodeEnvelope(Envelope(wrongCaseId, remoteId))
                : BoundFrame(wrongCaseId)));
            await RequireScopeFailure(async () => { _ = await client.ReceiveNextAsync().ConfigureAwait(false); },
                    branch == "inbound" ? "inbound_session_scope_violation" : "server_frame_scope_violation")
                .ConfigureAwait(false);
            Require(client.Phase == CurrentPathSignalingLifecyclePhase.Failed,
                "A wrong-owner inbound frame must fail the signaling session.");
        }
    }
}

static void ValidateCurrentPathSdpLimitContract()
{
    var oversizedSdp = BuildLargeCurrentPathSdp(
        "00:11:22",
        CurrentPathWebRtcSignalingPayload.MaxSdpBytes + 1);
    try
    {
        _ = new CurrentPathWebRtcSignalingPayload(sdp: oversizedSdp);
    }
    catch (InvalidDataException)
    {
        return;
    }

    throw new InvalidOperationException("Current-path SDP byte limit did not reject an oversized SDP payload.");
}

static string BuildLargeCurrentPathSdp(string fingerprint, int targetUtf8Bytes)
{
    const string PaddingPrefix = "a=x-skybridge-padding:";
    const string LineEnding = "\r\n";
    var prefix =
        "v=0\r\n" +
        "o=- 0 0 IN IP4 127.0.0.1\r\n" +
        "s=SkyBridge current-path limit probe\r\n" +
        "t=0 0\r\n" +
        $"a=fingerprint:sha-256 {fingerprint}\r\n";
    const string suffix = "a=end-of-candidates\r\n";
    var fixedBytes = Encoding.UTF8.GetByteCount(prefix + PaddingPrefix + LineEnding + suffix);
    var paddingBytes = Math.Max(0, targetUtf8Bytes - fixedBytes);
    return prefix + PaddingPrefix + new string('A', paddingBytes) + LineEnding + suffix;
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

static string Sha256HexBytes(ReadOnlySpan<byte> value) =>
    Convert.ToHexString(SHA256.HashData(value)).ToLowerInvariant();

static byte[] BuildFileTransferSmokePayload(int byteLength)
{
    if (byteLength <= 0 || byteLength > 2048)
    {
        throw new InvalidOperationException("FileTransfer smoke payload must be in the range 1..2048 bytes.");
    }

    var payload = new byte[byteLength];
    RandomNumberGenerator.Fill(payload);
    return payload;
}

static string FormatSuiteWireId(ushort suiteWireId) =>
    "0x" + suiteWireId.ToString("x4");

static void VerifyMlKem768KeyPair(
    ReadOnlySpan<byte> encapsulationKey,
    ReadOnlySpan<byte> decapsulationKey)
{
    if (!MLKem.IsSupported)
    {
        throw new PlatformNotSupportedException(
            "current-path product-control answerer AppControl proof requires .NET ML-KEM support.");
    }

    byte[]? ciphertext = null;
    byte[]? sharedSecretFromEncapsulation = null;
    byte[]? sharedSecretFromDecapsulation = null;
    try
    {
        using var publicKem = MLKem.ImportEncapsulationKey(MLKemAlgorithm.MLKem768, encapsulationKey);
        using var privateKem = MLKem.ImportDecapsulationKey(MLKemAlgorithm.MLKem768, decapsulationKey);
        publicKem.Encapsulate(out ciphertext, out sharedSecretFromEncapsulation);
        sharedSecretFromDecapsulation = privateKem.Decapsulate(ciphertext);
        if (!CryptographicOperations.FixedTimeEquals(
                sharedSecretFromEncapsulation,
                sharedSecretFromDecapsulation))
        {
            throw new InvalidOperationException(
                "local ML-KEM-768 public key does not match the supplied decapsulation key.");
        }
    }
    finally
    {
        if (ciphertext is not null)
        {
            CryptographicOperations.ZeroMemory(ciphertext);
        }

        if (sharedSecretFromEncapsulation is not null)
        {
            CryptographicOperations.ZeroMemory(sharedSecretFromEncapsulation);
        }

        if (sharedSecretFromDecapsulation is not null)
        {
            CryptographicOperations.ZeroMemory(sharedSecretFromDecapsulation);
        }
    }
}

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

static string NormalizeExpectedBoundRole(string raw)
{
    if (string.IsNullOrWhiteSpace(raw))
    {
        return string.Empty;
    }

    var value = raw.Trim();
    return value switch
    {
        "initiator" or "responder" => value,
        _ => throw new InvalidOperationException("--expected-bound-role must be either initiator or responder.")
    };
}

static async Task WriteOperatorSecretFileAsync(
    string outputPath,
    string value,
    string optionName,
    string emptyValueMessage,
    string requiredLeafPrefix,
    string label,
    CancellationToken cancellationToken)
{
    if (string.IsNullOrWhiteSpace(outputPath))
    {
        throw new InvalidOperationException($"{optionName} must not be empty.");
    }

    if (string.IsNullOrWhiteSpace(value))
    {
        throw new InvalidOperationException(emptyValueMessage);
    }

    var fullPath = Path.GetFullPath(outputPath);
    var outputDir = Path.GetDirectoryName(fullPath);
    if (string.IsNullOrEmpty(outputDir))
    {
        throw new InvalidOperationException($"{optionName} must include a dedicated parent directory.");
    }

    PrepareDedicatedOperatorSecretDirectory(outputDir, optionName, requiredLeafPrefix, label);
    if (File.Exists(fullPath) || Directory.Exists(fullPath))
    {
        RejectReparsePoint(fullPath, $"{optionName} file");
        throw new InvalidOperationException($"{optionName} must not already exist; use a fresh dedicated directory for each live gate run.");
    }

    var tempPath = fullPath + ".tmp-" + Guid.NewGuid().ToString("N");
    try
    {
        await using (var stream = CreateRestrictedOperatorSecretFileStream(tempPath))
        await using (var writer = new StreamWriter(stream, new UTF8Encoding(encoderShouldEmitUTF8Identifier: false)))
        {
            await writer.WriteLineAsync(value.AsMemory(), cancellationToken).ConfigureAwait(false);
        }

        RestrictOwnerOnlyFileModeIfSupported(tempPath);
        File.Move(tempPath, fullPath);
        RestrictOwnerOnlyFileModeIfSupported(fullPath);
    }
    finally
    {
        if (File.Exists(tempPath))
        {
            File.Delete(tempPath);
        }
    }
}

static void PrepareDedicatedOperatorSecretDirectory(
    string outputDir,
    string optionName,
    string requiredLeafPrefix,
    string label)
{
    var fullDirectory = Path.GetFullPath(outputDir);
    var leafName = Path.GetFileName(fullDirectory.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar));
    if (string.IsNullOrWhiteSpace(leafName) ||
        !leafName.StartsWith(requiredLeafPrefix, StringComparison.OrdinalIgnoreCase))
    {
        throw new InvalidOperationException($"{optionName} parent directory must be a dedicated directory whose leaf name starts with '{requiredLeafPrefix}'.");
    }

    RejectReparsePointAncestors(fullDirectory, $"{optionName} directory");
    if (Directory.Exists(fullDirectory))
    {
        RejectReparsePoint(fullDirectory, $"{optionName} directory");
        if (Directory.EnumerateFileSystemEntries(fullDirectory).Any())
        {
            throw new InvalidOperationException($"{optionName} parent directory must be empty before RuntimeSmoke writes the {label}.");
        }
    }
    else
    {
        Directory.CreateDirectory(fullDirectory);
    }

    RejectReparsePointAncestors(fullDirectory, $"{optionName} directory");
    RestrictOwnerOnlyDirectoryModeIfSupported(fullDirectory);
}

static void RejectReparsePointAncestors(string path, string label)
{
    var fullPath = Path.GetFullPath(path);
    var current = fullPath;
    while (!string.IsNullOrWhiteSpace(current))
    {
        if (Directory.Exists(current))
        {
            RejectReparsePoint(current, label);
        }

        var parent = Path.GetDirectoryName(current.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar));
        if (string.IsNullOrEmpty(parent) || string.Equals(parent, current, StringComparison.OrdinalIgnoreCase))
        {
            return;
        }

        current = parent;
    }
}

static void RejectReparsePoint(string path, string label)
{
    if (!File.Exists(path) && !Directory.Exists(path))
    {
        return;
    }

    var attributes = File.GetAttributes(path);
    if ((attributes & FileAttributes.ReparsePoint) != 0)
    {
        throw new InvalidOperationException($"{label} must not be a reparse point: {Path.GetFullPath(path)}");
    }
}

static void RestrictOwnerOnlyFileModeIfSupported(string path)
{
    if (OperatingSystem.IsWindows())
    {
        RestrictWindowsOperatorSecretFileAcl(path);
        return;
    }

    File.SetUnixFileMode(path, UnixFileMode.UserRead | UnixFileMode.UserWrite);
}

static void RestrictOwnerOnlyDirectoryModeIfSupported(string path)
{
    if (OperatingSystem.IsWindows())
    {
        RestrictWindowsOperatorSecretDirectoryAcl(path);
        return;
    }

    new DirectoryInfo(path).UnixFileMode = UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute;
}

static FileStream CreateRestrictedOperatorSecretFileStream(string path)
{
    if (OperatingSystem.IsWindows())
    {
        return FileSystemAclExtensions.Create(
            new FileInfo(path),
            FileMode.CreateNew,
            FileSystemRights.FullControl,
            FileShare.None,
            4096,
            FileOptions.WriteThrough,
            BuildWindowsOperatorSecretFileSecurity());
    }

    return new FileStream(
        path,
        FileMode.CreateNew,
        FileAccess.Write,
        FileShare.None,
        bufferSize: 4096,
        FileOptions.WriteThrough);
}

static void RestrictWindowsOperatorSecretFileAcl(string path)
{
    FileSystemAclExtensions.SetAccessControl(
        new FileInfo(path),
        BuildWindowsOperatorSecretFileSecurity());
}

static void RestrictWindowsOperatorSecretDirectoryAcl(string path)
{
    FileSystemAclExtensions.SetAccessControl(
        new DirectoryInfo(path),
        BuildWindowsOperatorSecretDirectorySecurity());
}

static FileSecurity BuildWindowsOperatorSecretFileSecurity()
{
    var currentUserSid = WindowsIdentity.GetCurrent().User
        ?? throw new InvalidOperationException("Unable to resolve the current Windows user SID.");
    var security = new FileSecurity();
    security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
    foreach (var identity in new IdentityReference[]
    {
        currentUserSid,
        new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, domainSid: null),
        new SecurityIdentifier(WellKnownSidType.LocalSystemSid, domainSid: null),
    })
    {
        security.AddAccessRule(new FileSystemAccessRule(
            identity,
            FileSystemRights.FullControl,
            AccessControlType.Allow));
    }

    return security;
}

static DirectorySecurity BuildWindowsOperatorSecretDirectorySecurity()
{
    var currentUserSid = WindowsIdentity.GetCurrent().User
        ?? throw new InvalidOperationException("Unable to resolve the current Windows user SID.");
    var security = new DirectorySecurity();
    security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
    foreach (var identity in new IdentityReference[]
    {
        currentUserSid,
        new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, domainSid: null),
        new SecurityIdentifier(WellKnownSidType.LocalSystemSid, domainSid: null),
    })
    {
        security.AddAccessRule(new FileSystemAccessRule(
            identity,
            FileSystemRights.FullControl,
            InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit,
            PropagationFlags.None,
            AccessControlType.Allow));
    }

    return security;
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

enum CurrentPathProductControlRuntimeProof
{
    TransportOnly,
    AppControl,
    FileTransfer,
}
