using System.Net;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Skybridge.WinClient.Services;
using Skybridge.WinClient.ViewModels;

if (args.Length == 2 && args[0] == "--live-account-devices")
{
    if (!OperatingSystem.IsWindowsVersionAtLeast(10,0,19041)) throw new PlatformNotSupportedException("Windows native account validation required.");
    await AccountDeviceLiveValidation.RunAsync(args[1]);
    return;
}

if (args.SequenceEqual(["--shell-interactions"]))
{
    foreach (var test in ShellInteractionTests.Cases) { await test.Run(); Console.WriteLine("PASS " + test.Name); }
    return;
}

if (args.SequenceEqual(["--account-devices"]))
{
    foreach (var test in AccountDeviceTests.Cases) { await test.Run(); Console.WriteLine("PASS " + test.Name); }
    return;
}

if (args.Length == 2 && args[0] == "--policybound-migration-stop-before-identity")
{
    await QPeriaptWindowsProductTests.StopBeforeIdentityCommitAsync(args[1]);
    return;
}
if (args.Length == 2 && args[0] == "--native-policybound-reupgrade")
{
    await QPeriaptSchema1ReupgradeTests.RunAsync(args[1]);
    Console.WriteLine("PASS Windows real legacy-owner re-upgrade, immutable snapshots and failure recovery");
    return;
}

if (args.SequenceEqual(["--native-policybound-product"]))
{
    await QPeriaptWindowsProductTests.RunAsync();
    Console.WriteLine("PASS Windows policy-bound identity recovery and native two-direction product handshake");
    return;
}

if (args.SequenceEqual(["--policybound-contract"]))
{
    foreach (var test in QPeriaptProductContractTests.ManagedCases)
    {
        await test.Run();
        Console.WriteLine($"PASS {test.Name}");
    }
    return;
}
if (args.SequenceEqual(["--native-policybound-contract"]))
{
    foreach (var test in QPeriaptProductContractTests.ManagedCases.Concat(QPeriaptProductContractTests.NativeCases))
    {
        await test.Run();
        Console.WriteLine($"PASS {test.Name}");
    }
    return;
}

if (args.SequenceEqual(["--native-desktop-power"]))
{
    await WindowsPowerKeepAwakeTests.NativeOwnershipAsync();
    Console.WriteLine("PASS native power requests survive async continuations and release only their own scope");
    return;
}
if (args.SequenceEqual(["--native-qperiapt"]))
{
    foreach (var test in QPeriaptNativeContractTests.Cases)
    {
        await test.Run();
        Console.WriteLine($"PASS {test.Name}");
    }
    return;
}
if (args.Length == 2 && args[0] == "--native-lan-file-transfer")
{
    if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 19041)) throw new PlatformNotSupportedException("Native LAN validation requires Windows.");
    await NativeLanFileTransferValidation.RunAsync(args[1]);
    return;
}
if (args.Length != 0) throw new ArgumentException("Unsupported contract-test arguments.");

var tests = new (string Name, Func<Task> Run)[]
{
    ("network telemetry HTTP and response boundaries", NetworkTelemetryTests.ProbeBoundariesAsync),
    ("network proxy display resolves DIRECT and explicit proxy routes", NetworkTelemetryTests.ProxyResolutionAsync),
    ("network telemetry independent sampling and cancellation", NetworkTelemetryTests.IndependentSamplingAsync),
    ("network telemetry counter reset and stopped-loop cleanup", NetworkTelemetryTests.CounterResetAsync),
    ("settings missing file is trusted defaults", TestSettingsMissingFileTrustedDefaults),
    ("settings corrupt file is untrusted", TestSettingsCorruptFileUntrusted),
    ("settings schema mismatch is untrusted", TestSettingsSchemaMismatchUntrusted),
    ("settings validation rejects unsafe values", TestSettingsValidationRejectsUnsafeValues),
    ("settings service import failure keeps current model", TestSettingsServiceImportFailureKeepsCurrentModel),
    ("session store classifies missing/corrupt/decrypt failures", TestSessionStoreTypedFailures),
    ("session store does not classify inaccessible paths as missing", TestSessionStoreDoesNotMaskInaccessiblePath),
    ("session store round trips valid sessions", TestSessionStoreRoundTrip),
    ("session store rejects legacy schema", TestSessionStoreRejectsLegacySchema),
    ("session store failed atomic commit preserves prior session", TestSessionStoreFailedCommitPreservesPriorSession),
    ("supabase auth classifies HTTP and JSON failures", TestSupabaseAuthTypedFailures),
    ("supabase user fallback does not mask auth rejection", TestSupabaseUserRejectDoesNotCallProfileFallback),
    ("account hydrate clears rejected persisted sessions", TestAccountHydrateClearsRejectedPersistedSession),
    ("account hydrate requires a rotated refresh token", TestAccountHydrateRequiresRotatedRefreshToken),
    ("account hydrate always verifies the live user", TestAccountHydrateAlwaysVerifiesLiveUser),
    ("account hydrate preserves credentials on transient service failure", TestAccountHydrateRetainsTransientFailure),
    ("account hydrate persists rotation before a failed user lookup", TestAccountHydratePersistsRotationBeforeVerification),
    ("account rotated-token commit failure preserves the prior session", TestAccountRotationCommitFailurePreservesSession),
    ("account hydrate persistence failure still revokes token", TestAccountHydratePersistenceFailureRevokesToken),
    ("account hydrate rejects authority mismatch before network", TestAccountHydrateRejectsAuthorityMismatch),
    ("account rejects out-of-range JWT expiry", TestAccountRejectsOutOfRangeJwtExpiry),
    ("account apply rejects subject drift", TestAccountApplyRejectsSubjectDrift),
    ("account sign-in fails when persistence fails", TestAccountSignInFailsWhenPersistenceFails),
    ("account sign-in distinguishes credentials network and storage", TestAccountSignInFailureKinds),
    ("account sign-out clear failure preserves signed-in truth", TestAccountSignOutClearFailurePreservesSignedInTruth),
    ("account sign-out remote failure reports local signed-out truth", TestAccountSignOutRemoteFailureReportsSignedOut),
    ("account mutations are serialized", TestAccountMutationsAreSerialized),
    ("account apply and sign-out mutations are serialized", TestAccountApplyAndSignOutAreSerialized),
    ("workspace error redaction strips secrets", TestWorkspaceErrorRedaction),
    ("protocol constants keep canonical DNS-SD and ALPN values", TestProtocolConstants),
    ("msquic transport secret rejects negotiated ALPN mismatch", TestMsQuicTransportSecretRejectsAlpnMismatch),
    ("discovery browser projects resolved dns-sd endpoints into routes", TestDiscoveryBrowserProjectsResolvedRoutes),
    ("discovery browser names canonical Apple records without granting trust", TestDiscoveryBrowserResolvedNames),
    ("discovery browser does not trust TXT ports without resolved endpoint", TestDiscoveryBrowserIgnoresTxtPortsWithoutResolvedEndpoint),
    ("discovery browser stale stop waits callback barrier and preserves replacement", TestDiscoveryBrowserStaleStopWaitsForOwnerBarrier),
    ("feature discovery cancellation drains its native owner", TestFeatureDiscoveryCancellationWaitsForOwnerBarrier),
    ("cancelled lookup does not supersede an active browser", TestCancelledLookupDoesNotSupersedeActiveBrowser),
    ("feature discovery owns a separate browser snapshot", TestFeatureDiscoveryDoesNotCancelUiBrowser),
    ("native dns-sd lifecycle uses callback barrier instead of fixed drain", TestNativeDnsSdCallbackBarrierContract),
    ("connection workspace validated state retains discovery candidate routes", TestConnectionWorkspaceValidatedStateRetainsDiscoveryCandidateRoutes),
    ("product action targets require authenticated route binding", TestProductActionTargetsRequireAuthenticatedRouteBinding),
    ("product action targets reject missing session and txt-only routes", TestProductActionTargetsRejectMissingSessionAndTxtOnlyRoutes),
    ("product action targets reject stale and mismatched sessions", TestProductActionTargetsRejectStaleAndMismatchedSessions),
    ("product action gate requires authenticated remote route", TestProductActionGateRequiresAuthenticatedRemoteRoute),
    ("webrtc authenticated route binding appcontrol codec is strict", TestWebRtcAuthenticatedRouteBindingAppControlCodec),
    ("webrtc authenticated route binding consumer rejects transport-only context", TestWebRtcAuthenticatedRouteBindingRejectsTransportOnlyContext),
    ("webrtc authenticated route binding consumer rejects receiver mismatch", TestWebRtcAuthenticatedRouteBindingRejectsReceiverMismatch),
    ("webrtc secure session runtime starts downstream after established context", TestWebRtcSecureSessionRuntimeStartsDownstreamAfterEstablishedContext),
    ("webrtc secure session runtime rejects non-established establisher", TestWebRtcSecureSessionRuntimeRejectsNonEstablishedEstablisher),
    ("webrtc secure session runtime cleans up after downstream start failure", TestWebRtcSecureSessionRuntimeCleansUpAfterDownstreamStartFailure),
    ("webrtc secure session runtime retains exact authority across stop failure", TestWebRtcSecureSessionRuntimeRetainsAuthorityAcrossStopFailure),
    ("webrtc secure session dispose retries exact pending owner", TestWebRtcSecureSessionDisposeRetriesExactPendingOwner),
    ("webrtc secure session dispose retries only failed dependency", TestWebRtcSecureSessionDisposeRetriesOnlyFailedDependency),
    ("webrtc secure session dispose barrier rejects in-flight stop", TestWebRtcSecureSessionDisposeBarrierRejectsInFlightStop),
    ("webrtc secure session incarnation rejects stale clear", TestWebRtcSecureSessionIncarnationRejectsStaleClear),
    ("webrtc stale startup failure preserves replacement session", TestWebRtcStaleStartupFailurePreservesReplacementSession),
    ("webrtc engine serializes connect and disconnect ownership", TestWebRtcEngineSerializesConnectAndDisconnectOwnership),
    ("webrtc engine rolls back partial consumer start", TestWebRtcEngineRollsBackPartialConsumerStart),
    ("webrtc product engine retains exact ownership across cleanup failure", TestWebRtcProductEngineRetainsOwnershipAcrossCleanupFailure),
    ("webrtc product transport rejects replacement while claimed", TestWebRtcProductTransportRejectsReplacementWhileClaimed),
    ("webrtc product engine suppresses inner early connected", TestWebRtcProductEngineSuppressesInnerEarlyConnected),
    ("webrtc product engine startup failure never publishes connected", TestWebRtcProductEngineStartupFailureNeverPublishesConnected),
    ("webrtc product engine dispose waits for connect and releases exact transport", TestWebRtcProductEngineDisposeWaitsForConnectAndReleasesExactTransport),
    ("webrtc product engine dispose retries completed secure consumer owner", TestWebRtcProductEngineDisposeRetriesCompletedSecureConsumerOwner),
    ("webrtc session engine serializes connect and disconnect ownership", TestWebRtcSessionEngineSerializesConnectAndDisconnectOwnership),
    ("webrtc session engine rolls back partial consumer start", TestWebRtcSessionEngineRollsBackPartialConsumerStart),
    ("webrtc session engine retains exact ownership across cleanup failure", TestWebRtcSessionEngineRetainsOwnershipAcrossCleanupFailure),
    ("webrtc session resource cleanup retains only failed owners for retry", TestWebRtcSessionResourceCleanupRetainsFailedOwnersForRetry),
    ("webrtc session engine dispose waits for connect and stops before transport", TestWebRtcSessionEngineDisposeWaitsForConnectAndStopsBeforeTransport),
    ("webrtc session engine double lifecycle is exact and idempotent", TestWebRtcSessionEngineDoubleLifecycleIsExactAndIdempotent),
    ("webrtc route binding stale stop preserves replacement", TestWebRtcRouteBindingStaleStopPreservesReplacement),
    ("windows native runtime factory wires product-control route-binding authority", TestWindowsNativeRuntimeFactoryWiresProductControlRouteBindingAuthority),
    ("webrtc authenticated route binding consumer writes action-gate snapshot", TestWebRtcAuthenticatedRouteBindingConsumerWritesActionGateSnapshot),
    ("webrtc authenticated route binding timestamp overflow fails closed", TestWebRtcAuthenticatedRouteBindingTimestampOverflowFailsClosed),
    ("remote desktop actions revalidate product gate before execution", TestRemoteDesktopActionsRevalidateProductGateBeforeExecution),
    ("native dns-sd TXT codec rejects separator injection", TestNativeDnsSdTxtCodecRejectsSeparatorInjection),
    ("webrtc file transfer wire uses cross-network op schema", TestWebRtcFileTransferWireUsesCrossNetworkOpSchema),
    ("webrtc file transfer proof round trips sbwc receipt", TestWebRtcFileTransferProofRoundTrip),
    ("webrtc file transfer proof rejects empty payload", TestWebRtcFileTransferRejectsEmptyPayload),
    ("webrtc file transfer proof rejects wrong packet type", TestWebRtcFileTransferRejectsWrongPacketType),
    ("async relay command reports escaped exception instead of crashing", TestAsyncRelayCommandReportsEscapedException),
    ("async relay command ignores reentrant execute while running", TestAsyncRelayCommandIgnoresReentrantExecute),
    ("async relay command runs again after completing", TestAsyncRelayCommandRunsAgainAfterCompletion),
    ("async relay command rejects a null execute delegate", TestAsyncRelayCommandRejectsNullExecute),

};

var remoteHostTests = Skybridge.WinClient.ContractTests.WindowsRemoteControlAudioAdvertisementTests.Cases
    .Concat(QPeriaptNativeContractTests.Cases)
    .Concat(QPeriaptProductContractTests.ManagedCases)
    .Concat(QPeriaptProductContractTests.NativeCases)
    .Concat(WindowsDesktopBackendContractTests.Cases)
    .Concat(RemoteControlHostSessionTests.Cases)
    .Concat(ClassicFileTransferWireTests.Cases)
    .Concat(ClassicFileTransferOperationTests.Cases)
    .Concat(LanProductControlSessionTests.Cases)
    .Concat(RemoteControlViewerSessionTests.Cases)
    .Concat(WindowsPowerKeepAwakeTests.Cases)
    .Concat(WeatherGlassGeometryTests.Cases)
    .Concat(RemoteControlHostAccessTests.Cases)
    .Concat(RemoteControlNetworkSelectionTests.Cases)
    .Append((Name: "remote protocol matches Mac production wire and authentication boundaries", Run: (Func<Task>)(async () =>
    {
        var count = await Skybridge.WinClient.ContractTests.RemoteControlProtocolContractTests.RunAsync(
            Path.Combine(AppContext.BaseDirectory, "Fixtures", "remote-control-mac-wire-v1.json"),
            requireNativePqc: OperatingSystem.IsWindows());
        Console.WriteLine($"Protocol assertions: {count}; native PQC required: {OperatingSystem.IsWindows()}");
        var identityCount = await Skybridge.WinClient.ContractTests.RemoteControlIdentityContractTests.RunAsync(
            requireNativePqc: OperatingSystem.IsWindows());
        Console.WriteLine($"Identity assertions: {identityCount}; native PQC required: {OperatingSystem.IsWindows()}");
        if (OperatingSystem.IsWindows())
        {
            await QPeriaptWindowsProductTests.RunAsync();
            Console.WriteLine("PASS Windows policy-bound identity recovery and native two-direction product handshake");
        }
    })));
foreach (var test in tests.Concat(AccountDeviceTests.Cases).Concat(ShellInteractionTests.Cases).Concat(remoteHostTests))
{
    await test.Run();
    Console.WriteLine($"PASS {test.Name}");
}

// ===== AsyncRelayCommand =====
// Every workspace command in the shell is bound through this adapter (57 construction
// sites), and ICommand.Execute forces `async void`, so an exception that escapes it is
// raised on the UI SynchronizationContext with no caller and terminates the process. These
// four tests pin the two properties that prevent that: escaped exceptions are reported,
// and a command already in flight cannot be started a second time.

static async Task TestAsyncRelayCommandReportsEscapedException()
{
    var reported = new TaskCompletionSource<Exception>(TaskCreationOptions.RunContinuationsAsynchronously);
    var previousSink = AsyncRelayCommand.UnhandledErrorSink;
    AsyncRelayCommand.UnhandledErrorSink = ex => reported.TrySetResult(ex);

    try
    {
        var command = new AsyncRelayCommand(() => throw new InvalidOperationException("escaped"));

        // Must not throw at the call site, and must not tear the process down.
        command.Execute(null);

        var completed = await Task.WhenAny(reported.Task, Task.Delay(TimeSpan.FromSeconds(5)));
        Require(completed == reported.Task, "escaped command exception must reach the unhandled-error sink");
        Require(
            reported.Task.Result is InvalidOperationException { Message: "escaped" },
            "the sink must receive the original exception, not a wrapper");
    }
    finally
    {
        AsyncRelayCommand.UnhandledErrorSink = previousSink;
    }
}

static async Task TestAsyncRelayCommandIgnoresReentrantExecute()
{
    var gate = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
    var started = 0;
    var command = new AsyncRelayCommand(async () =>
    {
        Interlocked.Increment(ref started);
        await gate.Task;
    });

    command.Execute(null);
    command.Execute(null);
    command.Execute(null);

    gate.SetResult();
    await Task.Delay(TimeSpan.FromMilliseconds(200));

    Require(
        Volatile.Read(ref started) == 1,
        $"a command already running must ignore further Execute calls; started {Volatile.Read(ref started)} times");
}

static async Task TestAsyncRelayCommandRunsAgainAfterCompletion()
{
    var runs = 0;
    var command = new AsyncRelayCommand(() =>
    {
        Interlocked.Increment(ref runs);
        return Task.CompletedTask;
    });

    command.Execute(null);
    await Task.Delay(TimeSpan.FromMilliseconds(100));
    command.Execute(null);
    await Task.Delay(TimeSpan.FromMilliseconds(100));

    Require(
        Volatile.Read(ref runs) == 2,
        $"the reentrancy guard must clear once the command completes; ran {Volatile.Read(ref runs)} times");
}

static Task TestAsyncRelayCommandRejectsNullExecute()
{
    var threw = false;
    try
    {
        _ = new AsyncRelayCommand(null!);
    }
    catch (ArgumentNullException)
    {
        threw = true;
    }

    Require(threw, "a null execute delegate must fail at construction, not at first click");
    return Task.CompletedTask;
}

static Task TestSettingsMissingFileTrustedDefaults()
{
    using var temp = TempDir.Create();
    var result = new SettingsStore(temp.Path).Load();
    Require(result.Status == SettingsStoreLoadStatus.MissingDefaults, "missing settings must be first-run defaults");
    Require(result.Trusted, "missing settings defaults must be trusted");
    return Task.CompletedTask;
}

static Task TestSettingsCorruptFileUntrusted()
{
    using var temp = TempDir.Create();
    File.WriteAllText(Path.Combine(temp.Path, "settings.json"), "{bad-json");
    var result = new SettingsStore(temp.Path).Load();
    Require(result.Status == SettingsStoreLoadStatus.InvalidJson, "corrupt settings must be invalid JSON");
    Require(!result.Trusted, "corrupt settings must not be trusted");
    return Task.CompletedTask;
}

static Task TestSettingsSchemaMismatchUntrusted()
{
    using var temp = TempDir.Create();
    File.WriteAllText(Path.Combine(temp.Path, "settings.json"), "{\"SchemaVersion\":999}");
    var result = new SettingsStore(temp.Path).Load();
    Require(result.Status == SettingsStoreLoadStatus.SchemaMismatch, "schema mismatch must be explicit");
    Require(!result.Trusted, "schema mismatch must not be trusted");
    return Task.CompletedTask;
}

static Task TestSettingsValidationRejectsUnsafeValues()
{
    using var temp = TempDir.Create();
    var store = new SettingsStore(temp.Path);
    var invalid = new SkyBridgeSettings { MaxConcurrentConnections = 0 };
    var result = store.Save(invalid);
    Require(result.Status == SettingsStoreWriteStatus.InvalidSettings, "invalid settings must not save");

    File.WriteAllText(
        Path.Combine(temp.Path, "settings.json"),
        JsonSerializer.Serialize(new SkyBridgeSettings { SignalStrengthAlpha = 2 }));
    var load = store.Load();
    Require(load.Status == SettingsStoreLoadStatus.InvalidSettings, "invalid loaded settings must be rejected");
    return Task.CompletedTask;
}

static Task TestSettingsServiceImportFailureKeepsCurrentModel()
{
    using var temp = TempDir.Create();
    var service = new SettingsService(new SettingsStore(temp.Path));
    service.Language = "en-US";

    var badImportPath = Path.Combine(temp.Path, "bad-import.json");
    File.WriteAllText(badImportPath, "{bad-json");

    Require(!service.ImportFrom(badImportPath), "bad import must fail");
    Require(service.Language == "en-US", "bad import must keep current settings");
    Require(service.RuntimeTruth.Trusted, "bad import must keep the current trusted model");
    Require(service.RuntimeTruth.LastErrorCode == "settings_invalid_json", "bad import must record the import error");

    var missingImportPath = Path.Combine(temp.Path, "missing-import.json");
    Require(!service.ImportFrom(missingImportPath), "missing import file must fail");
    Require(service.Language == "en-US", "missing import must keep current settings");
    Require(service.RuntimeTruth.LastErrorCode == "settings_missing_file", "missing import must record the missing-file error");
    return Task.CompletedTask;
}

static Task TestSessionStoreTypedFailures()
{
    using var temp = TempDir.Create();
    var store = new SessionStore(temp.Path, new PlainSessionProtector());
    Require(store.Load().Status == SessionStoreLoadStatus.Missing, "missing session must be explicit");
    var missingDirectoryStore = new SessionStore(
        Path.Combine(temp.Path, "missing-directory"),
        new PlainSessionProtector());
    Require(missingDirectoryStore.Clear().Succeeded, "clearing a missing session directory must be idempotent");

    File.WriteAllText(Path.Combine(temp.Path, "session.bin"), "{bad-json");
    Require(store.Load().Status == SessionStoreLoadStatus.InvalidJson, "bad session JSON must be explicit");

    var cryptoStore = new SessionStore(temp.Path, new ThrowingUnprotectSessionProtector());
    Require(cryptoStore.Load().Status == SessionStoreLoadStatus.DecryptFailed, "decrypt failure must be explicit");
    Require(
        store.Save(BuildPersistedSession() with { AccessToken = null }).Status == SessionStoreWriteStatus.InvalidSession,
        "schema-valid session with an empty access token must not save");
    return Task.CompletedTask;
}

static Task TestSessionStoreDoesNotMaskInaccessiblePath()
{
    using var temp = TempDir.Create();
    Directory.CreateDirectory(Path.Combine(temp.Path, "session.bin"));
    var store = new SessionStore(temp.Path, new PlainSessionProtector());

    Require(store.Load().Status == SessionStoreLoadStatus.IoFailure, "unreadable session path must be IO failure");
    Require(store.Clear().Status == SessionStoreWriteStatus.IoFailure, "undeletable session path must be IO failure");
    return Task.CompletedTask;
}

static Task TestSessionStoreRoundTrip()
{
    using var temp = TempDir.Create();
    var store = new SessionStore(temp.Path, new PlainSessionProtector());
    var save = store.Save(BuildPersistedSession());
    Require(save.Succeeded, "valid session must save");
    var load = store.Load();
    Require(load.Succeeded, "valid session must load");
    Require(load.Session?.Subject == "user-1", "loaded session subject mismatch");
    Require(load.Session?.Authority == TestSessionAuthority(), "loaded session authority mismatch");
    return Task.CompletedTask;
}

static Task TestSessionStoreRejectsLegacySchema()
{
    using var temp = TempDir.Create();
    File.WriteAllText(
        Path.Combine(temp.Path, "session.bin"),
        JsonSerializer.Serialize(new
        {
            accessToken = BuildJwt(DateTimeOffset.UtcNow.AddHours(1)),
            refreshToken = "legacy-refresh",
            userId = "user-1",
            issuedAtUnix = DateTimeOffset.UtcNow.ToUnixTimeSeconds()
        }));

    var result = new SessionStore(temp.Path, new PlainSessionProtector()).Load();
    Require(result.Status == SessionStoreLoadStatus.SchemaMismatch, "legacy session must be rejected explicitly");
    return Task.CompletedTask;
}

static Task TestSessionStoreFailedCommitPreservesPriorSession()
{
    using var temp = TempDir.Create();
    var initialStore = new SessionStore(temp.Path, new PlainSessionProtector());
    Require(initialStore.Save(BuildPersistedSession(displayName: "Original")).Succeeded, "initial session must save");
    var destination = Path.Combine(temp.Path, "session.bin");
    var originalBytes = File.ReadAllBytes(destination);

    var failingStore = new SessionStore(
        temp.Path,
        new PlainSessionProtector(),
        new ThrowingSessionFileCommitter());
    var result = failingStore.Save(BuildPersistedSession(displayName: "Replacement"));

    Require(result.Status == SessionStoreWriteStatus.IoFailure, "failed commit must be typed as IO failure");
    Require(File.ReadAllBytes(destination).SequenceEqual(originalBytes), "failed commit must preserve prior session bytes");
    Require(
        !Directory.EnumerateFiles(temp.Path, ".session.bin.*.tmp").Any(),
        "failed commit must not leave its temporary file behind");
    return Task.CompletedTask;
}

static async Task TestSupabaseAuthTypedFailures()
{
    RequireThrows<ArgumentException>(() => new SupabaseAuthClient(
        new HttpClient(new StaticHandler(HttpStatusCode.OK, "{}")),
        "http://insecure.example"));

    var unauthorized = new SupabaseAuthClient(new HttpClient(new StaticHandler(HttpStatusCode.Unauthorized, "{}")));
    var rejected = await unauthorized.SignInWithPasswordAsync("a@example.com", "password");
    Require(!rejected.Succeeded, "401 sign-in must fail");
    Require(rejected.Failure?.Kind == AuthFailureKind.Unauthorized, "401 sign-in must be unauthorized");

    var missingToken = new SupabaseAuthClient(new HttpClient(new StaticHandler(HttpStatusCode.OK, "{}")));
    var missing = await missingToken.SignInWithPasswordAsync("a@example.com", "password");
    Require(missing.Failure?.Kind == AuthFailureKind.MissingAccessToken, "200 without token must fail");

    var missingRefreshToken = new SupabaseAuthClient(new HttpClient(new StaticHandler(
        HttpStatusCode.OK,
        "{\"access_token\":\"access\"}")));
    var missingRefresh = await missingRefreshToken.SignInWithPasswordAsync("a@example.com", "password");
    Require(
        missingRefresh.Failure?.Kind == AuthFailureKind.MissingRefreshToken,
        "200 without a refresh token must fail");

    var badJson = new SupabaseAuthClient(new HttpClient(new StaticHandler(HttpStatusCode.OK, "{bad-json")));
    var invalid = await badJson.SignInWithPasswordAsync("a@example.com", "password");
    Require(invalid.Failure?.Kind == AuthFailureKind.InvalidJson, "invalid auth JSON must be classified");
}

static async Task TestSupabaseUserRejectDoesNotCallProfileFallback()
{
    var handler = new RecordingHandler(request =>
    {
        if (request.RequestUri?.AbsolutePath == "/auth/v1/user")
        {
            return new HttpResponseMessage(HttpStatusCode.Unauthorized)
            {
                Content = new StringContent("{}")
            };
        }

        return new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = new StringContent("[{\"full_name\":\"Masked\"}]")
        };
    });
    var client = new SupabaseAuthClient(new HttpClient(handler));
    var result = await client.GetUserAsync("access", "user-1");
    Require(!result.Succeeded, "rejected user lookup must fail");
    Require(handler.ProfileCalls == 0, "profile fallback must not mask auth/v1/user rejection");
}

