# Windows UI parity contract

This contract fixes the Windows shell entry points against the macOS reference so the port can add functionality without drifting from the existing product shape.

## Reference evidence
- macOS navigation order comes from `origin/tdsc-2026-01-0318-ios-sim-fix-20260211-adr:Sources/SkyBridgeCompassApp/Dashboard/Navigation/NavigationItem.swift`: Dashboard, Device Discovery, USB Management, File Transfer, Remote Desktop, Quantum, System Monitor, Settings.
- macOS dashboard routing is implemented in `origin/tdsc-2026-01-0318-ios-sim-fix-20260211-adr:Sources/SkyBridgeCompassApp/Dashboard/DashboardView.swift`.
- macOS top bar includes connection state, FPS/diagnostics, notifications, theme, and manual connection entry points in `origin/tdsc-2026-01-0318-ios-sim-fix-20260211-adr:Sources/SkyBridgeCompassApp/Dashboard/TopBar/TopNavigationBarView.swift`.
- macOS feature surfaces also include device discovery modes, file transfer actions/history, remote desktop session controls, system monitoring, settings tabs, security/trust/approval, and menu bar quick actions.

## Windows shell contract
- The Windows side navigation must keep the same feature order as the macOS `NavigationItem` list.
- The first visible viewport must be the product workspace, not a landing page. The shell is left navigation, top status/action bar, and main workspace.
- The top bar must surface the selected feature, Core status, and connection controls from the shared session view model.
- Unimplemented feature pages may show a disabled or placeholder workspace, but their navigation entry must remain present so parity gaps are visible and testable. Device Discovery is no longer a pure placeholder: it has a manual Core-validated Bonjour service/TXT parser while real DNS-SD browsing and pairing remain pending.
- USB Management must keep the macOS device-management shape visible: refresh, last scan, MFi certified count, Android device count, storage device count, total device count, empty state, device list, device ID, vendor ID, product ID, serial number, connection interface, and capabilities. Until Windows USB providers are wired, MFi/Android/vendor/product/serial details must be labeled pending instead of synthesized.
- File Transfer must keep the macOS quick-action shape visible: select files, select folder, QR sharing, transfer queue, transfer history, HMAC, and signature status. Until the real file picker and transport are wired, those actions may remain disabled but the queue/history/security workspace must be driven by Core contracts.
- Remote Desktop must keep the macOS session shape visible: recommended connect, advanced connect, connection mode, active/recent sessions, performance overlay, quality controls, settings, fullscreen, and disconnect. Until live capture/input/video transport are wired, those actions may remain disabled but the session/control workspace must be driven by Core contracts.
- System Monitor must keep the macOS monitoring shape visible: monitoring status, stop monitoring, advanced/helper monitoring, overview metrics, detailed monitoring cards, health, thermal, and load indicators. Until ETW/GPU/thermal providers are wired, unsupported metrics must be labeled pending instead of synthesized.
- Settings must keep the macOS preference-workspace shape visible: General, Network, Devices, File Transfer, Remote Desktop, System Monitor, Permissions, and Advanced tabs; export/import/reset actions; permission/system-settings actions; apply/default/reset-monitor actions; File Transfer, Video Transfer, Remote Desktop, System Monitor, and PQC/Core policy fields. Until persistence and providers are wired, high-risk writes must stay disabled and separated from read-only refresh.
- Connection, heartbeat, and disconnect commands must stay bound to `SessionViewModel` and must not invent per-page state.
- Runtime protocol facts must come from Rust Core contracts: transport selection, transport binding digest, channel mapping, connection planning, suite selection, frame metadata, and engine diagnostics. Quantum/Core diagnostics must call `CoreDiagnosticsClient` over `CoreBridge`, not re-derive protocol state in XAML or view-model code.

## Current Windows implementation
- `windows/Skybridge.WinClient/ViewModels/FeatureEntryContract.cs` defines the fixed feature entry order.
- `windows/Skybridge.WinClient/ViewModels/SessionViewModel.cs` exposes `NavigationItems`, `SelectedFeature`, session status, basic dashboard metrics, Device Discovery parser state/results, USB Management stats/device state/results, File Transfer queue/history/security state/results, Remote Desktop session/control state/results, Quantum/Core diagnostics state/results, System Monitor overview/detail/indicator state/results, Settings tabs/actions/details state/results, and existing connect/heartbeat/disconnect commands.
- `windows/Skybridge.WinClient/MainWindow.xaml` uses the contract as a shell skeleton with left navigation, top status bar, dashboard metrics, a Device Discovery service/TXT parser workspace, a USB Management stats/device workspace, a File Transfer queue/history/security workspace, a Remote Desktop session/control workspace, a Quantum/Core diagnostics workspace, a System Monitor overview/detail/indicator workspace, a Settings tabs/actions/details workspace, selected-feature workspace, and session controls.

## Acceptance checks to add
- Static test: run `Scripts/verify-windows-ui-parity.ps1` to verify `FeatureEntryContract.Entries` matches the macOS navigation IDs and order, and that the shell exposes the required bindings, Device Discovery parser signals, USB Management stats/device signals, File Transfer queue/history/security signals, Remote Desktop session/control signals, Quantum/Core diagnostics signals, System Monitor overview/detail/indicator signals, Settings tabs/actions/details signals, and commands.
- UI automation: each navigation entry can be selected and updates the selected-feature heading.
- UI automation: connect, heartbeat, and disconnect buttons enable/disable according to `EngineConnectionState`.
- Visual QA: left navigation order, top status bar, metric row, and session controls remain in stable positions across desktop window sizes.
- Diagnostic UI: expose `CoreBridge.PlanConnectionAsync`, transport selection, transport binding digest, channel mapping, frame codec metadata, suite negotiation, engine snapshot, metrics, and event queue output without silent fallback.
