# Skybridge Windows client architecture

The WinUI client is organized to keep UI binding, engine integration, and platform FFI clearly separated so the Rust core can be slotted in without disrupting the shell.

## Layers
- **ViewModels** (`windows/Skybridge.WinClient/ViewModels`): presentation logic and bindable state. `SessionViewModel` owns connection status, bitrate/framerate selections, and commands that orchestrate engine calls.
- **Services** (`windows/Skybridge.WinClient/Services`): engine abstractions behind `IEngineClient`. The stub `DummyEngineClient` simulates connect/disconnect/heartbeat flows; it will be replaced by a real FFI-backed implementation that calls into the Rust `ffi` module.
- **Views** (`windows/Skybridge.WinClient/MainWindow.xaml`): XAML-only bindings with no business logic in code-behind. The window creates the view model and relies on commands/properties for interactions.

## Planned Rust FFI integration
- Introduce a `FfiEngineClient` in `Services` that P/Invokes the C ABI exposed by `core/skybridge-core/src/ffi.rs` (e.g., `skybridge_engine_new`, `skybridge_engine_connect`, `skybridge_engine_shutdown`).
- Map engine callbacks (state changes, input responses) to UI updates via events or observable properties on the view model.
- Keep heavy work off the UI thread by continuing to use async commands for connect/heartbeat; the FFI layer should marshal any blocking calls to thread-pool threads when necessary.

## Testing approach
- UI logic remains in view models and services, enabling unit tests against `SessionViewModel` without a XAML runtime.
- FFI glue can be validated with integration tests on Windows by mocking the Rust DLL exports or linking against the compiled core crate.