static async Task TestAccountHydrateClearsRejectedPersistedSession()
{
    var store = new FakeSessionStore
    {
        LoadResult = SessionStoreLoadResult.Loaded(new PersistedSession
        {
            SchemaVersion = PersistedSession.CurrentSchemaVersion,
            Authority = TestSessionAuthority(),
            Subject = "user-1",
            AccessToken = BuildJwt(DateTimeOffset.UtcNow.AddHours(-1)),
            RefreshToken = "refresh",
            DisplayName = "Stale",
            IssuedAtUnix = DateTimeOffset.UtcNow.ToUnixTimeSeconds()
        })
    };
    var auth = new FakeAuthClient
    {
        RefreshResult = AuthClientResult<AuthToken>.Failed(AuthFailureKind.Unauthorized, "refresh_rejected")
    };
    var coordinator = new AccountSessionCoordinator(auth, store);
    var result = await coordinator.HydrateFromStoreAsync();

    Require(!result.Success, "rejected refresh must fail hydrate");
    Require(!coordinator.IsSignedIn, "rejected refresh must not leave signed in");
    Require(store.ClearCalled, "rejected refresh must clear persisted session");
}

static async Task TestAccountHydrateRequiresRotatedRefreshToken()
{
    var store = new FakeSessionStore
    {
        LoadResult = SessionStoreLoadResult.Loaded(BuildPersistedSession(
            accessToken: BuildJwt(DateTimeOffset.UtcNow.AddHours(-1))))
    };
    var auth = new FakeAuthClient
    {
        RefreshResult = AuthClientResult<AuthToken>.Success(new AuthToken
        {
            AccessToken = BuildJwt(DateTimeOffset.UtcNow.AddHours(1)),
            RefreshToken = null,
            User = BuildAuthUser()
        }),
        GetUserResult = AuthClientResult<AuthUser>.Success(BuildAuthUser())
    };

    var result = await new AccountSessionCoordinator(auth, store).HydrateFromStoreAsync();

    Require(!result.Success && result.SignedOut, "missing rotated refresh token must fail closed");
    Require(result.FailureKind == AccountSessionFailureKind.RefreshRejected, "missing rotated refresh token failure kind mismatch");
    Require(store.ClearCalls == 1, "missing rotated refresh token must clear persisted state");
    Require(auth.GetUserCalls == 0, "missing rotated refresh token must fail before live user verification");
}

static async Task TestAccountHydrateAlwaysVerifiesLiveUser()
{
    var store = new FakeSessionStore
    {
        LoadResult = SessionStoreLoadResult.Loaded(BuildPersistedSession())
    };
    var auth = new FakeAuthClient
    {
        GetUserResult = AuthClientResult<AuthUser>.Success(BuildAuthUser())
    };

    var coordinator = new AccountSessionCoordinator(auth, store);
    var result = await coordinator.HydrateFromStoreAsync();

    Require(result.Success, "fresh persisted session with verified user must hydrate");
    Require(auth.RefreshCalls == 0, "fresh access token must not refresh early");
    Require(auth.GetUserCalls == 1, "fresh access token must still call auth/v1/user exactly once");
    Require(store.SaveCalls == 1, "verified hydrated identity must be persisted once");
}

static async Task TestAccountHydrateRetainsTransientFailure()
{
    foreach (var expired in new[] { false, true })
        foreach (var kind in new[] { AuthFailureKind.Network, AuthFailureKind.Timeout, AuthFailureKind.HttpFailure })
        {
            var persisted = BuildPersistedSession(accessToken: BuildJwt(DateTimeOffset.UtcNow.AddHours(expired ? -1 : 1)));
            var store = new FakeSessionStore { LoadResult = SessionStoreLoadResult.Loaded(persisted) };
            var auth = new FakeAuthClient
            {
                RefreshResult = AuthClientResult<AuthToken>.Failed(kind, "auth_refresh_unavailable"),
                GetUserResult = AuthClientResult<AuthUser>.Failed(kind, "auth_user_unavailable")
            };
            var coordinator = new AccountSessionCoordinator(auth, store);
            var result = await coordinator.HydrateFromStoreAsync();
            Require(!result.Success && !result.SignedOut && result.FailureKind == AccountSessionFailureKind.Network,
                "A service failure must be distinguishable from credential revocation.");
            Require(!coordinator.IsSignedIn && string.IsNullOrEmpty(coordinator.DisplayName),
                "An unverified account must not gain signed-in privileges.");
            Require(store.ClearCalls == 0 && store.SaveCalls == 0 && auth.SignOutCalls == 0,
                "Transient connectivity failure must not destroy or revoke persisted credentials.");
        }
}

static async Task TestAccountHydratePersistsRotationBeforeVerification()
{
    var persisted = BuildPersistedSession(accessToken: BuildJwt(DateTimeOffset.UtcNow.AddHours(-1)));
    var rotated = BuildAuthToken() with { RefreshToken = "test-rotated-refresh" };
    var store = new FakeSessionStore { LoadResult = SessionStoreLoadResult.Loaded(persisted) };
    var auth = new FakeAuthClient
    {
        RefreshResult = AuthClientResult<AuthToken>.Success(rotated),
        GetUserResult = AuthClientResult<AuthUser>.Failed(AuthFailureKind.Timeout, "auth_user_timeout")
    };
    var coordinator = new AccountSessionCoordinator(auth, store);
    var result = await coordinator.HydrateFromStoreAsync();
    var saved = store.LastSaved ?? throw new Exception("The server-rotated credential was lost before verification.");
    Require(!result.Success && !coordinator.IsSignedIn && store.ClearCalls == 0 && store.SaveCalls == 1,
        "Failed live verification must preserve the rotation without publishing identity.");
    Require(saved.AccessToken == rotated.AccessToken && saved.RefreshToken == rotated.RefreshToken && saved.Subject == persisted.Subject,
        "The durable rotation changed identity or retained an obsolete credential.");
    store.LoadResult = SessionStoreLoadResult.Loaded(saved);
    auth.GetUserResult = AuthClientResult<AuthUser>.Success(BuildAuthUser());
    var retry = new AccountSessionCoordinator(auth, store);
    Require((await retry.HydrateFromStoreAsync()).Success && retry.IsSignedIn && auth.RefreshCalls == 1,
        "A fresh retry must verify the saved rotation without reusing the spent token.");
}

static async Task TestAccountRotationCommitFailurePreservesSession()
{
    var store = new FakeSessionStore
    {
        LoadResult = SessionStoreLoadResult.Loaded(BuildPersistedSession(accessToken: BuildJwt(DateTimeOffset.UtcNow.AddHours(-1)))),
        SaveResult = SessionStoreWriteResult.IoFailure()
    };
    var auth = new FakeAuthClient { RefreshResult = AuthClientResult<AuthToken>.Success(BuildAuthToken()) };
    var coordinator = new AccountSessionCoordinator(auth, store);
    var result = await coordinator.HydrateFromStoreAsync();
    Require(!result.Success && result.FailureKind == AccountSessionFailureKind.SessionPersistenceFailed && !coordinator.IsSignedIn,
        "A failed rotation commit must surface storage failure before account use.");
    Require(store.ClearCalls == 0 && auth.GetUserCalls == 0 && auth.SignOutCalls == 0,
        "Failed atomic replacement must preserve the prior retryable record.");
}

static async Task TestAccountHydratePersistenceFailureRevokesToken()
{
    var store = new FakeSessionStore
    {
        LoadResult = SessionStoreLoadResult.Loaded(BuildPersistedSession()),
        SaveResult = SessionStoreWriteResult.IoFailure(),
        ClearResult = SessionStoreWriteResult.IoFailure()
    };
    var auth = new FakeAuthClient
    {
        GetUserResult = AuthClientResult<AuthUser>.Success(BuildAuthUser())
    };
    var coordinator = new AccountSessionCoordinator(auth, store);

    var result = await coordinator.HydrateFromStoreAsync();

    Require(!result.Success && !result.SignedOut, "failed local clear must not claim signed-out persistence truth");
    Require(result.FailureKind == AccountSessionFailureKind.SessionPersistenceFailed, "hydrate persistence failure kind mismatch");
    Require(auth.SignOutCalls == 1, "hydrate persistence failure must attempt remote token revoke");
    Require(!coordinator.IsSignedIn, "failed hydrate must not publish the unpersisted identity");
}

static async Task TestAccountHydrateRejectsAuthorityMismatch()
{
    var foreignAuthority = new SessionAuthority(
        "https://foreign-project.supabase.co/auth/v1",
        "authenticated",
        "authenticated");
    var store = new FakeSessionStore
    {
        LoadResult = SessionStoreLoadResult.Loaded(BuildPersistedSession(
            authority: foreignAuthority,
            accessToken: BuildJwt(DateTimeOffset.UtcNow.AddHours(1), authority: foreignAuthority)))
    };
    var auth = new FakeAuthClient
    {
        GetUserResult = AuthClientResult<AuthUser>.Success(BuildAuthUser())
    };

    var result = await new AccountSessionCoordinator(auth, store).HydrateFromStoreAsync();

    Require(!result.Success && result.SignedOut, "foreign authority must fail closed to signed-out state");
    Require(result.FailureKind == AccountSessionFailureKind.AuthorityMismatch, "foreign authority failure kind mismatch");
    Require(store.ClearCalls == 1, "foreign authority must clear persisted state");
    Require(auth.GetUserCalls == 0, "foreign authority must be rejected before a user request");
}

static async Task TestAccountRejectsOutOfRangeJwtExpiry()
{
    var auth = new FakeAuthClient
    {
        GetUserResult = AuthClientResult<AuthUser>.Success(BuildAuthUser())
    };
    var token = BuildAuthToken() with { AccessToken = BuildJwtWithUnixExpiry(long.MaxValue) };

    var result = await new AccountSessionCoordinator(auth, new FakeSessionStore()).ApplyAuthAsync(token);

    Require(!result.Success, "out-of-range JWT expiry must be rejected without throwing");
    Require(result.FailureKind == AccountSessionFailureKind.InvalidToken, "out-of-range expiry failure kind mismatch");
    Require(auth.GetUserCalls == 0, "invalid expiry must fail before live user verification");
}

static async Task TestAccountApplyRejectsSubjectDrift()
{
    var store = new FakeSessionStore();
    var auth = new FakeAuthClient
    {
        GetUserResult = AuthClientResult<AuthUser>.Success(BuildAuthUser("user-2"))
    };
    var coordinator = new AccountSessionCoordinator(auth, store);

    var result = await coordinator.ApplyAuthAsync(BuildAuthToken("user-1"));

    Require(!result.Success, "subject drift must reject the authenticated state");
    Require(result.FailureKind == AccountSessionFailureKind.SubjectMismatch, "subject drift failure kind mismatch");
    Require(!coordinator.IsSignedIn, "subject drift must never publish signed-in truth");
    Require(store.SaveCalls == 0, "subject drift must not persist the mismatched identity");
}

static async Task TestAccountSignInFailsWhenPersistenceFails()
{
    var store = new FakeSessionStore
    {
        SaveResult = SessionStoreWriteResult.IoFailure()
    };
    var auth = new FakeAuthClient
    {
        SignInResult = AuthClientResult<AuthToken>.Success(BuildAuthToken()),
        GetUserResult = AuthClientResult<AuthUser>.Success(BuildAuthUser())
    };
    var coordinator = new AccountSessionCoordinator(auth, store);
    var result = await coordinator.SignInWithEmailAsync("user@example.com", "password");

    Require(!result.Success, "sign-in must fail when persistence fails");
    Require(result.FailureKind == EmailSignInFailureKind.Storage, "persistence failure must be exposed as storage failure");
    Require(!coordinator.IsSignedIn, "persistence failure must not show signed-in truth");
    Require(auth.SignOutCalls == 1, "persistence failure must attempt remote token revoke");
}

static async Task TestAccountSignInFailureKinds()
{
    var credentials = await new AccountSessionCoordinator(
        new FakeAuthClient
        {
            SignInResult = AuthClientResult<AuthToken>.Failed(
                AuthFailureKind.InvalidCredentials,
                "auth_invalid_credentials")
        },
        new FakeSessionStore()).SignInWithEmailAsync("user@example.com", "password");
    Require(credentials.FailureKind == EmailSignInFailureKind.Credentials, "credential failure must remain distinct");

    var network = await new AccountSessionCoordinator(
        new FakeAuthClient
        {
            SignInResult = AuthClientResult<AuthToken>.Failed(AuthFailureKind.Network, "auth_network")
        },
        new FakeSessionStore()).SignInWithEmailAsync("user@example.com", "password");
    Require(network.FailureKind == EmailSignInFailureKind.Network, "network failure must remain distinct");

    var verificationNetwork = await new AccountSessionCoordinator(
        new FakeAuthClient
        {
            SignInResult = AuthClientResult<AuthToken>.Success(BuildAuthToken()),
            GetUserResult = AuthClientResult<AuthUser>.Failed(AuthFailureKind.Timeout, "auth_user_timeout")
        },
        new FakeSessionStore()).SignInWithEmailAsync("user@example.com", "password");
    Require(
        verificationNetwork.FailureKind == EmailSignInFailureKind.Network,
        "live user verification timeout must remain a network failure at the UI boundary");

    var storage = await new AccountSessionCoordinator(
        new FakeAuthClient
        {
            SignInResult = AuthClientResult<AuthToken>.Success(BuildAuthToken()),
            GetUserResult = AuthClientResult<AuthUser>.Success(BuildAuthUser())
        },
        new FakeSessionStore { SaveResult = SessionStoreWriteResult.IoFailure() })
        .SignInWithEmailAsync("user@example.com", "password");
    Require(storage.FailureKind == EmailSignInFailureKind.Storage, "storage failure must remain distinct");
}

static async Task TestAccountSignOutClearFailurePreservesSignedInTruth()
{
    var store = new FakeSessionStore { ClearResult = SessionStoreWriteResult.IoFailure() };
    var auth = new FakeAuthClient
    {
        GetUserResult = AuthClientResult<AuthUser>.Success(BuildAuthUser())
    };
    var coordinator = new AccountSessionCoordinator(auth, store);
    var identityNotifications = 0;
    coordinator.IdentityChanged += (_, _) => identityNotifications++;
    Require((await coordinator.ApplyAuthAsync(BuildAuthToken())).Success, "precondition sign-in must succeed");

    var result = await coordinator.SignOutAsync();

    Require(!result.Success && !result.SignedOut, "local clear failure must not report signed out");
    Require(result.FailureKind == AccountSessionFailureKind.SessionPersistenceFailed, "clear failure kind mismatch");
    Require(coordinator.IsSignedIn, "local clear failure must preserve in-memory signed-in truth");
    Require(identityNotifications == 1, "local clear failure must not publish a signed-out identity");
    Require(auth.SignOutCalls == 0, "remote revoke must not run before local cleanup succeeds");
}

static async Task TestAccountSignOutRemoteFailureReportsSignedOut()
{
    var store = new FakeSessionStore();
    var auth = new FakeAuthClient
    {
        GetUserResult = AuthClientResult<AuthUser>.Success(BuildAuthUser()),
        SignOutResult = AuthClientResult<AuthSignOutReceipt>.Failed(
            AuthFailureKind.Network,
            "auth_sign_out_network")
    };
    var coordinator = new AccountSessionCoordinator(auth, store);
    Require((await coordinator.ApplyAuthAsync(BuildAuthToken())).Success, "precondition sign-in must succeed");

    var result = await coordinator.SignOutAsync();

    Require(!result.Success && result.SignedOut, "remote revoke failure must preserve local signed-out truth");
    Require(result.FailureKind == AccountSessionFailureKind.ServerSignOutFailed, "remote revoke failure kind mismatch");
    Require(!coordinator.IsSignedIn, "successful local clear must leave coordinator signed out");
    Require(store.ClearCalls == 1 && auth.SignOutCalls == 1, "sign-out must clear locally before one remote revoke attempt");
}

static async Task TestAccountMutationsAreSerialized()
{
    var firstEntered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
    var releaseFirst = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
    var subjects = new List<string>();
    var auth = new FakeAuthClient
    {
        GetUserHandler = async (_, expectedSubject) =>
        {
            var subject = expectedSubject ?? throw new InvalidOperationException("Expected subject was not supplied.");
            subjects.Add(subject);
            if (subject == "user-1")
            {
                firstEntered.TrySetResult();
                await releaseFirst.Task.ConfigureAwait(false);
            }

            return AuthClientResult<AuthUser>.Success(BuildAuthUser(subject));
        }
    };
    var store = new FakeSessionStore();
    var coordinator = new AccountSessionCoordinator(auth, store);

    var first = coordinator.ApplyAuthAsync(BuildAuthToken("user-1"));
    await firstEntered.Task.WaitAsync(TimeSpan.FromSeconds(5));
    var second = coordinator.ApplyAuthAsync(BuildAuthToken("user-2"));
    Require(auth.GetUserCalls == 1, "second mutation must wait while first mutation owns the gate");

    releaseFirst.TrySetResult();
    var results = await Task.WhenAll(first, second);

    Require(results.All(result => result.Success), "serialized mutations must both complete successfully");
    Require(subjects.SequenceEqual(new[] { "user-1", "user-2" }), "mutations must execute in acquisition order");
    Require(store.SaveCalls == 2, "each serialized mutation must persist exactly once");
    Require(store.LastSaved?.Subject == "user-2", "second mutation must own the final persisted subject");
}

static async Task TestAccountApplyAndSignOutAreSerialized()
{
    var applyEntered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
    var releaseApply = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
    var auth = new FakeAuthClient
    {
        GetUserHandler = async (_, expectedSubject) =>
        {
            applyEntered.TrySetResult();
            await releaseApply.Task.ConfigureAwait(false);
            return AuthClientResult<AuthUser>.Success(BuildAuthUser(expectedSubject!));
        }
    };
    var store = new FakeSessionStore();
    var coordinator = new AccountSessionCoordinator(auth, store);

    var apply = coordinator.ApplyAuthAsync(BuildAuthToken());
    await applyEntered.Task.WaitAsync(TimeSpan.FromSeconds(5));
    var signOut = coordinator.SignOutAsync();
    Require(store.ClearCalls == 0 && auth.SignOutCalls == 0, "sign-out must wait for in-flight apply mutation");

    releaseApply.TrySetResult();
    Require((await apply).Success, "apply must complete before queued sign-out");
    var signOutResult = await signOut;

    Require(signOutResult.Success && signOutResult.SignedOut, "queued sign-out must complete after apply");
    Require(store.SaveCalls == 1 && store.ClearCalls == 1, "apply save must precede one local clear");
    Require(auth.SignOutCalls == 1, "queued sign-out must revoke the committed access token exactly once");
    Require(!coordinator.IsSignedIn, "queued sign-out must own final in-memory truth");
}

static Task TestWorkspaceErrorRedaction()
{
    var input =
        "Bearer abc.def.ghi access_token=secret skybridge://connect?data=SECRET /Users/bill/private/file.txt user@example.com";
    var redacted = WorkspaceErrorStatusClient.Redact(input);
    Require(!redacted.Contains("abc.def.ghi", StringComparison.Ordinal), "bearer token leaked");
    Require(!redacted.Contains("secret", StringComparison.OrdinalIgnoreCase), "query token leaked");
    Require(!redacted.Contains("/Users/bill", StringComparison.Ordinal), "path leaked");
    Require(!redacted.Contains("user@example.com", StringComparison.OrdinalIgnoreCase), "email leaked");
    return Task.CompletedTask;
}

static Task TestProtocolConstants()
{
    var expectedQueryOrder = new[]
    {
        "_skybridge._udp",
        "_skybridge._tcp",
        "_skybridge-xfer._tcp",
        "_skybridge-rd._tcp",
        "_skybridge-transfer._tcp",
        "_skybridge-remote._tcp"
    };
    Require(
        SkyBridgeProtocolConstants.WindowsDnsSdQueryOrder.SequenceEqual(expectedQueryOrder),
        "Windows DNS-SD query order must contain control, canonical product, then legacy input aliases");
    var browserPolicy = new WindowsDiscoveryBrowserClient(
        new StaticDiscoveryClient(new string('a', 64))).BuildInputPolicy();
    Require(
        browserPolicy.ServiceQueryOrder.SequenceEqual(expectedQueryOrder),
        "Windows discovery browser must expose the shared canonical-first query order");
    Require(
        SkyBridgeProtocolConstants.TryCanonicalizeDnsSdServiceType(
            SkyBridgeProtocolConstants.LegacyFileTransferDnsSdService,
            out var fileService)
        && fileService == SkyBridgeProtocolConstants.FileTransferDnsSdService,
        "legacy file-transfer service must canonicalize");
    Require(
        SkyBridgeProtocolConstants.TryCanonicalizeDnsSdServiceType(
            SkyBridgeProtocolConstants.LegacyRemoteDesktopDnsSdService,
            out var remoteService)
        && remoteService == SkyBridgeProtocolConstants.RemoteDesktopDnsSdService,
        "legacy remote-desktop service must canonicalize");
    Require(
        !SkyBridgeProtocolConstants.TryCanonicalizeDnsSdServiceType("_skybridge-unknown._tcp", out _),
        "unknown service must not be accepted as a protocol service");
    Require(
        SkyBridgeProtocolConstants.CanonicalizeDnsSdInstanceName(
            "Desk Mac._skybridge-transfer._tcp.local",
            SkyBridgeProtocolConstants.LegacyFileTransferDnsSdService,
            SkyBridgeProtocolConstants.FileTransferDnsSdService)
            == "Desk Mac._skybridge-xfer._tcp.local",
        "legacy instance suffix must canonicalize without changing the instance label");
    Require(
        SkyBridgeProtocolConstants.CanonicalizeDnsSdInstanceName(
            "Desk Mac._skybridge-remote._tcp.local",
            SkyBridgeProtocolConstants.RemoteDesktopDnsSdService,
            SkyBridgeProtocolConstants.RemoteDesktopDnsSdService)
            == "Desk Mac._skybridge-rd._tcp.local",
        "legacy instance suffix must not survive a canonical service-type input");
    Require(
        SkyBridgeProtocolConstants.MsQuicAlpn == "skybridge-sbq/1",
        "Windows MsQuic ALPN must match the protocol ADR");
    return Task.CompletedTask;
}

static Task TestMsQuicTransportSecretRejectsAlpnMismatch()
{
    RequireThrows<ArgumentNullException>(() => WindowsNativeMsQuicTransportSecret.LeafFingerprint(null));

    var dialer = WindowsNativeMsQuicTransportSecret.Derive(
        "192.0.2.10:50000",
        "192.0.2.20:5443",
        SkyBridgeProtocolConstants.MsQuicAlpn,
        new string('a', 64),
        new string('b', 64),
        new string('c', 64));
    var listener = WindowsNativeMsQuicTransportSecret.Derive(
        "192.0.2.20:5443",
        "192.0.2.10:50000",
        SkyBridgeProtocolConstants.MsQuicAlpn,
        new string('a', 64),
        new string('c', 64),
        new string('b', 64));
    Require(dialer.SequenceEqual(listener), "mirrored MsQuic peers must derive the same transport secret");

    RequireThrows<InvalidOperationException>(() => WindowsNativeMsQuicTransportSecret.Derive(
        "192.0.2.10:50000",
        "192.0.2.20:5443",
        "skybridge/1",
        new string('a', 64),
        new string('b', 64),
        new string('c', 64)));
    RequireThrows<InvalidOperationException>(() => WindowsNativeMsQuicTransportSecret.Derive(
        "192.0.2.10:50000",
        "192.0.2.20:5443",
        "SKYBRIDGE-SBQ/1",
        new string('a', 64),
        new string('b', 64),
        new string('c', 64)));
    return Task.CompletedTask;
}

static async Task TestDiscoveryBrowserProjectsResolvedRoutes()
{
    const string fingerprint = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    var browser = new WindowsDiscoveryBrowserClient(
        new StaticDiscoveryClient(fingerprint),
        new StaticDnsSdBrowseClient(
            new WindowsDnsSdResolvedTxtRecord(
                SkyBridgeProtocolConstants.QuicControlDnsSdService,
                $"deviceId=mac-1;name=Desk Mac;pubKeyFP={fingerprint};capabilities=control",
                "Desk Mac._skybridge._udp.local",
                "desk-mac.local",
                5443),
            new WindowsDnsSdResolvedTxtRecord(
                "_skybridge-transfer._tcp",
                $"deviceId=mac-1;name=Desk Mac;pubKeyFP={fingerprint};capabilities=file_transfer;port=7777",
                "Desk Mac._skybridge-transfer._tcp.local",
                "desk-mac.local",
                9443),
            new WindowsDnsSdResolvedTxtRecord(
                "_skybridge-remote._tcp",
                $"deviceId=mac-1;name=Desk Mac;pubKeyFP={fingerprint};capabilities=remote_desktop;remoteControlPort=7778",
                "Desk Mac._skybridge-remote._tcp.local",
                "desk-mac.local",
                5901)));

    var snapshot = await browser.BuildReadOnlySnapshotAsync(
        new DiscoveryBrowserRequest(
            DiscoveryBrowserAction.Start,
            "",
            "",
            "",
            CompatibilityMode: false,
            ExtendedSearchSeconds: 2));

    Require(snapshot.Peers.Count == 3, "resolved DNS-SD records must produce three candidates");
    Require(!snapshot.IsScanning, "A completed native discovery snapshot must not claim its retired browser is still scanning.");
    var completed = new ConnectionWorkspaceStateClient().BuildDiscoveryBrowserResultPatch(
        DiscoveryBrowserAction.Refresh, snapshot, "paired");
    Require(completed.IsDiscoveryScanning == false && completed.DiscoveryBrowserStatus?.StartsWith("Snapshot ", StringComparison.Ordinal) == true,
        "Completed discovery must display a completed snapshot rather than an active or stopped scan.");
    var stopped = new ConnectionWorkspaceStateClient().BuildDiscoveryBrowserResultPatch(
        DiscoveryBrowserAction.Stop, snapshot, "paired");
    Require(stopped.DiscoveryBrowserStatus?.StartsWith("Stopped ", StringComparison.Ordinal) == true && stopped.PairingStatus == "paired",
        "Explicit stop must remain distinct and preserve existing pairing status.");
    var control = snapshot.Peers.Single(peer => peer.Peer.ServiceKind == CoreDiscoveryServiceKind.QuicPrimary);
    var controlRoute = control.Routes.Control
        ?? throw new InvalidOperationException("QUIC control service must project a control route");
    Require(controlRoute.HostName == "desk-mac.local", "QUIC control route host mismatch");
    Require(controlRoute.Port == 5443, "QUIC control route must use resolved DNS-SD port");
    Require(
        controlRoute.Service == SkyBridgeProtocolConstants.QuicControlDnsSdService,
        "QUIC control route must retain the canonical service type");
    Require(
        controlRoute.InstanceName == "Desk Mac._skybridge._udp.local",
        "QUIC control route must retain the canonical instance suffix");
    Require(
        controlRoute.Provenance == "resolved-dns-sd-endpoint",
        "QUIC control route must retain resolved endpoint provenance");
    Require(control.Routes.FileTransfer is null, "QUIC control service must not invent a file-transfer route");
    Require(control.Routes.RemoteDesktop is null, "QUIC control service must not invent a remote-desktop route");
    Require(
        control.ProductActionTargets.All(target =>
            !target.Enabled &&
            target.Endpoint is null &&
            target.DisabledReason == ProductSessionActionDisabledReason.MissingResolvedRoute),
        "QUIC control discovery must not expand into file-transfer or remote-desktop action semantics");

    var transfer = snapshot.Peers.Single(peer => peer.Peer.ServiceKind == CoreDiscoveryServiceKind.FileTransfer);
    var transferRoute = transfer.Routes.FileTransfer
        ?? throw new InvalidOperationException("file-transfer service must project a file-transfer route");
    Require(transferRoute.HostName == "desk-mac.local", "file-transfer route host mismatch");
    Require(transferRoute.Port == 9443, "file-transfer route must use resolved DNS-SD port");
    Require(
        transferRoute.Service == SkyBridgeProtocolConstants.FileTransferDnsSdService,
        "legacy file-transfer input must project the canonical service type");
    Require(
        transferRoute.InstanceName == "Desk Mac._skybridge-xfer._tcp.local",
        "legacy file-transfer instance must project the canonical service suffix");
    Require(transferRoute.Provenance == "resolved-dns-sd-endpoint", "file-transfer route provenance mismatch");
    Require(transfer.Routes.Control is null, "file-transfer service must not invent a control route");
    Require(transfer.Routes.RemoteDesktop is null, "file-transfer service must not invent a remote-desktop route");
    var transferGate = transfer.ProductActionTargets.Single(target => target.Kind == ProductSessionActionKind.FileTransfer);
    Require(!transferGate.Enabled, "resolved route must stay disabled until product-control authenticates it");
    Require(
        transferGate.DisabledReason == ProductSessionActionDisabledReason.MissingEstablishedProductControlSession,
        "resolved route without session must report missing product-control session");

    var remote = snapshot.Peers.Single(peer => peer.Peer.ServiceKind == CoreDiscoveryServiceKind.RemoteControl);
    var remoteRoute = remote.Routes.RemoteDesktop
        ?? throw new InvalidOperationException("remote-control service must project a remote-desktop route");
    Require(remoteRoute.HostName == "desk-mac.local", "remote-desktop route host mismatch");
    Require(remoteRoute.Port == 5901, "remote-desktop route must use resolved DNS-SD port");
    Require(
        remoteRoute.Service == SkyBridgeProtocolConstants.RemoteDesktopDnsSdService,
        "remote-desktop route must retain the canonical service type");
    Require(remote.Routes.FileTransfer is null, "remote-control service must not invent a file-transfer route");
    Require(
        snapshot.Facts.Any(fact => fact.Label == "Resolved route" && fact.Detail.Contains("file-transfer=desk-mac.local:9443", StringComparison.Ordinal)),
        "resolved file-transfer route fact missing");
    Require(
        snapshot.Facts.Any(fact => fact.Label == "Product action gate" && fact.Detail.Contains("FileTransfer=disabled:MissingEstablishedProductControlSession", StringComparison.Ordinal)),
        "product action gate fact must explain the missing session");
}

