using System;
using System.Collections.Generic;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;

namespace Skybridge.WinClient.Services;

public sealed class NativeWindowsDnsSdBrowseClient : IWindowsDnsSdBrowseClient
{
    private const uint DnsQueryRequestVersion1 = 1;
    private const uint DnsRequestPending = 9506;
    private const uint ErrorSuccess = 0;
    private const uint ErrorCancelled = 1223;
    private const ushort DnsTypePtr = 12;
    private const int MaxBrowseSeconds = 30;
    private const int MaxResolveSeconds = 3;
    private const int MaxDnsRecords = 128;

    public async Task<WindowsDnsSdBrowseSnapshot> BrowseAsync(
        WindowsDnsSdBrowseRequest request,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);

        var facts = new List<DiscoveryBrowserFact>();
        var records = new List<WindowsDnsSdResolvedTxtRecord>();
        if (!OperatingSystem.IsWindowsVersionAtLeast(10))
        {
            facts.Add(new DiscoveryBrowserFact(
                "Native browse",
                "unavailable",
                "Win32 DnsServiceBrowse/DnsServiceResolve require Windows 10 desktop APIs."));
            return new WindowsDnsSdBrowseSnapshot(records, facts);
        }

        var services = BuildServiceList(request.QueryOrder);
        if (services.Count == 0)
        {
            facts.Add(new DiscoveryBrowserFact(
                "Native browse",
                "invalid",
                "DNS-SD browse requires at least one _skybridge service query name."));
            return new WindowsDnsSdBrowseSnapshot(records, facts);
        }

        var browseWindow = TimeSpan.FromSeconds(Math.Clamp(request.ExtendedSearchSeconds, 1, MaxBrowseSeconds));
        var resolveWindow = TimeSpan.FromSeconds(Math.Clamp(request.ExtendedSearchSeconds, 1, MaxResolveSeconds));
        var browseTasks = new List<Task<NativeBrowseResult>>();
        foreach (var service in services)
        {
            browseTasks.Add(BrowseServiceInstancesAsync(
                service,
                NormalizeBrowseQueryName(service),
                browseWindow,
                cancellationToken));
        }

