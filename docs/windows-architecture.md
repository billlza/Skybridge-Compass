# Skybridge Windows client architecture

The WinUI client is organized to keep UI binding, engine integration, and platform FFI clearly separated so the Rust core can be slotted in without disrupting the shell.

## ADR alignment
- The mac reference ADR is `Docs/ADR-0001-SkyBridge-Core-Transport-Matrix.md` on `tdsc-2026-01-0318-ios-sim-fix-20260211-adr` (latest TDSC mac branch checked on 2026-06-07). It treats WebRTC, MsQuic, and Apple Network.framework as transport adapters. SkyBridge Core owns identity, pairing, trust, handshake, logical channels, transport selection, traffic padding, and audit semantics.
- Windows-to-Windows same-LAN sessions must prefer `WindowsNativeMsQuicTransport`; Windows-to-Apple MVP interop should use `WebRTCInteropTransport`; Apple-to-Apple remains Apple native and must not be replaced by WebRTC by default.
- The Rust core now exposes `transport` selection primitives plus `skybridge_select_transport` over FFI so the Windows UI can request an auditable plan instead of hardcoding protocol state.
- `channel.rs` maps Core logical channels to adapter-specific channel names and exposes them through `skybridge_map_channel` / `CoreBridge.MapChannelAsync`: MsQuic uses streams for control/file/clipboard and datagrams for telemetry/realtime; WebRTC uses separate DataChannel labels per logical channel; Apple native keeps the same Core names without switching Apple-to-Apple to WebRTC.
- The Rust core also defines the ADR canonical crypto suite IDs (`0x0001`, `0x0101`, `0x1001`, `0x1002`) in `suite.rs`; offered suites are derived from runtime provider capabilities and classic fallback requires an explicit policy gate.
- The Rust core provides SBP2 traffic-padding framing in `padding.rs` using the ADR wire shape (`SBP2` magic, `actual_len` u32be, payload, random padding). Transport adapters still need to call it after handshake policy enables padding.
- `frame.rs` defines the Core channel frame envelope (`SBF1` magic, version, channel, flags, sequence, payload length, payload) so MsQuic/WebRTC/Relay adapters can carry the same framed payloads. SBP2-padded payloads are flagged in the frame rather than inferred by transport-specific code.
- `connection.rs` combines transport selection, crypto suite negotiation, logical-channel binding, SBP2 policy, and frame metadata into one auditable Core connection plan. Windows adapters and UI should consume this plan instead of re-deriving protocol decisions in C#.

## Technology stack check
- **WinUI shell:** `net10.0-windows10.0.19041.0` with Windows App SDK `2.1.3`. Microsoft lists .NET 10 as active LTS through November 2028, and NuGet/Microsoft's Windows App SDK downloads page list `2.1.3` as the current stable package/runtime.
- **Windows native transport:** MsQuic remains the intended native QUIC adapter for Windows-to-Windows paths. It should sit below SkyBridge Core transport binding and emit ETW/EventSource-style diagnostics rather than owning session identity.
- **WebRTC interop:** Use a native DataChannel adapter such as libdatachannel for Windows-to-Apple MVP interop. libdatachannel remains active in 2026, with GitHub releases showing v0.24.3 as latest, and supports Windows plus Apple platforms, making it suitable as an adapter candidate, not as the protocol authority.
- **Rust core and CLI:** Keep the current Rust 2021 edition until a dedicated migration is scheduled. `src/cli.rs` and the `skybridge` binary are thin adapters over reusable Core functions; CLI smoke tests cover version, transport selection, channel profile/map, frame describe, connection plan, crypto suite offer/select, and invalid-command behavior. SBP2 padding has Core unit tests for fixed, bucketed, and malformed frame behavior.

## Layers
- **ViewModels** (`windows/Skybridge.WinClient/ViewModels`): presentation logic and bindable state. `SessionViewModel` owns connection status, bitrate/framerate selections, async commands for connect/disconnect/heartbeat, and busy-state handling to keep the UI responsive.
- **Services** (`windows/Skybridge.WinClient/Services`): engine abstractions behind `IEngineClient`. The stub `DummyEngineClient` simulates connect/disconnect/heartbeat flows and raises state-change events; it will be replaced by a real FFI-backed implementation that calls into the Rust `ffi` module.
- **Views** (`windows/Skybridge.WinClient/MainWindow.xaml`): XAML-only bindings with no business logic in code-behind. The window creates the view model and relies on commands/properties for interactions.