static async Task TestDiscoveryBrowserResolvedNames()
{
    var fingerprint = new string('d', 64);
    async Task<DiscoveryBrowserSnapshot> Discover(string instance, string parsedName = "Unknown Device", string search = "")
    {
        var browser = new WindowsDiscoveryBrowserClient(
            new StaticDiscoveryClient(fingerprint, parsedName),
            new StaticDnsSdBrowseClient(new WindowsDnsSdResolvedTxtRecord(
                "_skybridge-rd._tcp", $"deviceId=mac-1;pubKeyFP={fingerprint};version=2;platform=macos",
                instance, "mac.local", 58827)));
        return await browser.BuildReadOnlySnapshotAsync(new(
            DiscoveryBrowserAction.Start, "", "", search, false, 2));
    }

    var snapshot = await Discover("Lza的MacBook Pro._skybridge-rd._tcp.local.", search: "MacBook");
    var peer = snapshot.Peers.Single();
    Require(peer.Peer.DisplayName == "Lza的MacBook Pro", "Canonical TXT without a name must use the resolved Unicode instance label, including in search.");
    Require(peer.Peer.DeviceId == "mac-1" && peer.Peer.PublicKeyFingerprint == fingerprint,
        "A display label must not replace the Core-validated identity or fingerprint.");
    Require(peer.ProductActionTargets.All(target => !target.Enabled) && peer.Routes.RemoteDesktop?.Port == 58827,
        "A display name must not grant authority or invent a transport route.");
    Require((await Discover("Office.Mac._skybridge-rd._tcp.local")).Peers.Single().Peer.DisplayName == "Office.Mac",
        "An instance label containing a dot must remain intact.");
    Require((await Discover("Bonjour name._skybridge-rd._tcp.local", "Explicit TXT name")).Peers.Single().Peer.DisplayName == "Explicit TXT name",
        "An explicit Core TXT name must remain preferred.");
    foreach (var instance in new[] { "._skybridge-rd._tcp.local", "Wrong._other._tcp.local", "Line\nBreak._skybridge-rd._tcp.local", new string('界', 22) + "._skybridge-rd._tcp.local" })
        Require((await Discover(instance)).Peers.Single().Peer.DisplayName == "Unknown Device",
            "A missing, mismatched, control-containing, or oversized DNS-SD label must not become display data.");
}

static async Task TestDiscoveryBrowserIgnoresTxtPortsWithoutResolvedEndpoint()
{
    const string fingerprint = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    var browser = new WindowsDiscoveryBrowserClient(
        new StaticDiscoveryClient(fingerprint),
        new StaticDnsSdBrowseClient());

    var snapshot = await browser.BuildReadOnlySnapshotAsync(
        new DiscoveryBrowserRequest(
            DiscoveryBrowserAction.Start,
            "_skybridge-transfer._tcp",
            $"deviceId=mac-2;name=Desk Mac;pubKeyFP={fingerprint};capabilities=file_transfer;port=9443;fileTransferPort=9443",
            "",
            CompatibilityMode: false,
            ExtendedSearchSeconds: 2));

    Require(snapshot.Peers.Count == 1, "manual TXT input must still parse into a candidate");
    var candidate = snapshot.Peers.Single();
    Require(!candidate.Routes.HasAny, "manual TXT port fields must not create a dialable route");
    Require(candidate.Routes.Summary.Contains("TXT port fields are diagnostic only", StringComparison.Ordinal), "empty route summary must explain TXT-only provenance");
}

static async Task TestDiscoveryBrowserStaleStopWaitsForOwnerBarrier()
{
    const string fingerprint = "abababababababababababababababababababababababababababababababab";
    var controlledBrowse = new ControlledDnsSdBrowseClient();
    var browser = new WindowsDiscoveryBrowserClient(
        new StaticDiscoveryClient(fingerprint),
        controlledBrowse);
    var startRequest = new DiscoveryBrowserRequest(
        DiscoveryBrowserAction.Start,
        "",
        "",
        "",
        CompatibilityMode: false,
        ExtendedSearchSeconds: 2);
    var stopRequest = startRequest with { Action = DiscoveryBrowserAction.Stop };

    var startA = browser.BuildReadOnlySnapshotAsync(startRequest);
    var callA = await controlledBrowse.WaitForNextCallAsync();
    var stopA = browser.BuildReadOnlySnapshotAsync(stopRequest);
    await callA.WaitForCancellationAsync();
    Require(!stopA.IsCompleted, "Stop must await the cancelled owner's native callback completion barrier");

    var startB = browser.BuildReadOnlySnapshotAsync(startRequest);
    var callB = await controlledBrowse.WaitForNextCallAsync();
    Require(!callB.IsCancellationRequested, "replacement browse B must start with a live cancellation lease");

    callA.Complete();
    var snapshotA = await startA;
    var stoppedSnapshotA = await stopA;
    Require(!callB.IsCancellationRequested, "stale Stop(A) must not cancel replacement browse B");

    var published = new List<long>();
    Require(
        !browser.TryPublish(snapshotA, snapshot => published.Add(snapshot.OperationOwner!.Generation)),
        "completed browse A must not publish after Stop(A) and replacement B");
    Require(
        !browser.TryPublish(stoppedSnapshotA, snapshot => published.Add(snapshot.OperationOwner!.Generation)),
        "stale Stop(A) must not publish a stopped state over replacement B");

    callB.Complete();
    var snapshotB = await startB;
    Require(
        browser.TryPublish(snapshotB, snapshot => published.Add(snapshot.OperationOwner!.Generation)),
        "replacement browse B must retain publication ownership after A drains");
    Require(
        published.SequenceEqual(new[] { snapshotB.OperationOwner!.Generation }),
        "only replacement browse B may publish after the A/B stale-stop sequence");
}

static async Task TestFeatureDiscoveryCancellationWaitsForOwnerBarrier()
{
    var native = new ControlledDnsSdBrowseClient();
    var browser = new WindowsDiscoveryBrowserClient(new StaticDiscoveryClient(new string('a', 64)), native);
    using var cancellation = new CancellationTokenSource();
    var task = browser.BuildReadOnlySnapshotAsync(new(DiscoveryBrowserAction.Refresh, "", "", "", false, 2), cancellation.Token);
    var call = await native.WaitForNextCallAsync();
    cancellation.Cancel();
    await call.WaitForCancellationAsync();
    Require(!task.IsCompleted, "Cancelling a feature lookup must retain its native callback owner until the callback drains.");
    call.Complete();
    try { await task; throw new InvalidOperationException("Cancelled lookup returned a successful empty snapshot."); }
    catch (OperationCanceledException error) { Require(error.CancellationToken == cancellation.Token, "Lookup cancellation must retain its caller token."); }
}

static async Task TestCancelledLookupDoesNotSupersedeActiveBrowser()
{
    var native = new ControlledDnsSdBrowseClient();
    var browser = new WindowsDiscoveryBrowserClient(new StaticDiscoveryClient(new string('b', 64)), native);
    var request = new DiscoveryBrowserRequest(DiscoveryBrowserAction.Refresh, "", "", "", false, 2);
    var active = browser.BuildReadOnlySnapshotAsync(request);
    var call = await native.WaitForNextCallAsync();
    using var cancellation = new CancellationTokenSource();
    cancellation.Cancel();
    try { await browser.BuildReadOnlySnapshotAsync(request, cancellation.Token); throw new InvalidOperationException("Pre-cancelled lookup was accepted."); }
    catch (OperationCanceledException error) { Require(error.CancellationToken == cancellation.Token, "The cancelled lookup must report its caller token."); }
    Require(!call.IsCancellationRequested, "A pre-cancelled request must not cancel an existing native browser owner.");
    call.Complete();
    var snapshot = await active;
    Require(browser.TryPublish(snapshot, _ => { }), "Pre-cancelled lookup must not steal snapshot publication ownership.");
}

static async Task TestFeatureDiscoveryDoesNotCancelUiBrowser()
{
    var native = new ControlledDnsSdBrowseClient();
    var parser = new StaticDiscoveryClient(new string('c', 64));
    var ui = new WindowsDiscoveryBrowserClient(parser, native);
    var feature = new WindowsDiscoveryBrowserClient(parser, native);
    var request = new DiscoveryBrowserRequest(DiscoveryBrowserAction.Refresh, "", "", "", false, 2);
    var uiTask = ui.BuildReadOnlySnapshotAsync(request);
    var uiCall = await native.WaitForNextCallAsync();
    using var cancellation = new CancellationTokenSource();
    var lookup = feature.BuildReadOnlySnapshotAsync(request, cancellation.Token);
    var featureCall = await native.WaitForNextCallAsync();
    Require(!uiCall.IsCancellationRequested, "A file peer lookup must not replace a UI scan.");
    cancellation.Cancel();
    await featureCall.WaitForCancellationAsync();
    Require(!uiCall.IsCancellationRequested, "Cancelling a file picker must not cancel the UI browser.");
    featureCall.Complete();
    try { await lookup; throw new InvalidOperationException("Cancelled feature lookup returned success."); }
    catch (OperationCanceledException error) { Require(error.CancellationToken == cancellation.Token, "The cancelled lookup must report its caller token."); }
    uiCall.Complete();
    Require(ui.TryPublish(await uiTask, _ => { }), "The UI browser must retain its independent snapshot.");
}

static Task TestNativeDnsSdCallbackBarrierContract()
{
    var source = File.ReadAllText(Path.Combine(
        FindRepositoryRoot(),
        "windows",
        "Skybridge.WinClient",
        "Services",
        "NativeWindowsDnsSdBrowseClient.cs"));
    Require(
        !source.Contains("CallbackDrainDelay", StringComparison.Ordinal) &&
        !source.Contains("FromMilliseconds(250)", StringComparison.Ordinal),
        "native DNS-SD lifecycle must not use a fixed callback drain delay");
    Require(
        source.Contains("await context.CallbackCompleted.ConfigureAwait(false)", StringComparison.Ordinal),
        "native DNS-SD cancellation must await its callback completion barrier");
    Require(
        source.Contains("status == ErrorCancelled", StringComparison.Ordinal),
        "DnsServiceBrowse cancellation callback must close the exact native callback lease");
    return Task.CompletedTask;
}

static async Task TestConnectionWorkspaceValidatedStateRetainsDiscoveryCandidateRoutes()
{
    const string fingerprint = "bcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbc";
    var source = await BuildResolvedDiscoverySnapshotAsync(fingerprint);
    var remote = source.Peers.Single(peer => peer.Peer.ServiceKind == CoreDiscoveryServiceKind.RemoteControl);
    var snapshot = new DiscoveryBrowserSnapshot(
        DateTimeOffset.UtcNow,
        IsScanning: true,
        new[] { remote },
        Array.Empty<DiscoveryBrowserFact>());
    var stateClient = new ConnectionWorkspaceStateClient();

    var state = stateClient.BuildDiscoveryBrowserValidatedState(snapshot);
    Require(state.DiscoveredPeer?.DeviceId == "mac-1", "validated state must preserve the discovered peer");
    Require(state.DiscoveryCandidate is not null, "validated state must preserve the route-bearing discovery candidate");
    Require(
        state.DiscoveryCandidate!.Routes.RemoteDesktop?.Port == 5901,
        "validated state must preserve remote-desktop route");

    var paired = stateClient.BuildPairingValidatedState(state, new PairingMaterial("mac-1"));
    Require(
        paired.DiscoveryCandidate?.Routes.RemoteDesktop?.Port == 5901,
        "pairing validation must not drop the discovery candidate routes");

    var manual = stateClient.BuildDiscoveryPeerValidatedState(remote);
    Require(
        manual.DiscoveryCandidate?.Routes.RemoteDesktop?.Port == 5901,
        "single-peer validation must preserve the supplied discovery candidate");

    var multiple = stateClient.BuildDiscoveryBrowserValidatedState(source);
    Require(multiple.DiscoveredPeer is null, "multi-peer snapshot must not select an implicit discovered peer");
    Require(multiple.DiscoveryCandidate is null, "multi-peer snapshot must not select an implicit discovery candidate");
}

static async Task TestProductActionTargetsRequireAuthenticatedRouteBinding()
{
    const string fingerprint = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
    var now = DateTimeOffset.UtcNow;
    var snapshot = await BuildResolvedDiscoverySnapshotAsync(fingerprint);
    var transfer = snapshot.Peers.Single(peer => peer.Peer.ServiceKind == CoreDiscoveryServiceKind.FileTransfer);
    var remote = snapshot.Peers.Single(peer => peer.Peer.ServiceKind == CoreDiscoveryServiceKind.RemoteControl);
    var session = EstablishedSession(
        sessionId: "session-mac-1",
        remoteDeviceId: "mac-1",
        fingerprint,
        expiresAtUtc: now.AddMinutes(5)) with
    {
        AuthenticatedRouteBindings = new[]
        {
            AuthenticatedRouteBinding(ProductSessionActionKind.FileTransfer, transfer.Routes.FileTransfer!, now.AddMinutes(5)),
            AuthenticatedRouteBinding(ProductSessionActionKind.RemoteDesktop, remote.Routes.RemoteDesktop!, now.AddMinutes(5))
        }
    };

    var transferTarget = ProductSessionActionTargetProjection.ProjectFileTransfer(transfer, session, now);
    Require(transferTarget.Enabled, "matching established session plus authenticated route binding must enable file-transfer action target");
    Require(transferTarget.DisabledReason is null, "enabled file-transfer action must not carry a disabled reason");
    Require(transferTarget.SessionId == "session-mac-1", "file-transfer target must bind to the established session id");
    Require(transferTarget.Endpoint?.HostName == "desk-mac.local", "file-transfer target endpoint host mismatch");
    Require(transferTarget.Endpoint?.Port == 9443, "file-transfer target endpoint port mismatch");
    Require(!transferTarget.Detail.Contains("session-mac-1", StringComparison.Ordinal), "enabled target detail must not leak raw session id");

    var remoteTarget = ProductSessionActionTargetProjection.ProjectRemoteDesktop(remote, session, now);
    Require(remoteTarget.Enabled, "matching established session plus authenticated route binding must enable remote-desktop action target");
    Require(remoteTarget.Endpoint?.Port == 5901, "remote-desktop target endpoint port mismatch");
}

static async Task TestProductActionTargetsRejectMissingSessionAndTxtOnlyRoutes()
{
    const string fingerprint = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd";
    var now = DateTimeOffset.UtcNow;
    var resolvedSnapshot = await BuildResolvedDiscoverySnapshotAsync(fingerprint);
    var resolvedTransfer = resolvedSnapshot.Peers.Single(peer => peer.Peer.ServiceKind == CoreDiscoveryServiceKind.FileTransfer);
    var noSessionTarget = ProductSessionActionTargetProjection.ProjectFileTransfer(resolvedTransfer, null, now);
    Require(!noSessionTarget.Enabled, "resolved discovery route without session must stay disabled");
    Require(
        noSessionTarget.DisabledReason == ProductSessionActionDisabledReason.MissingEstablishedProductControlSession,
        "resolved route without session must require an established product-control session");

    var establishedWithoutBinding = ProductSessionActionTargetProjection.ProjectFileTransfer(
        resolvedTransfer,
        EstablishedSession("session-mac-1", "mac-1", fingerprint, now.AddMinutes(5)),
        now);
    Require(!establishedWithoutBinding.Enabled, "established session without authenticated route binding must stay disabled");
    Require(
        establishedWithoutBinding.DisabledReason == ProductSessionActionDisabledReason.MissingAuthenticatedRouteBinding,
        "established session without route binding must report missing authenticated route binding");

    var txtOnlyBrowser = new WindowsDiscoveryBrowserClient(
        new StaticDiscoveryClient(fingerprint),
        new StaticDnsSdBrowseClient());
    var txtOnlySnapshot = await txtOnlyBrowser.BuildReadOnlySnapshotAsync(
        new DiscoveryBrowserRequest(
            DiscoveryBrowserAction.Start,
            "_skybridge-transfer._tcp",
            $"deviceId=mac-1;name=Desk Mac;pubKeyFP={fingerprint};capabilities=file_transfer;fileTransferPort=9443",
            "",
            CompatibilityMode: false,
            ExtendedSearchSeconds: 2));
    var txtOnly = txtOnlySnapshot.Peers.Single();
    var matchingSession = EstablishedSession("session-mac-1", "mac-1", fingerprint, now.AddMinutes(5));
    var txtOnlyTarget = ProductSessionActionTargetProjection.ProjectFileTransfer(txtOnly, matchingSession, now);
    Require(!txtOnlyTarget.Enabled, "TXT-only file-transfer port hint must stay disabled even with a matching session");
    Require(
        txtOnlyTarget.DisabledReason == ProductSessionActionDisabledReason.MissingResolvedRoute,
        "TXT-only route must report missing resolved DNS-SD route");

    var injectedRouteCandidate = txtOnly with
    {
        Routes = new DiscoveryPeerRoutes(
            Control: null,
            FileTransfer: new DiscoveryPeerEndpoint(
                "_skybridge-transfer._tcp",
                "desk-mac.local",
                9443,
                "Desk Mac._skybridge-transfer._tcp.local",
                "manual-txt-port"),
            RemoteDesktop: null)
    };
    var injectedTarget = ProductSessionActionTargetProjection.ProjectFileTransfer(injectedRouteCandidate, matchingSession, now);
    Require(!injectedTarget.Enabled, "non-resolved file-transfer route provenance must stay disabled");
    Require(
        injectedTarget.DisabledReason == ProductSessionActionDisabledReason.UnsupportedRouteProvenance,
        "non-resolved route provenance must be explicit");
}

static async Task TestProductActionTargetsRejectStaleAndMismatchedSessions()
{
    const string fingerprint = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";
    var now = DateTimeOffset.UtcNow;
    var snapshot = await BuildResolvedDiscoverySnapshotAsync(fingerprint);
    var transfer = snapshot.Peers.Single(peer => peer.Peer.ServiceKind == CoreDiscoveryServiceKind.FileTransfer);

    var wrongPeer = ProductSessionActionTargetProjection.ProjectFileTransfer(
        transfer,
        EstablishedSession("session-mac-9", "mac-9", fingerprint, now.AddMinutes(5)),
        now);
    Require(!wrongPeer.Enabled, "peer id mismatch must keep file-transfer action disabled");
    Require(wrongPeer.DisabledReason == ProductSessionActionDisabledReason.PeerDeviceIdMismatch, "peer id mismatch reason mismatch");

    var wrongFingerprint = ProductSessionActionTargetProjection.ProjectFileTransfer(
        transfer,
        EstablishedSession(
            "session-mac-1",
            "mac-1",
            "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
            now.AddMinutes(5)),
        now);
    Require(!wrongFingerprint.Enabled, "fingerprint mismatch must keep file-transfer action disabled");
    Require(
        wrongFingerprint.DisabledReason == ProductSessionActionDisabledReason.PeerFingerprintMismatch,
        "fingerprint mismatch reason mismatch");

    var notEstablished = ProductSessionActionTargetProjection.ProjectFileTransfer(
        transfer,
        EstablishedSession("session-mac-1", "mac-1", fingerprint, now.AddMinutes(5), secureSessionState: "TransportOnly"),
        now);
    Require(!notEstablished.Enabled, "transport-only product-control session must not enable file transfer");
    Require(
        notEstablished.DisabledReason == ProductSessionActionDisabledReason.ProductControlSessionNotEstablished,
        "non-established session reason mismatch");

    var expired = ProductSessionActionTargetProjection.ProjectFileTransfer(
        transfer,
        EstablishedSession("session-mac-1", "mac-1", fingerprint, now.AddSeconds(-1)) with
        {
            AuthenticatedRouteBindings = new[]
            {
                AuthenticatedRouteBinding(ProductSessionActionKind.FileTransfer, transfer.Routes.FileTransfer!, now.AddMinutes(5))
            }
        },
        now);
    Require(!expired.Enabled, "expired product-control session must not enable file transfer");
    Require(expired.DisabledReason == ProductSessionActionDisabledReason.ProductControlSessionExpired, "expired session reason mismatch");

    var expiredBinding = ProductSessionActionTargetProjection.ProjectFileTransfer(
        transfer,
        EstablishedSession("session-mac-1", "mac-1", fingerprint, now.AddMinutes(5)) with
        {
            AuthenticatedRouteBindings = new[]
            {
                AuthenticatedRouteBinding(ProductSessionActionKind.FileTransfer, transfer.Routes.FileTransfer!, now.AddSeconds(-1))
            }
        },
        now);
    Require(!expiredBinding.Enabled, "expired authenticated route binding must not enable file transfer");
    Require(
        expiredBinding.DisabledReason == ProductSessionActionDisabledReason.AuthenticatedRouteBindingExpired,
        "expired route binding reason mismatch");

    var uppercaseFingerprint = ProductSessionActionTargetProjection.ProjectFileTransfer(
        transfer,
        EstablishedSession("session-mac-1", "mac-1", fingerprint.ToUpperInvariant(), now.AddMinutes(5)) with
        {
            AuthenticatedRouteBindings = new[]
            {
                AuthenticatedRouteBinding(ProductSessionActionKind.FileTransfer, transfer.Routes.FileTransfer!, now.AddMinutes(5))
            }
        },
        now);
    Require(!uppercaseFingerprint.Enabled, "fingerprint comparison must require canonical lower-hex fingerprints");
    Require(
        uppercaseFingerprint.DisabledReason == ProductSessionActionDisabledReason.PeerFingerprintMismatch,
        "uppercase fingerprint reason mismatch");
}

static async Task TestProductActionGateRequiresAuthenticatedRemoteRoute()
{
    const string fingerprint = "abababababababababababababababababababababababababababababababab";
    var now = DateTimeOffset.UtcNow;
    var snapshot = await BuildResolvedDiscoverySnapshotAsync(fingerprint);
    var remote = snapshot.Peers.Single(peer => peer.Peer.ServiceKind == CoreDiscoveryServiceKind.RemoteControl);

    var unavailableGate = new ProductSessionActionGateClient();
    var unavailable = unavailableGate.EvaluateRemoteDesktop(remote, now);
    Require(!unavailable.IsReady, "remote action gate must fail closed without a session authority");
    Require(
        unavailable.DisabledReason == ProductSessionActionDisabledReason.MissingEstablishedProductControlSession,
        "missing session authority reason mismatch");
    Require(
        unavailable.Detail.Contains("no established product-control session authority", StringComparison.OrdinalIgnoreCase),
        "missing authority detail must be explicit");

    var missingBindingGate = new ProductSessionActionGateClient(
        new StaticProductControlSessionSnapshotClient(
            EstablishedSession("session-mac-1", "mac-1", fingerprint, now.AddMinutes(5))));
    var missingBinding = missingBindingGate.EvaluateRemoteDesktop(remote, now);
    Require(!missingBinding.IsReady, "remote action gate must fail closed without an authenticated route binding");
    Require(
        missingBinding.DisabledReason == ProductSessionActionDisabledReason.MissingAuthenticatedRouteBinding,
        "missing route binding reason mismatch");

    var readyGate = new ProductSessionActionGateClient(
        new StaticProductControlSessionSnapshotClient(
            EstablishedSession("session-mac-1", "mac-1", fingerprint, now.AddMinutes(5)) with
            {
                AuthenticatedRouteBindings = new[]
                {
                    AuthenticatedRouteBinding(ProductSessionActionKind.RemoteDesktop, remote.Routes.RemoteDesktop!, now.AddMinutes(5))
                }
            }));
    var ready = readyGate.EvaluateRemoteDesktop(remote, now);
    Require(ready.IsReady, "remote action gate must pass with an authenticated route binding");
    Require(ready.Target?.Endpoint?.Port == 5901, "ready remote gate must preserve target endpoint");

    var noCandidate = readyGate.EvaluateRemoteDesktop(null, now);
    Require(!noCandidate.IsReady, "remote action gate must fail closed without a validated candidate");
    Require(
        noCandidate.DisabledReason == ProductSessionActionDisabledReason.MissingValidatedDiscoveryCandidate,
        "missing validated candidate reason mismatch");
}

