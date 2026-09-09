import SwiftUI
import SkyBridgeCore

/// A single window owns the local control workspace; each host retains its own engine.
struct NearFieldMirrorView: View {
    @StateObject private var model: NearFieldWorkspaceViewModel

    init(model: @autoclosure @escaping () -> NearFieldWorkspaceViewModel = NearFieldWorkspaceViewModel()) {
        _model = StateObject(wrappedValue: model())
    }

    var body: some View {
        NearFieldMirrorContent(model: model)
    }
}

/// Child observations must come from the model retained by the window's StateObject.
struct NearFieldMirrorContent: View {
    @ObservedObject private var model: NearFieldWorkspaceViewModel
    @ObservedObject private var workspace: ControlledHostWorkspace
    @ObservedObject private var discovery: DeviceDiscoveryManagerOptimized
    @State private var searchText = ""
    @State private var showsPairing = false
    // Retain the last visible frame while the workspace completes its focus
    // barrier. This presentation cache never determines the input destination.
    @State private var displayedManager: RemoteControlManager?
    @State private var displayedSessionId: String?

    init(model: NearFieldWorkspaceViewModel) {
        _model = ObservedObject(wrappedValue: model)
        _workspace = ObservedObject(wrappedValue: model.workspace)
        _discovery = ObservedObject(wrappedValue: model.discoveryManager)
    }

    var body: some View {
        workspaceContent
            .onAppear { model.startDiscovery() }
            .onDisappear {
                model.close()
                displayedManager = nil
                displayedSessionId = nil
            }
    }

