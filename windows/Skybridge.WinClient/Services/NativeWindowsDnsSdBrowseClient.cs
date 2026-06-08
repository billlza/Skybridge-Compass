using System;
using System.Collections.Generic;
using System.Linq;
using System.Runtime.InteropServices;
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
    private const int MaxTxtProperties = 64;
    private static readonly TimeSpan CallbackDrainDelay = TimeSpan.FromMilliseconds(250);

    public async Task<WindowsDnsSdBrowseSnapshot> BrowseAsync(WindowsDnsSdBrowseRequest request)
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
            browseTasks.Add(BrowseServiceInstancesAsync(service, NormalizeBrowseQueryName(service), browseWindow));
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
            resolveTasks.Add(ResolveServiceInstanceAsync(target, resolveWindow));
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
        TimeSpan browseWindow)
    {
        var context = new BrowseCallbackContext(service, queryName);
        DnsServiceBrowseCallback callback = BrowseCallback;
        var contextHandle = GCHandle.Alloc(context);
        var queryNamePointer = Marshal.StringToHGlobalUni(queryName);
        var cancel = new DnsServiceCancel();

        try
        {
            var nativeRequest = new DnsServiceBrowseRequestNative
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
            var status = DnsServiceBrowse(ref nativeRequest, ref cancel);
            if (status != DnsRequestPending)
            {
                context.AddFact("Native browse", FormatStatus(status), "DnsServiceBrowse did not enter the pending asynchronous state.");
                return context.ToResult();
            }

            await Task.Delay(browseWindow).ConfigureAwait(false);
            var cancelStatus = DnsServiceBrowseCancel(ref cancel);
            if (cancelStatus != ErrorSuccess && cancelStatus != ErrorCancelled)
            {
                context.AddFact("Native browse cancel", FormatStatus(cancelStatus), "DnsServiceBrowseCancel returned a non-success status.");
            }

            await Task.Delay(CallbackDrainDelay).ConfigureAwait(false);
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
            Marshal.FreeHGlobal(queryNamePointer);
            if (contextHandle.IsAllocated)
            {
                contextHandle.Free();
            }

            GC.KeepAlive(callback);
        }
    }

    private static async Task<NativeResolveResult> ResolveServiceInstanceAsync(
        NativeResolveTarget target,
        TimeSpan resolveWindow)
    {
        var context = new ResolveCallbackContext(target);
        DnsServiceResolveComplete callback = ResolveCallback;
        var contextHandle = GCHandle.Alloc(context);
        var queryNamePointer = Marshal.StringToHGlobalUni(target.InstanceName);
        var cancel = new DnsServiceCancel();

        try
        {
            var nativeRequest = new DnsServiceResolveRequestNative
            {
                Version = DnsQueryRequestVersion1,
                InterfaceIndex = 0,
                QueryName = queryNamePointer,
                ResolveCallback = Marshal.GetFunctionPointerForDelegate(callback),
                QueryContext = GCHandle.ToIntPtr(contextHandle)
            };

            var status = DnsServiceResolve(ref nativeRequest, ref cancel);
            if (status != DnsRequestPending)
            {
                context.AddFact("Native resolve", FormatStatus(status), $"DnsServiceResolve did not enter the pending state for {target.InstanceName}.");
                return context.ToResult();
            }

            await Task.Delay(resolveWindow).ConfigureAwait(false);
            var cancelStatus = DnsServiceResolveCancel(ref cancel);
            if (cancelStatus != ErrorSuccess && cancelStatus != ErrorCancelled)
            {
                context.AddFact("Native resolve cancel", FormatStatus(cancelStatus), "DnsServiceResolveCancel returned a non-success status.");
            }

            await Task.Delay(CallbackDrainDelay).ConfigureAwait(false);
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
            Marshal.FreeHGlobal(queryNamePointer);
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
                context.AddFact("Native browse callback", FormatStatus(status), "DnsServiceBrowse callback returned a non-success status.");
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
            context?.AddFact("Native browse callback", "parse error", ex.Message);
        }
        finally
        {
            if (dnsRecord != IntPtr.Zero)
            {
                DnsRecordListFree(dnsRecord, DnsFreeType.DnsFreeRecordList);
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
                context.AddFact("Native resolve callback", FormatStatus(status), "DnsServiceResolve callback returned a non-success status.");
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
            context?.AddFact("Native resolve callback", "parse error", ex.Message);
        }
        finally
        {
            if (instance != IntPtr.Zero)
            {
                DnsServiceFreeInstance(instance);
            }
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

        var parts = new List<string>();
        var count = (int)Math.Min(native.PropertyCount, (uint)MaxTxtProperties);
        for (var index = 0; index < count; index++)
        {
            var keyPointer = Marshal.ReadIntPtr(native.Keys, index * IntPtr.Size);
            if (keyPointer == IntPtr.Zero)
            {
                continue;
            }

            var key = Marshal.PtrToStringUni(keyPointer);
            if (string.IsNullOrWhiteSpace(key))
            {
                continue;
            }

            var valuePointer = Marshal.ReadIntPtr(native.Values, index * IntPtr.Size);
            var value = valuePointer == IntPtr.Zero ? "" : Marshal.PtrToStringUni(valuePointer) ?? "";
            parts.Add($"{key}={value}");
        }

        return string.Join(";", parts);
    }

    private static string FormatStatus(uint status) =>
        status == ErrorSuccess ? "success" : $"status {status}";

    private sealed class BrowseCallbackContext
    {
        private readonly object _sync = new();
        private readonly List<string> _instanceNames = new();
        private readonly List<DiscoveryBrowserFact> _facts = new();

        public BrowseCallbackContext(string service, string queryName)
        {
            Service = service;
            QueryName = queryName;
        }

        public string Service { get; }

        public string QueryName { get; }

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

        public NativeBrowseResult ToResult()
        {
            lock (_sync)
            {
                return new NativeBrowseResult(Service, _instanceNames.ToArray(), _facts.ToArray());
            }
        }
    }

    private sealed class ResolveCallbackContext
    {
        private readonly object _sync = new();
        private readonly List<WindowsDnsSdResolvedTxtRecord> _records = new();
        private readonly List<DiscoveryBrowserFact> _facts = new();

        public ResolveCallbackContext(NativeResolveTarget target)
        {
            Target = target;
        }

        public NativeResolveTarget Target { get; }

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

        public NativeResolveResult ToResult()
        {
            lock (_sync)
            {
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
        ref DnsServiceBrowseRequestNative request,
        ref DnsServiceCancel cancel);

    [DllImport("dnsapi.dll", EntryPoint = "DnsServiceBrowseCancel", SetLastError = true)]
    private static extern uint DnsServiceBrowseCancel(ref DnsServiceCancel cancel);

    [DllImport("dnsapi.dll", EntryPoint = "DnsServiceResolve", SetLastError = true)]
    private static extern uint DnsServiceResolve(
        ref DnsServiceResolveRequestNative request,
        ref DnsServiceCancel cancel);

    [DllImport("dnsapi.dll", EntryPoint = "DnsServiceResolveCancel", SetLastError = true)]
    private static extern uint DnsServiceResolveCancel(ref DnsServiceCancel cancel);

    [DllImport("dnsapi.dll", EntryPoint = "DnsRecordListFree", SetLastError = true)]
    private static extern void DnsRecordListFree(IntPtr records, DnsFreeType freeType);

    [DllImport("dnsapi.dll", EntryPoint = "DnsServiceFreeInstance", SetLastError = true)]
    private static extern void DnsServiceFreeInstance(IntPtr instance);
}