static Task TestWebRtcAuthenticatedRouteBindingAppControlCodec()
{
    var decoded = WebRtcAuthenticatedRouteBindingCodec.Decode(
        Encoding.UTF8.GetBytes(AuthenticatedRouteBindingJson(
            kind: "remoteDesktop",
            port: 5901,
            nonceBase64: Convert.ToBase64String(Enumerable.Range(1, 16).Select(i => (byte)i).ToArray()))));

    Require(decoded.Version == 1, "route binding version mismatch");
    Require(decoded.Kind == "remoteDesktop", "route binding kind mismatch");
    Require(
        decoded.ServiceType == SkyBridgeProtocolConstants.RemoteDesktopDnsSdService,
        "legacy route-binding service type must canonicalize");
    Require(
        decoded.InstanceName == "Desk Mac._skybridge-rd._tcp.local",
        "legacy route-binding instance name must canonicalize");
    Require(decoded.HostName == "desk-mac.local", "route binding host mismatch");
    Require(decoded.Port == 5901, "route binding port mismatch");
    Require(decoded.EndpointProvenance == "resolved-dns-sd-endpoint", "route binding provenance mismatch");
    Require(decoded.RouteAuthorityProtocolPublicKeyFingerprint == new string('a', 64), "route binding authority fingerprint mismatch");
    Require(decoded.RemoteProtocolPublicKeyFingerprint == new string('a', 64), "route binding fingerprint mismatch");
    Require(decoded.SessionHashHex == "0123456789abcdef", "route binding session hash mismatch");
    Require(decoded.TranscriptPrefixHex == "fedcba9876543210", "route binding transcript prefix mismatch");
    Require(decoded.Nonce.SequenceEqual(Enumerable.Range(1, 16).Select(i => (byte)i)), "route binding nonce mismatch");

    RequireThrows<WebRtcAuthenticatedRouteBindingException>(
        () => WebRtcAuthenticatedRouteBindingCodec.Decode(Encoding.UTF8.GetBytes("{}")));
    RequireThrows<WebRtcAuthenticatedRouteBindingException>(
        () => WebRtcAuthenticatedRouteBindingCodec.Decode(
            Encoding.UTF8.GetBytes(
                "{\"authenticatedRouteBinding\":{\"version\":1},\"pong\":{\"id\":1}}")));
    RequireThrows<WebRtcAuthenticatedRouteBindingException>(
        () => WebRtcAuthenticatedRouteBindingCodec.Decode(
            Encoding.UTF8.GetBytes(AuthenticatedRouteBindingJson(kind: "clipboard", port: 5901))));
    RequireThrows<WebRtcAuthenticatedRouteBindingException>(
        () => WebRtcAuthenticatedRouteBindingCodec.Decode(
            Encoding.UTF8.GetBytes(AuthenticatedRouteBindingJson(kind: "remoteDesktop", port: 0))));
    RequireThrows<WebRtcAuthenticatedRouteBindingException>(
        () => WebRtcAuthenticatedRouteBindingCodec.Decode(
            Encoding.UTF8.GetBytes(AuthenticatedRouteBindingJson(
                kind: "fileTransfer",
                port: 9443,
                serviceType: SkyBridgeProtocolConstants.RemoteDesktopDnsSdService))));
    RequireThrows<WebRtcAuthenticatedRouteBindingException>(
        () => WebRtcAuthenticatedRouteBindingCodec.Decode(
            Encoding.UTF8.GetBytes(AuthenticatedRouteBindingJson(
                kind: "remoteDesktop",
                port: 5901,
                endpointProvenance: "txt-port-hint"))));
    RequireThrows<WebRtcAuthenticatedRouteBindingException>(
        () => WebRtcAuthenticatedRouteBindingCodec.Decode(
            Encoding.UTF8.GetBytes(AuthenticatedRouteBindingJson(
                kind: "remoteDesktop",
                port: 5901,
                nonceBase64: "AQIDBA=="))));
    return Task.CompletedTask;
}

static async Task TestWebRtcAuthenticatedRouteBindingRejectsTransportOnlyContext()
{
    var keys = CreatePairedWebRtcSessionKeys();
    using var initiatorKeys = keys.Initiator;
    var store = new WebRtcAuthenticatedRouteBindingStore(
        new StaticWebRtcAppSessionKeyProvider(initiatorKeys));
    var context = TransportOnlyWebRtcContext(
        new FakeProductControlPlane(),
        peerDeviceId: "mac-1",
        peerPublicKeyFingerprint: new string('a', 64),
        role: "offer");

    await RequireThrowsAsync<WebRtcAuthenticatedRouteBindingStoreException>(
        () => store.StartAsync(context));
}

static async Task TestWebRtcAuthenticatedRouteBindingRejectsReceiverMismatch()
{
    const string fingerprint = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    var now = DateTimeOffset.UtcNow;
    var snapshot = await BuildResolvedDiscoverySnapshotAsync(fingerprint);
    var remote = snapshot.Peers.Single(peer => peer.Peer.ServiceKind == CoreDiscoveryServiceKind.RemoteControl);
    var planes = PairedProductControlPlanes.Create();
    var keys = CreatePairedWebRtcSessionKeys();
    using var initiatorKeys = keys.Initiator;
    using var responderKeys = keys.Responder;
    var context = EstablishedWebRtcContext(
        planes.Responder,
        peerDeviceId: "mac-1",
        peerPublicKeyFingerprint: fingerprint,
        role: "answer");
    var store = new WebRtcAuthenticatedRouteBindingStore(
        new StaticWebRtcAppSessionKeyProvider(responderKeys));

    var storeLease = await store.StartAsync(context);
    try
    {
        await planes.Initiator.SendAsync(SealRouteBindingJson(
            initiatorKeys,
            RouteBindingJson(
                ProductSessionActionKind.RemoteDesktop,
                remote.Routes.RemoteDesktop!,
                fingerprint,
                sessionHashHex: LowerHex16(WebRtcAppSecureEnvelope.SessionIdHash(initiatorKeys.SessionId)),
                transcriptPrefixHex: LowerHex16(WebRtcAppSecureEnvelope.TranscriptPrefix(initiatorKeys.TranscriptHash.Span)),
                sentAt: now,
                expiresAt: now.AddMinutes(2),
                remoteDeviceId: "other-windows-device"),
            counter: 1));

        var blocked = new ProductSessionActionGateClient(store).EvaluateRemoteDesktop(remote, now);
        Require(!blocked.IsReady, "receiver device mismatch must fail closed and disable the action");
        Require(
            blocked.DisabledReason == ProductSessionActionDisabledReason.MissingEstablishedProductControlSession,
            "receiver device mismatch must clear the established route-binding session snapshot");
    }
    finally
    {
        await store.StopAsync(storeLease);
    }

    var fingerprintMismatchStore = new WebRtcAuthenticatedRouteBindingStore(
        new StaticWebRtcAppSessionKeyProvider(responderKeys));
    var fingerprintMismatchLease = await fingerprintMismatchStore.StartAsync(context);
    try
    {
        await planes.Initiator.SendAsync(SealRouteBindingJson(
            initiatorKeys,
            RouteBindingJson(
                ProductSessionActionKind.RemoteDesktop,
                remote.Routes.RemoteDesktop!,
                fingerprint,
                sessionHashHex: LowerHex16(WebRtcAppSecureEnvelope.SessionIdHash(initiatorKeys.SessionId)),
                transcriptPrefixHex: LowerHex16(WebRtcAppSecureEnvelope.TranscriptPrefix(initiatorKeys.TranscriptHash.Span)),
                sentAt: now,
                expiresAt: now.AddMinutes(2),
                remoteProtocolPublicKeyFingerprint: new string('b', 64)),
            counter: 2));

        var blocked = new ProductSessionActionGateClient(fingerprintMismatchStore).EvaluateRemoteDesktop(remote, now);
        Require(!blocked.IsReady, "receiver fingerprint mismatch must fail closed and disable the action");
        Require(
            blocked.DisabledReason == ProductSessionActionDisabledReason.MissingEstablishedProductControlSession,
            "receiver fingerprint mismatch must clear the established route-binding session snapshot");
    }
    finally
    {
        await fingerprintMismatchStore.StopAsync(fingerprintMismatchLease);
    }
}

static async Task TestWebRtcSecureSessionRuntimeStartsDownstreamAfterEstablishedContext()
{
    var secureSessionStore = new WebRtcProductSecureSessionStore();
    var downstream = new TrackingProductControlRuntimeConsumer();
    var establisher = new InstallingSecureSessionEstablisher(secureSessionStore);
    var runtime = new WebRtcProductSecureSessionRuntimeConsumer(
        establisher,
        secureSessionStore,
        new IWebRtcProductControlRuntimeConsumer[] { downstream });
    var context = TransportOnlyWebRtcContext(
        new FakeProductControlPlane(),
        peerDeviceId: "mac-1",
        peerPublicKeyFingerprint: new string('a', 64),
        role: "offer");

    var runtimeLease = await runtime.StartAsync(context);
    Require(establisher.EstablishCalls == 1, "secure runtime must establish the SBWC session before downstream start");
    Require(downstream.StartCalls == 1, "secure runtime must start the downstream consumer");
    Require(
        downstream.StartedContext?.SecureSessionState == WebRtcProductControlSecureSessionState.Established,
        "downstream consumer must receive an Established context");
    var authority = (IWebRtcProductControlEstablishedSessionAuthority)runtime;
    var authoritativeContext = authority.RequireEstablishedContext(runtimeLease);
    Require(
        authoritativeContext == downstream.StartedContext &&
        authoritativeContext.SessionIncarnation is not null,
        "secure runtime must publish the exact Established context for its runtime lease");

    await runtime.StopAsync(runtimeLease);
    Require(downstream.StopCalls == 1, "secure runtime must stop the downstream consumer");
    RequireThrows<InvalidOperationException>(() => authority.RequireEstablishedContext(runtimeLease));
    await RequireThrowsAsync<WebRtcAppSessionKeysUnavailableException>(
        () =>
        {
            _ = secureSessionStore.RequireEstablishedKeys(downstream.StartedContext!);
            return Task.CompletedTask;
        });
}

static async Task TestWebRtcSecureSessionRuntimeRejectsNonEstablishedEstablisher()
{
    var secureSessionStore = new WebRtcProductSecureSessionStore();
    var downstream = new TrackingProductControlRuntimeConsumer();
    var runtime = new WebRtcProductSecureSessionRuntimeConsumer(
        new StaticSecureSessionEstablisher(WebRtcProductControlSecureSessionState.TransportOnly),
        secureSessionStore,
        new IWebRtcProductControlRuntimeConsumer[] { downstream });
    var context = TransportOnlyWebRtcContext(
        new FakeProductControlPlane(),
        peerDeviceId: "mac-1",
        peerPublicKeyFingerprint: new string('a', 64),
        role: "offer");

    await RequireThrowsAsync<InvalidOperationException>(() => runtime.StartAsync(context));
    Require(downstream.StartCalls == 0, "downstream consumer must not start when the establisher returns TransportOnly");
}

static async Task TestWebRtcSecureSessionRuntimeCleansUpAfterDownstreamStartFailure()
{
    var secureSessionStore = new WebRtcProductSecureSessionStore();
    var firstDownstream = new TrackingProductControlRuntimeConsumer();
    var failingDownstream = new TrackingProductControlRuntimeConsumer(throwOnStart: true);
    var establisher = new InstallingSecureSessionEstablisher(secureSessionStore);
    var runtime = new WebRtcProductSecureSessionRuntimeConsumer(
        establisher,
        secureSessionStore,
        new IWebRtcProductControlRuntimeConsumer[] { firstDownstream, failingDownstream });
    var context = TransportOnlyWebRtcContext(
        new FakeProductControlPlane(),
        peerDeviceId: "mac-1",
        peerPublicKeyFingerprint: new string('a', 64),
        role: "offer");

    await RequireThrowsAsync<InvalidOperationException>(() => runtime.StartAsync(context));
    Require(firstDownstream.StartCalls == 1, "first downstream consumer must have started before the injected failure");
    Require(firstDownstream.StopCalls == 1, "started downstream consumer must be stopped after later startup failure");
    Require(failingDownstream.StartCalls == 1, "failing downstream consumer must be attempted exactly once");
    var establishedContext = establisher.LastEstablishedContext
        ?? throw new InvalidOperationException("test establisher did not record its established context");
    await RequireThrowsAsync<WebRtcAppSessionKeysUnavailableException>(
        () =>
        {
            _ = secureSessionStore.RequireEstablishedKeys(establishedContext);
            return Task.CompletedTask;
        });
}

static async Task TestWebRtcSecureSessionRuntimeRetainsAuthorityAcrossStopFailure()
{
    var secureSessionStore = new WebRtcProductSecureSessionStore();
    var downstream = new TrackingProductControlRuntimeConsumer(stopFailures: 1);
    var establisher = new InstallingSecureSessionEstablisher(secureSessionStore);
    var runtime = new WebRtcProductSecureSessionRuntimeConsumer(
        establisher,
        secureSessionStore,
        new IWebRtcProductControlRuntimeConsumer[] { downstream });
    var context = TransportOnlyWebRtcContext(
        new FakeProductControlPlane(),
        peerDeviceId: "mac-1",
        peerPublicKeyFingerprint: new string('a', 64),
        role: "offer");
    var runtimeLease = await runtime.StartAsync(context);
    var authority = (IWebRtcProductControlEstablishedSessionAuthority)runtime;

    await RequireThrowsAsync<AggregateException>(() => runtime.StopAsync(runtimeLease));
    var retainedContext = authority.RequireEstablishedContext(runtimeLease);
    using (var retainedKeys = secureSessionStore.RequireEstablishedKeys(retainedContext))
    {
        Require(!string.IsNullOrWhiteSpace(retainedKeys.SessionId), "failed stop must retain exact established session keys for cleanup retry");
    }

    Require(downstream.StopAttempts == 1 && downstream.StopCalls == 0, "injected downstream stop failure must remain pending");
    await runtime.StopAsync(runtimeLease);
    Require(downstream.StopAttempts == 2 && downstream.StopCalls == 1, "cleanup retry must stop the retained exact downstream lease");
    RequireThrows<InvalidOperationException>(() => authority.RequireEstablishedContext(runtimeLease));
    await RequireThrowsAsync<WebRtcAppSessionKeysUnavailableException>(
        () =>
        {
            _ = secureSessionStore.RequireEstablishedKeys(retainedContext);
            return Task.CompletedTask;
        });
    runtime.Dispose();
}

static async Task TestWebRtcSecureSessionDisposeRetriesExactPendingOwner()
{
    var secureSessionStore = new WebRtcProductSecureSessionStore();
    var downstream = new TrackingProductControlRuntimeConsumer(stopFailures: 1);
    var establisher = new InstallingSecureSessionEstablisher(secureSessionStore);
    var runtime = new WebRtcProductSecureSessionRuntimeConsumer(
        establisher,
        secureSessionStore,
        new IWebRtcProductControlRuntimeConsumer[] { downstream });
    var context = TransportOnlyWebRtcContext(
        new FakeProductControlPlane(),
        peerDeviceId: "mac-1",
        peerPublicKeyFingerprint: new string('a', 64),
        role: "offer");
    var runtimeLease = await runtime.StartAsync(context);
    var establishedContext = establisher.LastEstablishedContext
        ?? throw new InvalidOperationException("test establisher did not publish its Established context");

    RequireThrows<AggregateException>(runtime.Dispose);
    Require(downstream.StopAttempts == 1 && downstream.StopCalls == 0, "first Dispose must retain the exact failed downstream owner");
    Require(downstream.DisposeAttempts == 0, "Dispose must not destroy a dependency whose exact Stop owner is still pending");
    Require(establisher.DisposeAttempts == 0, "Dispose must not destroy the establisher while active cleanup is pending");
    using (var retainedKeys = secureSessionStore.RequireEstablishedKeys(establishedContext))
    {
        Require(!string.IsNullOrWhiteSpace(retainedKeys.SessionId), "failed Dispose must retain session keys until the exact owner stops");
    }

    await RequireThrowsAsync<ObjectDisposedException>(() => runtime.StopAsync(runtimeLease));
    runtime.Dispose();
    Require(downstream.StopAttempts == 2 && downstream.StopCalls == 1, "Dispose retry must stop the original downstream lease exactly once");
    Require(downstream.LastStoppedLease == downstream.LastStartedLease, "Dispose retry must use the original downstream owner lease");
    Require(downstream.DisposeAttempts == 1 && downstream.DisposeCalls == 1, "dependency disposal must run after exact Stop succeeds");
    Require(establisher.DisposeAttempts == 1 && establisher.DisposeCalls == 1, "establisher disposal must run after active cleanup succeeds");
    await RequireThrowsAsync<WebRtcAppSessionKeysUnavailableException>(
        () =>
        {
            _ = secureSessionStore.RequireEstablishedKeys(establishedContext);
            return Task.CompletedTask;
        });

    runtime.Dispose();
    Require(downstream.StopAttempts == 2, "completed Dispose must not repeat exact downstream Stop");
    Require(downstream.DisposeAttempts == 1, "completed Dispose must not redispose a successful dependency");
    Require(establisher.DisposeAttempts == 1, "completed Dispose must not redispose the establisher");
}

static async Task TestWebRtcSecureSessionDisposeRetriesOnlyFailedDependency()
{
    var secureSessionStore = new WebRtcProductSecureSessionStore();
    var retryingDependency = new TrackingProductControlRuntimeConsumer(disposeFailures: 1);
    var successfulDependency = new TrackingProductControlRuntimeConsumer();
    var establisher = new InstallingSecureSessionEstablisher(secureSessionStore);
    var runtime = new WebRtcProductSecureSessionRuntimeConsumer(
        establisher,
        secureSessionStore,
        new IWebRtcProductControlRuntimeConsumer[] { retryingDependency, successfulDependency });
    var context = TransportOnlyWebRtcContext(
        new FakeProductControlPlane(),
        peerDeviceId: "mac-1",
        peerPublicKeyFingerprint: new string('a', 64),
        role: "offer");
    _ = await runtime.StartAsync(context);

    RequireThrows<AggregateException>(runtime.Dispose);
    Require(retryingDependency.StopAttempts == 1 && retryingDependency.StopCalls == 1, "active cleanup must stop the retrying dependency once");
    Require(successfulDependency.StopAttempts == 1 && successfulDependency.StopCalls == 1, "active cleanup must stop the successful dependency once");
    Require(retryingDependency.DisposeAttempts == 1 && retryingDependency.DisposeCalls == 0, "failed dependency disposal must remain pending");
    Require(successfulDependency.DisposeAttempts == 1 && successfulDependency.DisposeCalls == 1, "successful dependency disposal must complete once");
    Require(establisher.DisposeAttempts == 1 && establisher.DisposeCalls == 1, "successful establisher disposal must complete once");

    runtime.Dispose();
    Require(retryingDependency.DisposeAttempts == 2 && retryingDependency.DisposeCalls == 1, "Dispose retry must target only the failed dependency");
    Require(successfulDependency.DisposeAttempts == 1, "Dispose retry must not redispose the successful dependency");
    Require(establisher.DisposeAttempts == 1, "Dispose retry must not redispose the successful establisher");
    Require(retryingDependency.StopAttempts == 1 && successfulDependency.StopAttempts == 1, "dependency-dispose retry must not repeat completed Stop owners");

    runtime.Dispose();
    Require(retryingDependency.DisposeAttempts == 2, "completed disposal must be idempotent");
}

static async Task TestWebRtcSecureSessionDisposeBarrierRejectsInFlightStop()
{
    var secureSessionStore = new WebRtcProductSecureSessionStore();
    var downstream = new BlockingStopProductControlRuntimeConsumer();
    var establisher = new InstallingSecureSessionEstablisher(secureSessionStore);
    var runtime = new WebRtcProductSecureSessionRuntimeConsumer(
        establisher,
        secureSessionStore,
        new IWebRtcProductControlRuntimeConsumer[] { downstream });
    var context = TransportOnlyWebRtcContext(
        new FakeProductControlPlane(),
        peerDeviceId: "mac-1",
        peerPublicKeyFingerprint: new string('a', 64),
        role: "offer");
    var runtimeLease = await runtime.StartAsync(context);
    var stop = runtime.StopAsync(runtimeLease);
    await downstream.WaitForStopAsync();

    RequireThrows<InvalidOperationException>(runtime.Dispose);
    await RequireThrowsAsync<ObjectDisposedException>(() => runtime.StopAsync(runtimeLease));
    Require(!stop.IsCompleted, "Dispose barrier must not race a second cleanup over the in-flight exact Stop owner");

    downstream.ReleaseStop();
    await stop.WaitAsync(TimeSpan.FromSeconds(5));
    runtime.Dispose();
    Require(downstream.StopCalls == 1, "in-flight Stop must release its exact owner once");
    Require(downstream.DisposeCalls == 1, "Dispose retry must dispose the dependency after Stop completes");
    Require(establisher.DisposeCalls == 1, "Dispose retry must dispose the establisher once");
}

static Task TestWebRtcSecureSessionIncarnationRejectsStaleClear()
{
    var store = new WebRtcProductSecureSessionStore();
    var transportContext = TransportOnlyWebRtcContext(
        new FakeProductControlPlane(),
        peerDeviceId: "mac-1",
        peerPublicKeyFingerprint: new string('a', 64),
        role: "offer");
    var keysA = CreatePairedWebRtcSessionKeys();
    using var initiatorA = keysA.Initiator;
    using var responderA = keysA.Responder;
    var establishedA = store.InstallEstablishedSession(
        transportContext,
        initiatorA,
        WebRtcProductHandshakeCodec.SuiteMlKem768Mldsa65);
    var keysB = CreatePairedWebRtcSessionKeys();
    using var initiatorB = keysB.Initiator;
    using var responderB = keysB.Responder;
    var establishedB = store.InstallEstablishedSession(
        transportContext,
        initiatorB,
        WebRtcProductHandshakeCodec.SuiteMlKem768Mldsa65);

    Require(
        establishedA.SessionIncarnation is not null &&
        establishedB.SessionIncarnation is not null &&
        establishedA.SessionIncarnation != establishedB.SessionIncarnation,
        "replacement secure sessions must receive distinct incarnation owners");
    Require(!store.Clear(establishedA), "stale Clear(A) must not remove replacement secure session B");
    using (var requiredB = store.RequireEstablishedKeys(establishedB))
    {
        Require(
            requiredB.SessionId == initiatorB.SessionId,
            "replacement secure session B must remain readable after stale Clear(A)");
    }

    RequireThrows<WebRtcAppSessionKeysUnavailableException>(
        () => store.RequireEstablishedKeys(establishedA));
    Require(store.Clear(establishedB), "exact Clear(B) must remove replacement secure session B");
    RequireThrows<WebRtcAppSessionKeysUnavailableException>(
        () => store.RequireEstablishedKeys(establishedB));
    return Task.CompletedTask;
}

static async Task TestWebRtcStaleStartupFailurePreservesReplacementSession()
{
    var store = new WebRtcProductSecureSessionStore();
    var delayedFailure = new DelayedFailingProductControlRuntimeConsumer();
    var establisherA = new InstallingSecureSessionEstablisher(store);
    var runtimeA = new WebRtcProductSecureSessionRuntimeConsumer(
        establisherA,
        store,
        new IWebRtcProductControlRuntimeConsumer[] { delayedFailure });
    var establisherB = new InstallingSecureSessionEstablisher(store);
    var runtimeB = new WebRtcProductSecureSessionRuntimeConsumer(establisherB, store);
    var contextA = TransportOnlyWebRtcContext(
        new FakeProductControlPlane(),
        peerDeviceId: "mac-1",
        peerPublicKeyFingerprint: new string('a', 64),
        role: "offer");
    var contextB = contextA with { ControlPlane = new FakeProductControlPlane() };

    var startA = runtimeA.StartAsync(contextA);
    await delayedFailure.WaitForStartAsync();
    var leaseB = await runtimeB.StartAsync(contextB);
    var establishedB = establisherB.LastEstablishedContext
        ?? throw new InvalidOperationException("replacement establisher did not publish context B");

    delayedFailure.ReleaseFailure();
    await RequireThrowsAsync<InvalidOperationException>(async () => _ = await startA);
    using (var keysB = store.RequireEstablishedKeys(establishedB))
    {
        Require(
            !string.IsNullOrWhiteSpace(keysB.SessionId),
            "replacement session B must remain installed after stale startup failure cleanup from A");
    }

    await runtimeB.StopAsync(leaseB);
    runtimeA.Dispose();
    runtimeB.Dispose();
}

static async Task TestWebRtcEngineSerializesConnectAndDisconnectOwnership()
{
    var consumer = new BlockingProductControlRuntimeConsumer();
    var inner = new TrackingEngineClient(() => consumer.StopCalls);
    var transport = new TrackingProductControlEngineTransport(
        TransportOnlyWebRtcContext(
            new FakeProductControlPlane(),
            peerDeviceId: "mac-1",
            peerPublicKeyFingerprint: new string('a', 64),
            role: "offer"),
        () => consumer.ActiveLease is not null,
        () => consumer.StopCalls);
    var engine = new WebRtcProductControlEngineClient(
        inner,
        transport,
        new IWebRtcProductControlRuntimeConsumer[] { consumer });
    var request = new ConnectionLaunchRequest(
        new PairingMaterial("mac-1"),
        new ConnectionPreflightSnapshot(
            DateTimeOffset.UtcNow,
            new ConnectionPreflightPlan(IsLiveAdapterReady: true)));

    try
    {
        var connect = engine.ConnectAsync(request);
        await consumer.WaitForStartAsync();

        var disconnect = engine.DisconnectAsync();
        try
        {
            Require(!disconnect.IsCompleted, "Disconnect must wait for the in-flight Connect owner to finish publishing");
            Require(inner.DisconnectCalls == 0, "Disconnect must not tear down the inner engine while consumer Start is in flight");
            Require(
                transport.DisposeTransportCalls == 0,
                "Disconnect must not tear down the transport while consumer Start is in flight");
            Require(consumer.StopCalls == 0, "Disconnect must not stop a consumer before Start returns its exact lease");
        }
        finally
        {
            consumer.ReleaseStart();
        }

        await connect.WaitAsync(TimeSpan.FromSeconds(5));
        await disconnect.WaitAsync(TimeSpan.FromSeconds(5));

        Require(consumer.StartCalls == 1, "the runtime consumer must start exactly once");
        Require(consumer.StopCalls == 1, "Disconnect must stop the exact runtime consumer lease exactly once");
        Require(
            consumer.StartedLease is not null && consumer.LastStoppedLease == consumer.StartedLease,
            "Disconnect must present the exact lease returned by the completed Start operation");
        Require(consumer.ActiveLease is null, "Disconnect must leave no active runtime consumer lease");
        Require(inner.ConnectCalls == 1 && inner.DisconnectCalls == 1, "inner engine lifecycle must remain paired");
        Require(
            inner.StopCallsObservedAtDisconnect == 1,
            "inner disconnect must occur only after the exact runtime consumer lease is stopped");
        Require(transport.DisposeTransportCalls == 1, "transport teardown must run exactly once after consumer stop");
        Require(
            !transport.ConsumerWasActiveDuringDispose && transport.StopCallsObservedAtDispose == 1,
            "transport teardown must occur only after the exact runtime consumer lease is stopped");
    }
    finally
    {
        consumer.ReleaseStart();
        engine.Dispose();
    }
}

static async Task TestWebRtcEngineRollsBackPartialConsumerStart()
{
    var firstConsumer = new BlockingProductControlRuntimeConsumer(blockStart: false);
    var failingConsumer = new TrackingProductControlRuntimeConsumer(throwOnStart: true);
    var inner = new TrackingEngineClient(() => firstConsumer.StopCalls);
    var transport = new TrackingProductControlEngineTransport(
        TransportOnlyWebRtcContext(
            new FakeProductControlPlane(),
            peerDeviceId: "mac-1",
            peerPublicKeyFingerprint: new string('a', 64),
            role: "offer"),
        () => firstConsumer.ActiveLease is not null,
        () => firstConsumer.StopCalls);
    var engine = new WebRtcProductControlEngineClient(
        inner,
        transport,
        new IWebRtcProductControlRuntimeConsumer[] { firstConsumer, failingConsumer });
    var request = new ConnectionLaunchRequest(
        new PairingMaterial("mac-1"),
        new ConnectionPreflightSnapshot(
            DateTimeOffset.UtcNow,
            new ConnectionPreflightPlan(IsLiveAdapterReady: true)));

    try
    {
        await RequireThrowsAsync<InvalidOperationException>(() => engine.ConnectAsync(request));
        Require(firstConsumer.StartCalls == 1, "first consumer must start before the injected later failure");
        Require(failingConsumer.StartCalls == 1, "failing consumer must be attempted exactly once");
        Require(firstConsumer.StopCalls == 1, "partial engine startup must roll back the first consumer exactly once");
        Require(
            firstConsumer.StartedLease is not null &&
            firstConsumer.LastStoppedLease == firstConsumer.StartedLease,
            "partial engine startup rollback must stop the exact lease returned by the first consumer");
        Require(firstConsumer.ActiveLease is null, "partial engine startup rollback must leave no active consumer lease");
        Require(inner.DisconnectCalls == 1, "partial engine startup rollback must disconnect the inner engine");
        Require(
            inner.StopCallsObservedAtDisconnect == 1,
            "partial engine startup rollback must stop the exact consumer before inner disconnect");
        Require(transport.DisposeTransportCalls == 1, "partial engine startup rollback must dispose the transport");
        Require(
            !transport.ConsumerWasActiveDuringDispose && transport.StopCallsObservedAtDispose == 1,
            "partial engine startup rollback must stop the exact consumer before transport disposal");
    }
    finally
    {
        engine.Dispose();
    }
}

