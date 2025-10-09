import SwiftUI
import Observation

struct RemoteDesktopView: View {
    @State private var viewModel = RemoteDesktopViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                qualityPicker
                endpointCarousel
                sessionCard
                previewCard
                if let message = viewModel.errorMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.pink)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.ultraThinMaterial)
                        .clipShape(.rect(cornerRadius: 20))
                }
            }
            .padding(24)
        }
        .navigationTitle("远程桌面")
        .background(TransparentBackground())
        .task { await viewModel.bootstrap() }
        .toolbar { toolbarContent }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("云桥远程桌面")
                .font(.largeTitle.bold())
            Text("一键接入远端主机，借助液态玻璃界面实时掌控图形流")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var qualityPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("串流质量", systemImage: "speedometer")
                .font(.headline)
            Picker("质量", selection: $viewModel.selectedQuality) {
                ForEach(RemoteDesktopSession.StreamQuality.allCases, id: \.self) { quality in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(quality.displayName)
                        Text(quality.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(quality)
                }
            }
            .pickerStyle(.segmented)
        }
        .padding(24)
        .liquidGlass()
    }

    private var endpointCarousel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("可用工作站", systemImage: "display")
                .font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(viewModel.endpoints) { endpoint in
                        EndpointCard(
                            endpoint: endpoint,
                            isActive: viewModel.activeSession?.endpoint.id == endpoint.id,
                            action: {
                                Task { await viewModel.toggleConnection(for: endpoint.id) }
                            }
                        )
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var sessionCard: some View {
        Group {
            if let session = viewModel.activeSession {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(session.endpoint.name)
                            .font(.title2.bold())
                        Spacer()
                        Button(role: .destructive) {
                            Task { await viewModel.disconnect() }
                        } label: {
                            Label("断开", systemImage: "xmark.circle")
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("位置", value: session.endpoint.location)
                        LabeledContent("分辨率", value: session.endpoint.resolution)
                        LabeledContent("帧率", value: String(format: "%.0f fps", session.endpoint.frameRate))
                        LabeledContent("延迟", value: session.endpoint.formattedLatency)
                        LabeledContent("比特率", value: "\(session.bitrate) kbps")
                        LabeledContent("编解码", value: session.codec)
                        LabeledContent("安全加密", value: session.isSecure ? "已启用" : "未启用")
                        LabeledContent("质量模式", value: session.quality.displayName)
                    }
                }
                .padding(24)
                .liquidGlass()
            } else if !viewModel.endpoints.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("选择一个工作站以开始串流")
                        .font(.headline)
                    Text("所有连接均通过低延迟 QUIC 隧道建立，保障画面无损与安全性。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(24)
                .liquidGlass()
            }
        }
    }

    private var previewCard: some View {
        Group {
            if let frame = viewModel.preview {
                VStack(alignment: .leading, spacing: 12) {
                    Text("实时缩略图")
                        .font(.headline)
                    if let url = frame.previewImageURL {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let image):
                                image
                                    .resizable()
                                    .scaledToFit()
                                    .clipShape(.rect(cornerRadius: 16))
                            case .empty:
                                ProgressView()
                                    .frame(height: 180)
                            case .failure:
                                Color.black.opacity(0.2)
                                    .overlay(alignment: .center) {
                                        Label("无法加载预览", systemImage: "exclamationmark.triangle")
                                            .foregroundStyle(.secondary)
                                    }
                                    .frame(height: 180)
                                    .clipShape(.rect(cornerRadius: 16))
                            @unknown default:
                                EmptyView()
                            }
                        }
                    } else {
                        Color.black.opacity(0.2)
                            .frame(height: 180)
                            .clipShape(.rect(cornerRadius: 16))
                            .overlay {
                                Label("预览暂不可用", systemImage: "photo")
                                    .foregroundStyle(.secondary)
                            }
                    }
                    HStack {
                        Label(frame.resolution, systemImage: "display")
                        Spacer()
                        Text(frame.timestamp.formatted(date: .numeric, time: .standard))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(24)
                .liquidGlass()
            }
        }
    }

    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if viewModel.isBusy {
                ProgressView()
            }
            Button {
                Task { await viewModel.refreshEndpoints() }
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
        }
    }
}

private struct EndpointCard: View {
    let endpoint: RemoteDesktopEndpoint
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(endpoint.name, systemImage: endpoint.status.systemImage)
                        .font(.headline)
                    Spacer()
                    if endpoint.isSecure {
                        Image(systemName: "lock.shield")
                            .foregroundStyle(.blue)
                    }
                }
                Text(endpoint.location)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(endpoint.resolution, systemImage: "rectangle.on.rectangle")
                        Label(String(format: "%.0f fps", endpoint.frameRate), systemImage: "speedometer")
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Label(endpoint.formattedLatency, systemImage: "waveform")
                        Text(endpoint.status.displayName)
                            .font(.caption)
                            .foregroundStyle(statusColor)
                    }
                }
                if isActive {
                    Text("正在串流")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .padding(.top, 4)
                }
            }
            .padding(20)
            .frame(width: 260)
            .background(.ultraThinMaterial)
            .clipShape(.rect(cornerRadius: 24))
            .shadow(radius: 4, y: 3)
        }
        .buttonStyle(.plain)
    }

    private var statusColor: Color {
        switch endpoint.status {
        case .available: return .green
        case .busy: return .orange
        case .offline: return .red
        }
    }
}

@MainActor
@Observable
final class RemoteDesktopViewModel {
    var endpoints: [RemoteDesktopEndpoint] = []
    var activeSession: RemoteDesktopSession?
    var preview: RemoteDesktopFrame?
    var selectedQuality: RemoteDesktopSession.StreamQuality = .balanced
    var errorMessage: String?
    var isBusy: Bool = false

    private let service: RemoteDesktopService
    private var previewTask: Task<Void, Never>?

    init(service: RemoteDesktopService = .shared) {
        self.service = service
    }

    deinit {
        previewTask?.cancel()
    }

    func bootstrap() async {
        await refreshEndpoints()
    }

    func refreshEndpoints() async {
        isBusy = true
        defer { isBusy = false }
        do {
            endpoints = try await service.fetchEndpoints()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func toggleConnection(for endpointID: UUID) async {
        if activeSession?.endpoint.id == endpointID {
            await disconnect()
        } else {
            await connect(to: endpointID)
        }
    }

    func connect(to endpointID: UUID) async {
        isBusy = true
        do {
            let session = try await service.startSession(endpointID: endpointID, quality: selectedQuality)
            activeSession = session
            preview = nil
            errorMessage = nil
            startPreviewUpdates(for: session.id)
        } catch {
            errorMessage = error.localizedDescription
        }
        isBusy = false
    }

    func disconnect() async {
        guard let session = activeSession else { return }
        isBusy = true
        do {
            try await service.stopSession(sessionID: session.id)
            activeSession = nil
            preview = nil
            previewTask?.cancel()
            previewTask = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        isBusy = false
    }

    private func startPreviewUpdates(for sessionID: UUID) {
        previewTask?.cancel()
        previewTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                do {
                    let frame = try await self.service.fetchPreview(sessionID: sessionID)
                    await MainActor.run {
                        self.preview = frame
                        self.errorMessage = nil
                    }
                } catch {
                    await MainActor.run {
                        self.errorMessage = error.localizedDescription
                    }
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
}

private struct TransparentBackground: View {
    var body: some View {
        Color.clear
    }
}
