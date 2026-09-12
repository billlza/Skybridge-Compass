using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace Skybridge.WinClient.Services.RemoteControl;

public sealed class WindowsRemoteControlAdvertisementOptions
{
    private static readonly Encoding HostNameEncoding = new UTF8Encoding(false, true);

    public WindowsRemoteControlAdvertisementOptions(
        string instanceName,
        string hostName,
        IPAddress localAddress,
        int port,
        uint interfaceIndex,
        IReadOnlyDictionary<string, string> txtProperties)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(instanceName);
        ArgumentException.ThrowIfNullOrWhiteSpace(hostName);
        ArgumentNullException.ThrowIfNull(localAddress);
        ArgumentNullException.ThrowIfNull(txtProperties);
        if (Encoding.UTF8.GetByteCount(instanceName) > 63 ||
            instanceName.Any(character => char.IsControl(character) || character is '.' or '\\'))
        {
            throw new ArgumentException("The DNS-SD instance must be one label of at most 63 UTF-8 bytes without dots or backslashes.", nameof(instanceName));
        }

        // Preserve the system's Unicode DNS name. Converting it to an ASCII
        // alias would point SRV at a different name that Windows may not publish.
        var normalizedHost = hostName.EndsWith('.') ? hostName[..^1] : hostName;
        if (Uri.CheckHostName(normalizedHost) != UriHostNameType.Dns ||
            HostNameEncoding.GetByteCount(normalizedHost) > 253 ||
            !normalizedHost.EndsWith(".local", StringComparison.OrdinalIgnoreCase) ||
            normalizedHost.Split('.').Any(label => HostNameEncoding.GetByteCount(label) is 0 or > 63 ||
                label[0] == '-' || label[^1] == '-'))
        {
            throw new ArgumentException("The mDNS host must be a valid Unicode DNS name ending in .local, with labels of at most 63 UTF-8 bytes.", nameof(hostName));
        }

        if (port is < 1 or > 65535)
        {
            throw new ArgumentOutOfRangeException(nameof(port), "The advertisement must use the listener's assigned TCP port.");
        }

        if (interfaceIndex == 0)
        {
            throw new ArgumentOutOfRangeException(nameof(interfaceIndex), "A remote-control advertisement must select its LAN interface.");
        }

        if (localAddress.AddressFamily is not AddressFamily.InterNetwork and not AddressFamily.InterNetworkV6 ||
            localAddress.Equals(IPAddress.Any) || localAddress.Equals(IPAddress.IPv6Any) ||
            IPAddress.IsLoopback(localAddress) || localAddress.IsIPv6Multicast ||
            localAddress.Equals(IPAddress.Broadcast) ||
            (localAddress.AddressFamily == AddressFamily.InterNetwork && localAddress.GetAddressBytes()[0] >= 224))
        {
            throw new ArgumentException("The advertisement requires a concrete unicast LAN address.", nameof(localAddress));
        }

        var properties = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var property in txtProperties)
        {
            properties.Add(property.Key, property.Value);
        }

        var expectedKeys = new HashSet<string>(StringComparer.Ordinal) { "version", "deviceId", "pubKeyFP", "platform" };
        if (properties.ContainsKey("osVersion"))
        {
            expectedKeys.Add("osVersion");
            var version = RequireProperty(properties, "osVersion");
            if (!version.StartsWith("Windows ", StringComparison.Ordinal) || !QPeriaptPeerPlatform.IsEligible(version))
            { throw new InvalidDataException("Windows Q-Periapt discovery requires the canonical supported kernel version."); }
        }
        if (!expectedKeys.SetEquals(properties.Keys) ||
            RequireProperty(properties, "version") != "2" || RequireProperty(properties, "platform") != "windows")
        {
            throw new InvalidDataException("Version-2 remote-control discovery requires version, deviceId, pubKeyFP, lowercase windows platform and an optional validated osVersion.");
        }

        var deviceId = RequireProperty(properties, "deviceId");
        if (deviceId.Length is < 16 or > 128 ||
            deviceId.Any(character => !char.IsAsciiLetterOrDigit(character) && character is not ('.' or '_' or ':' or '-')))
        {
            throw new InvalidDataException("The advertised device identity must contain 16 to 128 canonical ASCII characters.");
        }

        var fingerprint = RequireProperty(properties, "pubKeyFP");
        if (fingerprint.Length != 64 || fingerprint.Any(character => character is not (>= '0' and <= '9') and not (>= 'a' and <= 'f')))
        {
            throw new InvalidDataException("The advertised protocol identity fingerprint must be 64 lowercase hex characters.");
        }

        if (!NativeWindowsDnsSdTxtRecordCodec.TrySerialize(properties.ToArray(), out _, out var error))
        {
            throw new InvalidDataException(error);
        }

        var wireBytes = 0;
        foreach (var property in properties)
        {
            var entryBytes = Encoding.UTF8.GetByteCount(property.Key) + Encoding.UTF8.GetByteCount(property.Value) + 1;
            if (entryBytes > 255)
            {
                throw new InvalidDataException($"DNS-SD TXT property '{property.Key}' exceeds one 255-byte TXT string.");
            }

            wireBytes += 1 + entryBytes;
        }

        if (wireBytes > 200)
        {
            throw new InvalidDataException("The version-2 DNS-SD advertisement exceeds its 200-byte wire budget.");
        }

        InstanceName = instanceName;
        HostName = normalizedHost;
        LocalAddress = localAddress.AddressFamily == AddressFamily.InterNetworkV6
            ? new IPAddress(localAddress.GetAddressBytes(), localAddress.ScopeId)
            : new IPAddress(localAddress.GetAddressBytes());
        Port = port;
        InterfaceIndex = interfaceIndex;
        TxtProperties = new ReadOnlyDictionary<string, string>(properties);
    }

    public string InstanceName { get; }
    public string ServiceName => $"{InstanceName}.{SkyBridgeProtocolConstants.RemoteDesktopDnsSdService}.local";
    public string HostName { get; }
    public IPAddress LocalAddress { get; }
    public int Port { get; }
    public uint InterfaceIndex { get; }
    public IReadOnlyDictionary<string, string> TxtProperties { get; }

    private static string RequireProperty(IReadOnlyDictionary<string, string> properties, string key) =>
        properties.TryGetValue(key, out var value) && !string.IsNullOrWhiteSpace(value)
            ? value
            : throw new InvalidDataException($"DNS-SD remote-control advertisement is missing '{key}'.");
}