static async Task TestWebRtcProductEngineRetainsOwnershipAcrossCleanupFailure()
{
    var consumer = new BlockingProductControlRuntimeConsumer(blockStart: false);
    var inner = new TrackingEngineClient(() => consumer.StopCalls);
    var transport = new TrackingProductControlEngineTransport(
        TransportOnlyWebRtcContext(
            new FakeProductControlPlane(),
            peerDeviceId: "mac-1",
            peerPublicKeyFingerprint: new string('a', 64),
            role: "offer"),
        () => consumer.ActiveLease is not null,
        () => consumer.StopCalls,
        disposeFailures: 1);
    var engine = new WebRtcProductControlEngineClient(
        inner,
        transport,
        new IWebRtcProductControlRuntimeConsumer[] { consumer });
    var request = TestProductControlLaunchRequest();

    try
    {
        await engine.ConnectAsync(request);
        await RequireThrowsAsync<AggregateException>(engine.DisconnectAsync);
        Require(
            transport.DisposeTransportAttempts == 1 && transport.DisposeTransportCalls == 0,
            "injected transport cleanup failure must retain the exact claimed transport owner");
        Require(
            transport.ClaimedLease is not null && transport.LastAttemptedLease == transport.ClaimedLease,
            "failed cleanup must attempt the exact lease claimed by Connect");
        Require(engine.State == EngineConnectionState.ShuttingDown, "failed cleanup must remain explicitly ShuttingDown");
        await RequireThrowsAsync<InvalidOperationException>(() => engine.ConnectAsync(request));
        await RequireThrowsAsync<InvalidOperationException>(engine.SendHeartbeatAsync);
        Require(inner.ConnectCalls == 1, "unresolved cleanup ownership must block replacement Connect before the inner engine");

        await engine.DisconnectAsync();
        Require(
            transport.DisposeTransportAttempts == 2 && transport.DisposeTransportCalls == 1,
            "cleanup retry must release the retained exact transport once");
        Require(
            transport.LastAttemptedLease == transport.ClaimedLease &&
            transport.LastDisposedLease == transport.ClaimedLease,
            "cleanup retry must preserve the original transport lease identity");
        Require(engine.State == EngineConnectionState.Disconnected, "successful cleanup retry must publish Disconnected");
    }
    finally
    {
        engine.Dispose();
    }
}

static Task TestWebRtcProductTransportRejectsReplacementWhileClaimed()
{
    var claim = new WebRtcProductControlTransportClaim();
    var lease = claim.ClaimForEngine();
    lease.RequireValid();
    Require(claim.IsClaimedByEngine, "claim gate must record the active engine owner");
    RequireThrows<InvalidOperationException>(claim.RequireUnclaimedForReplacement);
    RequireThrows<InvalidOperationException>(claim.RequireUnclaimedForOwnerlessTeardown);
    Require(claim.IsOwnedBy(lease), "claim gate must retain the exact lease after rejected replacement and teardown");
    Require(
        !claim.IsOwnedBy(WebRtcProductControlTransportLease.Create()),
        "a foreign lease must not own the claimed product-control transport");
    return Task.CompletedTask;
}

static async Task TestWebRtcProductEngineSuppressesInnerEarlyConnected()
{
    var consumer = new BlockingProductControlRuntimeConsumer();
    var inner = new TrackingEngineClient(() => consumer.StopCalls);
    var transport = new TrackingProductControlEngineTransport(
        TransportOnlyWebRtcContext(
            new FakeProductControlPlane(),
            peerDeviceId: "mac-1",
            peerPublicKeyFingerprint: new string('a', 64),
            role: "offer"),
        () => consumer.ActiveLease is not null,
        () => consumer.StopCalls);
    var engine = new WebRtcProductControlEngineClient(
        inner,
        transport,
        new IWebRtcProductControlRuntimeConsumer[] { consumer });
    var published = new List<EngineConnectionState>();
    engine.ConnectionStateChanged += (_, state) => published.Add(state);
    var connect = engine.ConnectAsync(TestProductControlLaunchRequest());
    await consumer.WaitForStartAsync();

    try
    {
        Require(inner.State == EngineConnectionState.Connected, "test inner engine must publish its early Connected state");
        Require(engine.State == EngineConnectionState.Connecting, "product wrapper must remain Connecting until Established authority exists");
        Require(!published.Contains(EngineConnectionState.Connected), "inner early Connected must not escape the product wrapper");

        consumer.ReleaseStart();
        await connect.WaitAsync(TimeSpan.FromSeconds(5));
        Require(engine.State == EngineConnectionState.Connected, "wrapper must publish Connected after exact Established authority");
        Require(
            published.SequenceEqual(new[] { EngineConnectionState.Connecting, EngineConnectionState.Connected }),
            "product wrapper must publish only its serialized Connecting then Connected transitions");
        await engine.DisconnectAsync();
    }
    finally
    {
        consumer.ReleaseStart();
        engine.Dispose();
    }
}

static async Task TestWebRtcProductEngineStartupFailureNeverPublishesConnected()
{
    var leaseOnlyConsumer = new TrackingProductControlRuntimeConsumer(
        requireEstablishedContext: false);
    var inner = new TrackingEngineClient(() => leaseOnlyConsumer.StopCalls);
    var transport = new TrackingProductControlEngineTransport(
        TransportOnlyWebRtcContext(
            new FakeProductControlPlane(),
            peerDeviceId: "mac-1",
            peerPublicKeyFingerprint: new string('a', 64),
            role: "offer"),
        () => false,
        () => leaseOnlyConsumer.StopCalls);
    var engine = new WebRtcProductControlEngineClient(
        inner,
        transport,
        new IWebRtcProductControlRuntimeConsumer[] { leaseOnlyConsumer });
    var published = new List<EngineConnectionState>();
    engine.ConnectionStateChanged += (_, state) => published.Add(state);

    try
    {
        await RequireThrowsAsync<InvalidOperationException>(
            () => engine.ConnectAsync(TestProductControlLaunchRequest()));
        Require(leaseOnlyConsumer.StartCalls == 1, "lease-only consumer must start before the authority gate rejects it");
        Require(leaseOnlyConsumer.StopCalls == 1, "authority rejection must roll back the exact lease-only consumer");
        Require(!published.Contains(EngineConnectionState.Connected), "consumer startup failure must never publish product Connected");
        Require(engine.State == EngineConnectionState.Disconnected, "clean startup rollback must publish Disconnected");
        Require(
            published.SequenceEqual(new[] { EngineConnectionState.Connecting, EngineConnectionState.Disconnected }),
            "startup failure must expose the explicit serialized Connecting to Disconnected transition");
    }
    finally
    {
        engine.Dispose();
    }
}

static async Task TestWebRtcProductEngineDisposeWaitsForConnectAndReleasesExactTransport()
{
    var consumer = new BlockingProductControlRuntimeConsumer();
    var inner = new TrackingEngineClient(() => consumer.StopCalls);
    var transport = new TrackingProductControlEngineTransport(
        TransportOnlyWebRtcContext(
            new FakeProductControlPlane(),
            peerDeviceId: "mac-1",
            peerPublicKeyFingerprint: new string('a', 64),
            role: "offer"),
        () => consumer.ActiveLease is not null,
        () => consumer.StopCalls);
    var engine = new WebRtcProductControlEngineClient(
        inner,
        transport,
        new IWebRtcProductControlRuntimeConsumer[] { consumer });
    var connect = engine.ConnectAsync(TestProductControlLaunchRequest());
    await consumer.WaitForStartAsync();
    var dispose = Task.Run(engine.Dispose);

    try
    {
        var disposeRequested = SpinWait.SpinUntil(
            () => IsWebRtcProductControlEngineDisposeRequested(engine),
            TimeSpan.FromSeconds(5));
        Require(disposeRequested, "Dispose must publish its fail-closed product barrier before waiting for Connect");
        Require(!dispose.IsCompleted, "Dispose must wait for the in-flight product consumer Start barrier");
        Require(consumer.StopCalls == 0, "Dispose must not stop a product consumer before Start returns its lease");

        consumer.ReleaseStart();
        await RequireThrowsAsync<ObjectDisposedException>(async () => await connect.ConfigureAwait(false));
        await dispose.WaitAsync(TimeSpan.FromSeconds(5));
        Require(consumer.StopCalls == 1, "Connect/Dispose race must stop the exact product consumer lease once");
        Require(
            consumer.StartedLease is not null && consumer.LastStoppedLease == consumer.StartedLease,
            "Connect/Dispose race must stop the exact product consumer lease returned by Start");
        Require(
            transport.ClaimedLease is not null && transport.LastDisposedLease == transport.ClaimedLease,
            "Connect/Dispose race must release the exact claimed product transport lease");
        Require(transport.DisposeTransportCalls == 1, "Connect rollback must release the product transport exactly once");
        Require(transport.DisposeCalls == 1, "final engine disposal must dispose the transport owner once");
        Require(inner.DisconnectCalls == 1 && inner.DisposeCalls == 1, "inner engine rollback and disposal must remain paired");
        Require(consumer.DisposeCalls == 1 && !consumer.WasActiveDuringDispose, "consumer disposal must follow exact-lease stop");
    }
    finally
    {
        consumer.ReleaseStart();
        engine.Dispose();
    }
}

static async Task TestWebRtcProductEngineDisposeRetriesCompletedSecureConsumerOwner()
{
    var secureSessionStore = new WebRtcProductSecureSessionStore();
    var downstream = new TrackingProductControlRuntimeConsumer(stopFailures: 1);
    var secureRuntime = new WebRtcProductSecureSessionRuntimeConsumer(
        new InstallingSecureSessionEstablisher(secureSessionStore),
        secureSessionStore,
        new IWebRtcProductControlRuntimeConsumer[] { downstream });
    var inner = new TrackingEngineClient(() => downstream.StopCalls);
    var transport = new TrackingProductControlEngineTransport(
        TransportOnlyWebRtcContext(
            new FakeProductControlPlane(),
            peerDeviceId: "mac-1",
            peerPublicKeyFingerprint: new string('a', 64),
            role: "offer"),
        () => downstream.StartedLease is not null,
        () => downstream.StopCalls);
    var engine = new WebRtcProductControlEngineClient(
        inner,
        transport,
        new IWebRtcProductControlRuntimeConsumer[] { secureRuntime });
    await engine.ConnectAsync(TestProductControlLaunchRequest());

    RequireThrows<AggregateException>(engine.Dispose);
    Require(
        downstream.StopAttempts == 2 && downstream.StopCalls == 1,
        "wrapper Dispose must let secure-runtime disposal retry the exact Stop owner after the first Stop failure");
    Require(
        downstream.DisposeAttempts == 1 && downstream.DisposeCalls == 1,
        "secure-runtime disposal must finish its dependency after exact Stop retry succeeds");

    engine.Dispose();
    Require(
        downstream.StopAttempts == 2,
        "wrapper Dispose retry must treat the already completed secure-runtime Stop owner as idempotent");
    Require(
        transport.ClaimedLease is not null && transport.LastDisposedLease == transport.ClaimedLease,
        "wrapper Dispose retries must never release a foreign product transport owner");
    engine.Dispose();
    Require(downstream.DisposeAttempts == 1, "completed wrapper disposal must remain idempotent");
}

static ConnectionLaunchRequest TestProductControlLaunchRequest() =>
    new(
        new PairingMaterial("mac-1"),
        new ConnectionPreflightSnapshot(
            DateTimeOffset.UtcNow,
            new ConnectionPreflightPlan(IsLiveAdapterReady: true)));

static bool IsWebRtcProductControlEngineDisposeRequested(WebRtcProductControlEngineClient engine)
{
    var field = typeof(WebRtcProductControlEngineClient).GetField(
        "_disposeRequested",
        System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic)
        ?? throw new InvalidOperationException("WebRTC product-control engine disposal barrier field is unavailable");
    return field.GetValue(engine) is int value && value != 0;
}

static async Task TestWebRtcSessionEngineSerializesConnectAndDisconnectOwnership()
{
    var consumer = new TrackingWebRtcSessionRuntimeConsumer(blockStart: true);
    var inner = new TrackingEngineClient(() => consumer.StopCalls);
    var transport = new TrackingWebRtcSessionEngineTransport(
        TestWebRtcSessionContext(),
        () => consumer.ActiveLease is not null,
        () => consumer.StopCalls);
    var engine = new WebRtcSessionEngineClient(
        inner,
        transport,
        new IWebRtcSessionRuntimeConsumer[] { consumer });
    var request = TestWebRtcSessionLaunchRequest();

    try
    {
        var connect = engine.ConnectAsync(request);
        await consumer.WaitForStartAsync();

        var disconnect = engine.DisconnectAsync();
        try
        {
            Require(!disconnect.IsCompleted, "Disconnect must wait for the in-flight WebRTC session Connect owner");
            Require(inner.DisconnectCalls == 0, "Disconnect must not tear down the inner engine while session consumer Start is in flight");
            Require(
                transport.DisposeSessionCalls == 0,
                "Disconnect must not tear down the session transport while consumer Start is in flight");
            Require(consumer.StopCalls == 0, "Disconnect must not stop a session consumer before Start returns its exact lease");
        }
        finally
        {
            consumer.ReleaseStart();
        }

        await connect.WaitAsync(TimeSpan.FromSeconds(5));
        await disconnect.WaitAsync(TimeSpan.FromSeconds(5));

        Require(consumer.StartCalls == 1, "the WebRTC session runtime consumer must start exactly once");
        Require(consumer.StopCalls == 1, "Disconnect must stop the exact WebRTC session runtime lease exactly once");
        Require(
            consumer.LastStartedLease is not null && consumer.LastStoppedLease == consumer.LastStartedLease,
            "Disconnect must present the exact lease returned by the completed session consumer Start operation");
        Require(consumer.ActiveLease is null, "Disconnect must leave no active WebRTC session consumer lease");
        Require(inner.ConnectCalls == 1 && inner.DisconnectCalls == 1, "inner session engine lifecycle must remain paired");
        Require(
            inner.StopCallsObservedAtDisconnect == 1,
            "inner disconnect must occur only after the exact session consumer lease is stopped");
        Require(transport.DisposeSessionCalls == 1, "session transport teardown must run exactly once after consumer stop");
        Require(
            transport.ClaimedLease is not null && transport.LastDisposedLease == transport.ClaimedLease,
            "session transport teardown must present the exact lease claimed by Connect");
        Require(
            !transport.ConsumerWasActiveDuringSessionDispose && transport.StopCallsObservedAtSessionDispose == 1,
            "session transport teardown must occur only after the exact consumer lease is stopped");
    }
    finally
    {
        consumer.ReleaseStart();
        engine.Dispose();
    }
}

static async Task TestWebRtcSessionEngineRollsBackPartialConsumerStart()
{
    var firstConsumer = new TrackingWebRtcSessionRuntimeConsumer();
    var failingConsumer = new TrackingWebRtcSessionRuntimeConsumer(throwOnStart: true);
    var inner = new TrackingEngineClient(() => firstConsumer.StopCalls);
    var transport = new TrackingWebRtcSessionEngineTransport(
        TestWebRtcSessionContext(),
        () => firstConsumer.ActiveLease is not null,
        () => firstConsumer.StopCalls);
    var engine = new WebRtcSessionEngineClient(
        inner,
        transport,
        new IWebRtcSessionRuntimeConsumer[] { firstConsumer, failingConsumer });

    try
    {
        await RequireThrowsAsync<InvalidOperationException>(
            () => engine.ConnectAsync(TestWebRtcSessionLaunchRequest()));
        Require(firstConsumer.StartCalls == 1, "first session consumer must start before the injected later failure");
        Require(failingConsumer.StartCalls == 1, "failing session consumer must be attempted exactly once");
        Require(firstConsumer.StopCalls == 1, "partial session startup must roll back the first consumer exactly once");
        Require(
            firstConsumer.LastStartedLease is not null &&
            firstConsumer.LastStoppedLease == firstConsumer.LastStartedLease,
            "partial session startup rollback must stop the exact lease returned by the first consumer");
        Require(firstConsumer.ActiveLease is null, "partial session startup rollback must leave no active consumer lease");
        Require(inner.DisconnectCalls == 1, "partial session startup rollback must disconnect the inner engine");
        Require(
            inner.StopCallsObservedAtDisconnect == 1,
            "partial session startup rollback must stop the exact consumer before inner disconnect");
        Require(transport.DisposeSessionCalls == 1, "partial session startup rollback must dispose the transport session");
        Require(
            transport.ClaimedLease is not null && transport.LastDisposedLease == transport.ClaimedLease,
            "partial session startup rollback must release the exact claimed transport lease");
        Require(
            !transport.ConsumerWasActiveDuringSessionDispose && transport.StopCallsObservedAtSessionDispose == 1,
            "partial session startup rollback must stop the exact consumer before transport disposal");
    }
    finally
    {
        engine.Dispose();
    }
}

static async Task TestWebRtcSessionEngineRetainsOwnershipAcrossCleanupFailure()
{
    var consumer = new TrackingWebRtcSessionRuntimeConsumer(stopFailures: 1);
    var inner = new TrackingEngineClient(() => consumer.StopCalls);
    var transport = new TrackingWebRtcSessionEngineTransport(
        TestWebRtcSessionContext(),
        () => consumer.ActiveLease is not null,
        () => consumer.StopCalls);
    var engine = new WebRtcSessionEngineClient(
        inner,
        transport,
        new IWebRtcSessionRuntimeConsumer[] { consumer });
    var request = TestWebRtcSessionLaunchRequest();

    try
    {
        await engine.ConnectAsync(request);
        await RequireThrowsAsync<AggregateException>(engine.DisconnectAsync);
        Require(consumer.StopAttempts == 1 && consumer.StopCalls == 0, "injected stop failure must leave the exact consumer lease active");
        Require(consumer.ActiveLease == consumer.LastStartedLease, "failed cleanup must retain the original consumer lease ownership");
        Require(inner.DisconnectCalls == 1, "failed consumer stop must not skip inner disconnect cleanup");
        Require(transport.DisposeSessionCalls == 1, "failed consumer stop must not skip exact transport cleanup");
        await RequireThrowsAsync<InvalidOperationException>(() => engine.ConnectAsync(request));
        Require(inner.ConnectCalls == 1, "unresolved cleanup ownership must block a replacement Connect before the inner engine");
        await RequireThrowsAsync<InvalidOperationException>(engine.SendHeartbeatAsync);
        Require(inner.HeartbeatCalls == 0, "unresolved cleanup ownership must block heartbeat before the inner engine");

        await engine.DisconnectAsync();
        Require(consumer.StopAttempts == 2 && consumer.StopCalls == 1, "cleanup retry must stop the retained exact lease once");
        Require(consumer.LastStoppedLease == consumer.LastStartedLease, "cleanup retry must use the original consumer lease");
        Require(inner.DisconnectCalls == 2, "cleanup retry must revalidate inner disconnect completion");
        Require(transport.DisposeSessionCalls == 1, "stale exact transport release retry must not dispose a replacement session");
        await engine.DisconnectAsync();
        Require(consumer.StopAttempts == 2, "completed cleanup retry must make later Disconnect idempotent");
    }
    finally
    {
        engine.Dispose();
    }
}

static async Task TestWebRtcSessionResourceCleanupRetainsFailedOwnersForRetry()
{
    var dataPlane = new TrackingAsyncDisposable(failuresBeforeSuccess: 1);
    var helperSession = new TrackingAsyncDisposable();
    var owner = new WebRtcSessionResourceOwner(dataPlane, helperSession);

    await RequireThrowsAsync<InvalidOperationException>(owner.DisposePendingAsync);
    Require(owner.HasPendingResources, "failed data-plane cleanup must remain owned for an explicit retry");
    Require(dataPlane.DisposeAttempts == 1, "the failing data plane must be attempted exactly once");
    Require(helperSession.DisposeAttempts == 1, "a data-plane failure must not skip helper cleanup");
    Require(helperSession.SuccessfulDisposals == 1, "successful helper cleanup must be recorded");

    await owner.DisposePendingAsync();
    Require(!owner.HasPendingResources, "a successful retry must clear all retained resource owners");
    Require(dataPlane.DisposeAttempts == 2, "cleanup retry must target the exact failed data-plane resource");
    Require(dataPlane.SuccessfulDisposals == 1, "the retained data plane must be released once");
    Require(helperSession.DisposeAttempts == 1, "cleanup retry must not redispose an already released helper");

    await owner.DisposePendingAsync();
    Require(dataPlane.DisposeAttempts == 2 && helperSession.DisposeAttempts == 1, "completed cleanup must be idempotent");
}

static async Task TestWebRtcSessionEngineDisposeWaitsForConnectAndStopsBeforeTransport()
{
    var consumer = new TrackingWebRtcSessionRuntimeConsumer(blockStart: true);
    var inner = new TrackingEngineClient(() => consumer.StopCalls);
    var transport = new TrackingWebRtcSessionEngineTransport(
        TestWebRtcSessionContext(),
        () => consumer.ActiveLease is not null,
        () => consumer.StopCalls);
    var engine = new WebRtcSessionEngineClient(
        inner,
        transport,
        new IWebRtcSessionRuntimeConsumer[] { consumer });
    var connect = engine.ConnectAsync(TestWebRtcSessionLaunchRequest());
    await consumer.WaitForStartAsync();

    var dispose = Task.Run(engine.Dispose);
    try
    {
        var disposeRequested = SpinWait.SpinUntil(
            () => IsWebRtcSessionEngineDisposeRequested(engine),
            TimeSpan.FromSeconds(5));
        Require(disposeRequested, "Dispose must publish its fail-closed barrier before waiting for in-flight Connect");
        Require(!dispose.IsCompleted, "Dispose must wait for the in-flight session consumer Start barrier");
        Require(consumer.StopCalls == 0, "Dispose must not stop a session consumer before Start returns its lease");

        consumer.ReleaseStart();
        await RequireThrowsAsync<ObjectDisposedException>(async () => await connect.ConfigureAwait(false));
        await dispose.WaitAsync(TimeSpan.FromSeconds(5));

        Require(consumer.StopCalls == 1, "Connect/Dispose race must stop the published session consumer lease exactly once");
        Require(
            consumer.LastStartedLease is not null && consumer.LastStoppedLease == consumer.LastStartedLease,
            "Connect/Dispose race must stop the exact lease returned by Start");
        Require(inner.DisconnectCalls == 1, "Connect rollback must disconnect the inner engine before final disposal");
        Require(inner.StopCallsObservedAtDisconnect == 1, "inner disconnect must observe the consumer already stopped");
        Require(inner.DisposeCalls == 1 && inner.StopCallsObservedAtDispose == 1, "inner disposal must occur after consumer stop");
        Require(transport.DisposeSessionCalls == 1, "Connect rollback must close the session transport exactly once");
        Require(
            transport.ClaimedLease is not null && transport.LastDisposedLease == transport.ClaimedLease,
            "Connect/Dispose rollback must release the exact claimed transport lease");
        Require(transport.DisposeCalls == 1, "engine disposal must dispose the session transport owner exactly once");
        Require(
            !transport.ConsumerWasActiveDuringSessionDispose && !transport.ConsumerWasActiveDuringDispose,
            "both transport teardown phases must observe the consumer already stopped");
        Require(consumer.DisposeCalls == 1 && !consumer.WasActiveDuringDispose, "consumer disposal must follow exact-lease stop");
    }
    finally
    {
        consumer.ReleaseStart();
        engine.Dispose();
    }
}

static async Task TestWebRtcSessionEngineDoubleLifecycleIsExactAndIdempotent()
{
    var consumer = new TrackingWebRtcSessionRuntimeConsumer();
    var inner = new TrackingEngineClient(() => consumer.StopCalls);
    var transport = new TrackingWebRtcSessionEngineTransport(
        TestWebRtcSessionContext(),
        () => consumer.ActiveLease is not null,
        () => consumer.StopCalls);
    var engine = new WebRtcSessionEngineClient(
        inner,
        transport,
        new IWebRtcSessionRuntimeConsumer[] { consumer });
    var request = TestWebRtcSessionLaunchRequest();

    await engine.ConnectAsync(request);
    await RequireThrowsAsync<InvalidOperationException>(() => engine.ConnectAsync(request));
    Require(inner.ConnectCalls == 1, "double Connect must fail before invoking the inner engine again");
    Require(consumer.StartCalls == 1, "double Connect must not start another consumer incarnation");

    await engine.DisconnectAsync();
    await engine.DisconnectAsync();
    Require(consumer.StopCalls == 1, "double Disconnect must not stop an already-cleared consumer lease again");
    Require(inner.DisconnectCalls == 1, "double Disconnect must not invoke the inner engine twice");
    Require(transport.DisposeSessionCalls == 1, "double Disconnect must not tear down the session transport twice");
    Require(
        transport.ClaimedLease is not null && transport.LastDisposedLease == transport.ClaimedLease,
        "double lifecycle must release only the exact transport lease claimed by Connect");

    engine.Dispose();
    engine.Dispose();
    Require(inner.DisposeCalls == 1, "double Dispose must dispose the inner engine exactly once");
    Require(transport.DisposeCalls == 1, "double Dispose must dispose the transport owner exactly once");
    Require(consumer.DisposeCalls == 1, "double Dispose must dispose each runtime consumer exactly once");
    await RequireThrowsAsync<ObjectDisposedException>(() => engine.ConnectAsync(request));
    await RequireThrowsAsync<ObjectDisposedException>(engine.DisconnectAsync);
    await RequireThrowsAsync<ObjectDisposedException>(engine.SendHeartbeatAsync);
}

static ConnectionLaunchRequest TestWebRtcSessionLaunchRequest() =>
    new(
        new PairingMaterial("mac-1"),
        new ConnectionPreflightSnapshot(
            DateTimeOffset.UtcNow,
            new ConnectionPreflightPlan(IsLiveAdapterReady: true)));

static LiveWebRtcSessionContext TestWebRtcSessionContext() =>
    new(
        new TestSkyBridgeDataPlane(),
        "mac-1",
        new string('a', 64),
        new string('b', 64),
        "test-webrtc-session-binding",
        "127.0.0.1:41000",
        "192.0.2.10:42000",
        "webrtc/dtls/sctp/test-local-test-remote",
        10_000,
        Array.Empty<ChannelMapping>());

static bool IsWebRtcSessionEngineDisposeRequested(WebRtcSessionEngineClient engine)
{
    var field = typeof(WebRtcSessionEngineClient).GetField(
        "_disposeRequested",
        System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic)
        ?? throw new InvalidOperationException("WebRTC session engine disposal barrier field is unavailable");
    return field.GetValue(engine) is int value && value != 0;
}

