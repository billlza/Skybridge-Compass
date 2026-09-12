using System.Text;
using System.Text.Json;

namespace Skybridge.WinClient.Services;

// This is a request snapshot of an already server-verified session. It does not
// authenticate a JWT by decoding it, and never includes credentials in ToString.
internal sealed class AccountDeviceAuthentication
{
    private AccountDeviceAuthentication(string token, string subject, string tenant, SessionAuthority authority)
    { AccessToken = token; Subject = subject; TenantId = tenant; Authority = authority; }
    internal string AccessToken { get; }
    internal string Subject { get; }
    internal string TenantId { get; }
    internal SessionAuthority Authority { get; }
    internal string Scope => Authority.Issuer + "/" + Subject;
    public override string ToString() => "Authenticated account request (credentials redacted)";

    internal static AccountDeviceAuthentication FromVerifiedSession(string token, SessionAuthority authority, string subject)
    {
        if (!SessionJwtValidator.TryValidate(token, authority, subject, true, out _, out _))
            throw new InvalidDataException("Account request requires an unexpired authority-bound token.");
        string payload = token.Split('.')[1].Replace('-', '+').Replace('_', '/');
        using var doc = JsonDocument.Parse(Convert.FromBase64String(payload.PadRight((payload.Length + 3) / 4 * 4, '=')));
        var tenants = new HashSet<string>(StringComparer.Ordinal);
        if (doc.RootElement.TryGetProperty("app_metadata", out var metadata) && metadata.ValueKind != JsonValueKind.Null)
        {
            if (metadata.ValueKind != JsonValueKind.Object) throw new InvalidDataException("Protected account metadata is invalid.");
            foreach (string name in new[] { "tenant_id", "tenantId", "org_id", "workspace_id" })
            {
                if (!metadata.TryGetProperty(name, out var raw) || raw.ValueKind == JsonValueKind.Null) continue;
                if (raw.ValueKind != JsonValueKind.String) throw new InvalidDataException("Protected tenant claim is not a string.");
                string value = raw.GetString() ?? throw new InvalidDataException("Protected tenant claim is null.");
                if (value.Length == 0 || value.Trim() != value || Encoding.UTF8.GetByteCount(value) > 256 || value.Any(char.IsControl))
                    throw new InvalidDataException("Protected tenant claim is invalid.");
                tenants.Add(value);
            }
        }
        if (tenants.Count > 1) throw new InvalidDataException("Protected tenant claims conflict.");
        return new(token, subject, tenants.SingleOrDefault() ?? subject, authority);
    }
}
