using System;
using System.ComponentModel;
using System.Linq;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading.Tasks;

namespace Skybridge.WinClient.Services.RemoteControl;

internal sealed class WindowsDnsSdAdvertisementBackend : IWindowsDnsSdAdvertisementBackend
{
    private const uint DnsRequestPending = 9506;
    private const int ErrorMoreData = 234;
    private IntPtr _requestedInstance;
    private IntPtr _registeredInstance;
    private NativeRequest? _registrationRequest;
    private bool _registered;

    public bool IsRegistered => _registered;

    internal static string GetLocalHostName()
    {
        if (!OperatingSystem.IsWindowsVersionAtLeast(10))
        {
            throw new PlatformNotSupportedException("Remote-control DNS-SD advertisement requires Windows 10 or later.");
        }

        // A successful DnsServiceRegister callback does not guarantee address
        // records for an application-created alias.
        // Use the physical DNS hostname whose addresses Windows publishes.
        uint length = 0;
        var sizeReturned = GetComputerNameExW(ComputerNameFormat.PhysicalDnsHostname, null, ref length);
        var sizeError = Marshal.GetLastPInvokeError();
        if (sizeReturned)
        {
            throw new InvalidOperationException("Windows returned a DNS hostname without a destination buffer.");
        }

        if (sizeError != ErrorMoreData)
        {
            throw new Win32Exception(sizeError, "Unable to read the size of the Windows DNS hostname.");
        }

        if (length == 0)
        {
            throw new InvalidOperationException("Windows returned an empty DNS hostname buffer size.");
        }

        var buffer = new StringBuilder(checked((int)length));
        if (!GetComputerNameExW(ComputerNameFormat.PhysicalDnsHostname, buffer, ref length))
        {
            throw new Win32Exception(Marshal.GetLastPInvokeError(), "Unable to read the Windows DNS hostname.");
        }

        if (buffer.Length == 0)
        {
            throw new InvalidOperationException("Windows returned an empty DNS hostname.");
        }

        return buffer.ToString() + ".local";
    }

    public async Task RegisterAsync(WindowsRemoteControlAdvertisementOptions options)
    {
        ArgumentNullException.ThrowIfNull(options);
        if (!OperatingSystem.IsWindowsVersionAtLeast(10))
        {
            throw new PlatformNotSupportedException("Remote-control DNS-SD advertisement requires Windows 10 or later.");
        }

        if (_requestedInstance != IntPtr.Zero || _registered)
        {
            throw new InvalidOperationException("The DNS-SD backend already owns a registration.");
        }

        var properties = options.TxtProperties.OrderBy(property => property.Key, StringComparer.Ordinal).ToArray();
        var address = options.LocalAddress.GetAddressBytes();
        var addressBuffer = Marshal.AllocHGlobal(address.Length);
        try
        {
            Marshal.Copy(address, 0, addressBuffer, address.Length);
            _requestedInstance = DnsServiceConstructInstance(
                options.ServiceName,
                options.HostName,
                options.LocalAddress.AddressFamily == AddressFamily.InterNetwork ? addressBuffer : IntPtr.Zero,
                options.LocalAddress.AddressFamily == AddressFamily.InterNetworkV6 ? addressBuffer : IntPtr.Zero,
                checked((ushort)options.Port),
                0,
                0,
                checked((uint)properties.Length),
                properties.Select(property => property.Key).ToArray(),
                properties.Select(property => property.Value).ToArray());
        }
        finally
        {
            // DnsServiceConstructInstance owns copies of the supplied addresses.
            Marshal.FreeHGlobal(addressBuffer);
        }

        if (_requestedInstance == IntPtr.Zero)
        {
            throw new Win32Exception(Marshal.GetLastPInvokeError(), "Unable to construct the remote-control DNS-SD service instance.");
        }

        try
        {
            _registrationRequest = new NativeRequest(_requestedInstance, options.InterfaceIndex);
            var immediateStatus = DnsServiceRegister(_registrationRequest.Pointer, IntPtr.Zero);
            if (immediateStatus != DnsRequestPending)
            {
                throw Error(immediateStatus, "register remote-control DNS-SD service");
            }

            var completion = await _registrationRequest.Completion.ConfigureAwait(false);
            if (completion.Status != 0)
            {
                FreeReturnedInstance(completion.Instance);
                throw Error(completion.Status, "complete remote-control DNS-SD registration");
            }

            // The callback's optional result may contain the effective instance
            // name assigned by mDNS. Preserve it for exact deregistration.
            _registeredInstance = completion.Instance == IntPtr.Zero ? _requestedInstance : completion.Instance;
            _registered = true;
        }
        catch
        {
            FreeOwnedInstances();
            throw;
        }
    }