static async Task TestWebRtcRouteBindingStaleStopPreservesReplacement()
{
    const string fingerprint = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    var snapshot = await BuildResolvedDiscoverySnapshotAsync(fingerprint);
    var candidate = snapshot.Peers.Single(peer => peer.Peer.ServiceKind == CoreDiscoveryServiceKind.RemoteControl);
    var secureStore = new WebRtcProductSecureSessionStore();
    var routeStore = new WebRtcAuthenticatedRouteBindingStore(secureStore);
    var controlPlaneA = new RetainingCallbackProductControlPlane();
    var contextA = TransportOnlyWebRtcContext(
        controlPlaneA,
        peerDeviceId: "mac-1",
        peerPublicKeyFingerprint: fingerprint,
        role: "answer");
    var keysA = CreatePairedWebRtcSessionKeys();
    using var initiatorA = keysA.Initiator;
    using var responderA = keysA.Responder;
    var establishedA = secureStore.InstallEstablishedSession(
        contextA,
        responderA,
        WebRtcProductHandshakeCodec.SuiteMlKem768Mldsa65);
    var leaseA = await routeStore.StartAsync(establishedA);

    var contextB = contextA with { ControlPlane = new FakeProductControlPlane() };
    var keysB = CreatePairedWebRtcSessionKeys();
    using var initiatorB = keysB.Initiator;
    using var responderB = keysB.Responder;
    var establishedB = secureStore.InstallEstablishedSession(
        contextB,
        responderB,
        WebRtcProductHandshakeCodec.SuiteMlKem768Mldsa65);
    var leaseB = await routeStore.StartAsync(establishedB);

    controlPlaneA.InvokeRemovedHandler(WebRtcControlChannelCodec.EncryptAppPayload(
        Encoding.UTF8.GetBytes("{}"),
        initiatorA,
        WebRtcAppSecurePacketType.AppControl,
        counter: 1));

    await routeStore.StopAsync(leaseA);
    var afterStaleStop = routeStore.Capture(candidate, DateTimeOffset.UtcNow);
    Require(afterStaleStop.Session is not null, "stale route Stop(A) must not remove replacement route session B");
    Require(
        afterStaleStop.Session!.SessionId == responderB.SessionId,
        "route snapshot must remain bound to replacement session B after stale Stop(A)");

    await routeStore.StopAsync(leaseB);
    var afterExactStop = routeStore.Capture(candidate, DateTimeOffset.UtcNow);
    Require(afterExactStop.Session is null, "exact route Stop(B) must remove replacement route session B");
    Require(secureStore.Clear(establishedB), "test cleanup must clear exact secure session B");
}

static Task TestWindowsNativeRuntimeFactoryWiresProductControlRouteBindingAuthority()
{
    var repositoryRoot = FindRepositoryRoot();
    var source = File.ReadAllText(Path.Combine(
        repositoryRoot,
        "windows",
        "Skybridge.WinClient",
        "WindowsNativeRuntimeDependencyFactory.cs"));

    Require(
        source.Contains("new WebRtcAuthenticatedRouteBindingStore(secureSessionStore)", StringComparison.Ordinal),
        "production factory must create a route-binding store from the secure session store");
    Require(
        source.Contains("new ProductSessionActionGateClient(authenticatedRouteBindingStore)", StringComparison.Ordinal),
        "production factory must inject the route-binding store into the product action gate");
    Require(
        source.Contains("new WebRtcProductSecureSessionRuntimeConsumer(", StringComparison.Ordinal),
        "production factory must establish a secure session before starting route-binding consumers");
    Require(
        source.Contains("new IWebRtcProductControlRuntimeConsumer[] { authenticatedRouteBindingStore }", StringComparison.Ordinal),
        "route-binding store must be downstream of the secure-session runtime consumer");
    Require(
        !source.Contains("CreateWebRtcProductControlRuntimeConsumersFromEnvironment());", StringComparison.Ordinal),
        "production factory must not use the old product-control runtime consumer composition with an unavailable gate");
    var secureSessionStoreSource = File.ReadAllText(Path.Combine(
        repositoryRoot,
        "windows",
        "Skybridge.WinClient",
        "Services",
        "WebRtcProductSecureSessionStore.cs"));
    var secureRuntimeSource = File.ReadAllText(Path.Combine(
        repositoryRoot,
        "windows",
        "Skybridge.WinClient",
        "Services",
        "WebRtcProductSecureSessionRuntimeConsumer.cs"));
    Require(
        secureSessionStoreSource.Contains("ClearAllForGlobalShutdown", StringComparison.Ordinal) &&
        !secureSessionStoreSource.Contains("ClearAll()", StringComparison.Ordinal),
        "secure session store must expose only an explicitly named ownerless global-shutdown clear");
    Require(
        secureRuntimeSource.Split("ClearAllForGlobalShutdown", StringSplitOptions.None).Length == 2 &&
        secureRuntimeSource.Contains("public void Dispose()", StringComparison.Ordinal),
        "ownerless secure-session clear must be called exactly once from the global Dispose boundary");
    return Task.CompletedTask;
}

static async Task TestWebRtcAuthenticatedRouteBindingConsumerWritesActionGateSnapshot()
{
    const string fingerprint = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    var now = DateTimeOffset.UtcNow;
    var snapshot = await BuildResolvedDiscoverySnapshotAsync(fingerprint);
    var remote = snapshot.Peers.Single(peer => peer.Peer.ServiceKind == CoreDiscoveryServiceKind.RemoteControl);
    var file = snapshot.Peers.Single(peer => peer.Peer.ServiceKind == CoreDiscoveryServiceKind.FileTransfer);
    var planes = PairedProductControlPlanes.Create();
    var keys = CreatePairedWebRtcSessionKeys();
    using var initiatorKeys = keys.Initiator;
    using var responderKeys = keys.Responder;
    var context = EstablishedWebRtcContext(
        planes.Responder,
        peerDeviceId: "mac-1",
        peerPublicKeyFingerprint: fingerprint,
        role: "answer");
    var store = new WebRtcAuthenticatedRouteBindingStore(
        new StaticWebRtcAppSessionKeyProvider(responderKeys));

    var storeLease = await store.StartAsync(context);
    try
    {
        await planes.Initiator.SendAsync(SealRouteBinding(
            initiatorKeys,
            ProductSessionActionKind.RemoteDesktop,
            remote.Routes.RemoteDesktop!,
            fingerprint,
            sessionHashHex: LowerHex16(WebRtcAppSecureEnvelope.SessionIdHash(initiatorKeys.SessionId)),
            transcriptPrefixHex: LowerHex16(WebRtcAppSecureEnvelope.TranscriptPrefix(initiatorKeys.TranscriptHash.Span)),
            sentAt: now,
            expiresAt: now.AddMinutes(2),
            counter: 1));

        await planes.Initiator.SendAsync(SealRouteBinding(
            initiatorKeys,
            ProductSessionActionKind.FileTransfer,
            file.Routes.FileTransfer!,
            fingerprint,
            sessionHashHex: LowerHex16(WebRtcAppSecureEnvelope.SessionIdHash(initiatorKeys.SessionId)),
            transcriptPrefixHex: LowerHex16(WebRtcAppSecureEnvelope.TranscriptPrefix(initiatorKeys.TranscriptHash.Span)),
            sentAt: now,
            expiresAt: now.AddMinutes(2),
            counter: 2));

        var gate = new ProductSessionActionGateClient(store);
        var remoteReady = gate.EvaluateRemoteDesktop(remote, now);
        Require(remoteReady.IsReady, "route-binding consumer must enable the matching remote desktop action");
        Require(remoteReady.Target?.Endpoint?.Port == 5901, "remote desktop action must preserve the resolved endpoint");
        Require(
            remoteReady.Target?.Endpoint?.Service == SkyBridgeProtocolConstants.RemoteDesktopDnsSdService,
            "stored remote route binding must use the canonical service type");

        var fileReady = gate.EvaluateFileTransfer(file, now);
        Require(fileReady.IsReady, "route-binding consumer must enable the matching file-transfer action");
        Require(fileReady.Target?.Endpoint?.Port == 9443, "file-transfer action must preserve the resolved endpoint");
        Require(
            fileReady.Target?.Endpoint?.Service == SkyBridgeProtocolConstants.FileTransferDnsSdService,
            "stored file route binding must use the canonical service type");

        var mismatchedCandidate = remote with
        {
            Peer = remote.Peer with { PublicKeyFingerprint = new string('b', 64) }
        };
        var mismatch = gate.EvaluateRemoteDesktop(mismatchedCandidate, now);
        Require(!mismatch.IsReady, "route-binding snapshot must not enable a fingerprint-mismatched candidate");
        Require(
            mismatch.DisabledReason == ProductSessionActionDisabledReason.PeerFingerprintMismatch,
            "fingerprint mismatch must remain explicit");
    }
    finally
    {
        await store.StopAsync(storeLease);
    }

    var badStore = new WebRtcAuthenticatedRouteBindingStore(
        new StaticWebRtcAppSessionKeyProvider(responderKeys));
    var badStoreLease = await badStore.StartAsync(context);
    try
    {
        await planes.Initiator.SendAsync(SealRouteBinding(
            initiatorKeys,
            ProductSessionActionKind.RemoteDesktop,
            remote.Routes.RemoteDesktop!,
            fingerprint,
            sessionHashHex: "1111111111111111",
            transcriptPrefixHex: LowerHex16(WebRtcAppSecureEnvelope.TranscriptPrefix(initiatorKeys.TranscriptHash.Span)),
            sentAt: now,
            expiresAt: now.AddMinutes(2),
            counter: 3));

        var blocked = new ProductSessionActionGateClient(badStore).EvaluateRemoteDesktop(remote, now);
        Require(!blocked.IsReady, "session hash mismatch must fail closed and leave the action disabled");
        Require(
            blocked.DisabledReason == ProductSessionActionDisabledReason.MissingEstablishedProductControlSession,
            "session hash mismatch must clear the established route-binding session snapshot");
    }
    finally
    {
        await badStore.StopAsync(badStoreLease);
    }
}

static async Task TestWebRtcAuthenticatedRouteBindingTimestampOverflowFailsClosed()
{
    const string fingerprint = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";
    var now = DateTimeOffset.UtcNow;
    var snapshot = await BuildResolvedDiscoverySnapshotAsync(fingerprint);
    var remote = snapshot.Peers.Single(peer => peer.Peer.ServiceKind == CoreDiscoveryServiceKind.RemoteControl);
    var planes = PairedProductControlPlanes.Create();
    var keys = CreatePairedWebRtcSessionKeys();
    using var initiatorKeys = keys.Initiator;
    using var responderKeys = keys.Responder;
    var context = EstablishedWebRtcContext(
        planes.Responder,
        peerDeviceId: "mac-1",
        peerPublicKeyFingerprint: fingerprint,
        role: "answer");
    var store = new WebRtcAuthenticatedRouteBindingStore(
        new StaticWebRtcAppSessionKeyProvider(responderKeys));

    var storeLease = await store.StartAsync(context);
    try
    {
        var payload = RouteBindingJson(
            ProductSessionActionKind.RemoteDesktop,
            remote.Routes.RemoteDesktop!,
            fingerprint,
            sessionHashHex: LowerHex16(WebRtcAppSecureEnvelope.SessionIdHash(initiatorKeys.SessionId)),
            transcriptPrefixHex: LowerHex16(WebRtcAppSecureEnvelope.TranscriptPrefix(initiatorKeys.TranscriptHash.Span)),
            sentAt: now,
            expiresAt: now.AddMinutes(2),
            sentAtLiteral: "100000000000000000000.0",
            expiresAtLiteral: "100000000000000000001.0");
        await planes.Initiator.SendAsync(SealRouteBindingJson(initiatorKeys, payload, counter: 1));

        var blocked = new ProductSessionActionGateClient(store).EvaluateRemoteDesktop(remote, now);
        Require(!blocked.IsReady, "timestamp overflow must fail closed and disable the action");
        Require(
            blocked.DisabledReason == ProductSessionActionDisabledReason.MissingEstablishedProductControlSession,
            "timestamp overflow must clear the established route-binding session snapshot");
    }
    finally
    {
        await store.StopAsync(storeLease);
    }
}

static async Task TestRemoteDesktopActionsRevalidateProductGateBeforeExecution()
{
    const string fingerprint = "cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd";
    var now = DateTimeOffset.UtcNow;
    var snapshot = await BuildResolvedDiscoverySnapshotAsync(fingerprint);
    var remote = snapshot.Peers.Single(peer => peer.Peer.ServiceKind == CoreDiscoveryServiceKind.RemoteControl);
    var blockedClient = new TrackingRemoteDesktopWorkspaceClient();
    var blockedState = new ConnectionWorkspaceValidatedState(remote.Peer, remote, null, null);
    var blockedActions = new RemoteDesktopWorkspaceActions(
        BuildBusyCoordinator(out var blockedStatus, out var blockedRemoteStatus),
        blockedClient,
        new ProductSessionActionGateClient(),
        () => blockedState,
        () => "Medium",
        () => "Fps60",
        value => blockedRemoteStatus.Value = value,
        value => blockedStatus.Value = value);

    await blockedActions.RecommendedConnectAsync();
    Require(blockedClient.RecommendedCalls == 0, "blocked remote desktop action must not call the workspace client");
    Require(
        blockedRemoteStatus.Value.Contains("MissingEstablishedProductControlSession", StringComparison.Ordinal),
        "blocked remote desktop status must expose the disabled reason");

    var allowedClient = new TrackingRemoteDesktopWorkspaceClient();
    var allowedActions = new RemoteDesktopWorkspaceActions(
        BuildBusyCoordinator(out var allowedStatus, out var allowedRemoteStatus),
        allowedClient,
        new ProductSessionActionGateClient(
            new StaticProductControlSessionSnapshotClient(
                EstablishedSession("session-mac-1", "mac-1", fingerprint, now.AddMinutes(5)) with
                {
                    AuthenticatedRouteBindings = new[]
                    {
                        AuthenticatedRouteBinding(ProductSessionActionKind.RemoteDesktop, remote.Routes.RemoteDesktop!, now.AddMinutes(5))
                    }
                })),
        () => blockedState,
        () => "Medium",
        () => "Fps60",
        value => allowedRemoteStatus.Value = value,
        value => allowedStatus.Value = value);

    await allowedActions.RecommendedConnectAsync();
    Require(allowedClient.RecommendedCalls == 1, "ready remote desktop action must call the workspace client exactly once");
    Require(allowedRemoteStatus.Value == "recommended-ran", "ready remote desktop action status mismatch");
}

static Task TestNativeDnsSdTxtCodecRejectsSeparatorInjection()
{
    var ok = NativeWindowsDnsSdTxtRecordCodec.TrySerialize(
        new[]
        {
            new KeyValuePair<string, string>("deviceId", "mac-1"),
            new KeyValuePair<string, string>("pubKeyFP", new string('a', 64)),
            new KeyValuePair<string, string>("platform", "macOS")
        },
        out var txtRecord,
        out var error);
    Require(ok, $"valid native DNS-SD TXT must serialize: {error}");
    Require(
        txtRecord == $"deviceId=mac-1;pubKeyFP={new string('a', 64)};platform=macOS",
        "valid native DNS-SD TXT serialization mismatch");

    ok = NativeWindowsDnsSdTxtRecordCodec.TrySerialize(
        new[] { new KeyValuePair<string, string>("name", " Desk Mac ") },
        out txtRecord,
        out error);
    Require(ok, $"TXT value whitespace must serialize without mutation: {error}");
    Require(txtRecord == "name= Desk Mac ", "TXT value whitespace must be preserved");

    RequireRejectsNativeDnsSdTxt(
        "TXT semicolon injection must be rejected",
        new KeyValuePair<string, string>("name", "Desk;deviceId=attacker"));
    ok = NativeWindowsDnsSdTxtRecordCodec.TrySerialize(
        new[] { new KeyValuePair<string, string>("name", "Desk=Mac") },
        out txtRecord,
        out error);
    Require(ok, $"TXT value equals must serialize because Core splits only the first equals: {error}");
    Require(txtRecord == "name=Desk=Mac", "TXT value equals serialization mismatch");
    RequireRejectsNativeDnsSdTxt(
        "TXT NUL/control character must be rejected",
        new KeyValuePair<string, string>("name", "Desk\u0000Mac"));
    RequireRejectsNativeDnsSdTxt(
        "TXT key control character must be rejected",
        new KeyValuePair<string, string>("bad\nkey", "value"));
    RequireRejectsNativeDnsSdTxt(
        "TXT key separator must be rejected",
        new KeyValuePair<string, string>("bad;key", "value"));
    RequireRejectsNativeDnsSdTxt(
        "TXT key equals separator must be rejected",
        new KeyValuePair<string, string>("bad=key", "value"));
    RequireRejectsNativeDnsSdTxt(
        "TXT key leading whitespace must be rejected",
        new KeyValuePair<string, string>(" deviceId", "mac-1"));
    RequireRejectsNativeDnsSdTxt(
        "TXT key trailing whitespace must be rejected",
        new KeyValuePair<string, string>("deviceId ", "mac-1"));
    RequireRejectsNativeDnsSdTxt(
        "duplicate TXT keys must be rejected",
        new KeyValuePair<string, string>("deviceId", "mac-1"),
        new KeyValuePair<string, string>("deviceId", "mac-2"));
    RequireRejectsNativeDnsSdTxt(
        "oversized TXT values must be rejected",
        new KeyValuePair<string, string>("name", new string('x', 1025)));
    RequireRejectsNativeDnsSdTxt(
        "too many TXT properties must be rejected",
        Enumerable
            .Range(0, NativeWindowsDnsSdTxtRecordCodec.MaxTxtProperties + 1)
            .Select(index => new KeyValuePair<string, string>($"k{index}", "v"))
            .ToArray());
    RequireRejectsNativeDnsSdTxt(
        "oversized TXT records must be rejected",
        new KeyValuePair<string, string>("k0", new string('x', NativeWindowsDnsSdTxtRecordCodec.MaxTxtValueBytes)),
        new KeyValuePair<string, string>("k1", new string('x', NativeWindowsDnsSdTxtRecordCodec.MaxTxtValueBytes)),
        new KeyValuePair<string, string>("k2", new string('x', NativeWindowsDnsSdTxtRecordCodec.MaxTxtValueBytes)),
        new KeyValuePair<string, string>("k3", new string('x', NativeWindowsDnsSdTxtRecordCodec.MaxTxtValueBytes)));

    return Task.CompletedTask;
}

static Task TestWebRtcFileTransferWireUsesCrossNetworkOpSchema()
{
    var transferId = WebRtcFileTransferProofPayloads.NewTransferId();
    Require(
        Guid.TryParseExact(transferId, "D", out var parsed) &&
        string.Equals(parsed.ToString("D"), transferId, StringComparison.Ordinal),
        "Windows FileTransfer proof transferId must be canonical UUID");

    var payload = Encoding.UTF8.GetBytes("file-transfer-contract-payload-v1");
    var fileSha256 = Convert.ToHexString(SHA256.HashData(payload)).ToLowerInvariant();
    var manifest = ParseJson(WebRtcFileTransferProofPayloads.BuildManifestPayload(transferId, payload.Length, fileSha256));
    using (manifest)
    {
        var root = manifest.RootElement;
        Require(!root.TryGetProperty("type", out _), "CrossNetwork file-transfer metadata must not use legacy type field");
        Require(JsonString(root, "op") == "metadata", "metadata op mismatch");
        Require(JsonString(root, "transferId") == transferId, "metadata transferId mismatch");
        Require(JsonInt(root, "version") == 1, "metadata version mismatch");
        Require(JsonInt(root, "chunkSize") == payload.Length, "metadata chunkSize mismatch");
        Require(JsonInt(root, "totalChunks") == 1, "metadata totalChunks mismatch");
        Require(JsonBase64(root, "fileSha256").SequenceEqual(SHA256.HashData(payload)), "metadata fileSha256 must be base64 SHA-256 bytes");
    }

    var chunk = ParseJson(WebRtcFileTransferProofPayloads.BuildChunkPayload(transferId, payload, fileSha256));
    using (chunk)
    {
        var root = chunk.RootElement;
        Require(!root.TryGetProperty("type", out _), "CrossNetwork file-transfer chunk must not use legacy type field");
        Require(JsonString(root, "op") == "chunk", "chunk op mismatch");
        Require(JsonInt(root, "chunkIndex") == 0, "chunk index mismatch");
        Require(JsonBase64(root, "chunkData").SequenceEqual(payload), "chunkData must be base64 file bytes");
        Require(JsonBase64(root, "chunkSha256").SequenceEqual(SHA256.HashData(payload)), "chunkSha256 must be base64 SHA-256 bytes");
        Require(JsonInt(root, "rawSize") == payload.Length, "chunk rawSize mismatch");
    }

    var complete = ParseJson(WebRtcFileTransferProofPayloads.BuildCompletePayload(transferId, payload.Length, fileSha256));
    using (complete)
    {
        var root = complete.RootElement;
        Require(!root.TryGetProperty("type", out _), "CrossNetwork file-transfer complete must not use legacy type field");
        Require(JsonString(root, "op") == "complete", "complete op mismatch");
        Require(JsonInt(root, "receivedBytes") == payload.Length, "complete receivedBytes mismatch");
        Require(JsonBase64(root, "fileSha256").SequenceEqual(SHA256.HashData(payload)), "complete fileSha256 must be base64 SHA-256 bytes");
    }

    var completeAck = ParseJson(WebRtcFileTransferProofPayloads.BuildCompleteAckPayload(transferId, payload.Length, fileSha256));
    using (completeAck)
    {
        var root = completeAck.RootElement;
        Require(!root.TryGetProperty("type", out _), "CrossNetwork file-transfer completeAck must not use legacy type field");
        Require(JsonString(root, "op") == "completeAck", "completeAck op mismatch");
        Require(JsonInt(root, "receivedBytes") == payload.Length, "completeAck receivedBytes mismatch");
        Require(JsonBase64(root, "fileSha256").SequenceEqual(SHA256.HashData(payload)), "completeAck fileSha256 must be base64 SHA-256 bytes");
    }

    return Task.CompletedTask;
}

static async Task TestWebRtcFileTransferProofRoundTrip()
{
    using var temp = TempDir.Create();
    var planes = PairedProductControlPlanes.Create();
    var keys = CreatePairedWebRtcSessionKeys();
    using var initiatorKeys = keys.Initiator;
    using var responderKeys = keys.Responder;
    var options = new WebRtcFileTransferProofOptions(TimeSpan.FromSeconds(2));
    var client = new WebRtcFileTransferProofClient(options);
    var responder = new WebRtcFileTransferResponderHost(options);
    var payload = Encoding.UTF8.GetBytes("file-transfer-contract-payload-v1");

    var responderTask = responder.ReceiveSingleChunkAndAckAsync(planes.Responder, responderKeys);
    var result = await client.ExchangeSingleChunkAsync(planes.Initiator, initiatorKeys, payload);
    var responderResult = await responderTask;

    Require(result.TransferredBytes == payload.Length, "file transfer proof sent byte count mismatch");
    Require(result.ChunkCount == 1, "file transfer proof must send one chunk");
    Require(result.ChunkAckCount == result.ChunkCount, "file transfer proof must ACK every chunk");
    Require(result.CompleteAckReceived, "file transfer proof must receive complete ACK");
    Require(result.ReceiptMatchesSentHash, "file transfer proof receipt hash mismatch");
    Require(result.SentFileSha256 == result.FileSha256Receipt, "file transfer proof receipt must equal source SHA");
    Require(result.ProductSendCount == 3, "file transfer proof must send manifest, chunk, and complete");
    Require(result.ProductReceiveCount == 3, "file transfer proof must receive manifest ACK, chunk ACK, and complete ACK");
    Require(responderResult.ReceivedBytes == payload.Length, "file transfer responder byte count mismatch");
    Require(responderResult.ChunkAckCount == responderResult.ChunkCount, "file transfer responder must ACK every chunk");
    Require(responderResult.CompleteAckSent, "file transfer responder must send complete ACK");
    Require(responderResult.ReceiptMatchesReceivedHash, "file transfer responder receipt hash mismatch");
    Require(result.SessionIdSha256 == responderResult.SessionIdSha256, "file transfer proof session hash mismatch");
    Require(result.TransferIdSha256 == responderResult.TransferIdSha256, "file transfer proof transfer hash mismatch");

    var evidencePath = Path.Combine(temp.Path, "file-transfer-local-loop-evidence.json");
    WebRtcFileTransferProofEvidenceWriter.WriteLocalLoopEvidence(evidencePath, result);
    var evidence = File.ReadAllText(evidencePath);
    Require(evidence.Contains("\"Profile\": \"windows-sbwc-file-transfer-local-loop\"", StringComparison.Ordinal), "file transfer evidence profile mismatch");
    Require(evidence.Contains("\"NotWindowsLiveFileTransferProof\": true", StringComparison.Ordinal), "file transfer evidence must keep live-proof boundary visible");
    Require(evidence.Contains("\"RawPayloadCaptured\": false", StringComparison.Ordinal), "file transfer evidence must not capture raw payload");
    Require(!evidence.Contains(initiatorKeys.SessionId, StringComparison.Ordinal), "file transfer evidence leaked raw session id");
    Require(!evidence.Contains("file-transfer-contract-payload", StringComparison.Ordinal), "file transfer evidence leaked raw payload");
    Require(!evidence.Contains(Convert.ToBase64String(payload), StringComparison.Ordinal), "file transfer evidence leaked encoded payload");
}

static async Task TestWebRtcFileTransferRejectsEmptyPayload()
{
    var planes = PairedProductControlPlanes.Create();
    var keys = CreatePairedWebRtcSessionKeys();
    using var initiatorKeys = keys.Initiator;
    using var responderKeys = keys.Responder;
    var client = new WebRtcFileTransferProofClient(new WebRtcFileTransferProofOptions(TimeSpan.FromSeconds(2)));

    _ = responderKeys;
    await RequireThrowsAsync<WebRtcFileTransferProofException>(
        () => client.ExchangeSingleChunkAsync(planes.Initiator, initiatorKeys, ReadOnlyMemory<byte>.Empty));
}

static async Task TestWebRtcFileTransferRejectsWrongPacketType()
{
    var planes = PairedProductControlPlanes.Create();
    var keys = CreatePairedWebRtcSessionKeys();
    using var initiatorKeys = keys.Initiator;
    using var responderKeys = keys.Responder;
    var options = new WebRtcFileTransferProofOptions(TimeSpan.FromSeconds(2));
    var responder = new WebRtcFileTransferResponderHost(options);
    var responderTask = responder.ReceiveSingleChunkAndAckAsync(planes.Responder, responderKeys);
    var appControlPayload = Encoding.UTF8.GetBytes("{\"ping\":{\"id\":1}}");
    var wrongPacket = WebRtcControlChannelCodec.EncryptAppPayload(
        appControlPayload,
        initiatorKeys,
        WebRtcAppSecurePacketType.AppControl,
        counter: 1);

    await planes.Initiator.SendAsync(wrongPacket);
    var error = await RequireThrowsAsync<WebRtcFileTransferProofException>(() => responderTask);
    Require(error.InnerException is WebRtcAppSecureEnvelopeException, "wrong packet type must fail during SBWC packet authentication");
}

static SessionAuthority TestSessionAuthority() =>
    new(
        "https://hloqytmhjludmuhwyyzb.supabase.co/auth/v1",
        "authenticated",
        "authenticated");

static PersistedSession BuildPersistedSession(
    string subject = "user-1",
    SessionAuthority? authority = null,
    string? accessToken = null,
    string displayName = "User")
{
    authority ??= TestSessionAuthority();
    return new PersistedSession
    {
        SchemaVersion = PersistedSession.CurrentSchemaVersion,
        Authority = authority,
        Subject = subject,
        AccessToken = accessToken ?? BuildJwt(DateTimeOffset.UtcNow.AddHours(1), subject, authority),
        RefreshToken = "refresh",
        DisplayName = displayName,
        IssuedAtUnix = DateTimeOffset.UtcNow.ToUnixTimeSeconds()
    };
}