/// <summary>
/// Publishes a live listener only after the native mDNS registration callback.
/// TXT identity fields are discovery hints; the session still verifies its peer.
/// </summary>
public sealed class WindowsRemoteControlAdvertisement : IAsyncDisposable
{
    private readonly IWindowsDnsSdAdvertisementBackend _backend;
    private readonly SemaphoreSlim _lifecycle = new(1, 1);
    private readonly object _stateGate = new();
    private CancellationTokenSource? _startupCancellation;
    private bool _disposed;
    private volatile bool _registered;

    public WindowsRemoteControlAdvertisement()
        : this(new WindowsDnsSdAdvertisementBackend())
    {
    }

    internal WindowsRemoteControlAdvertisement(IWindowsDnsSdAdvertisementBackend backend)
    {
        _backend = backend ?? throw new ArgumentNullException(nameof(backend));
    }

    public bool IsRegistered => _registered;

    public async Task StartAsync(
        TcpListener listener,
        WindowsRemoteControlAdvertisementOptions options,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(options);
        ValidateListener(listener, options);
        await _lifecycle.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            lock (_stateGate)
            {
                ObjectDisposedException.ThrowIf(_disposed, this);
                if (_backend.IsRegistered)
                {
                    throw new InvalidOperationException("A remote-control advertisement is already registered.");
                }

                _startupCancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            }

            try
            {
                await _backend.RegisterAsync(options).ConfigureAwait(false);
                // Native registration owns its request until its callback. A
                // cancellation during that operation is settled by deregistering
                // the exact result, never by freeing an in-flight request.
                _startupCancellation.Token.ThrowIfCancellationRequested();
                ValidateListener(listener, options);
                _registered = true;
            }
            catch (Exception startError)
            {
                try
                {
                    await _backend.DeregisterAsync().ConfigureAwait(false);
                }
                catch (Exception cleanupError)
                {
                    _registered = _backend.IsRegistered;
                    throw new AggregateException("Remote-control advertisement start failed and its registration could not be removed.", startError, cleanupError);
                }

                throw;
            }
            finally
            {
                lock (_stateGate)
                {
                    _startupCancellation.Dispose();
                    _startupCancellation = null;
                }
            }
        }
        finally
        {
            _lifecycle.Release();
        }
    }

    public async Task StopAsync(CancellationToken cancellationToken = default)
    {
        lock (_stateGate)
        {
            _startupCancellation?.Cancel();
        }

        await _lifecycle.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await _backend.DeregisterAsync().ConfigureAwait(false);
            _registered = false;
        }
        finally
        {
            _lifecycle.Release();
        }
    }

    public async ValueTask DisposeAsync()
    {
        lock (_stateGate)
        {
            _disposed = true;
        }

        await StopAsync().ConfigureAwait(false);
    }

    internal static void ValidateListener(TcpListener listener, WindowsRemoteControlAdvertisementOptions options)
    {
        ArgumentNullException.ThrowIfNull(listener);
        if (!listener.Server.IsBound ||
            listener.Server.GetSocketOption(SocketOptionLevel.Socket, SocketOptionName.AcceptConnection) is not int accepting || accepting != 1 ||
            listener.LocalEndpoint is not IPEndPoint endpoint || endpoint.Port != options.Port ||
            (endpoint.AddressFamily != options.LocalAddress.AddressFamily && !listener.Server.DualMode) ||
            (!endpoint.Address.Equals(IPAddress.Any) && !endpoint.Address.Equals(IPAddress.IPv6Any) && !endpoint.Address.Equals(options.LocalAddress)))
        {
            throw new InvalidOperationException("DNS-SD registration requires a listening TCP socket on the advertised address and port.");
        }
    }
}

internal interface IWindowsDnsSdAdvertisementBackend
{
    bool IsRegistered { get; }
    Task RegisterAsync(WindowsRemoteControlAdvertisementOptions options);
    Task DeregisterAsync();
}