    public async Task DeregisterAsync()
    {
        if (!_registered)
        {
            return;
        }

        if (_registrationRequest is null || _registeredInstance == IntPtr.Zero)
        {
            throw new InvalidOperationException("An active DNS-SD registration lost its native owner.");
        }

        // Distinct callback owners prevent a delayed registration completion
        // from being mistaken for the deregistration receipt.
        using var request = new NativeRequest(_registeredInstance, _registrationRequest.InterfaceIndex);
        var immediateStatus = DnsServiceDeRegister(request.Pointer, IntPtr.Zero);
        if (immediateStatus != DnsRequestPending)
        {
            throw Error(immediateStatus, "deregister remote-control DNS-SD service");
        }

        var completion = await request.Completion.ConfigureAwait(false);
        FreeReturnedInstance(completion.Instance);
        if (completion.Status != 0)
        {
            // The registration still owns its buffers. A subsequent StopAsync
            // retries the same service instead of abandoning its native owner.
            throw Error(completion.Status, "complete remote-control DNS-SD deregistration");
        }

        _registered = false;
        FreeOwnedInstances();
    }

    private void FreeReturnedInstance(IntPtr instance)
    {
        if (instance != IntPtr.Zero && instance != _requestedInstance && instance != _registeredInstance)
        {
            DnsServiceFreeInstance(instance);
        }
    }

    private void FreeOwnedInstances()
    {
        _registrationRequest?.Dispose();
        _registrationRequest = null;
        if (_registeredInstance != IntPtr.Zero && _registeredInstance != _requestedInstance)
        {
            DnsServiceFreeInstance(_registeredInstance);
        }

        _registeredInstance = IntPtr.Zero;
        if (_requestedInstance != IntPtr.Zero)
        {
            DnsServiceFreeInstance(_requestedInstance);
            _requestedInstance = IntPtr.Zero;
        }
    }

    private static Win32Exception Error(uint status, string operation) =>
        new(unchecked((int)status), $"Unable to {operation} (DNS status {status}).");

    private readonly record struct NativeCompletion(uint Status, IntPtr Instance);

    private sealed class NativeRequest : IDisposable
    {
        private readonly RegisterCompletionCallback _callback;
        private readonly IntPtr _inputInstance;
        private readonly object _callbackGate = new();
        private readonly TaskCompletionSource<NativeCompletion> _completion = new(TaskCreationOptions.RunContinuationsAsynchronously);
        private IntPtr _returnedInstance;
        private bool _callbackDelivered;
        private IntPtr _pointer;

        public NativeRequest(IntPtr instance, uint interfaceIndex)
        {
            _inputInstance = instance;
            InterfaceIndex = interfaceIndex;
            _callback = Complete;
            var request = new RegisterRequest
            {
                Version = 1,
                InterfaceIndex = interfaceIndex,
                ServiceInstance = instance,
                Callback = Marshal.GetFunctionPointerForDelegate(_callback),
                QueryContext = IntPtr.Zero,
                Credentials = IntPtr.Zero,
                UnicastEnabled = 0
            };
            _pointer = Marshal.AllocHGlobal(Marshal.SizeOf<RegisterRequest>());
            Marshal.StructureToPtr(request, _pointer, false);
        }

        public uint InterfaceIndex { get; }
        public IntPtr Pointer => _pointer;
        public Task<NativeCompletion> Completion => _completion.Task;

        private void Complete(uint status, IntPtr context, IntPtr instance)
        {
            lock (_callbackGate)
            {
                if (_callbackDelivered)
                {
                    if (instance != IntPtr.Zero && instance != _inputInstance && instance != _returnedInstance)
                    {
                        DnsServiceFreeInstance(instance);
                    }

                    return;
                }

                _callbackDelivered = true;
                _returnedInstance = instance;
                _completion.SetResult(new NativeCompletion(status, instance));
            }
        }

        public void Dispose()
        {
            if (_pointer != IntPtr.Zero)
            {
                Marshal.FreeHGlobal(_pointer);
                _pointer = IntPtr.Zero;
            }

            GC.KeepAlive(_callback);
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct RegisterRequest
    {
        public uint Version;
        public uint InterfaceIndex;
        public IntPtr ServiceInstance;
        public IntPtr Callback;
        public IntPtr QueryContext;
        public IntPtr Credentials;
        public int UnicastEnabled;
    }

    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    private delegate void RegisterCompletionCallback(uint status, IntPtr context, IntPtr instance);

    private enum ComputerNameFormat { PhysicalDnsHostname = 5 }

    [DllImport("kernel32.dll", ExactSpelling = true, CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetComputerNameExW(ComputerNameFormat format, StringBuilder? buffer, ref uint size);

    [DllImport("dnsapi.dll", ExactSpelling = true, CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr DnsServiceConstructInstance(
        string serviceName,
        string hostName,
        IntPtr ipv4,
        IntPtr ipv6,
        ushort port,
        ushort priority,
        ushort weight,
        uint propertyCount,
        [MarshalAs(UnmanagedType.LPArray, ArraySubType = UnmanagedType.LPWStr)] string[] keys,
        [MarshalAs(UnmanagedType.LPArray, ArraySubType = UnmanagedType.LPWStr)] string[] values);

    [DllImport("dnsapi.dll", ExactSpelling = true)]
    private static extern uint DnsServiceRegister(IntPtr request, IntPtr cancel);

    [DllImport("dnsapi.dll", ExactSpelling = true)]
    private static extern uint DnsServiceDeRegister(IntPtr request, IntPtr cancel);

    [DllImport("dnsapi.dll", ExactSpelling = true)]
    private static extern void DnsServiceFreeInstance(IntPtr instance);
}
