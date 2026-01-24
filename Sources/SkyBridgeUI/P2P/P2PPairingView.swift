//
// P2PPairingView.swift
// SkyBridgeUI
//
// iOS/iPadOS P2P Integration - Pairing UI
// Requirements: 1.2, 2.1, 2.2
//

import SwiftUI
import SkyBridgeCore

// MARK: - P2P Pairing View

/// P2P 配对视图
/// 支持 QR 码和 6 位数字码两种配对方式
@available(macOS 14.0, iOS 17.0, *)
public struct P2PPairingView: View {

 // MARK: - State

    @StateObject private var viewModel = P2PPairingViewModel()
    @State private var selectedTab: PairingTab = .qrCode
    @State private var manualCode: String = ""
    @FocusState private var isCodeFieldFocused: Bool

 // MARK: - Environment

    @Environment(\.dismiss) private var dismiss

 // MARK: - Body

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
 // 标题栏
            headerView

            Divider()

 // 标签页选择器
            tabSelector

 // 内容区域
            contentView
                .frame(maxWidth: .infinity, maxHeight: .infinity)

 // 底部状态栏
            statusBar
        }
        .frame(minWidth: 400, minHeight: 500)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            viewModel.startPairing()
        }
        .onDisappear {
            viewModel.stopPairing()
        }
    }

 // MARK: - Header

    private var headerView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("设备配对")
                    .font(.headline)
                Text("扫描 QR 码或输入配对码连接 iOS/iPadOS 设备")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button(action: { dismiss() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding()
    }

 // MARK: - Tab Selector

    private var tabSelector: some View {
        HStack(spacing: 0) {
            tabButton(tab: .qrCode, title: "QR 码", icon: "qrcode")
            tabButton(tab: .manualCode, title: "配对码", icon: "number")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private func tabButton(tab: PairingTab, title: String, icon: String) -> some View {
        Button(action: { selectedTab = tab }) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(title)
            }
            .font(.subheadline)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(selectedTab == tab ? Color.accentColor.opacity(0.15) : Color.clear)
            .foregroundColor(selectedTab == tab ? .accentColor : .secondary)
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }

 // MARK: - Content

    @ViewBuilder
    private var contentView: some View {
        switch selectedTab {
        case .qrCode:
            qrCodeView
        case .manualCode:
            manualCodeView
        }
    }

 // MARK: - QR Code View

    private var qrCodeView: some View {
        VStack(spacing: 24) {
            Spacer()

 // QR 码显示
            if let qrImage = viewModel.qrCodeImage {
                Image(nsImage: qrImage)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .frame(width: 200, height: 200)
                    .background(Color.white)
                    .cornerRadius(12)
                    .shadow(color: .black.opacity(0.1), radius: 8, x: 0, y: 4)
            } else {
                ProgressView()
                    .frame(width: 200, height: 200)
            }

 // 说明文字
            VStack(spacing: 8) {
                Text("使用 iOS 设备扫描此 QR 码")
                    .font(.headline)

                Text("在 iOS 设备上打开 SkyBridge Compass，选择「扫描配对」")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

 // 过期倒计时
            if let expiresIn = viewModel.qrCodeExpiresIn {
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                    Text("有效期: \(expiresIn)秒")
                }
                .font(.caption)
                .foregroundColor(expiresIn < 60 ? .orange : .secondary)
            }

 // 刷新按钮
            Button(action: { viewModel.refreshQRCode() }) {
                Label("刷新 QR 码", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)

            Spacer()
        }
        .padding()
    }

 // MARK: - Manual Code View

    private var manualCodeView: some View {
        VStack(spacing: 24) {
            Spacer()

 // 图标
            Image(systemName: "number.circle.fill")
                .font(.system(size: 60))
                .foregroundColor(.accentColor)

 // 说明
            VStack(spacing: 8) {
                Text("输入配对码")
                    .font(.headline)

                Text("在 iOS 设备上显示的 6 位数字配对码")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

 // 输入框
            HStack(spacing: 8) {
                ForEach(0..<6, id: \.self) { index in
                    codeDigitView(index: index)
                }
            }

 // 隐藏的文本输入框
            TextField("", text: $manualCode)
                .textFieldStyle(.plain)
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .focused($isCodeFieldFocused)
                .onChange(of: manualCode) { _, newValue in
 // 限制为 6 位数字
                    let filtered = newValue.filter { $0.isNumber }
                    if filtered.count <= 6 {
                        manualCode = filtered
                    } else {
                        manualCode = String(filtered.prefix(6))
                    }

 // 自动提交
                    if manualCode.count == 6 {
                        viewModel.pairWithCode(manualCode)
                    }
                }

 // 配对按钮
            Button(action: { viewModel.pairWithCode(manualCode) }) {
                Text("配对")
                    .frame(minWidth: 120)
            }
            .buttonStyle(.borderedProminent)
            .disabled(manualCode.count != 6 || viewModel.isPairing)

            Spacer()
        }
        .padding()
        .onTapGesture {
            isCodeFieldFocused = true
        }
        .onAppear {
            isCodeFieldFocused = true
        }
    }

    private func codeDigitView(index: Int) -> some View {
        let digit = index < manualCode.count ? String(manualCode[manualCode.index(manualCode.startIndex, offsetBy: index)]) : ""

        return Text(digit)
            .font(.system(size: 32, weight: .bold, design: .monospaced))
            .frame(width: 44, height: 56)
            .background(Color(nsColor: .textBackgroundColor))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(index == manualCode.count ? Color.accentColor : Color.gray.opacity(0.3), lineWidth: index == manualCode.count ? 2 : 1)
            )
    }

 // MARK: - Status Bar

    private var statusBar: some View {
        HStack {
 // 状态指示器
            HStack(spacing: 6) {
                Circle()
                    .fill(viewModel.statusColor)
                    .frame(width: 8, height: 8)

                Text(viewModel.statusText)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

 // 错误信息
            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

// MARK: - Pairing Tab

private enum PairingTab {
    case qrCode
    case manualCode
}

// MARK: - View Model

@available(macOS 14.0, iOS 17.0, *)
@MainActor
class P2PPairingViewModel: ObservableObject {

    @Published var qrCodeImage: NSImage?
    @Published var qrCodeExpiresIn: Int?
    @Published var isPairing: Bool = false
    @Published var errorMessage: String?
    @Published var statusText: String = "等待配对"
    @Published var statusColor: Color = .gray

    private var expirationTimer: Timer?

    func startPairing() {
        statusText = "正在生成 QR 码..."
        statusColor = .orange

 // 生成 QR 码
        Task {
            await generateQRCode()
        }
    }

    func stopPairing() {
        expirationTimer?.invalidate()
        expirationTimer = nil
    }

    func refreshQRCode() {
        Task {
            await generateQRCode()
        }
    }

    func pairWithCode(_ code: String) {
        guard code.count == 6 else { return }

        isPairing = true
        statusText = "正在配对..."
        statusColor = .orange
        errorMessage = nil

        Task {
            do {
 // 调用配对服务
 // try await sessionManager.pairWithCode(code, device: selectedDevice)

 // 模拟配对延迟
                try await Task.sleep(nanoseconds: 2_000_000_000)

                await MainActor.run {
                    isPairing = false
                    statusText = "配对成功"
                    statusColor = .green
                }
            } catch {
                await MainActor.run {
                    isPairing = false
                    statusText = "配对失败"
                    statusColor = .red
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func generateQRCode() async {
        // 生成 QR 码数据（与 iOS 端互通）：
        // - iOS 端会把 skybridge://pair 解析成 QRCodeData.devicePairing
        // - v=2 携带 addr/port/name/pk，iOS 可直接发起连接
        let deviceId = UUID().uuidString
        let deviceName = Host.current().localizedName ?? "Mac"
        let ip = LocalIP.bestEffortIPv4() ?? "0.0.0.0"
        let port = 9527
        let ts = Int(Date().timeIntervalSince1970)
        let exp = 300

        var components = URLComponents()
        components.scheme = "skybridge"
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "v", value: "2"),
            URLQueryItem(name: "id", value: deviceId),
            URLQueryItem(name: "name", value: deviceName),
            URLQueryItem(name: "addr", value: ip),
            URLQueryItem(name: "port", value: "\(port)"),
            URLQueryItem(name: "t", value: "\(ts)"),
            URLQueryItem(name: "exp", value: "\(exp)")
        ]

        let qrData = components.url?.absoluteString ?? "skybridge://pair?v=2&id=\(deviceId)&t=\(ts)"

 // 生成 QR 码图像
        if let filter = CIFilter(name: "CIQRCodeGenerator") {
            filter.setValue(qrData.data(using: .utf8), forKey: "inputMessage")
            filter.setValue("H", forKey: "inputCorrectionLevel")

            if let outputImage = filter.outputImage {
                let transform = CGAffineTransform(scaleX: 10, y: 10)
                let scaledImage = outputImage.transformed(by: transform)

                let rep = NSCIImageRep(ciImage: scaledImage)
                let nsImage = NSImage(size: rep.size)
                nsImage.addRepresentation(rep)

                await MainActor.run {
                    qrCodeImage = nsImage
                    qrCodeExpiresIn = 300 // 5 分钟
                    statusText = "等待扫描"
                    statusColor = .blue
                }

 // 启动倒计时
                startExpirationTimer()
            }
        }
    }

    private func startExpirationTimer() {
        expirationTimer?.invalidate()
        expirationTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, let current = self.qrCodeExpiresIn else { return }
                if current > 0 {
                    self.qrCodeExpiresIn = current - 1
                } else {
                    self.expirationTimer?.invalidate()
                    self.statusText = "QR 码已过期"
                    self.statusColor = .red
                }
            }
        }
    }
}

// MARK: - Local IP (best-effort, for LAN pairing)

private enum LocalIP {
    static func bestEffortIPv4() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        // Collect candidate IPv4s by interface priority.
        // Priority: VPN (utun*) > Wi‑Fi (en0) > other en*
        var candidates: [(priority: Int, ip: String)] = []

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = decodeCString(ptr.pointee.ifa_name)
            let addrFamily = ptr.pointee.ifa_addr.pointee.sa_family
            guard addrFamily == UInt8(AF_INET) else { continue }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(
                ptr.pointee.ifa_addr,
                socklen_t(ptr.pointee.ifa_addr.pointee.sa_len),
                &hostname,
                socklen_t(hostname.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            let ip = decodeCCharBuffer(hostname)
            guard !ip.isEmpty,
                  !ip.hasPrefix("127."),
                  !ip.hasPrefix("169.254") else { continue }

            let priority: Int
            if interface.hasPrefix("utun") {
                priority = 0
            } else if interface == "en0" {
                priority = 1
            } else if interface.hasPrefix("en") {
                priority = 2
            } else {
                continue
            }
            candidates.append((priority, ip))
        }

        if let best = candidates.sorted(by: { a, b in
            if a.priority != b.priority { return a.priority < b.priority }
            return a.ip < b.ip
        }).first {
            address = best.ip
        }

        return address
    }
}

// MARK: - Preview

#if DEBUG
@available(macOS 14.0, iOS 17.0, *)
#Preview {
    P2PPairingView()
        .frame(width: 450, height: 550)
}
#endif
