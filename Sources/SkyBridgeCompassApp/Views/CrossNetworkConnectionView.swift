import SwiftUI
import SkyBridgeCore
import CoreImage.CIFilterBuiltins
import OSLog
import AVFoundation

/// 跨网络连接视图 - 三维连接矩阵
/// 2025年创新设计 - 比传统连接码更优雅
@MainActor
struct CrossNetworkConnectionView: View {
    @StateObject private var connectionManager = CrossNetworkConnectionManager.shared
    @State private var selectedMethod: ConnectionMethod = .qrCode
    @State private var inputCode: String = ""
    @State private var showingScanner = false
    @State private var qrCodeErrorMessage: String?
    @State private var lastQRCodeErrorFingerprint: String?
    @State private var lastQRCodeErrorAt: Date = .distantPast
    @State private var hoveredMethod: ConnectionMethod? = nil
    @State private var connectingCloudDeviceId: String?
    @StateObject private var qrScannerManager = QRCodeScannerManager.shared
    @ObservedObject private var unifiedDeviceManager = UnifiedOnlineDeviceManager.shared
    private let logger = Logger(subsystem: "com.skybridge.SkyBridgeCompassApp", category: "CrossNetworkConnection")

    var body: some View {
        VStack(spacing: 0) {
 // 顶部：连接方式选择器
            connectionMethodPicker

            Divider()

 // 主体：根据选择显示不同内容
            ScrollView {
                VStack(spacing: 24) {
                    switch selectedMethod {
                    case .qrCode:
                        qrCodeSection
                    case .cloudLink:
                        cloudLinkSection
                    case .connectionCode:
                        connectionCodeSection
                    }
                }
                .padding(24)
            }

            Divider()

 // 底部：状态栏
            statusBar
        }
        .frame(minWidth: 700, minHeight: 600)
        .navigationTitle(LocalizationManager.shared.localizedString("connection.crossNetwork.title"))
        .task {
 // 自动发现 iCloud 设备
            unifiedDeviceManager.startDiscovery()
            try? await connectionManager.discoverCloudDevices()
        }
        .sheet(isPresented: $showingScanner) {
            QRCodeScannerView(
                onResult: { result in
                    if isCrossNetworkConnectLink(result) {
                        let scannedContent = result
                        showingScanner = false
                        Task { await connectScannedQRCodeFromUI(scannedContent, trigger: "cross_network_window_scanner") }
                    } else {
                        presentQRCodeError(LocalizationManager.shared.localizedString("discovery.qrCode.error.unrecognized"))
                        showingScanner = false
                    }
                },
                onError: { message in
                    presentQRCodeError(message)
                    showingScanner = false
                }
            )
            .frame(minWidth: 500, minHeight: 320)
        }
        .alert(
            LocalizationManager.shared.localizedString("discovery.qrCode.error.title"),
            isPresented: Binding(
                get: { qrCodeErrorMessage != nil },
                set: { newValue in
                    if !newValue { qrCodeErrorMessage = nil }
                }
            )
        ) {
            Button(LocalizationManager.shared.localizedString("discovery.qrCode.error.ok")) {
                qrCodeErrorMessage = nil
            }
        } message: {
            Text(qrCodeErrorMessage ?? "")
        }
        .alert(
            "iCloud 设备连接失败",
            isPresented: Binding(
                get: { deviceChainViewModel.errorMessage != nil },
                set: { newValue in
                    if !newValue { deviceChainViewModel.errorMessage = nil }
                }
            )
        ) {
            Button(LocalizationManager.shared.localizedString("discovery.qrCode.error.ok")) {
                deviceChainViewModel.errorMessage = nil
            }
        } message: {
            Text(deviceChainViewModel.errorMessage ?? "")
        }
    }

 // MARK: - 连接方式选择器