static AuthToken BuildAuthToken(string subject = "user-1") =>
    new()
    {
        AccessToken = BuildJwt(DateTimeOffset.UtcNow.AddHours(1), subject),
        RefreshToken = $"refresh-{subject}",
        User = BuildAuthUser(subject)
    };

static AuthUser BuildAuthUser(string subject = "user-1") =>
    new()
    {
        Id = subject,
        Email = $"{subject}@example.com",
        UserMetadata = new AuthUserMetadata { DisplayName = $"User {subject}" }
    };

static string BuildJwt(
    DateTimeOffset expiresAt,
    string subject = "user-1",
    SessionAuthority? authority = null) =>
    BuildJwtWithUnixExpiry(expiresAt.ToUnixTimeSeconds(), subject, authority);

static string BuildJwtWithUnixExpiry(
    long expiresAtUnix,
    string subject = "user-1",
    SessionAuthority? authority = null)
{
    authority ??= TestSessionAuthority();
    var header = Base64Url("{}");
    var payload = Base64Url(JsonSerializer.Serialize(new
    {
        iss = authority.Issuer,
        sub = subject,
        exp = expiresAtUnix,
        role = authority.Role,
        aud = authority.Audience
    }));
    return $"{header}.{payload}.sig";
}

static string AuthenticatedRouteBindingJson(
    string kind,
    int port,
    string endpointProvenance = "resolved-dns-sd-endpoint",
    string nonceBase64 = "AQIDBAUGBwgJCgsMDQ4PEA==",
    string serviceType = SkyBridgeProtocolConstants.LegacyRemoteDesktopDnsSdService) =>
    $$"""
      {
        "authenticatedRouteBinding": {
          "version": 1,
          "kind": "{{kind}}",
          "serviceType": "{{serviceType}}",
          "instanceName": "Desk Mac._skybridge-remote._tcp.local",
          "hostName": "desk-mac.local",
          "port": {{port}},
          "endpointProvenance": "{{endpointProvenance}}",
          "localDeviceId": "mac-device",
          "remoteDeviceId": "windows-device",
          "routeAuthorityProtocolPublicKeyFingerprint": "{{new string('a', 64)}}",
          "remoteProtocolPublicKeyFingerprint": "{{new string('a', 64)}}",
          "sessionHashHex": "0123456789abcdef",
          "transcriptPrefixHex": "fedcba9876543210",
          "sentAt": 42.0,
          "expiresAt": 72.0,
          "nonce": "{{nonceBase64}}"
        }
      }
      """;

static string Base64Url(string value) =>
    Convert.ToBase64String(Encoding.UTF8.GetBytes(value))
        .TrimEnd('=')
        .Replace('+', '-')
        .Replace('/', '_');

static void Require(bool condition, string message)
{
    if (!condition)
    {
        throw new InvalidOperationException(message);
    }
}

static TException RequireThrows<TException>(Action action)
    where TException : Exception
{
    try
    {
        action();
    }
    catch (TException ex)
    {
        return ex;
    }

    throw new InvalidOperationException($"Expected {typeof(TException).Name}.");
}

static void RequireRejectsNativeDnsSdTxt(
    string message,
    params KeyValuePair<string, string>[] properties)
{
    var ok = NativeWindowsDnsSdTxtRecordCodec.TrySerialize(properties, out var txtRecord, out var error);
    Require(!ok, message);
    Require(string.IsNullOrEmpty(txtRecord), "rejected native DNS-SD TXT must not emit a record");
    Require(!string.IsNullOrWhiteSpace(error), "rejected native DNS-SD TXT must explain the failure");
}

static async Task<TException> RequireThrowsAsync<TException>(Func<Task> action)
    where TException : Exception
{
    try
    {
        await action();
    }
    catch (TException ex)
    {
        return ex;
    }

    throw new InvalidOperationException($"Expected {typeof(TException).Name}.");
}

static JsonDocument ParseJson(byte[] payload) =>
    JsonDocument.Parse(payload);

static string JsonString(JsonElement root, string name)
{
    Require(root.TryGetProperty(name, out var value), $"JSON field missing: {name}");
    Require(value.ValueKind == JsonValueKind.String, $"JSON field must be string: {name}");
    return value.GetString() ?? "";
}

static int JsonInt(JsonElement root, string name)
{
    Require(root.TryGetProperty(name, out var value), $"JSON field missing: {name}");
    Require(value.TryGetInt32(out var parsed), $"JSON field must be int: {name}");
    return parsed;
}

static byte[] JsonBase64(JsonElement root, string name)
{
    Require(root.TryGetProperty(name, out var value), $"JSON field missing: {name}");
    Require(value.ValueKind == JsonValueKind.String, $"JSON field must be base64 string: {name}");
    return value.GetBytesFromBase64();
}

static (WebRtcAppSecureSessionKeys Initiator, WebRtcAppSecureSessionKeys Responder) CreatePairedWebRtcSessionKeys()
{
    return TestWebRtcSessionKeyMaterial.CreatePaired();
}

static byte[] SealRouteBinding(
    WebRtcAppSecureSessionKeys senderKeys,
    ProductSessionActionKind kind,
    DiscoveryPeerEndpoint endpoint,
    string authorityFingerprint,
    string sessionHashHex,
    string transcriptPrefixHex,
    DateTimeOffset sentAt,
    DateTimeOffset expiresAt,
    ulong counter)
{
    var payload = Encoding.UTF8.GetBytes(RouteBindingJson(
        kind,
        endpoint,
        authorityFingerprint,
        sessionHashHex,
        transcriptPrefixHex,
        sentAt,
        expiresAt));
    return WebRtcControlChannelCodec.EncryptAppPayload(
        payload,
        senderKeys,
        WebRtcAppSecurePacketType.AppControl,
        counter);
}

static byte[] SealRouteBindingJson(
    WebRtcAppSecureSessionKeys senderKeys,
    string json,
    ulong counter)
{
    return WebRtcControlChannelCodec.EncryptAppPayload(
        Encoding.UTF8.GetBytes(json),
        senderKeys,
        WebRtcAppSecurePacketType.AppControl,
        counter);
}

static string RouteBindingJson(
    ProductSessionActionKind kind,
    DiscoveryPeerEndpoint endpoint,
    string authorityFingerprint,
    string sessionHashHex,
    string transcriptPrefixHex,
    DateTimeOffset sentAt,
    DateTimeOffset expiresAt,
    string? sentAtLiteral = null,
    string? expiresAtLiteral = null,
    string remoteDeviceId = "windows-device",
    string? remoteProtocolPublicKeyFingerprint = null)
{
    var kindText = kind switch
    {
        ProductSessionActionKind.FileTransfer => "fileTransfer",
        ProductSessionActionKind.RemoteDesktop => "remoteDesktop",
        _ => throw new ArgumentOutOfRangeException(nameof(kind), kind, "Unknown product action kind.")
    };
    var nonceBase64 = Convert.ToBase64String(Enumerable.Range(1, 16).Select(value => (byte)value).ToArray());
    return $$"""
      {
        "authenticatedRouteBinding": {
          "version": 1,
          "kind": "{{kindText}}",
          "serviceType": "{{endpoint.Service}}",
          "instanceName": "{{endpoint.InstanceName}}",
          "hostName": "{{endpoint.HostName}}",
          "port": {{endpoint.Port}},
          "endpointProvenance": "{{endpoint.Provenance}}",
          "localDeviceId": "mac-1",
          "remoteDeviceId": "{{remoteDeviceId}}",
          "routeAuthorityProtocolPublicKeyFingerprint": "{{authorityFingerprint}}",
          "remoteProtocolPublicKeyFingerprint": "{{remoteProtocolPublicKeyFingerprint ?? authorityFingerprint}}",
          "sessionHashHex": "{{sessionHashHex}}",
          "transcriptPrefixHex": "{{transcriptPrefixHex}}",
          "sentAt": {{sentAtLiteral ?? SwiftDateSeconds(sentAt).ToString("R", System.Globalization.CultureInfo.InvariantCulture)}},
          "expiresAt": {{expiresAtLiteral ?? SwiftDateSeconds(expiresAt).ToString("R", System.Globalization.CultureInfo.InvariantCulture)}},
          "nonce": "{{nonceBase64}}"
        }
      }
      """;
}

static LiveWebRtcProductControlContext EstablishedWebRtcContext(
    IWebRtcProductControlPlane controlPlane,
    string peerDeviceId,
    string peerPublicKeyFingerprint,
    string role,
    string localDeviceId = "windows-device",
    string? localPublicKeyFingerprint = null) =>
    new(
        controlPlane,
        peerDeviceId,
        peerPublicKeyFingerprint,
        role,
        "mac-product-control-v1",
        "skybridge",
        $"contract/{role}/binding",
        "127.0.0.1:1111",
        "127.0.0.1:2222",
        "contract-candidate-pair",
        LateRemoteIceCandidateRelayCount: 0,
        TransportBindingDigestHex: new string('c', 64),
        TimestampWindowMs: 10_000,
        WebRtcProductControlSecureSessionState.Established,
        LocalDeviceId: localDeviceId,
        LocalPublicKeyFingerprint: localPublicKeyFingerprint ?? peerPublicKeyFingerprint);

static LiveWebRtcProductControlContext TransportOnlyWebRtcContext(
    IWebRtcProductControlPlane controlPlane,
    string peerDeviceId,
    string peerPublicKeyFingerprint,
    string role) =>
    EstablishedWebRtcContext(
        controlPlane,
        peerDeviceId,
        peerPublicKeyFingerprint,
        role) with
    {
        SecureSessionState = WebRtcProductControlSecureSessionState.TransportOnly
    };

static string LowerHex16(ulong value) =>
    value.ToString("x16", System.Globalization.CultureInfo.InvariantCulture);

static double SwiftDateSeconds(DateTimeOffset value) =>
    (value.ToUniversalTime() - new DateTimeOffset(2001, 1, 1, 0, 0, 0, TimeSpan.Zero)).TotalSeconds;

static Task<DiscoveryBrowserSnapshot> BuildResolvedDiscoverySnapshotAsync(string fingerprint)
{
    var browser = new WindowsDiscoveryBrowserClient(
        new StaticDiscoveryClient(fingerprint),
        new StaticDnsSdBrowseClient(
            new WindowsDnsSdResolvedTxtRecord(
                "_skybridge-transfer._tcp",
                $"deviceId=mac-1;name=Desk Mac;pubKeyFP={fingerprint};capabilities=file_transfer;port=7777",
                "Desk Mac._skybridge-transfer._tcp.local",
                "desk-mac.local",
                9443),
            new WindowsDnsSdResolvedTxtRecord(
                SkyBridgeProtocolConstants.RemoteDesktopDnsSdService,
                $"deviceId=mac-1;name=Desk Mac;pubKeyFP={fingerprint};capabilities=remote_desktop;remoteControlPort=7778",
                "Desk Mac._skybridge-rd._tcp.local",
                "desk-mac.local",
                5901)));

    return browser.BuildReadOnlySnapshotAsync(
        new DiscoveryBrowserRequest(
            DiscoveryBrowserAction.Start,
            "",
            "",
            "",
            CompatibilityMode: false,
            ExtendedSearchSeconds: 2));
}

static EstablishedProductControlSessionSnapshot EstablishedSession(
    string sessionId,
    string remoteDeviceId,
    string fingerprint,
    DateTimeOffset expiresAtUtc,
    string secureSessionState = "Established") =>
    new(
        sessionId,
        remoteDeviceId,
        fingerprint,
        secureSessionState,
        expiresAtUtc);

static AuthenticatedProductRouteBinding AuthenticatedRouteBinding(
    ProductSessionActionKind kind,
    DiscoveryPeerEndpoint endpoint,
    DateTimeOffset expiresAtUtc) =>
    new(
        kind,
        endpoint.Service,
        endpoint.HostName,
        endpoint.Port,
        endpoint.InstanceName,
        endpoint.Provenance,
        expiresAtUtc);

static string FindRepositoryRoot()
{
    var directory = new DirectoryInfo(AppContext.BaseDirectory);
    while (directory is not null)
    {
        if (Directory.Exists(Path.Combine(directory.FullName, "windows", "Skybridge.WinClient")) &&
            Directory.Exists(Path.Combine(directory.FullName, "windows", "Skybridge.WinClient.ContractTests")))
        {
            return directory.FullName;
        }

        directory = directory.Parent;
    }

    throw new DirectoryNotFoundException("Could not locate the Skybridge-Compass repository root.");
}

static WorkspaceBusyCoordinator BuildBusyCoordinator(
    out MutableString status,
    out MutableString remoteDesktopStatus)
{
    var isBusy = false;
    status = new MutableString();
    remoteDesktopStatus = new MutableString();
    var capturedStatus = status;
    var capturedRemoteDesktopStatus = remoteDesktopStatus;
    return new WorkspaceBusyCoordinator(
        () => isBusy,
        value => isBusy = value,
        new WorkspaceStatusPatchApplier(
            value => capturedStatus.Value = value,
            _ => { },
            _ => { },
            _ => { },
            _ => { },
            _ => { },
            _ => { },
            _ => { },
            _ => { },
            _ => { },
            _ => { },
            value => capturedRemoteDesktopStatus.Value = value,
            _ => { },
            _ => { }),
        new WorkspaceErrorStatusClient());
}

sealed class MutableString
{
    public string Value { get; set; } = "";
}

sealed class StaticProductControlSessionSnapshotClient : IProductControlSessionSnapshotClient
{
    private readonly EstablishedProductControlSessionSnapshot? _session;

    public StaticProductControlSessionSnapshotClient(EstablishedProductControlSessionSnapshot? session)
    {
        _session = session;
    }

    public ProductControlSessionSnapshotResult Capture(
        DiscoveryBrowserPeerCandidate candidate,
        DateTimeOffset nowUtc) =>
        new(_session, _session is null ? ProductControlSessionSnapshotUnavailableReason.NoEstablishedSession : null, "static test session snapshot");
}

static class TestWebRtcSessionKeyMaterial
{
    public static (WebRtcAppSecureSessionKeys Initiator, WebRtcAppSecureSessionKeys Responder) CreatePaired()
    {
        var sessionId = "contract-session-" + Guid.NewGuid().ToString("N");
        var transcriptHash = Hash32("contract-transcript");
        var initiatorToResponderKey = Hash32("contract-initiator-to-responder-key");
        var responderToInitiatorKey = Hash32("contract-responder-to-initiator-key");
        return (
            new WebRtcAppSecureSessionKeys(
                WebRtcAppSecureRole.Initiator,
                sessionId,
                transcriptHash,
                initiatorToResponderKey,
                responderToInitiatorKey),
            new WebRtcAppSecureSessionKeys(
                WebRtcAppSecureRole.Responder,
                sessionId,
                transcriptHash,
                responderToInitiatorKey,
                initiatorToResponderKey));
    }

    private static byte[] Hash32(string label) =>
        SHA256.HashData(Encoding.UTF8.GetBytes(label));
}

sealed class StaticSecureSessionEstablisher : IWebRtcProductSecureSessionEstablisher
{
    private readonly WebRtcProductControlSecureSessionState _returnedState;

    public StaticSecureSessionEstablisher(WebRtcProductControlSecureSessionState returnedState)
    {
        _returnedState = returnedState;
    }

    public Task<LiveWebRtcProductControlContext> EstablishAsync(
        LiveWebRtcProductControlContext transportContext,
        CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        return Task.FromResult(transportContext with { SecureSessionState = _returnedState });
    }
}

sealed class InstallingSecureSessionEstablisher :
    IWebRtcProductSecureSessionEstablisher,
    IDisposable
{
    private readonly WebRtcProductSecureSessionStore _sessionStore;
    private int _disposeFailuresRemaining;
    private bool _disposed;

    public InstallingSecureSessionEstablisher(
        WebRtcProductSecureSessionStore sessionStore,
        int disposeFailures = 0)
    {
        if (disposeFailures < 0)
        {
            throw new ArgumentOutOfRangeException(nameof(disposeFailures));
        }

        _sessionStore = sessionStore ?? throw new ArgumentNullException(nameof(sessionStore));
        _disposeFailuresRemaining = disposeFailures;
    }

    public int EstablishCalls { get; private set; }

    public LiveWebRtcProductControlContext? LastEstablishedContext { get; private set; }

    public int DisposeAttempts { get; private set; }

    public int DisposeCalls { get; private set; }

    public Task<LiveWebRtcProductControlContext> EstablishAsync(
        LiveWebRtcProductControlContext transportContext,
        CancellationToken cancellationToken = default)
    {
        if (_disposed)
        {
            throw new ObjectDisposedException(nameof(InstallingSecureSessionEstablisher));
        }

        ArgumentNullException.ThrowIfNull(transportContext);
        cancellationToken.ThrowIfCancellationRequested();
        EstablishCalls++;
        if (transportContext.SecureSessionState != WebRtcProductControlSecureSessionState.TransportOnly)
        {
            throw new InvalidOperationException("test establisher requires a TransportOnly context");
        }

        var keys = TestWebRtcSessionKeyMaterial.CreatePaired();
        var roleKeys = transportContext.Role switch
        {
            "offer" => keys.Initiator,
            "answer" => keys.Responder,
            _ => throw new InvalidOperationException("test establisher requires role offer or answer")
        };
        using var initiatorKeys = keys.Initiator;
        using var responderKeys = keys.Responder;
        LastEstablishedContext = _sessionStore.InstallEstablishedSession(
            transportContext,
            roleKeys,
            WebRtcProductHandshakeCodec.SuiteMlKem768Mldsa65);
        return Task.FromResult(LastEstablishedContext);
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        DisposeAttempts++;
        if (_disposeFailuresRemaining > 0)
        {
            _disposeFailuresRemaining--;
            throw new InvalidOperationException("injected secure-session establisher disposal failure");
        }

        DisposeCalls++;
        _disposed = true;
    }
}

sealed class TrackingProductControlRuntimeConsumer :
    IWebRtcProductControlRuntimeConsumer,
    IDisposable
{
    private readonly bool _throwOnStart;
    private readonly bool _requireEstablishedContext;
    private int _stopFailuresRemaining;
    private int _disposeFailuresRemaining;
    private bool _disposed;

    public TrackingProductControlRuntimeConsumer(
        bool throwOnStart = false,
        bool requireEstablishedContext = true,
        int stopFailures = 0,
        int disposeFailures = 0)
    {
        if (stopFailures < 0 || disposeFailures < 0)
        {
            throw new ArgumentOutOfRangeException(
                stopFailures < 0 ? nameof(stopFailures) : nameof(disposeFailures));
        }

        _throwOnStart = throwOnStart;
        _requireEstablishedContext = requireEstablishedContext;
        _stopFailuresRemaining = stopFailures;
        _disposeFailuresRemaining = disposeFailures;
    }

    public int StartCalls { get; private set; }

    public int StopCalls { get; private set; }

    public int StopAttempts { get; private set; }

    public int DisposeAttempts { get; private set; }

    public int DisposeCalls { get; private set; }

    public LiveWebRtcProductControlContext? StartedContext { get; private set; }

    public WebRtcProductControlRuntimeLease? StartedLease { get; private set; }

    public WebRtcProductControlRuntimeLease? LastStartedLease { get; private set; }

    public WebRtcProductControlRuntimeLease? LastStoppedLease { get; private set; }

    public Task<WebRtcProductControlRuntimeLease> StartAsync(
        LiveWebRtcProductControlContext context,
        CancellationToken cancellationToken = default)
    {
        if (_disposed)
        {
            throw new ObjectDisposedException(nameof(TrackingProductControlRuntimeConsumer));
        }

        ArgumentNullException.ThrowIfNull(context);
        cancellationToken.ThrowIfCancellationRequested();
        StartCalls++;
        StartedContext = context;
        if (_throwOnStart)
        {
            throw new InvalidOperationException("injected downstream start failure");
        }

        if (_requireEstablishedContext &&
            context.SecureSessionState != WebRtcProductControlSecureSessionState.Established)
        {
            throw new InvalidOperationException("tracking downstream requires Established context");
        }

        var lease = WebRtcProductControlRuntimeLease.Create();
        StartedLease = lease;
        LastStartedLease = lease;
        return Task.FromResult(lease);
    }

    public Task StopAsync(
        WebRtcProductControlRuntimeLease lease,
        CancellationToken cancellationToken = default)
    {
        lease.RequireValid();
        cancellationToken.ThrowIfCancellationRequested();
        if (StartedLease != lease)
        {
            return Task.CompletedTask;
        }

        StopAttempts++;
        if (_stopFailuresRemaining > 0)
        {
            _stopFailuresRemaining--;
            throw new InvalidOperationException("injected downstream stop failure");
        }

        StopCalls++;
        LastStoppedLease = lease;
        StartedLease = null;
        return Task.CompletedTask;
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        DisposeAttempts++;
        if (StartedLease is not null)
        {
            throw new InvalidOperationException("test product consumer cannot be disposed while its runtime lease is active");
        }

        if (_disposeFailuresRemaining > 0)
        {
            _disposeFailuresRemaining--;
            throw new InvalidOperationException("injected product consumer disposal failure");
        }

        DisposeCalls++;
        _disposed = true;
    }
}

sealed class DelayedFailingProductControlRuntimeConsumer : IWebRtcProductControlRuntimeConsumer
{
    private readonly TaskCompletionSource _startEntered =
        new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly TaskCompletionSource _releaseFailure =
        new(TaskCreationOptions.RunContinuationsAsynchronously);

    public async Task<WebRtcProductControlRuntimeLease> StartAsync(
        LiveWebRtcProductControlContext context,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(context);
        cancellationToken.ThrowIfCancellationRequested();
        _startEntered.TrySetResult();
        await _releaseFailure.Task.WaitAsync(cancellationToken).ConfigureAwait(false);
        throw new InvalidOperationException("injected delayed downstream start failure");
    }

    public Task StopAsync(
        WebRtcProductControlRuntimeLease lease,
        CancellationToken cancellationToken = default)
    {
        lease.RequireValid();
        cancellationToken.ThrowIfCancellationRequested();
        return Task.CompletedTask;
    }

    public async Task WaitForStartAsync()
    {
        await _startEntered.Task.WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);
    }

    public void ReleaseFailure() => _releaseFailure.TrySetResult();
}

sealed class BlockingStopProductControlRuntimeConsumer :
    IWebRtcProductControlRuntimeConsumer,
    IDisposable
{
    private readonly TaskCompletionSource _stopEntered =
        new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly TaskCompletionSource _releaseStop =
        new(TaskCreationOptions.RunContinuationsAsynchronously);
    private WebRtcProductControlRuntimeLease? _activeLease;

    public int StopCalls { get; private set; }

    public int DisposeCalls { get; private set; }

    public Task<WebRtcProductControlRuntimeLease> StartAsync(
        LiveWebRtcProductControlContext context,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(context);
        cancellationToken.ThrowIfCancellationRequested();
        if (context.SecureSessionState != WebRtcProductControlSecureSessionState.Established)
        {
            throw new InvalidOperationException("blocking-stop consumer requires Established context");
        }

        var lease = WebRtcProductControlRuntimeLease.Create();
        _activeLease = lease;
        return Task.FromResult(lease);
    }

    public async Task StopAsync(
        WebRtcProductControlRuntimeLease lease,
        CancellationToken cancellationToken = default)
    {
        lease.RequireValid();
        cancellationToken.ThrowIfCancellationRequested();
        if (_activeLease is null)
        {
            return;
        }

        if (_activeLease != lease)
        {
            throw new InvalidOperationException("blocking-stop consumer received a foreign lease");
        }

        _stopEntered.TrySetResult();
        await _releaseStop.Task.WaitAsync(cancellationToken).ConfigureAwait(false);
        _activeLease = null;
        StopCalls++;
    }

    public async Task WaitForStopAsync() =>
        await _stopEntered.Task.WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);

    public void ReleaseStop() => _releaseStop.TrySetResult();

    public void Dispose()
    {
        if (_activeLease is not null)
        {
            throw new InvalidOperationException("blocking-stop consumer was disposed before exact Stop completed");
        }

        DisposeCalls++;
    }
}

sealed class BlockingProductControlRuntimeConsumer :
    IWebRtcProductControlRuntimeConsumer,
    IWebRtcProductControlEstablishedSessionAuthority,
    IDisposable
{
    private readonly bool _blockStart;
    private readonly TaskCompletionSource _startEntered =
        new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly TaskCompletionSource _releaseStart =
        new(TaskCreationOptions.RunContinuationsAsynchronously);
    private int _stopFailuresRemaining;
    private LiveWebRtcProductControlContext? _establishedContext;
    private bool _disposed;

    public BlockingProductControlRuntimeConsumer(
        bool blockStart = true,
        int stopFailures = 0)
    {
        if (stopFailures < 0)
        {
            throw new ArgumentOutOfRangeException(nameof(stopFailures));
        }

        _blockStart = blockStart;
        _stopFailuresRemaining = stopFailures;
    }

    public int StartCalls { get; private set; }

    public int StopCalls { get; private set; }

    public int StopAttempts { get; private set; }

    public int DisposeCalls { get; private set; }

    public bool WasActiveDuringDispose { get; private set; }

    public WebRtcProductControlRuntimeLease? StartedLease { get; private set; }

    public WebRtcProductControlRuntimeLease? LastStoppedLease { get; private set; }

    public WebRtcProductControlRuntimeLease? ActiveLease { get; private set; }

    public async Task<WebRtcProductControlRuntimeLease> StartAsync(
        LiveWebRtcProductControlContext context,
        CancellationToken cancellationToken = default)
    {
        if (_disposed)
        {
            throw new ObjectDisposedException(nameof(BlockingProductControlRuntimeConsumer));
        }

        ArgumentNullException.ThrowIfNull(context);
        cancellationToken.ThrowIfCancellationRequested();
        if (context.SecureSessionState != WebRtcProductControlSecureSessionState.TransportOnly)
        {
            throw new InvalidOperationException("test product authority requires a TransportOnly context");
        }

        StartCalls++;
        _startEntered.TrySetResult();
        if (_blockStart)
        {
            await _releaseStart.Task.WaitAsync(cancellationToken).ConfigureAwait(false);
        }

        var lease = WebRtcProductControlRuntimeLease.Create();
        StartedLease = lease;
        ActiveLease = lease;
        _establishedContext = context with
        {
            SecureSessionState = WebRtcProductControlSecureSessionState.Established,
            SessionIncarnation = WebRtcProductSessionIncarnation.Create()
        };
        return lease;
    }

    public Task StopAsync(
        WebRtcProductControlRuntimeLease lease,
        CancellationToken cancellationToken = default)
    {
        lease.RequireValid();
        cancellationToken.ThrowIfCancellationRequested();
        if (ActiveLease is null)
        {
            return Task.CompletedTask;
        }

        if (ActiveLease != lease)
        {
            throw new InvalidOperationException("engine supplied a stale or foreign runtime consumer lease");
        }

        StopAttempts++;
        if (_stopFailuresRemaining > 0)
        {
            _stopFailuresRemaining--;
            throw new InvalidOperationException("injected product consumer stop failure");
        }

        StopCalls++;
        LastStoppedLease = lease;
        ActiveLease = null;
        _establishedContext = null;
        return Task.CompletedTask;
    }

    public LiveWebRtcProductControlContext RequireEstablishedContext(
        WebRtcProductControlRuntimeLease lease)
    {
        lease.RequireValid();
        if (ActiveLease != lease || _establishedContext is null)
        {
            throw new InvalidOperationException("test product authority does not own the supplied runtime lease");
        }

        return _establishedContext;
    }

    public async Task WaitForStartAsync()
    {
        await _startEntered.Task.WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);
    }

    public void ReleaseStart() => _releaseStart.TrySetResult();

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        DisposeCalls++;
        WasActiveDuringDispose = ActiveLease is not null;
        if (WasActiveDuringDispose)
        {
            throw new InvalidOperationException("test product consumer was disposed while its exact lease remained active");
        }

        _disposed = true;
    }
}

