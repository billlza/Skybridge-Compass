using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text;
using Microsoft.Win32;

namespace Skybridge.WinClient.Services;

internal static class WindowsAccountDeviceMetadata
{
    [System.Runtime.Versioning.SupportedOSPlatform("windows10.0.19041")]
    internal static Task<AccountDeviceMetadata> ReadAsync(CancellationToken ct) => Task.Run(() =>
    {
        ct.ThrowIfCancellationRequested();
        using var bios=Registry.LocalMachine.OpenSubKey(@"HARDWARE\DESCRIPTION\System\BIOS");
        string? model=NormalizeModel(bios?.GetValue("SystemProductName") as string);
        var addresses=NetworkInterface.GetAllNetworkInterfaces().Where(n=>n.OperationalStatus==OperationalStatus.Up && n.NetworkInterfaceType is not (NetworkInterfaceType.Loopback or NetworkInterfaceType.Tunnel))
            .SelectMany(n=>n.GetIPProperties().UnicastAddresses).Select(a=>a.Address).Where(IsLan).Select(a=>a.ToString()).Distinct().Take(8).ToArray();
        return new AccountDeviceMetadata(Environment.MachineName,model,"Windows "+Environment.OSVersion.Version,addresses);
    },ct);
    internal static string? NormalizeModel(string? raw)
    {
        if(string.IsNullOrWhiteSpace(raw))return null;
        string value=raw.Trim();
        if(value.Equals("System Product Name",StringComparison.OrdinalIgnoreCase) || value.Equals("To Be Filled By O.E.M.",StringComparison.OrdinalIgnoreCase)
            || value.Equals("Default string",StringComparison.OrdinalIgnoreCase))return null;
        if(value.Any(char.IsControl) || Encoding.UTF8.GetByteCount(value)>64)throw new InvalidDataException("Firmware product model is invalid.");
        return value;
    }
    private static bool IsLan(IPAddress address)
    {
        var b=address.GetAddressBytes();
        return address.AddressFamily==AddressFamily.InterNetwork ? b[0]==10 || b[0]==192&&b[1]==168 || b[0]==172&&b[1]>=16&&b[1]<=31
            : address.AddressFamily==AddressFamily.InterNetworkV6 && (b[0]&0xfe)==0xfc;
    }
}