    var workspaceContent: some View {
        VStack(spacing: 0) {
            workspaceBar
            Divider()
            if model.showsDevicePicker || (workspace.focusedManager == nil && !workspace.isSwitchingFocus) {
                devicePicker
            } else if let manager = workspace.focusedManager ?? displayedManager,
                      let sessionId = workspace.focusedSessionId ?? displayedSessionId {
                NearFieldControlCanvas(
                    manager: manager,
                    inputEnabled: !workspace.isSwitchingFocus,
                    onMouse: { model.submitMouseEvent($0, to: sessionId) },
                    onKeyboard: { model.submitKeyboardEvent($0, to: sessionId) }
                )
                .id(ObjectIdentifier(manager))
                .overlay {
                    if workspace.isSwitchingFocus {
                        ProgressView("正在切换设备…")
                            .padding(20)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            } else {
                ProgressView("正在准备设备画面…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("近距远程控制")
        .sheet(isPresented: $showsPairing) { RemoteControlPairingView() }
        .onChange(of: workspace.focusedSessionId, initial: true) { _, id in
            if let id, let manager = workspace.focusedManager {
                displayedManager = manager
                displayedSessionId = id
            }
        }
        .onChange(of: workspace.isSwitchingFocus) { _, switching in
            if !switching, workspace.focusedSessionId == nil {
                displayedManager = nil
                displayedSessionId = nil
            }
        }
        .alert("远程控制", isPresented: Binding(
            get: { model.errorMessage != nil || workspace.lastError != nil },
            set: { if !$0 { dismissError() } }
        )) {
            Button("确定") { dismissError() }
        } message: {
            Text(model.errorMessage ?? workspace.lastError ?? "")
        }
    }

    private var workspaceBar: some View {
        HStack(spacing: 12) {
            if workspace.sessions.isEmpty {
                Text("近距远程控制").font(.headline)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(workspace.sessions) { session in sessionTab(session) }
                    }
                }
            }
            Spacer(minLength: 0)
            Text("\(occupiedCount) / \(workspace.concurrentHostLimit) 台")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary).fixedSize()
            Button("配对设备") { showsPairing = true }
                .help("交换公钥配对信息并建立设备信任")
                .disabled(workspace.isSwitchingFocus)
            Button { model.showsDevicePicker = true } label: {
                Label("添加设备", systemImage: "plus")
            }
            .help("保留当前连接，选择另一台设备")
            .disabled(workspace.isSwitchingFocus)
        }
        .padding(12)
    }

    private func sessionTab(_ session: ControlledHostSessionSnapshot) -> some View {
        HStack(spacing: 8) {
            Button { model.focus(on: session.id) } label: {
                HStack(spacing: 8) {
                    if session.state == .connecting || session.state == .disconnecting {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: session.state == .failed ? "exclamationmark.circle" : "desktopcomputer")
                            .foregroundStyle(session.state == .failed ? Color.orange : Color.primary)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.name).font(.subheadline.weight(.medium)).lineLimit(1)
                        Text(statusText(session)).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .frame(minWidth: 100, maxWidth: 175, alignment: .leading)
            }
            .buttonStyle(.plain)
            .disabled(session.state != .connected || workspace.isSwitchingFocus)
            Button { model.disconnect(session.id) } label: {
                Image(systemName: "xmark").font(.caption2.weight(.semibold))
            }
            .buttonStyle(.plain)
            .help(session.state == .connecting ? "取消连接" : "关闭此会话")
            .accessibilityLabel("关闭 \(session.name)")
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(
            workspace.focusedSessionId == session.id && !model.showsDevicePicker
                ? Color.accentColor.opacity(0.17) : Color.primary.opacity(0.04),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .help(session.error ?? session.name)
    }

    private var devicePicker: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("选择要控制的设备").font(.title2.weight(.semibold))
                    Text("连接会保留在上方。切换设备后，键鼠只发送到当前设备。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                if workspace.focusedSessionId != nil {
                    Button("返回当前设备") { model.showsDevicePicker = false }
                }
            }
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索附近设备", text: $searchText).textFieldStyle(.plain)
                if discovery.isScanning { ProgressView().controlSize(.small) }
                Button { model.refreshDiscovery() } label: { Image(systemName: "arrow.clockwise") }
                    .help("刷新设备列表")
            }
            .padding(10)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            if availableDevices.isEmpty {
                ContentUnavailableView(
                    searchText.isEmpty ? "正在查找附近设备" : "没有匹配的设备",
                    systemImage: searchText.isEmpty ? "desktopcomputer.and.arrow.down" : "magnifyingglass",
                    description: Text(searchText.isEmpty
                        ? "请确认目标设备已开启 SkyBridge，且与此 Mac 在同一网络。"
                        : "试试其他设备名称。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(availableDevices) { device in
                            deviceRow(device)
                            Divider()
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func deviceRow(_ device: DiscoveredDevice) -> some View {
        let key = RemoteControlManager.controlPeerIdentifier(for: device)
        let session = workspace.sessions.first { $0.id == key }
        return HStack(spacing: 14) {
            Image(systemName: "desktopcomputer").font(.title2).foregroundStyle(.secondary).frame(width: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text(device.name).font(.headline)
                Text(session.map(statusText) ?? "可建立近距连接").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if session?.state == .connecting {
                Button("取消") { model.disconnect(key) }
            } else {
                Button(session?.state == .connected ? "切换" : "连接") { model.connect(to: device) }
                    .disabled(workspace.isSwitchingFocus || session?.state == .disconnecting)
            }
        }
        .padding(.vertical, 16)
    }

    private var occupiedCount: Int { workspace.sessions.filter { $0.state != .failed }.count }

    private var availableDevices: [DiscoveredDevice] {
        var seen: Set<String> = []
        return discovery.discoveredDevices.filter { device in
            discovery.supportsRemoteControl(device)
                && (searchText.isEmpty || device.name.localizedCaseInsensitiveContains(searchText))
                && seen.insert(RemoteControlManager.controlPeerIdentifier(for: device)).inserted
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func statusText(_ session: ControlledHostSessionSnapshot) -> String {
        switch session.state {
        case .connecting: return "正在建立安全会话"
        case .disconnecting: return "正在断开"
        case .failed: return "连接失败"
        case .connected: return workspace.focusedSessionId == session.id ? "当前设备" : "后台保持连接"
        }
    }

    private func dismissError() {
        model.errorMessage = nil
        workspace.clearError()
    }
}
