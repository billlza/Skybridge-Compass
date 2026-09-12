using System.Net.Http;
using System.Runtime.Versioning;
using System.Text.Json;
using Skybridge.WinClient.Services;
using Skybridge.WinClient.ViewModels;

internal static class AccountDeviceLiveValidation
{
    [SupportedOSPlatform("windows10.0.19041")]
    internal static async Task RunAsync(string directory)
    {
        Directory.CreateDirectory(directory);
        string result=Path.Combine(directory,"account-live.json");
        if(File.Exists(result))throw new IOException("Live account evidence already exists.");
        string stage="authentication";
        try
        {
            var account=new AccountSessionCoordinator();
            var hydrated=await account.HydrateFromStoreAsync();
            if(!hydrated.Success)throw new InvalidOperationException("Native account hydration: "+hydrated.FailureKind);
            var auth=await account.GetDeviceAuthenticationAsync(default)??throw new InvalidOperationException("Native account is not signed in.");
            stage="device identity";
            await using var workspace=new WindowsDeviceWorkspace();
            var binding=await workspace.AccountIdentityAsync(default);
            var metadata=await WindowsAccountDeviceMetadata.ReadAsync(default);
            await File.WriteAllTextAsync(Path.Combine(directory,"current-device.json"),JsonSerializer.Serialize(new{auth.Subject,auth.TenantId,binding.DeviceId,binding.ProtocolSigningAlgorithmWireName,binding.ProtocolPublicKeyFingerprint,metadata},new JsonSerializerOptions{WriteIndented=true}));
            stage="presence and account list";
            using var http=new HttpClient(new HttpClientHandler{AllowAutoRedirect=false}){Timeout=TimeSpan.FromSeconds(8)};
            using var deadline=new CancellationTokenSource(TimeSpan.FromSeconds(25));
            var snapshot=await new AccountDeviceRosterClient(http).RefreshAsync(auth,binding,metadata,deadline.Token);
            await File.WriteAllTextAsync(result,JsonSerializer.Serialize(new{success=true,callerActive=snapshot.Devices.Any(d=>d.IsCaller&&d.Status=="active"),snapshot},new JsonSerializerOptions{WriteIndented=true}));
        }
        catch(Exception e)
        {
            await File.WriteAllTextAsync(result,JsonSerializer.Serialize(new{success=false,stage,errorType=e.GetType().Name,message=e.Message,stack=e.StackTrace},new JsonSerializerOptions{WriteIndented=true}));
            throw;
        }
    }
}
