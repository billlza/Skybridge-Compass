# Windows UI parity contract

This contract fixes the Windows shell entry points against the macOS reference so the port can add functionality without drifting from the existing product shape.

## Reference evidence
- macOS navigation order comes from `origin/main:Sources/SkyBridgeCompassApp/Dashboard/Navigation/NavigationItem.swift`: Dashboard, Device Discovery, USB Management, File Transfer, Remote Desktop, Quantum, System Monitor, Settings.
- macOS dashboard routing is implemented in `origin/main:Sources/SkyBridgeCompassApp/Dashboard/DashboardView.swift`.
- macOS top bar includes connection state, FPS/diagnostics, notifications, theme, and manual connection entry points in `origin/main:Sources/SkyBridgeCompassApp/Dashboard/TopBar/TopNavigationBarView.swift`.
- macOS feature surfaces also include device discovery modes, file transfer actions/history, remote desktop session controls, system monitoring, settings tabs, security/trust/approval, and menu bar quick actions.

## Windows shell contract
- The Windows side navigation must keep the same feature order as the macOS `NavigationItem` list.
- The first visible viewport must be the product workspace, not a landing page. The shell is left navigation, top status/action bar, and main workspace.
- The top bar must surface the selected feature, Core status, and connection controls from the shared session view model.
- Unimplemented feature pages may show a disabled or placeholder workspace, but their navigation entry must remain present so parity gaps are visible and testable.
- Connection, heartbeat, and disconnect commands must stay bound to `SessionViewModel` and must not invent per-page state.
- Runtime protocol facts must come from Rust Core contracts: transport selection, channel mapping, connection planning, suite selection, frame metadata, and engine diagnostics.

## Current Windows implementation
- `windows/Skybridge.WinClient/ViewModels/FeatureEntryContract.cs` defines the fixed feature entry order.
- `windows/Skybridge.WinClient/ViewModels/SessionViewModel.cs` exposes `NavigationItems`, `SelectedFeature`, session status, basic dashboard metrics, and existing connect/heartbeat/disconnect commands.
- `windows/Skybridge.WinClient/MainWindow.xaml` uses the contract as a shell skeleton with left navigation, top status bar, dashboard metrics, selected-feature workspace, and session controls.

## Acceptance checks to add
- Static test: run `Scripts/verify-windows-ui-parity.ps1` to verify `FeatureEntryContract.Entries` matches the macOS navigation IDs and order, and that the shell exposes the required bindings and commands.
- UI automation: each navigation entry can be selected and updates the selected-feature heading.
- UI automation: connect, heartbeat, and disconnect buttons enable/disable according to `EngineConnectionState`.
- Visual QA: left navigation order, top status bar, metric row, and session controls remain in stable positions across desktop window sizes.
- Diagnostic UI: expose `CoreBridge.PlanConnectionAsync`, transport selection, channel mapping, frame codec metadata, suite negotiation, engine snapshot, metrics, and event queue output without silent fallback.