sealed class TestSkyBridgeDataPlane : ISkyBridgeDataPlane
{
}

sealed class TrackingWebRtcSessionRuntimeConsumer : IWebRtcSessionRuntimeConsumer, IDisposable
{
    private readonly bool _blockStart;
    private readonly bool _throwOnStart;
    private int _stopFailuresRemaining;
    private readonly TaskCompletionSource _startEntered =
        new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly TaskCompletionSource _releaseStart =
        new(TaskCreationOptions.RunContinuationsAsynchronously);

    public TrackingWebRtcSessionRuntimeConsumer(
        bool blockStart = false,
        bool throwOnStart = false,
        int stopFailures = 0)
    {
        if (stopFailures < 0)
        {
            throw new ArgumentOutOfRangeException(nameof(stopFailures));
        }

        _blockStart = blockStart;
        _throwOnStart = throwOnStart;
        _stopFailuresRemaining = stopFailures;
    }

    public int StartCalls { get; private set; }

    public int StopCalls { get; private set; }

    public int StopAttempts { get; private set; }

    public int DisposeCalls { get; private set; }

    public bool WasActiveDuringDispose { get; private set; }

    public WebRtcSessionRuntimeLease? LastStartedLease { get; private set; }

    public WebRtcSessionRuntimeLease? LastStoppedLease { get; private set; }

    public WebRtcSessionRuntimeLease? ActiveLease { get; private set; }

    public async Task<WebRtcSessionRuntimeLease> StartAsync(
        LiveWebRtcSessionContext session,
        ConnectionLaunchRequest request,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(session);
        ArgumentNullException.ThrowIfNull(request);
        cancellationToken.ThrowIfCancellationRequested();
        StartCalls++;
        _startEntered.TrySetResult();
        if (_blockStart)
        {
            await _releaseStart.Task.WaitAsync(cancellationToken).ConfigureAwait(false);
        }

        if (_throwOnStart)
        {
            throw new InvalidOperationException("injected WebRTC session consumer start failure");
        }

        var lease = WebRtcSessionRuntimeLease.Create();
        LastStartedLease = lease;
        ActiveLease = lease;
        return lease;
    }

    public Task StopAsync(
        WebRtcSessionRuntimeLease lease,
        CancellationToken cancellationToken = default)
    {
        lease.RequireValid();
        cancellationToken.ThrowIfCancellationRequested();
        if (ActiveLease is null)
        {
            return Task.CompletedTask;
        }

        if (ActiveLease != lease)
        {
            throw new InvalidOperationException("engine supplied a stale or foreign WebRTC session runtime consumer lease");
        }

        StopAttempts++;
        if (_stopFailuresRemaining > 0)
        {
            _stopFailuresRemaining--;
            throw new InvalidOperationException("injected WebRTC session consumer stop failure");
        }

        StopCalls++;
        LastStoppedLease = lease;
        ActiveLease = null;
        return Task.CompletedTask;
    }

    public async Task WaitForStartAsync()
    {
        await _startEntered.Task.WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);
    }

    public void ReleaseStart() => _releaseStart.TrySetResult();

    public void Dispose()
    {
        DisposeCalls++;
        WasActiveDuringDispose = ActiveLease is not null;
    }
}

sealed class TrackingAsyncDisposable : IAsyncDisposable
{
    private int _failuresRemaining;

    public TrackingAsyncDisposable(int failuresBeforeSuccess = 0)
    {
        if (failuresBeforeSuccess < 0)
        {
            throw new ArgumentOutOfRangeException(nameof(failuresBeforeSuccess));
        }

        _failuresRemaining = failuresBeforeSuccess;
    }

    public int DisposeAttempts { get; private set; }

    public int SuccessfulDisposals { get; private set; }

    public ValueTask DisposeAsync()
    {
        DisposeAttempts++;
        if (_failuresRemaining > 0)
        {
            _failuresRemaining--;
            throw new InvalidOperationException("injected asynchronous resource cleanup failure");
        }

        SuccessfulDisposals++;
        return ValueTask.CompletedTask;
    }
}

sealed class TrackingWebRtcSessionEngineTransport : IWebRtcSessionEngineTransport
{
    private readonly LiveWebRtcSessionContext _context;
    private readonly Func<bool> _consumerIsActive;
    private readonly Func<int> _stopCalls;
    private bool _sessionAvailable = true;
    private WebRtcSessionTransportLease? _activeLease;

    public TrackingWebRtcSessionEngineTransport(
        LiveWebRtcSessionContext context,
        Func<bool> consumerIsActive,
        Func<int> stopCalls)
    {
        _context = context ?? throw new ArgumentNullException(nameof(context));
        _consumerIsActive = consumerIsActive ?? throw new ArgumentNullException(nameof(consumerIsActive));
        _stopCalls = stopCalls ?? throw new ArgumentNullException(nameof(stopCalls));
    }

    public int DisposeSessionCalls { get; private set; }

    public int DisposeCalls { get; private set; }

    public bool ConsumerWasActiveDuringSessionDispose { get; private set; }

    public bool ConsumerWasActiveDuringDispose { get; private set; }

    public int StopCallsObservedAtSessionDispose { get; private set; }

    public WebRtcSessionTransportLease? ClaimedLease { get; private set; }

    public WebRtcSessionTransportLease? LastDisposedLease { get; private set; }

    public Task<OwnedWebRtcSessionContext> ClaimLiveSessionAsync(ConnectionLaunchRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (!_sessionAvailable)
        {
            throw new InvalidOperationException("test WebRTC session transport is not live");
        }

        if (_activeLease is not null)
        {
            throw new InvalidOperationException("test WebRTC session transport is already claimed");
        }

        var lease = WebRtcSessionTransportLease.Create();
        _activeLease = lease;
        ClaimedLease = lease;
        return Task.FromResult(new OwnedWebRtcSessionContext(lease, _context));
    }

    public Task DisposeSessionAsync(WebRtcSessionTransportLease lease)
    {
        lease.RequireValid();
        if (_activeLease != lease)
        {
            return Task.CompletedTask;
        }

        DisposeSessionCalls++;
        LastDisposedLease = lease;
        ConsumerWasActiveDuringSessionDispose = _consumerIsActive();
        StopCallsObservedAtSessionDispose = _stopCalls();
        _activeLease = null;
        _sessionAvailable = false;
        return Task.CompletedTask;
    }

    public ValueTask DisposeAsync()
    {
        DisposeCalls++;
        ConsumerWasActiveDuringDispose = _consumerIsActive();
        _sessionAvailable = false;
        return ValueTask.CompletedTask;
    }
}

sealed class TrackingEngineClient : IEngineClient, IDisposable
{
    private readonly Func<int> _stopCalls;
    private EventHandler<EngineConnectionState>? _connectionStateChanged;

    public TrackingEngineClient(Func<int> stopCalls)
    {
        _stopCalls = stopCalls ?? throw new ArgumentNullException(nameof(stopCalls));
    }

    public EngineConnectionState State { get; private set; } = EngineConnectionState.Disconnected;

    public int ConnectCalls { get; private set; }

    public int DisconnectCalls { get; private set; }

    public int HeartbeatCalls { get; private set; }

    public int StopCallsObservedAtDisconnect { get; private set; }

    public int DisposeCalls { get; private set; }

    public int StopCallsObservedAtDispose { get; private set; }

    public event EventHandler<EngineConnectionState>? ConnectionStateChanged
    {
        add => _connectionStateChanged += value;
        remove => _connectionStateChanged -= value;
    }

    public Task ConnectAsync(ConnectionLaunchRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        ConnectCalls++;
        State = EngineConnectionState.Connected;
        _connectionStateChanged?.Invoke(this, State);
        return Task.CompletedTask;
    }

    public Task DisconnectAsync()
    {
        DisconnectCalls++;
        StopCallsObservedAtDisconnect = _stopCalls();
        State = EngineConnectionState.Disconnected;
        _connectionStateChanged?.Invoke(this, State);
        return Task.CompletedTask;
    }

    public Task SendHeartbeatAsync()
    {
        HeartbeatCalls++;
        return Task.CompletedTask;
    }

    public void Dispose()
    {
        DisposeCalls++;
        StopCallsObservedAtDispose = _stopCalls();
        State = EngineConnectionState.Disconnected;
        _connectionStateChanged = null;
    }
}

sealed class TrackingProductControlEngineTransport : IWebRtcProductControlEngineTransport
{
    private readonly LiveWebRtcProductControlContext _context;
    private readonly Func<bool> _consumerIsActive;
    private readonly Func<int> _stopCalls;
    private readonly WebRtcProductControlTransportClaim _claim = new();
    private int _disposeFailuresRemaining;
    private bool _transportAvailable = true;

    public TrackingProductControlEngineTransport(
        LiveWebRtcProductControlContext context,
        Func<bool> consumerIsActive,
        Func<int> stopCalls,
        int disposeFailures = 0)
    {
        if (disposeFailures < 0)
        {
            throw new ArgumentOutOfRangeException(nameof(disposeFailures));
        }

        _context = context ?? throw new ArgumentNullException(nameof(context));
        _consumerIsActive = consumerIsActive ?? throw new ArgumentNullException(nameof(consumerIsActive));
        _stopCalls = stopCalls ?? throw new ArgumentNullException(nameof(stopCalls));
        _disposeFailuresRemaining = disposeFailures;
    }

    public int DisposeTransportCalls { get; private set; }

    public int DisposeTransportAttempts { get; private set; }

    public int DisposeCalls { get; private set; }

    public bool ConsumerWasActiveDuringDispose { get; private set; }

    public int StopCallsObservedAtDispose { get; private set; }

    public WebRtcProductControlTransportLease? ClaimedLease { get; private set; }

    public WebRtcProductControlTransportLease? LastAttemptedLease { get; private set; }

    public WebRtcProductControlTransportLease? LastDisposedLease { get; private set; }

    public Task<OwnedWebRtcProductControlContext> ClaimLiveTransportAsync(
        ConnectionLaunchRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (!_transportAvailable)
        {
            throw new InvalidOperationException("test product-control transport is not live");
        }

        var lease = _claim.ClaimForEngine();
        ClaimedLease = lease;
        return Task.FromResult(new OwnedWebRtcProductControlContext(lease, _context));
    }

    public Task DisposeTransportAsync(WebRtcProductControlTransportLease lease)
    {
        lease.RequireValid();
        if (!_claim.IsOwnedBy(lease) || !_transportAvailable)
        {
            return Task.CompletedTask;
        }

        DisposeTransportAttempts++;
        LastAttemptedLease = lease;
        ConsumerWasActiveDuringDispose = _consumerIsActive();
        StopCallsObservedAtDispose = _stopCalls();
        if (_disposeFailuresRemaining > 0)
        {
            _disposeFailuresRemaining--;
            throw new InvalidOperationException("injected product transport cleanup failure");
        }

        DisposeTransportCalls++;
        LastDisposedLease = lease;
        _transportAvailable = false;
        return Task.CompletedTask;
    }

    public ValueTask DisposeAsync()
    {
        DisposeCalls++;
        _transportAvailable = false;
        return ValueTask.CompletedTask;
    }
}

sealed class StaticWebRtcAppSessionKeyProvider : IWebRtcAppSessionKeyProvider
{
    private readonly WebRtcAppSecureSessionKeys _keys;

    public StaticWebRtcAppSessionKeyProvider(WebRtcAppSecureSessionKeys keys)
    {
        _keys = keys ?? throw new ArgumentNullException(nameof(keys));
    }

    public WebRtcAppSecureSessionKeys RequireEstablishedKeys(LiveWebRtcProductControlContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        if (context.SecureSessionState != WebRtcProductControlSecureSessionState.Established)
        {
            throw new WebRtcAppSessionKeysUnavailableException("test context is not established");
        }

        return _keys.Clone();
    }
}

sealed class TrackingRemoteDesktopWorkspaceClient : IRemoteDesktopWorkspaceClient
{
    public int RecommendedCalls { get; private set; }

    public string BuildInitialStatus() => "ready";

    public string BuildPendingStatus() => "refreshing";

    public string BuildCompletedStatus(RemoteDesktopWorkspaceSnapshot snapshot) => "done";

    public string BuildCompletedStatusMessage() => "updated";

    public bool CanStartRecommendedSession() => true;

    public bool CanStartAdvancedSession() => true;

    public bool CanShowPerformanceOverlay() => true;

    public bool CanApplyQuality() => true;

    public bool CanOpenSettings() => true;

    public bool CanEnterFullScreen() => true;

    public bool CanDisconnectSession() => true;

    public string BuildRecommendedConnectPendingStatus() => "recommended-pending";

    public string BuildAdvancedConnectPendingStatus() => "advanced-pending";

    public string BuildNearFieldPendingStatus() => "near-field-pending";

    public string BuildAdvancedConnectModeStatus() => "advanced-mode";

    public string BuildPerformanceOverlayPendingStatus() => "overlay-pending";

    public string BuildQualityPendingStatus() => "quality-pending";

    public string BuildSettingsPendingStatus() => "settings-pending";

    public string BuildFullScreenPendingStatus() => "fullscreen-pending";

    public string BuildDisconnectSessionPendingStatus() => "disconnect-pending";

    public Task<RemoteDesktopWorkspaceSnapshot> BuildReadOnlySnapshotAsync(
        string bitrateProfile,
        string framerateProfile) =>
        Task.FromResult(new RemoteDesktopWorkspaceSnapshot(
            DateTimeOffset.UtcNow,
            Array.Empty<RemoteDesktopSessionItem>(),
            Array.Empty<RemoteDesktopControlFact>()));

    public Task<RemoteDesktopWorkspaceActionResult> BuildRecommendedConnectActionAsync()
    {
        RecommendedCalls++;
        return Task.FromResult(new RemoteDesktopWorkspaceActionResult(
            "recommended-ran",
            "recommended complete",
            "test action"));
    }

    public Task<RemoteDesktopWorkspaceActionResult> BuildAdvancedConnectActionAsync() =>
        Task.FromResult(new RemoteDesktopWorkspaceActionResult("advanced-ran", "advanced complete", "test action"));

    public Task<RemoteDesktopWorkspaceActionResult> BuildPerformanceOverlayActionAsync() =>
        Task.FromResult(new RemoteDesktopWorkspaceActionResult("overlay-ran", "overlay complete", "test action"));

    public Task<RemoteDesktopWorkspaceActionResult> BuildQualityActionAsync(
        string bitrateProfile,
        string framerateProfile) =>
        Task.FromResult(new RemoteDesktopWorkspaceActionResult("quality-ran", "quality complete", "test action"));

    public Task<RemoteDesktopWorkspaceActionResult> BuildSettingsActionAsync() =>
        Task.FromResult(new RemoteDesktopWorkspaceActionResult("settings-ran", "settings complete", "test action"));

    public Task<RemoteDesktopWorkspaceActionResult> BuildFullScreenActionAsync() =>
        Task.FromResult(new RemoteDesktopWorkspaceActionResult("fullscreen-ran", "fullscreen complete", "test action"));

    public Task<RemoteDesktopWorkspaceActionResult> BuildDisconnectSessionActionAsync() =>
        Task.FromResult(new RemoteDesktopWorkspaceActionResult("disconnect-ran", "disconnect complete", "test action"));
}

sealed class StaticDiscoveryClient : IDiscoveryClient
{
    private readonly string _fingerprint;
    private readonly string _displayName;

    public StaticDiscoveryClient(string fingerprint, string displayName = "Desk Mac")
    {
        _fingerprint = fingerprint;
        _displayName = displayName;
    }

    public string BuildPendingStatus() => "Parsing...";

    public bool CanParseAdvertisement(string service, string txtRecord) =>
        !string.IsNullOrWhiteSpace(service) && !string.IsNullOrWhiteSpace(txtRecord);

    public Task<DiscoveredPeer> ParseAdvertisementAsync(string service, string txtRecord)
    {
        var serviceKind = service.Trim().ToLowerInvariant() switch
        {
            "_skybridge-xfer._tcp" or "_skybridge-transfer._tcp" => CoreDiscoveryServiceKind.FileTransfer,
            "_skybridge-rd._tcp" or "_skybridge-remote._tcp" => CoreDiscoveryServiceKind.RemoteControl,
            "_skybridge._tcp" => CoreDiscoveryServiceKind.TcpFallback,
            "_skybridge._udp" => CoreDiscoveryServiceKind.QuicPrimary,
            _ => CoreDiscoveryServiceKind.Unknown
        };
        var deviceId = txtRecord.Contains("deviceId=mac-2", StringComparison.Ordinal)
            ? "mac-2"
            : "mac-1";

        return Task.FromResult(new DiscoveredPeer(
            serviceKind,
            deviceId,
            _displayName,
            CorePeerPlatform.Apple,
            "macOS",
            _fingerprint,
            "file_transfer,remote_desktop",
            "1",
            PeerCapabilities.Apple()));
    }
}

sealed class StaticDnsSdBrowseClient : IWindowsDnsSdBrowseClient
{
    private readonly IReadOnlyList<WindowsDnsSdResolvedTxtRecord> _records;

    public StaticDnsSdBrowseClient(params WindowsDnsSdResolvedTxtRecord[] records)
    {
        _records = records;
    }

    public Task<WindowsDnsSdBrowseSnapshot> BrowseAsync(
        WindowsDnsSdBrowseRequest request,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);
        cancellationToken.ThrowIfCancellationRequested();
        IReadOnlyList<DiscoveryBrowserFact> facts =
        [
            new("Native browse", "test", "static resolved DNS-SD records")
        ];
        return Task.FromResult(new WindowsDnsSdBrowseSnapshot(_records, facts));
    }
}

sealed class ControlledDnsSdBrowseClient : IWindowsDnsSdBrowseClient
{
    private readonly object _gate = new();
    private readonly Queue<ControlledDnsSdBrowseCall> _calls = new();
    private readonly SemaphoreSlim _callAvailable = new(0);

    public async Task<WindowsDnsSdBrowseSnapshot> BrowseAsync(
        WindowsDnsSdBrowseRequest request,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);
        var call = new ControlledDnsSdBrowseCall();
        lock (_gate)
        {
            _calls.Enqueue(call);
        }

        _callAvailable.Release();
        using var registration = cancellationToken.Register(call.SignalCancellation);
        return await call.Completion.ConfigureAwait(false);
    }

    public async Task<ControlledDnsSdBrowseCall> WaitForNextCallAsync()
    {
        if (!await _callAvailable.WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false))
        {
            throw new TimeoutException("Timed out waiting for the controlled DNS-SD browse call.");
        }

        lock (_gate)
        {
            return _calls.Dequeue();
        }
    }
}

sealed class ControlledDnsSdBrowseCall
{
    private readonly TaskCompletionSource<WindowsDnsSdBrowseSnapshot> _completion =
        new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly TaskCompletionSource _cancellationObserved =
        new(TaskCreationOptions.RunContinuationsAsynchronously);
    private int _isCancellationRequested;

    public Task<WindowsDnsSdBrowseSnapshot> Completion => _completion.Task;

    public bool IsCancellationRequested => Volatile.Read(ref _isCancellationRequested) != 0;

    public void SignalCancellation()
    {
        Interlocked.Exchange(ref _isCancellationRequested, 1);
        _cancellationObserved.TrySetResult();
    }

    public async Task WaitForCancellationAsync()
    {
        await _cancellationObserved.Task.WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);
    }

    public void Complete()
    {
        IReadOnlyList<DiscoveryBrowserFact> facts =
        [
            new("Native browse", "controlled", "controlled callback completion barrier released")
        ];
        if (!_completion.TrySetResult(
            new WindowsDnsSdBrowseSnapshot(Array.Empty<WindowsDnsSdResolvedTxtRecord>(), facts)))
        {
            throw new InvalidOperationException("Controlled DNS-SD browse call completed more than once.");
        }
    }
}

sealed class TempDir : IDisposable
{
    private TempDir(string path)
    {
        Path = path;
        Directory.CreateDirectory(path);
    }

    public string Path { get; }

    public static TempDir Create() =>
        new(System.IO.Path.Combine(System.IO.Path.GetTempPath(), $"skybridge-contract-{Guid.NewGuid():N}"));

    public void Dispose()
    {
        try
        {
            Directory.Delete(Path, recursive: true);
        }
        catch
        {
            // Test cleanup only.
        }
    }
}

sealed class PlainSessionProtector : ISessionProtector
{
    public byte[] Protect(byte[] bytes) => bytes;

    public byte[] Unprotect(byte[] bytes) => bytes;
}

sealed class ThrowingUnprotectSessionProtector : ISessionProtector
{
    public byte[] Protect(byte[] bytes) => bytes;

    public byte[] Unprotect(byte[] bytes) => throw new CryptographicException("test decrypt failure");
}

sealed class ThrowingSessionFileCommitter : ISessionFileCommitter
{
    public void Commit(string temporaryPath, string destinationPath) =>
        throw new IOException("test atomic commit failure");
}

sealed class StaticHandler : HttpMessageHandler
{
    private readonly HttpStatusCode _statusCode;
    private readonly string _body;

    public StaticHandler(HttpStatusCode statusCode, string body)
    {
        _statusCode = statusCode;
        _body = body;
    }

    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) =>
        Task.FromResult(new HttpResponseMessage(_statusCode)
        {
            Content = new StringContent(_body, Encoding.UTF8, "application/json")
        });
}

sealed class RecordingHandler : HttpMessageHandler
{
    private readonly Func<HttpRequestMessage, HttpResponseMessage> _handler;

    public RecordingHandler(Func<HttpRequestMessage, HttpResponseMessage> handler)
    {
        _handler = handler;
    }

    public int ProfileCalls { get; private set; }

    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        if (request.RequestUri?.AbsolutePath.Contains("/rest/v1/user_profiles", StringComparison.Ordinal) == true)
        {
            ProfileCalls++;
        }

        return Task.FromResult(_handler(request));
    }
}

sealed class FakeSessionStore : ISessionStore
{
    public SessionStoreLoadResult LoadResult { get; set; } = SessionStoreLoadResult.Missing();

    public SessionStoreWriteResult SaveResult { get; set; } = SessionStoreWriteResult.Saved();

    public SessionStoreWriteResult ClearResult { get; set; } = SessionStoreWriteResult.Cleared();

    public int SaveCalls { get; private set; }

    public int ClearCalls { get; private set; }

    public bool ClearCalled => ClearCalls != 0;

    public PersistedSession? LastSaved { get; private set; }

    public SessionStoreLoadResult Load() => LoadResult;

    public SessionStoreWriteResult Save(PersistedSession session)
    {
        SaveCalls++;
        LastSaved = session;
        return SaveResult;
    }

    public SessionStoreWriteResult Clear()
    {
        ClearCalls++;
        return ClearResult;
    }
}

sealed class FakeAuthClient : ISupabaseAuthClient
{
    public SessionAuthority SessionAuthority { get; set; } = new(
        "https://hloqytmhjludmuhwyyzb.supabase.co/auth/v1",
        "authenticated",
        "authenticated");

    public AuthClientResult<AuthToken> SignInResult { get; set; } =
        AuthClientResult<AuthToken>.Failed(AuthFailureKind.InvalidCredentials, "not_configured");

    public AuthClientResult<AuthToken> RefreshResult { get; set; } =
        AuthClientResult<AuthToken>.Failed(AuthFailureKind.Unauthorized, "not_configured");

    public AuthClientResult<AuthUser> GetUserResult { get; set; } =
        AuthClientResult<AuthUser>.Failed(AuthFailureKind.Unauthorized, "not_configured");

    public AuthClientResult<AuthSignOutReceipt> SignOutResult { get; set; } =
        AuthClientResult<AuthSignOutReceipt>.Success(new AuthSignOutReceipt(ServerRevoked: true));

    public Func<string, string?, Task<AuthClientResult<AuthUser>>>? GetUserHandler { get; set; }

    public int SignInCalls { get; private set; }

    public int RefreshCalls { get; private set; }

    public int GetUserCalls { get; private set; }

    public int SignOutCalls { get; private set; }

    public Task<AuthClientResult<AuthToken>> SignInWithPasswordAsync(string email, string password)
    {
        SignInCalls++;
        return Task.FromResult(SignInResult);
    }

    public Task<AuthClientResult<AuthToken>> RefreshAsync(string refreshToken)
    {
        RefreshCalls++;
        return Task.FromResult(RefreshResult);
    }

    public Task<AuthClientResult<AuthUser>> GetUserAsync(string accessToken, string? userId = null)
    {
        GetUserCalls++;
        return GetUserHandler is null
            ? Task.FromResult(GetUserResult)
            : GetUserHandler(accessToken, userId);
    }

    public Task<AuthClientResult<AuthSignOutReceipt>> SignOutAsync(string accessToken)
    {
        SignOutCalls++;
        return Task.FromResult(SignOutResult);
    }
}

sealed class PairedProductControlPlanes
{
    private PairedProductControlPlanes(
        FakeProductControlPlane initiator,
        FakeProductControlPlane responder)
    {
        Initiator = initiator;
        Responder = responder;
    }

    public FakeProductControlPlane Initiator { get; }

    public FakeProductControlPlane Responder { get; }

    public static PairedProductControlPlanes Create()
    {
        var initiator = new FakeProductControlPlane();
        var responder = new FakeProductControlPlane();
        initiator.ConnectPeer(responder);
        responder.ConnectPeer(initiator);
        return new PairedProductControlPlanes(initiator, responder);
    }
}

sealed class FakeProductControlPlane : IWebRtcProductControlPlane
{
    private FakeProductControlPlane? _peer;

    public bool IsConnected { get; private set; } = true;

    public event Action<byte[]>? MessageReceived;

    public void ConnectPeer(FakeProductControlPlane peer)
    {
        _peer = peer;
    }

    public Task SendAsync(ReadOnlyMemory<byte> message, CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (!IsConnected)
        {
            throw new InvalidOperationException("fake product-control plane is disconnected");
        }

        if (message.Length == 0)
        {
            throw new InvalidOperationException("fake product-control plane refuses empty messages");
        }

        var peer = _peer ?? throw new InvalidOperationException("fake product-control plane peer is not connected");
        if (!peer.IsConnected)
        {
            throw new InvalidOperationException("fake product-control plane peer is disconnected");
        }

        peer.MessageReceived?.Invoke(message.ToArray());
        return Task.CompletedTask;
    }
}

sealed class RetainingCallbackProductControlPlane : IWebRtcProductControlPlane
{
    private Action<byte[]>? _messageReceived;
    private Action<byte[]>? _removedHandler;

    public bool IsConnected => true;

    public event Action<byte[]>? MessageReceived
    {
        add => _messageReceived += value;
        remove
        {
            _removedHandler = value;
            _messageReceived -= value;
        }
    }

    public Task SendAsync(ReadOnlyMemory<byte> message, CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (message.IsEmpty)
        {
            throw new InvalidOperationException("retaining product-control plane refuses empty messages");
        }

        _messageReceived?.Invoke(message.ToArray());
        return Task.CompletedTask;
    }

    public void InvokeRemovedHandler(byte[] message)
    {
        ArgumentNullException.ThrowIfNull(message);
        var removedHandler = _removedHandler
            ?? throw new InvalidOperationException("route store did not unsubscribe the previous owner's callback");
        removedHandler(message);
    }
}