    private var connectionMethodPicker: some View {
        HStack(spacing: 0) {
            ForEach(ConnectionMethod.allCases) { method in
                let isSelected = selectedMethod == method
                let isHovered = hoveredMethod == method
                ConnectionMethodButtonView(
                    method: method,
                    isSelected: isSelected,
                    isHovered: isHovered,
                    onSelect: {
                        withAnimation(.spring(response: 0.3)) { selectedMethod = method }
                    },
                    onHoverChanged: { hovering in
                        if hovering { hoveredMethod = method }
                        else if hoveredMethod == method { hoveredMethod = nil }
                    }
                )
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
    }

    private struct ConnectionMethodButtonView: View {
        let method: ConnectionMethod
        let isSelected: Bool
        let isHovered: Bool
        let onSelect: () -> Void
        let onHoverChanged: (Bool) -> Void
        var body: some View {
            VStack(spacing: 8) {
                Image(systemName: method.iconName)
                    .font(.system(size: 24))
                    .foregroundColor(method.accentColor)
                Text(method.title)
                    .font(.headline)
                    .foregroundColor(method.accentColor)
                Text(method.subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .background(isSelected ? method.accentColor.opacity(0.12) : Color.clear)
            .background(
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .opacity(isHovered ? 0.35 : 0)
            )
            .overlay(
                Rectangle()
                    .stroke(isHovered ? Color.white.opacity(0.08) : Color.clear, lineWidth: 1)
                    .allowsHitTesting(false)
            )
            .shadow(color: isHovered ? Color.white.opacity(0.06) : .clear, radius: 8, x: 0, y: 0)
            .overlay(
                Rectangle()
                    .fill(isSelected ? method.accentColor : Color.clear)
                    .frame(height: 3),
                alignment: .bottom
            )
            .contentShape(Rectangle())
            .onTapGesture { onSelect() }
            .onHover { onHoverChanged($0) }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(Text(method.title))
        }
    }

 // MARK: - 1️⃣ 动态二维码模式

    private var qrCodeSection: some View {
        VStack(spacing: 24) {
 // 说明卡片
            InfoCard(
                icon: "qrcode",
                title: LocalizationManager.shared.localizedString("connection.qrcode.title"),
                description: LocalizationManager.shared.localizedString("connection.qrcode.longDescription"),
                highlight: LocalizationManager.shared.localizedString("connection.qrcode.highlight")
            )

            HStack(spacing: 32) {
 // 左侧：生成二维码
                VStack(spacing: 16) {
                    Text("在此设备上")
                        .font(.title3)
                        .fontWeight(.semibold)

                    if let qrData = connectionManager.qrCodeData {
                        QRCodeView(data: qrData)
                            .frame(width: 280, height: 280)
                            .background(Color.white)
                            .cornerRadius(12)
                            .shadow(radius: 4)
                            .overlay(alignment: .topTrailing) {
                                Image(systemName: "arrow.clockwise.circle.fill")
                                    .font(.system(size: 28))
                                    .foregroundStyle(.white, Color.blue)
                                    .padding(10)
                            }
                            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .help("点击二维码立即刷新")
                            .onTapGesture {
                                Task { await generateDynamicQRCodeFromUI(trigger: "cross_network_window_tap_qr_refresh") }
                            }

                        Text("扫描此二维码，点击二维码可立即刷新")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        if case .waiting(_) = connectionManager.connectionStatus {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text(LocalizationManager.shared.localizedString("connection.waiting"))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }

                        Button {
                            Task { await generateDynamicQRCodeFromUI(trigger: "cross_network_window_regenerate_qr") }
                        } label: {
                            Label(
                                LocalizationManager.shared.localizedString("action.refresh"),
                                systemImage: "arrow.clockwise"
                            )
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Button(action: {
                            Task { await generateDynamicQRCodeFromUI(trigger: "cross_network_window_generate_qr") }
                        }) {
                            VStack(spacing: 8) {
                                Image(systemName: "qrcode")
                                    .font(.system(size: 60))
                                Text(LocalizationManager.shared.localizedString("connection.generateQR"))
                                    .font(.headline)
                            }
                            .frame(width: 280, height: 280)
                            .background(Color.blue.opacity(0.1))
                            .cornerRadius(12)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Divider()

 // 右侧：扫描二维码
                VStack(spacing: 16) {
                    Text(LocalizationManager.shared.localizedString("connection.device.other"))
                        .font(.title3)
                        .fontWeight(.semibold)

                    Button(action: {
                        Task { @MainActor in
                            let granted = await qrScannerManager.requestCameraPermission()
                            if granted {
                                showingScanner = true
                            } else if let message = qrScannerManager.errorMessage {
                                qrCodeErrorMessage = message
                            } else {
                                qrCodeErrorMessage = "摄像头权限被拒绝"
                            }
                        }
                    }) {
                        VStack(spacing: 16) {
                            Image(systemName: "camera.viewfinder")
                                .font(.system(size: 60))
                                .foregroundColor(.blue)

                            Text(LocalizationManager.shared.localizedString("connection.scanQR"))
                                .font(.headline)

                            Text(LocalizationManager.shared.localizedString("connection.scanQR.description"))
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(width: 250, height: 250)
                        .background(Color.green.opacity(0.1))
                        .cornerRadius(12)
                    }
                    .buttonStyle(.plain)
                }
            }

 // 特性说明
            HStack(spacing: 16) {
                FeatureTag(icon: "lock.shield", text: LocalizationManager.shared.localizedString("connection.security.encrypted"))
                FeatureTag(icon: "timer", text: LocalizationManager.shared.localizedString("connection.validity.5min"))
                FeatureTag(icon: "bolt.fill", text: LocalizationManager.shared.localizedString("connection.p2p"))
                FeatureTag(icon: "network", text: LocalizationManager.shared.localizedString("connection.natTraversal"))
            }
        }
    }

 // 🆕 iCloud 设备链视图模型
    @StateObject private var deviceChainViewModel: CloudDeviceListViewModel

    init(deviceChainViewModel: CloudDeviceListViewModel = CloudDeviceListViewModel()) {
        _deviceChainViewModel = StateObject(wrappedValue: deviceChainViewModel)
    }

 // MARK: - 2️⃣ iCloud 设备链模式

    private var cloudLinkSection: some View {
        VStack(spacing: 24) {
            InfoCard(
                icon: "icloud.fill",
                title: LocalizationManager.shared.localizedString("connection.icloud.title"),
                description: LocalizationManager.shared.localizedString("connection.icloud.description"),
                highlight: LocalizationManager.shared.localizedString("connection.icloud.highlight")
            )

            if deviceChainViewModel.authorizedDevices.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "icloud.slash")
                        .font(.system(size: 60))
                        .foregroundColor(.secondary)

                    Text(LocalizationManager.shared.localizedString("connection.icloud.noDevices"))
                        .font(.headline)

                    Text(LocalizationManager.shared.localizedString("connection.icloud.instruction"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)

                    Button(LocalizationManager.shared.localizedString("action.refresh")) {
                        Task {
                            await deviceChainViewModel.refreshDevices()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(deviceChainViewModel.isLoading)
                }
                .padding(.vertical, 40)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(String(format: LocalizationManager.shared.localizedString("connection.availableDevices"), deviceChainViewModel.authorizedDevices.count))
                            .font(.headline)

                        Spacer()

                        if deviceChainViewModel.isLoading {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Button {
                                Task {
                                    await deviceChainViewModel.refreshDevices()
                                }
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .buttonStyle(.borderless)
                        }
                    }

                    ForEach(deviceChainViewModel.authorizedDevices) { device in
                        CloudDeviceCard(
                            device: mapToCloudDevice(device),
                            isConnecting: connectingCloudDeviceId == device.id
                        ) {
                            Task { await connectToCloudDevice(device) }
                        }
                    }
                }
            }

            HStack(spacing: 16) {
                FeatureTag(icon: "icloud.fill", text: LocalizationManager.shared.localizedString("connection.icloud.sync"))
                FeatureTag(icon: "applelogo", text: LocalizationManager.shared.localizedString("connection.apple.ecosystem"))
                FeatureTag(icon: "arrow.triangle.2.circlepath", text: LocalizationManager.shared.localizedString("connection.auto.discovery"))
                FeatureTag(icon: "checkmark.shield", text: LocalizationManager.shared.localizedString("connection.apple.auth"))
            }
        }
    }

    private func mapToCloudDevice(_ device: iCloudDevice) -> CloudDevice {
        let type: CloudDevice.DeviceType
        if device.model.contains("iPhone") {
            type = .iPhone
        } else if device.model.contains("iPad") {
            type = .iPad
        } else {
            type = .mac
        }

        let mappedCapabilities: [CloudDevice.DeviceCapability] = device.capabilities.compactMap { cap in
            switch cap {
            case .remoteDesktop: return .remoteDesktop
            case .fileTransfer: return .fileTransfer
            default: return nil
            }
        }

        let liveDevice = unifiedDeviceManager.resolvedOnlineDevice(for: device)
        let effectiveLastSeen: Date = {
            guard let liveDevice, liveDevice.connectionStatus != .offline else {
                return device.lastSeen
            }
            return max(device.lastSeen, liveDevice.lastSeen)
        }()

        return CloudDevice(
            id: device.id,
            name: device.name,
            type: type,
            lastSeen: effectiveLastSeen,
            capabilities: mappedCapabilities.isEmpty ? [.remoteDesktop] : mappedCapabilities
        )
    }

    private func connectToCloudDevice(_ device: iCloudDevice) async {
        guard connectingCloudDeviceId == nil else { return }
        connectingCloudDeviceId = device.id
        defer { connectingCloudDeviceId = nil }

        if let liveDevice = unifiedDeviceManager.resolvedOnlineDevice(for: device),
           unifiedDeviceManager.hasResolvedConnectableControlRoute(for: liveDevice) {
            do {
                try await OnlineDeviceConnectionCoordinator.connect(to: liveDevice)
                deviceChainViewModel.errorMessage = nil
            } catch {
                let localized = HandshakeErrorLocalizer.localizedMessage(for: error)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                deviceChainViewModel.errorMessage = localized.isEmpty ? error.localizedDescription : localized
                logger.error("❌ iCloud row local P2P connect failed: \(device.name, privacy: .public) \(error.localizedDescription, privacy: .public)")
            }
            return
        }

        deviceChainViewModel.errorMessage = "没有发现这台设备的本地 P2P/Bonjour 端点，iCloud 自动连接暂不可用。请确认 iPad 与 Mac 在同一局域网、SkyBridge 在前台，并刷新设备。"
    }

 // MARK: - 3️⃣ 智能连接码模式

    private var connectionCodeSection: some View {
        VStack(spacing: 24) {
            InfoCard(
                icon: "number.square.fill",
                title: LocalizationManager.shared.localizedString("connection.smartCode.title"),
                description: LocalizationManager.shared.localizedString("connection.smartCode.fullDescription"),
                highlight: LocalizationManager.shared.localizedString("connection.smartCode.highlight")
            )

            HStack(spacing: 32) {
 // 左侧：生成连接码
                VStack(spacing: 16) {
                    Text(LocalizationManager.shared.localizedString("connection.device.this"))
                        .font(.title3)
                        .fontWeight(.semibold)

                    if let code = connectionManager.connectionCode {
                        VStack(spacing: 12) {
                            Picker(
                                LocalizationManager.shared.localizedString("connection.codeMode.title"),
                                selection: $connectionManager.connectionCodeLeaseMode
                            ) {
                                Text(LocalizationManager.shared.localizedString("connection.codeMode.short"))
                                    .tag(CrossNetworkConnectionManager.ConnectionCodeLeaseMode.shortLived)
                                Text(LocalizationManager.shared.localizedString("connection.codeMode.day"))
                                    .tag(CrossNetworkConnectionManager.ConnectionCodeLeaseMode.dayStable)
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 280)

                            Text(
                                connectionManager.connectionCodeLeaseMode == .dayStable
                                    ? LocalizationManager.shared.localizedString("connection.codeMode.dayHint")
                                    : LocalizationManager.shared.localizedString("connection.codeMode.shortHint")
                            )
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(width: 280)

                            Text(code)
                                .font(.system(size: 48, weight: .bold, design: .rounded))
                                .tracking(8)
                                .foregroundColor(.blue)
                                .padding(.horizontal, 32)
                                .padding(.vertical, 24)
                                .background(Color.blue.opacity(0.1))
                                .cornerRadius(16)

                            Text(LocalizationManager.shared.localizedString("connection.smartCode.shareInstruction"))
                                .font(.caption)
                                .foregroundColor(.secondary)

                            HStack(spacing: 16) {
                                Button(action: {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(code, forType: .string)
                                }) {
                                    Label(LocalizationManager.shared.localizedString("connection.copy"), systemImage: "doc.on.doc")
                                }
                                .buttonStyle(.bordered)

                                Button(action: {
                                    Task {
                                        do {
                                            qrCodeErrorMessage = nil
                                            _ = try await connectionManager.generateConnectionCode()
                                        } catch {
                                            logger.error("❌ 重新生成连接码失败: \(error.localizedDescription, privacy: .public)")
                                            qrCodeErrorMessage = error.localizedDescription
                                        }
                                    }
                                }) {
                                    Label(LocalizationManager.shared.localizedString("connection.regenerate"), systemImage: "arrow.clockwise")
                                }
                                .buttonStyle(.bordered)
                            }

                            if case .waiting = connectionManager.connectionStatus {
                                HStack(spacing: 8) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text(LocalizationManager.shared.localizedString("connection.waiting"))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                .padding(.top, 8)
                            }
                        }
                    } else {
                        Button(action: {
                            Task {
                                do {
                                    qrCodeErrorMessage = nil
                                    _ = try await connectionManager.generateConnectionCode()
                                } catch {
                                    logger.error("❌ 生成连接码失败: \(error.localizedDescription, privacy: .public)")
                                    qrCodeErrorMessage = error.localizedDescription
                                }
                            }
                        }) {
                            VStack(spacing: 16) {
                                Image(systemName: "number.square")
                                    .font(.system(size: 60))
                                    .foregroundColor(.blue)

                                Text(LocalizationManager.shared.localizedString("connection.smartCode.generate"))
                                    .font(.headline)
                            }
                            .frame(width: 280, height: 200)
                            .background(Color.blue.opacity(0.1))
                            .cornerRadius(12)
                        }
                        .buttonStyle(.plain)

                        Picker(
                            LocalizationManager.shared.localizedString("connection.codeMode.title"),
                            selection: $connectionManager.connectionCodeLeaseMode
                        ) {
                            Text(LocalizationManager.shared.localizedString("connection.codeMode.short"))
                                .tag(CrossNetworkConnectionManager.ConnectionCodeLeaseMode.shortLived)
                            Text(LocalizationManager.shared.localizedString("connection.codeMode.day"))
                                .tag(CrossNetworkConnectionManager.ConnectionCodeLeaseMode.dayStable)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 280)

                        Text(
                            connectionManager.connectionCodeLeaseMode == .dayStable
                                ? LocalizationManager.shared.localizedString("connection.codeMode.dayHint")
                                : LocalizationManager.shared.localizedString("connection.codeMode.shortHint")
                        )
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(width: 280)
                    }
                }

                Divider()

 // 右侧：输入连接码
                VStack(spacing: 16) {
                    Text(LocalizationManager.shared.localizedString("connection.device.other"))
                        .font(.title3)
                        .fontWeight(.semibold)

                    VStack(spacing: 12) {
                        TextField(LocalizationManager.shared.localizedString("connection.smartCode.placeholder"), text: $inputCode)
                            .font(.system(size: 32, weight: .semibold, design: .rounded))
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.center)
                            .textCase(.uppercase)
                            .frame(width: 280)
                            .padding(.vertical, 20)
                            .background(Color(NSColor.textBackgroundColor))
                            .cornerRadius(12)
                            .onChange(of: inputCode) { _, newValue in
 // 统一连接码过滤规则，避免 UI 与服务端长度语义漂移
                                inputCode = CrossNetworkConnectionManager.sanitizeConnectionCodeInput(newValue)
                            }

                        Button(action: {
                            Task {
                                do {
                                    qrCodeErrorMessage = nil
                                    _ = try await connectionManager.connectWithCode(inputCode)
                                } catch {
                                    logger.error("❌ 连接码连接失败: \(error.localizedDescription, privacy: .public)")
                                    qrCodeErrorMessage = error.localizedDescription
                                }
                            }
                        }) {
                            HStack {
                                Image(systemName: "arrow.right.circle.fill")
                                Text(LocalizationManager.shared.localizedString("connection.smartCode.connect"))
                                    .fontWeight(.semibold)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!CrossNetworkConnectionManager.canSubmitConnectionCode(inputCode))
                        .frame(width: 280)

                    }
                    .frame(height: 200)
                }
            }

            HStack(spacing: 16) {
                FeatureTag(icon: "speedometer", text: LocalizationManager.shared.localizedString("connection.fast"))
                FeatureTag(icon: "p.circle.fill", text: LocalizationManager.shared.localizedString("connection.p2p.priority"))
                FeatureTag(icon: "arrow.triangle.branch", text: LocalizationManager.shared.localizedString("connection.smart.relay"))
                FeatureTag(
                    icon: "hourglass",
                    text: LocalizationManager.shared.localizedString(
                        connectionManager.connectionCodeLeaseMode == .dayStable
                            ? "connection.validity.1day"
                            : "connection.validity.10min"
                    )
                )
            }
        }
    }

 // MARK: - 状态栏

    private var statusBar: some View {
        HStack(spacing: 16) {
 // 状态指示
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)

                Text(statusText)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

 // 操作按钮
            if case .connected = connectionManager.connectionStatus {
                Button(LocalizationManager.shared.localizedString("action.disconnect")) {
                    Task {
                        await connectionManager.disconnect()
                    }
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var statusColor: Color {
        switch connectionManager.connectionStatus {
        case .idle: return .gray
        case .generating, .connecting: return .orange
        case .waiting: return .blue
        case .connected: return .green
        case .failed: return .red
        }
    }

    private var statusText: String {
        switch connectionManager.connectionStatus {
        case .idle: return LocalizationManager.shared.localizedString("status.ready")
        case .generating: return LocalizationManager.shared.localizedString("status.generating")
        case .waiting(let code): return String(format: LocalizationManager.shared.localizedString("status.waiting.code"), code)
        case .connecting: return LocalizationManager.shared.localizedString("status.connecting")
        case .connected: return LocalizationManager.shared.localizedString("status.connected")
        case .failed(let error): return String(format: LocalizationManager.shared.localizedString("status.failed"), error)
        }
    }

    private func isCrossNetworkConnectLink(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("skybridge://connect/") { return true }
        guard let url = URL(string: trimmed), url.scheme == "skybridge", url.host == "connect" else {
            return false
        }
        let pathPayload = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !pathPayload.isEmpty { return true }
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let queryPayload = components.queryItems?.first(where: { $0.name == "data" })?.value {
            return !queryPayload.isEmpty
        }
        return false
    }

    private func generateDynamicQRCodeFromUI(trigger: String) async {
        guard !isGeneratingQRCode else { return }
        do {
            qrCodeErrorMessage = nil
            logger.info("📷 QR action started: \(trigger, privacy: .public)")
            _ = try await connectionManager.generateDynamicQRCode()
            logger.info("✅ QR action succeeded: \(trigger, privacy: .public)")
        } catch {
            logger.error("❌ QR action failed: \(trigger, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            presentQRCodeError(error.localizedDescription)
        }
    }

    private func connectScannedQRCodeFromUI(_ content: String, trigger: String) async {
        do {
            qrCodeErrorMessage = nil
            logger.info("📷 QR scan connect started: \(trigger, privacy: .public)")
            let data = Data(content.utf8)
            _ = try await connectionManager.scanDynamicQRCode(data)
            logger.info("✅ QR scan connect succeeded: \(trigger, privacy: .public)")
        } catch {
            logger.error("❌ QR scan connect failed: \(trigger, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            presentQRCodeError(error.localizedDescription)
        }
    }

    private var isGeneratingQRCode: Bool {
        if case .generating = connectionManager.connectionStatus {
            return true
        }
        return false
    }

    private func presentQRCodeError(_ message: String, dedupeWindow: TimeInterval = 12) {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        let now = Date()
        if lastQRCodeErrorFingerprint == normalized,
           now.timeIntervalSince(lastQRCodeErrorAt) < dedupeWindow {
            return
        }
        lastQRCodeErrorFingerprint = normalized
        lastQRCodeErrorAt = now
        qrCodeErrorMessage = normalized
    }
}

struct CrossNetworkConnectionView_Previews: PreviewProvider {
    static var previews: some View {
        CrossNetworkConnectionView(deviceChainViewModel: CloudDeviceListViewModel(service: PreviewCloudDeviceService()))
    }
}

// MARK: - 辅助视图

/// 信息卡片
@MainActor
struct InfoCard: View {
    let icon: String
    let title: String
    let description: String
    let highlight: String

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundColor(.blue)

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.headline)

                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text(highlight)
                    .font(.caption)
                    .foregroundColor(.blue)
            }

            Spacer()
        }
        .padding(16)
        .background(Color.blue.opacity(0.05))
        .cornerRadius(12)
    }
}

/// 二维码视图
@MainActor
struct QRCodeView: View {
    let data: Data

    var body: some View {
        if let qrImage = generateQRCode(from: data) {
            Image(nsImage: qrImage)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: "xmark.circle")
                .font(.system(size: 60))
                .foregroundColor(.red)
        }
    }

    private func generateQRCode(from data: Data) -> NSImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")

        guard let ciImage = filter.outputImage else { return nil }

        let transform = CGAffineTransform(scaleX: 10, y: 10)
        let scaledImage = ciImage.transformed(by: transform)

        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else { return nil }

        return NSImage(cgImage: cgImage, size: NSSize(width: 250, height: 250))
    }
}

/// 特性标签
@MainActor
struct FeatureTag: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
            Text(text)
                .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(12)
    }
}

/// iCloud 设备卡片
@MainActor
struct CloudDeviceCard: View {
    let device: CloudDevice
    let isConnecting: Bool
    let onConnect: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: deviceIcon)
                .font(.system(size: 32))
                .foregroundColor(.blue)
                .frame(width: 50, height: 50)
                .background(Color.blue.opacity(0.1))
                .cornerRadius(10)

            VStack(alignment: .leading, spacing: 4) {
                Text(device.name)
                    .font(.headline)

                Text(deviceTypeText)
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack(spacing: 8) {
                    ForEach(device.deviceCapabilities, id: \.self) { capability in
                        Text(capability.rawValue)
                            .font(.caption2)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.2))
                            .cornerRadius(4)
                    }
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(timeAgoText)
                    .font(.caption2)
                    .foregroundColor(.secondary)

                Button {
                    onConnect()
                } label: {
                    if isConnecting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(LocalizationManager.shared.localizedString("device.action.connect"))
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isConnecting)
            }
        }
        .padding(16)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(12)
    }

    private var deviceIcon: String {
        switch device.type {
        case .mac: return "desktopcomputer"
        case .iPhone: return "iphone"
        case .iPad: return "ipad"
        }
    }

    private var deviceTypeText: String {
        switch device.type {
        case .mac: return LocalizationManager.shared.localizedString("connection.device.mac")
        case .iPhone: return LocalizationManager.shared.localizedString("connection.device.iphone")
        case .iPad: return LocalizationManager.shared.localizedString("connection.device.ipad")
        }
    }

    private var timeAgoText: String {
        let interval = Date().timeIntervalSince(device.lastSeen)
        if interval < 60 {
            return LocalizationManager.shared.localizedString("time.justNow")
        } else if interval < 3600 {
            return String(format: LocalizationManager.shared.localizedString("time.minutesAgo"), Int(interval / 60))
        } else {
            return String(format: LocalizationManager.shared.localizedString("time.hoursAgo"), Int(interval / 3600))
        }
    }
}

/// 连接方式枚举
enum ConnectionMethod: String, CaseIterable, Identifiable {
    case qrCode = "qrCode"
    case cloudLink = "cloudLink"
    case connectionCode = "connectionCode"

    var id: String { rawValue }

    @MainActor
    var title: String {
        switch self {
        case .qrCode: return LocalizationManager.shared.localizedString("connection.method.qrCode.title")
        case .cloudLink: return LocalizationManager.shared.localizedString("connection.method.cloudLink.title")
        case .connectionCode: return LocalizationManager.shared.localizedString("connection.method.connectionCode.title")
        }
    }

    @MainActor
    var subtitle: String {
        switch self {
        case .qrCode: return LocalizationManager.shared.localizedString("connection.method.qrCode.subtitle")
        case .cloudLink: return LocalizationManager.shared.localizedString("connection.method.cloudLink.subtitle")
        case .connectionCode: return LocalizationManager.shared.localizedString("connection.method.connectionCode.subtitle")
        }
    }

    var iconName: String {
        switch self {
        case .qrCode: return "qrcode.viewfinder"
        case .cloudLink: return "icloud.fill"
        case .connectionCode: return "number.square.fill"
        }
    }
    var accentColor: Color {
        switch self {
        case .qrCode: return .green
        case .cloudLink: return .purple
        case .connectionCode: return .orange
        }
    }
}
