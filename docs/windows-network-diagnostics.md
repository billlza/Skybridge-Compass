# Windows network diagnostics

The top bar reads local interface counters independently from external requests.
`TopBarNetworkStatusClient` owns network I/O; `TopBarNetworkCoordinator` owns three
cancellable polling loops and posts results through the window dispatcher.

- Throughput: cumulative IP byte counters from active, non-loopback, non-tunnel
  interfaces, sampled every two seconds. A reset establishes a new baseline;
  an unreadable sample clears the baseline and reports an error.
- Latency: an HTTPS HEAD request to `https://www.microsoft.com/`, every 15 seconds.
  This is HTTP response time, including connection establishment when needed. It
  is neither ICMP latency nor a remote session's input latency.
- Location: `https://ipwho.is/?fields=success,ip,city,country_code`, every five
  minutes after success. The service source appears in the localized tooltip.
  A missing city still leaves a valid IP result. Proxy status describes the
  configured HTTP lookup route, including system and environment proxy settings.
  The resolver must return a distinct proxy address: `GetProxy` returning null or
  the destination itself means direct access. On Windows, `IsBypassed` returning
  false alone is not evidence of a proxy. This indicator does not detect VPNs,
  transparent gateways or the remote-control session's network path.

Windows previously used a Vercel endpoint that timed out on the validation host
and an IP service that returned HTTP 403. The current endpoints were explicitly
selected for reachable Windows diagnostics. The Mac application keeps its own
existing endpoint configuration; latency values from different destinations
must not be compared as measurements of the same route.

Location responses are limited to 16 KiB, and address/field types are validated.
Timeouts, unreachable services, HTTP status failures and malformed responses are
reported separately. Transient failures retry with bounded exponential delays;
HTTP 429 honors `Retry-After`. Cancellation retires all three loops before their
token source is released, and queued UI updates cannot publish after disposal.
No retry changes provider or reports a fabricated success.

## Validation

`dotnet run --project windows/Skybridge.WinClient.ContractTests/Skybridge.WinClient.ContractTests.csproj -p:TreatWarningsAsErrors=true`
checks response validation, cancellation, independent sampling, counter resets,
retry cadence and teardown. On Windows it uses the same x64 Core target as the
product. `Scripts/verify-windows-network-status.ps1` probes the real providers and
interface counters. Its output contains the current public IP and belongs in
local diagnostics, rather than public build logs.