## Planned Rust FFI integration
- Introduce a `FfiEngineClient` in `Services` that P/Invokes the C ABI exposed by `core/skybridge-core/src/ffi.rs` (e.g., `skybridge_engine_new`, `skybridge_engine_connect`, `skybridge_engine_shutdown`).
- Use `CoreBridge.SelectTransportAsync` / `skybridge_select_transport` to choose Apple-native, Windows MsQuic, WebRTC interop, relay, or TCP fallback plans from peer capabilities and path facts.
- Use `CoreBridge.MapChannelAsync` / `skybridge_map_channel` so Windows services consume Core logical-channel mappings instead of duplicating adapter policy in C#.
- Use `skybridge transport select` for operator smoke checks against the same Rust selector before WinUI or native adapter wiring is available.
- Use `skybridge channel map` to verify that each transport adapter uses channel-specific streams, datagrams, or DataChannels before real adapter wiring is enabled.
- Use `skybridge frame describe` to verify Core channel frame metadata and SBP2 padding flags before real adapter wiring is enabled.
- Use `skybridge connection plan` to verify the full Core-owned pre-adapter contract: selected transport, selected crypto suite, offered suites, channel bindings, frame header size, and SBP2 policy.
- Use `skybridge suite offer` and `skybridge suite select` to verify provider-derived suite offers, remote wire ID parsing, and downgrade audit behavior before platform crypto provider wiring is available.
- Map engine callbacks (state changes, input responses) to UI updates via events or observable properties on the view model.
- Keep heavy work off the UI thread by continuing to use async commands for connect/heartbeat; the FFI layer should marshal any blocking calls to thread-pool threads when necessary.

## Testing approach
- UI logic remains in view models and services, enabling unit tests against `SessionViewModel` without a XAML runtime.
- FFI glue can be validated with integration tests on Windows by mocking the Rust DLL exports or linking against the compiled core crate.
- Rust tests must cover transport selection defaults, channel reliability, transport binding digest changes, and FFI selector contracts.
- Channel mapping tests must prove WebRTC uses distinct DataChannel labels, Windows MsQuic uses stream/datagram mappings, Apple native does not route Apple-to-Apple through WebRTC, and TCP fallback is visible as head-of-line blocking risk.
- Suite tests must prove unknown suite IDs fail closed, offered suites come from actual capabilities, classic/P-256 fallback is policy-gated, and timeout cannot trigger crypto downgrade.
- SBP2 tests must prove payload roundtrip, bucket selection, padding statistics, too-small target rejection, missing bucket rejection, bad magic rejection, and truncated frame rejection.
- Frame tests must prove plain and SBP2-padded frame roundtrip, version/magic/channel/flag validation, truncated payload rejection, and CLI smoke coverage.
- Connection-plan tests must prove Windows-to-Apple interop selects WebRTC with distinct channels, Apple-to-Apple remains Apple native, unsupported peers fail closed, and timeout cannot create a classic crypto fallback plan.
- CLI smoke tests must launch the compiled `skybridge` binary and verify successful and failing basic commands.

## Sources checked on 2026-06-07
- TDSC mac ADR: https://github.com/billlza/Skybridge-Compass/blob/tdsc-2026-01-0318-ios-sim-fix-20260211-adr/Docs/ADR-0001-SkyBridge-Core-Transport-Matrix.md
- .NET lifecycle: https://learn.microsoft.com/en-us/lifecycle/products/microsoft-net-and-net-core
- Windows App SDK downloads: https://learn.microsoft.com/en-us/windows/apps/windows-app-sdk/downloads
- MsQuic release/support docs: https://microsoft.github.io/msquic/msquicdocs/docs/Release.html
- libdatachannel releases: https://github.com/paullouisageneau/libdatachannel/releases
