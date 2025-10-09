import SwiftUI
import Observation

struct FileTransferView: View {
    @State private var viewModel = FileTransferViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            List {
                Section("目录浏览") {
                    if viewModel.isLoading {
                        ProgressView()
                    }
                    ForEach(viewModel.items) { item in
                        Button {
                            Task { await viewModel.handleTap(on: item) }
                        } label: {
                            FileTransferRow(item: item)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                Task { await viewModel.download(item) }
                            } label: {
                                Label("下载到本地", systemImage: "square.and.arrow.down")
                            }
                        }
                    }
                    if viewModel.items.isEmpty, !viewModel.isLoading {
                        ContentUnavailableView(
                            "暂无文件",
                            systemImage: "externaldrive",
                            description: Text("使用上方上传按钮推送文件到当前目录")
                        )
                    }
                }

                Section("传输队列") {
                    ForEach(viewModel.jobs) { job in
                        HStack(spacing: 12) {
                            Image(systemName: job.direction.systemImage)
                                .foregroundStyle(.accent)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(job.itemName)
                                    .font(.headline)
                                Text(job.progressText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: job.state.systemImage)
                                .foregroundStyle(job.state == .failed ? .pink : .secondary)
                        }
                        .padding(.vertical, 6)
                    }
                    if viewModel.jobs.isEmpty {
                        Text("暂无传输任务")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let message = viewModel.errorMessage {
                    Section {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.pink)
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
        .padding(.top, 12)
        .navigationTitle("文件传输")
        .toolbar { toolbarContent }
        .task { await viewModel.bootstrap() }
        .onDisappear { viewModel.stopJobMonitoring() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("工作目录")
                .font(.headline)
            HStack(alignment: .center, spacing: 12) {
                Text(viewModel.currentPath)
                    .font(.callout.monospaced())
                Spacer()
                Button {
                    Task { await viewModel.refresh() }
                } label: {
                    Label("同步", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
            }
            .padding(16)
            .liquidGlass()
        }
        .padding(.horizontal, 16)
    }

    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                Task { await viewModel.goUp() }
            } label: {
                Label("上一级", systemImage: "arrow.up.left")
            }
            .disabled(!viewModel.canGoUp)

            Menu {
                Button {
                    Task { await viewModel.uploadSampleProfile() }
                } label: {
                    Label("上传监控策略", systemImage: "doc.badge.plus")
                }
                Button {
                    Task { await viewModel.uploadDiagnostics() }
                } label: {
                    Label("上传诊断日志", systemImage: "wrench.and.screwdriver")
                }
            } label: {
                Label("上传", systemImage: "square.and.arrow.up")
            }
        }
    }
}

private struct FileTransferRow: View {
    let item: FileTransferItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.iconName)
                .font(.title3)
                .foregroundStyle(item.isDirectory ? .cyan : .accent)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(.headline)
                Text(item.isDirectory ? item.formattedDate : "\(item.formattedSize) · \(item.formattedDate)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if item.isDirectory {
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 6)
    }
}

@MainActor
@Observable
final class FileTransferViewModel {
    var currentPath: String = "/"
    var items: [FileTransferItem] = []
    var jobs: [FileTransferJob] = []
    var isLoading: Bool = false
    var errorMessage: String?

    var canGoUp: Bool {
        currentPath != "/"
    }

    private let service: FileTransferService
    private var jobTask: Task<Void, Never>?

    init(service: FileTransferService = .shared) {
        self.service = service
    }

    deinit {
        jobTask?.cancel()
    }

    func bootstrap() async {
        await refresh()
        startJobMonitoring()
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            items = try await service.listDirectory(at: currentPath)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func handleTap(on item: FileTransferItem) async {
        if item.isDirectory {
            await enter(directory: item)
        } else {
            await download(item)
        }
    }

    func enter(directory: FileTransferItem) async {
        guard directory.isDirectory else { return }
        if currentPath == "/" {
            currentPath = "/\(directory.name)"
        } else {
            currentPath += "/\(directory.name)"
        }
        await refresh()
    }

    func goUp() async {
        guard canGoUp else { return }
        let components = currentPath.split(separator: "/")
        if components.count <= 1 {
            currentPath = "/"
        } else {
            currentPath = components.dropLast().reduce(into: "") { partialResult, element in
                partialResult.append("/")
                partialResult.append(contentsOf: element)
            }
        }
        await refresh()
    }

    func uploadSampleProfile() async {
        let payload = "# Skybridge 策略\nrefresh=5\nstream=balanced\n".data(using: .utf8) ?? Data()
        await upload(data: payload, named: "policy.conf")
    }

    func uploadDiagnostics() async {
        let diagnostics = "timestamp,level,message\n\(Date().ISO8601Format()),INFO,system-health-check".data(using: .utf8) ?? Data()
        await upload(data: diagnostics, named: "diagnostics.csv")
    }

    private func upload(data: Data, named fileName: String) async {
        do {
            let job = try await service.upload(data: data, fileName: fileName, destinationPath: currentPath)
            jobs = insertOrUpdate(job: job, in: jobs)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func download(_ item: FileTransferItem) async {
        do {
            let job = try await service.download(itemID: item.id, destinationPath: "/Downloads")
            jobs = insertOrUpdate(job: job, in: jobs)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func startJobMonitoring() {
        jobTask?.cancel()
        jobTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                do {
                    let jobs = try await self.service.fetchJobs()
                    await MainActor.run {
                        self.jobs = jobs
                        self.errorMessage = nil
                    }
                } catch {
                    await MainActor.run {
                        self.errorMessage = error.localizedDescription
                    }
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stopJobMonitoring() {
        jobTask?.cancel()
        jobTask = nil
    }

    private func insertOrUpdate(job: FileTransferJob, in jobs: [FileTransferJob]) -> [FileTransferJob] {
        var updated = jobs
        if let index = updated.firstIndex(where: { $0.id == job.id }) {
            updated[index] = job
        } else {
            updated.insert(job, at: 0)
        }
        return updated.sorted { lhs, rhs in
            lhs.startedAt > rhs.startedAt
        }
    }
}