        var browseResults = await Task.WhenAll(browseTasks).ConfigureAwait(false);
        var resolveTargets = new List<NativeResolveTarget>();
        var seenInstances = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var browseResult in browseResults)
        {
            facts.AddRange(browseResult.Facts);
            foreach (var instanceName in browseResult.InstanceNames)
            {
                if (seenInstances.Add(instanceName))
                {
                    resolveTargets.Add(new NativeResolveTarget(browseResult.Service, instanceName));
                }
            }
        }

        if (cancellationToken.IsCancellationRequested)
        {
            facts.Add(new DiscoveryBrowserFact(
                "Native browse",
                "cancelled",
                "All exact-owner DnsServiceBrowse cancellation callbacks completed; resolve operations were not started."));
            return new WindowsDnsSdBrowseSnapshot(records, facts);
        }

        if (resolveTargets.Count == 0)
        {
            facts.Add(new DiscoveryBrowserFact(
                "Native resolve",
                "no instances",
                "DnsServiceBrowse returned no service instance names to resolve during this snapshot window."));
            return new WindowsDnsSdBrowseSnapshot(records, facts);
        }

        var resolveTasks = new List<Task<NativeResolveResult>>();
        foreach (var target in resolveTargets)
        {
            resolveTasks.Add(ResolveServiceInstanceAsync(target, resolveWindow, cancellationToken));
        }

        var resolveResults = await Task.WhenAll(resolveTasks).ConfigureAwait(false);
        foreach (var resolveResult in resolveResults)
        {
            facts.AddRange(resolveResult.Facts);
            records.AddRange(resolveResult.Records);
        }

        return new WindowsDnsSdBrowseSnapshot(records, facts);
    }

    private static async Task<NativeBrowseResult> BrowseServiceInstancesAsync(
        string service,
        string queryName,
        TimeSpan browseWindow,
        CancellationToken cancellationToken)
    {
        var context = new BrowseCallbackContext(service, queryName);
        if (cancellationToken.IsCancellationRequested)
        {
            context.AddFact(
                "Native browse",
                "cancelled",
                $"{queryName} was cancelled before DnsServiceBrowse acquired a native callback lease.");
            return context.ToResult();
        }

        DnsServiceBrowseCallback callback = BrowseCallback;
        var contextHandle = default(GCHandle);
        var requestHandle = default(GCHandle);
        var cancelHandle = default(GCHandle);
        var queryNamePointer = IntPtr.Zero;
        var cancel = new DnsServiceCancel[1];

        try
        {
            contextHandle = GCHandle.Alloc(context);
            queryNamePointer = Marshal.StringToHGlobalUni(queryName);
            var nativeRequest = new DnsServiceBrowseRequestNative[1];
            nativeRequest[0] = new DnsServiceBrowseRequestNative
            {
                Version = DnsQueryRequestVersion1,
                InterfaceIndex = 0,
                QueryName = queryNamePointer,
                BrowseCallback = Marshal.GetFunctionPointerForDelegate(callback),
                QueryContext = GCHandle.ToIntPtr(contextHandle)
            };

            context.AddFact(
                "Native browse",
                "query",
                $"{queryName} via DnsServiceBrowse; returned PTR records are resolved with DnsServiceResolve.");
            // DNS-SD owns these native addresses across the asynchronous operation.
            // A ref argument is pinned only during the P/Invoke; a compacting GC
            // after the await must not move the request or cancellation handle.
            requestHandle = GCHandle.Alloc(nativeRequest, GCHandleType.Pinned);
            cancelHandle = GCHandle.Alloc(cancel, GCHandleType.Pinned);
            var status = DnsServiceBrowse(requestHandle.AddrOfPinnedObject(), cancelHandle.AddrOfPinnedObject());
            if (status != DnsRequestPending)
            {
                context.AddFailure(new InvalidOperationException(
                    $"DnsServiceBrowse for {queryName} did not enter the pending asynchronous state ({FormatStatus(status)})."));
                return context.ToResult();
            }

            await WaitForWindowOrCancellationAsync(browseWindow, cancellationToken).ConfigureAwait(false);
            var cancelStatus = DnsServiceBrowseCancel(cancelHandle.AddrOfPinnedObject());
            if (cancelStatus != ErrorSuccess && cancelStatus != ErrorCancelled)
            {
                context.AddFailure(new InvalidOperationException(
                    $"DnsServiceBrowseCancel for {queryName} failed ({FormatStatus(cancelStatus)})."));
            }

            await context.CallbackCompleted.ConfigureAwait(false);
            return context.ToResult();
        }
        catch (DllNotFoundException ex)
        {
            context.AddFact("Native browse", "unavailable", $"dnsapi.dll was not available: {ex.Message}");
            return context.ToResult();
        }
        catch (EntryPointNotFoundException ex)
        {
            context.AddFact("Native browse", "unavailable", $"DnsServiceBrowse export was not available: {ex.Message}");
            return context.ToResult();
        }
        catch (MarshalDirectiveException ex)
        {
            context.AddFact("Native browse", "marshal error", $"DnsServiceBrowse interop marshaling failed: {ex.Message}");
            return context.ToResult();
        }
        finally
        {
            if (requestHandle.IsAllocated) requestHandle.Free();
            if (cancelHandle.IsAllocated) cancelHandle.Free();
            if (queryNamePointer != IntPtr.Zero)
            {
                Marshal.FreeHGlobal(queryNamePointer);
            }

            if (contextHandle.IsAllocated)
            {
                contextHandle.Free();
            }

            GC.KeepAlive(callback);
        }
    }

    private static async Task<NativeResolveResult> ResolveServiceInstanceAsync(
        NativeResolveTarget target,
        TimeSpan resolveWindow,
        CancellationToken cancellationToken)
    {
        var context = new ResolveCallbackContext(target);
        if (cancellationToken.IsCancellationRequested)
        {
            context.AddFact(
                "Native resolve",
                "cancelled",
                $"{target.InstanceName} was cancelled before DnsServiceResolve acquired a native callback lease.");
            return context.ToResult();
        }

        DnsServiceResolveComplete callback = ResolveCallback;
        var contextHandle = default(GCHandle);
        var requestHandle = default(GCHandle);
        var cancelHandle = default(GCHandle);
        var queryNamePointer = IntPtr.Zero;
        var cancel = new DnsServiceCancel[1];

        try
        {
            contextHandle = GCHandle.Alloc(context);
            queryNamePointer = Marshal.StringToHGlobalUni(target.InstanceName);
            var nativeRequest = new DnsServiceResolveRequestNative[1];
            nativeRequest[0] = new DnsServiceResolveRequestNative
            {
                Version = DnsQueryRequestVersion1,
                InterfaceIndex = 0,
                QueryName = queryNamePointer,
                ResolveCallback = Marshal.GetFunctionPointerForDelegate(callback),
                QueryContext = GCHandle.ToIntPtr(contextHandle)
            };

            // DNS-SD owns these native addresses across the asynchronous operation.
            // A ref argument is pinned only during the P/Invoke; a compacting GC
            // after the await must not move the request or cancellation handle.
            requestHandle = GCHandle.Alloc(nativeRequest, GCHandleType.Pinned);
            cancelHandle = GCHandle.Alloc(cancel, GCHandleType.Pinned);
            var status = DnsServiceResolve(requestHandle.AddrOfPinnedObject(), cancelHandle.AddrOfPinnedObject());
            if (status != DnsRequestPending)
            {
                context.AddFailure(new InvalidOperationException(
                    $"DnsServiceResolve for {target.InstanceName} did not enter the pending asynchronous state ({FormatStatus(status)})."));
                return context.ToResult();
            }

            var windowOrCancellation = WaitForWindowOrCancellationAsync(resolveWindow, cancellationToken);
            var completed = await Task.WhenAny(context.CallbackCompleted, windowOrCancellation).ConfigureAwait(false);
            if (completed != context.CallbackCompleted && !context.CallbackCompleted.IsCompleted)
            {
                var cancelStatus = DnsServiceResolveCancel(cancelHandle.AddrOfPinnedObject());
                if (cancelStatus != ErrorSuccess && cancelStatus != ErrorCancelled)
                {
                    context.AddFailure(new InvalidOperationException(
                        $"DnsServiceResolveCancel for {target.InstanceName} failed ({FormatStatus(cancelStatus)})."));
                }
            }

            await context.CallbackCompleted.ConfigureAwait(false);
            return context.ToResult();
        }
        catch (DllNotFoundException ex)
        {
            context.AddFact("Native resolve", "unavailable", $"dnsapi.dll was not available: {ex.Message}");
            return context.ToResult();
        }
        catch (EntryPointNotFoundException ex)
        {
            context.AddFact("Native resolve", "unavailable", $"DnsServiceResolve export was not available: {ex.Message}");
            return context.ToResult();
        }
        catch (MarshalDirectiveException ex)
        {
            context.AddFact("Native resolve", "marshal error", $"DnsServiceResolve interop marshaling failed: {ex.Message}");
            return context.ToResult();
        }
        finally
        {
            if (requestHandle.IsAllocated) requestHandle.Free();
            if (cancelHandle.IsAllocated) cancelHandle.Free();
            if (queryNamePointer != IntPtr.Zero)
            {
                Marshal.FreeHGlobal(queryNamePointer);
            }

            if (contextHandle.IsAllocated)
            {
                contextHandle.Free();
            }

            GC.KeepAlive(callback);
        }
    }

    private static List<string> BuildServiceList(IReadOnlyList<string> queryOrder)
    {
        var services = new List<string>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var service in queryOrder)
        {
            if (string.IsNullOrWhiteSpace(service))
            {
                continue;
            }

            var trimmed = service.Trim();
            if (seen.Add(trimmed))
            {
                services.Add(trimmed);
            }
        }

        return services;
    }

    private static async Task WaitForWindowOrCancellationAsync(
        TimeSpan window,
        CancellationToken cancellationToken)
    {
        var windowElapsed = Task.Delay(window);
        if (!cancellationToken.CanBeCanceled)
        {
            await windowElapsed.ConfigureAwait(false);
            return;
        }

        var cancellationRequested = Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken);
        await Task.WhenAny(windowElapsed, cancellationRequested).ConfigureAwait(false);
    }

    private static string NormalizeBrowseQueryName(string service) =>
        service.EndsWith(".local", StringComparison.OrdinalIgnoreCase)
            ? service
            : $"{service}.local";

    private static void BrowseCallback(uint status, IntPtr queryContext, IntPtr dnsRecord)
    {
        var context = TryGetContext<BrowseCallbackContext>(queryContext);
        try
        {
            if (context is null)
            {
                return;
            }

            if (status != ErrorSuccess && status != ErrorCancelled)
            {
                context.AddFailure(new InvalidOperationException(
                    $"DnsServiceBrowse callback failed ({FormatStatus(status)})."));
            }

            if (dnsRecord == IntPtr.Zero)
            {
                return;
            }

            foreach (var instanceName in ReadPtrRecordInstanceNames(dnsRecord))
            {
                context.AddInstanceName(instanceName);
            }
        }
        catch (Exception ex) when (ex is ArgumentException or InvalidOperationException or MarshalDirectiveException)
        {
            context?.AddFailure(ex);
        }
        finally
        {
            if (dnsRecord != IntPtr.Zero)
            {
                DnsRecordListFree(dnsRecord, DnsFreeType.DnsFreeRecordList);
            }

            if (status == ErrorCancelled)
            {
                context?.CompleteCallbackBarrier();
            }
        }
    }

    private static void ResolveCallback(uint status, IntPtr queryContext, IntPtr instance)
    {
        var context = TryGetContext<ResolveCallbackContext>(queryContext);
        try
        {
            if (context is null)
            {
                return;
            }

            if (status != ErrorSuccess && status != ErrorCancelled)
            {
                context.AddFailure(new InvalidOperationException(
                    $"DnsServiceResolve callback failed ({FormatStatus(status)})."));
            }

            if (instance == IntPtr.Zero)
            {
                return;
            }

            var record = ReadResolvedTxtRecord(context.Target, instance);
            if (record is null)
            {
                context.AddFact("Native resolve", "no TXT", $"Resolved {context.Target.InstanceName} without usable TXT properties.");
                return;
            }

            context.AddRecord(record);
        }
        catch (Exception ex) when (ex is ArgumentException or InvalidOperationException or MarshalDirectiveException)
        {
            context?.AddFailure(ex);
        }
        finally
        {
            if (instance != IntPtr.Zero)
            {
                DnsServiceFreeInstance(instance);
            }
            context?.CompleteCallbackBarrier();
        }
    }

    private static T? TryGetContext<T>(IntPtr queryContext)
        where T : class
    {
        if (queryContext == IntPtr.Zero)
        {
            return null;
        }

        try
        {
            return GCHandle.FromIntPtr(queryContext).Target as T;
        }
        catch (InvalidOperationException)
        {
            return null;
        }
    }

    private static IReadOnlyList<string> ReadPtrRecordInstanceNames(IntPtr dnsRecord)
    {
        var names = new List<string>();
        var current = dnsRecord;
        var count = 0;
        while (current != IntPtr.Zero && count < MaxDnsRecords)
        {
            var record = Marshal.PtrToStructure<DnsRecordNative>(current);
            if (record.Type == DnsTypePtr && record.Data != IntPtr.Zero)
            {
                var instanceName = Marshal.PtrToStringUni(record.Data);
                if (!string.IsNullOrWhiteSpace(instanceName))
                {
                    names.Add(instanceName);
                }
            }

            current = record.Next;
            count++;
        }

        return names;
    }

    private static WindowsDnsSdResolvedTxtRecord? ReadResolvedTxtRecord(
        NativeResolveTarget target,
        IntPtr instance)
    {
        var native = Marshal.PtrToStructure<DnsServiceInstanceNative>(instance);
        var txtRecord = BuildTxtRecord(native);
        if (string.IsNullOrWhiteSpace(txtRecord))
        {
            return null;
        }

        var instanceName = Marshal.PtrToStringUni(native.InstanceName) ?? target.InstanceName;
        var hostName = Marshal.PtrToStringUni(native.HostName) ?? "";
        return new WindowsDnsSdResolvedTxtRecord(
            target.Service,
            txtRecord,
            instanceName,
            hostName,
            native.Port);
    }

    private static string BuildTxtRecord(DnsServiceInstanceNative native)
    {
        if (native.PropertyCount == 0 || native.Keys == IntPtr.Zero || native.Values == IntPtr.Zero)
        {
            return "";
        }

        if (native.PropertyCount > NativeWindowsDnsSdTxtRecordCodec.MaxTxtProperties)
        {
            throw new InvalidOperationException(
                $"DNS-SD TXT property count exceeds {NativeWindowsDnsSdTxtRecordCodec.MaxTxtProperties}.");
        }

        var count = checked((int)native.PropertyCount);
        var properties = new List<KeyValuePair<string, string>>(count);
        for (var index = 0; index < count; index++)
        {
            var keyPointer = Marshal.ReadIntPtr(native.Keys, index * IntPtr.Size);
            var key = keyPointer == IntPtr.Zero ? "" : Marshal.PtrToStringUni(keyPointer) ?? "";
            var valuePointer = Marshal.ReadIntPtr(native.Values, index * IntPtr.Size);
            var value = valuePointer == IntPtr.Zero ? "" : Marshal.PtrToStringUni(valuePointer) ?? "";
            properties.Add(new KeyValuePair<string, string>(key, value));
        }

        if (!NativeWindowsDnsSdTxtRecordCodec.TrySerialize(properties, out var txtRecord, out var error))
        {
            throw new InvalidOperationException(error);
        }

        return txtRecord;
    }

    private static string FormatStatus(uint status) =>
        status == ErrorSuccess ? "success" : $"status {status}";

    private sealed class BrowseCallbackContext
    {
        private readonly object _sync = new();
        private readonly List<string> _instanceNames = new();
        private readonly List<DiscoveryBrowserFact> _facts = new();
        private readonly TaskCompletionSource _callbackCompleted =
            new(TaskCreationOptions.RunContinuationsAsynchronously);
        private Exception? _failure;

        public BrowseCallbackContext(string service, string queryName)
        {
            Service = service;
            QueryName = queryName;
        }

        public string Service { get; }

        public string QueryName { get; }

        public Task CallbackCompleted => _callbackCompleted.Task;

        public void AddInstanceName(string instanceName)
        {
            lock (_sync)
            {
                if (!_instanceNames.Contains(instanceName, StringComparer.OrdinalIgnoreCase))
                {
                    _instanceNames.Add(instanceName);
                    _facts.Add(new DiscoveryBrowserFact(
                        "Native browse",
                        "found",
                        $"{QueryName} returned {instanceName}; resolving via DnsServiceResolve."));
                }
            }
        }

        public void AddFact(string label, string value, string detail)
        {
            lock (_sync)
            {
                _facts.Add(new DiscoveryBrowserFact(label, value, detail));
            }
        }

        public void AddFailure(Exception failure)
        {
            ArgumentNullException.ThrowIfNull(failure);
            lock (_sync)
            {
                _failure ??= failure;
            }
        }

        public void CompleteCallbackBarrier() => _callbackCompleted.TrySetResult();

        public NativeBrowseResult ToResult()
        {
            lock (_sync)
            {
                if (_failure is not null)
                {
                    throw new InvalidOperationException(
                        $"Native DNS-SD browse failed for {QueryName}.",
                        _failure);
                }

                return new NativeBrowseResult(Service, _instanceNames.ToArray(), _facts.ToArray());
            }
        }
    }

    private sealed class ResolveCallbackContext
    {
        private readonly object _sync = new();
        private readonly List<WindowsDnsSdResolvedTxtRecord> _records = new();
        private readonly List<DiscoveryBrowserFact> _facts = new();
        private readonly TaskCompletionSource _callbackCompleted =
            new(TaskCreationOptions.RunContinuationsAsynchronously);
        private Exception? _failure;

        public ResolveCallbackContext(NativeResolveTarget target)
        {
            Target = target;
        }

        public NativeResolveTarget Target { get; }

        public Task CallbackCompleted => _callbackCompleted.Task;

        public void AddRecord(WindowsDnsSdResolvedTxtRecord record)
        {
            lock (_sync)
            {
                _records.Add(record);
                _facts.Add(new DiscoveryBrowserFact(
                    "Native resolve",
                    "resolved",
                    $"{record.InstanceName} resolved to {record.HostName}:{record.Port}; TXT is still parsed by CoreDiscoveryClient."));
            }
        }

        public void AddFact(string label, string value, string detail)
        {
            lock (_sync)
            {
                _facts.Add(new DiscoveryBrowserFact(label, value, detail));
            }
        }

        public void AddFailure(Exception failure)
        {
            ArgumentNullException.ThrowIfNull(failure);
            lock (_sync)
            {
                _failure ??= failure;
            }
        }

        public void CompleteCallbackBarrier() => _callbackCompleted.TrySetResult();

        public NativeResolveResult ToResult()
        {
            lock (_sync)
            {
                if (_failure is not null)
                {
                    throw new InvalidOperationException(
                        $"Native DNS-SD resolve failed for {Target.InstanceName}.",
                        _failure);
                }

                return new NativeResolveResult(_records.ToArray(), _facts.ToArray());
            }
        }
    }

    private sealed record NativeBrowseResult(
        string Service,
        IReadOnlyList<string> InstanceNames,
        IReadOnlyList<DiscoveryBrowserFact> Facts);

    private sealed record NativeResolveTarget(
        string Service,
        string InstanceName);

    private sealed record NativeResolveResult(
        IReadOnlyList<WindowsDnsSdResolvedTxtRecord> Records,
        IReadOnlyList<DiscoveryBrowserFact> Facts);

    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    private delegate void DnsServiceBrowseCallback(uint status, IntPtr queryContext, IntPtr dnsRecord);

    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    private delegate void DnsServiceResolveComplete(uint status, IntPtr queryContext, IntPtr instance);

    [StructLayout(LayoutKind.Sequential)]
    private struct DnsServiceBrowseRequestNative
    {
        public uint Version;
        public uint InterfaceIndex;
        public IntPtr QueryName;
        public IntPtr BrowseCallback;
        public IntPtr QueryContext;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct DnsServiceResolveRequestNative
    {
        public uint Version;
        public uint InterfaceIndex;
        public IntPtr QueryName;
        public IntPtr ResolveCallback;
        public IntPtr QueryContext;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct DnsServiceCancel
    {
        public IntPtr Reserved;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct DnsRecordNative
    {
        public IntPtr Next;
        public IntPtr Name;
        public ushort Type;
        public ushort DataLength;
        public uint Flags;
        public uint Ttl;
        public uint Reserved;
        public IntPtr Data;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct DnsServiceInstanceNative
    {
        public IntPtr InstanceName;
        public IntPtr HostName;
        public IntPtr Ip4Address;
        public IntPtr Ip6Address;
        public ushort Port;
        public ushort Priority;
        public ushort Weight;
        public uint PropertyCount;
        public IntPtr Keys;
        public IntPtr Values;
        public uint InterfaceIndex;
    }

    private enum DnsFreeType
    {
        DnsFreeFlat = 0,
        DnsFreeRecordList = 1,
        DnsFreeParsedMessageFields = 2
    }

    [DllImport("dnsapi.dll", EntryPoint = "DnsServiceBrowse", SetLastError = true)]
    private static extern uint DnsServiceBrowse(
        IntPtr request,
        IntPtr cancel);

    [DllImport("dnsapi.dll", EntryPoint = "DnsServiceBrowseCancel", SetLastError = true)]
    private static extern uint DnsServiceBrowseCancel(IntPtr cancel);

    [DllImport("dnsapi.dll", EntryPoint = "DnsServiceResolve", SetLastError = true)]
    private static extern uint DnsServiceResolve(
        IntPtr request,
        IntPtr cancel);

    [DllImport("dnsapi.dll", EntryPoint = "DnsServiceResolveCancel", SetLastError = true)]
    private static extern uint DnsServiceResolveCancel(IntPtr cancel);

    [DllImport("dnsapi.dll", EntryPoint = "DnsRecordListFree", SetLastError = true)]
    private static extern void DnsRecordListFree(IntPtr records, DnsFreeType freeType);

    [DllImport("dnsapi.dll", EntryPoint = "DnsServiceFreeInstance", SetLastError = true)]
    private static extern void DnsServiceFreeInstance(IntPtr instance);
}
