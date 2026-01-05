import SwiftUI
import Foundation
import SkyBridgeCore

// MARK: - 设备详情视图
// ⚡ 重构：移除 Mock 实现，连接到真实的 SkyBridgeCore 服务
// 📌 UI 结构保持不变

/// 设备详情视图
public struct DeviceDetailView: View {
    let device: DiscoveredDevice
    @StateObject private var hardwareController = HardwareRemoteController()
    @ObservedObject private var securityManager = DeviceSecurityManager.shared
    @StateObject private var fileTransferEngine: FileTransferEngine
    
    public init(device: DiscoveredDevice) {
        self.device = device
 // 初始化文件传输引擎
        _fileTransferEngine = StateObject(wrappedValue: FileTransferEngine())
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
 // 设备基本信息
            deviceInfoSection
            
 // 连接控制
            connectionControlSection
            
 // 安全设置
            securitySection
            
 // 文件传输
            fileTransferSection
            
            Spacer()
        }
        .padding()
        .navigationTitle(device.name)
        .task {
 // DeviceSecurityManager 继承自 BaseManager，在 init 时自动初始化
 // 等待初始化完成
            while !securityManager.isInitialized {
                try? await Task.sleep(nanoseconds: 50_000_000) // 0.05秒
            }
        }
    }
    
 // MARK: - 子视图
    
    private var deviceInfoSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("设备信息")
                .font(.headline)
            
            HStack {
                Text("名称:")
                    .fontWeight(.medium)
                Text(device.name)
                    .foregroundColor(.secondary)
            }
            
            if let ipv4 = device.ipv4 {
                HStack {
                    Text("IPv4:")
                        .fontWeight(.medium)
                    Text(ipv4)
                        .foregroundColor(.secondary)
                }
            }
            
            if let ipv6 = device.ipv6 {
                HStack {
                    Text("IPv6:")
                        .fontWeight(.medium)
                    Text(ipv6)
                        .foregroundColor(.secondary)
                }
            }
            
            HStack {
                Text("服务:")
                    .fontWeight(.medium)
                Text(device.services.joined(separator: ", "))
                    .foregroundColor(.secondary)
            }
            
 // 显示连接类型
            if !device.connectionTypes.isEmpty {
                HStack {
                    Text("连接方式:")
                        .fontWeight(.medium)
                    Text(device.connectionTypes.map { $0.rawValue }.joined(separator: ", "))
                        .foregroundColor(.secondary)
                }
            }
            
 // 显示信号强度
            if let strength = device.signalStrength {
                HStack {
                    Text("信号强度:")
                        .fontWeight(.medium)
                    Text(String(format: "%.0f%%", strength))
                        .foregroundColor(strength > 70 ? .green : (strength > 40 ? .orange : .red))
                }
            }
        }
        .padding()
        .background(Color(.controlBackgroundColor))
        .cornerRadius(8)
    }
    
    private var connectionControlSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("连接控制")
                .font(.headline)
            
            HStack {
                Text("状态:")
                    .fontWeight(.medium)
                Text(hardwareController.connectionStatus)
                    .foregroundColor(hardwareController.isConnected ? .green : .secondary)
            }
            
            if let error = hardwareController.lastError {
                HStack {
                    Text("错误:")
                        .fontWeight(.medium)
                    Text(error)
                        .foregroundColor(.red)
                        .lineLimit(2)
                }
            }
            
            HStack {
                Button(hardwareController.isConnected ? "断开连接" : "连接") {
                    Task {
                        if hardwareController.isConnected {
                            hardwareController.disconnect()
                        } else {
                            do {
                                try await hardwareController.connect(to: device)
                            } catch {
 // 错误已在 hardwareController 中处理
                            }
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(hardwareController.connectionStatus == "连接中...")
                
                Spacer()
            }
        }
        .padding()
        .background(Color(.controlBackgroundColor))
        .cornerRadius(8)
    }
    
    private var securitySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("安全设置")
                .font(.headline)
            
            HStack {
                Text("安全级别:")
                    .fontWeight(.medium)
                Picker("安全级别", selection: $securityManager.securityLevel) {
                    ForEach(SecurityLevel.allCases, id: \.self) { level in
                        Text(level.rawValue).tag(level)
                    }
                }
                .pickerStyle(MenuPickerStyle())
            }
            
            HStack {
                Text("信任状态:")
                    .fontWeight(.medium)
                Text(securityManager.isDeviceTrusted(device) ? "已信任" : "未信任")
                    .foregroundColor(securityManager.isDeviceTrusted(device) ? .green : .secondary)
            }
            
            HStack {
                Button(securityManager.isDeviceTrusted(device) ? "取消信任" : "添加到受信任设备") {
                    if securityManager.isDeviceTrusted(device) {
                        securityManager.removeTrustedDevice(device.id.uuidString)
                    } else {
                        securityManager.addTrustedDevice(device)
                    }
                }
                .buttonStyle(.bordered)
                
                Spacer()
            }
        }
        .padding()
        .background(Color(.controlBackgroundColor))
        .cornerRadius(8)
    }
    
    private var fileTransferSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("文件传输")
                .font(.headline)
            
            HStack {
                Text("传输速度:")
                    .fontWeight(.medium)
                Text(formatTransferSpeed(fileTransferEngine.transferSpeed))
                    .foregroundColor(.secondary)
            }
            
            if !fileTransferEngine.activeTransfers.isEmpty {
                Text("活跃传输:")
                    .fontWeight(.medium)
                
                ForEach(Array(fileTransferEngine.activeTransfers.values), id: \.id) { session in
                    HStack {
                        Text(session.fileName)
                            .lineLimit(1)
                        Spacer()
                        ProgressView(value: session.progress)
                            .frame(width: 100)
                        Text(String(format: "%.1f%%", session.progress * 100))
                            .foregroundColor(.secondary)
                            .frame(width: 50, alignment: .trailing)
                    }
                }
            } else {
                Text("暂无活跃传输")
                    .foregroundColor(.secondary)
                    .font(.caption)
            }
            
            HStack {
                Button("选择文件传输") {
                    selectAndTransferFile()
                }
                .buttonStyle(.bordered)
                .disabled(!hardwareController.isConnected)
                
                Spacer()
            }
            
            if !hardwareController.isConnected {
                Text("请先连接设备以启用文件传输")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color(.controlBackgroundColor))
        .cornerRadius(8)
    }
    
 // MARK: - 辅助方法
    
    private func formatTransferSpeed(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond >= 1_000_000_000 {
            return String(format: "%.2f GB/s", bytesPerSecond / 1_000_000_000)
        } else if bytesPerSecond >= 1_000_000 {
            return String(format: "%.2f MB/s", bytesPerSecond / 1_000_000)
        } else if bytesPerSecond >= 1_000 {
            return String(format: "%.2f KB/s", bytesPerSecond / 1_000)
        } else {
            return String(format: "%.0f B/s", bytesPerSecond)
        }
    }
    
    private func selectAndTransferFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "选择要传输的文件"
        panel.prompt = "传输"
        
        panel.begin { response in
            if response == .OK, let url = panel.url {
                Task {
                    do {
                        _ = try await fileTransferEngine.sendFile(
                            at: url,
                            to: device.id.uuidString
                        )
                    } catch {
 // 文件传输引擎内部会处理错误
                    }
                }
            }
        }
    }
}

// MARK: - Preview Provider

#if DEBUG
struct DeviceDetailView_Previews: PreviewProvider {
    static var previews: some View {
        DeviceDetailView(device: DiscoveredDevice(
            id: UUID(),
            name: "测试设备",
            ipv4: "192.168.1.100",
            ipv6: nil,
            services: ["SSH", "HTTP"],
            portMap: ["SSH": 22, "HTTP": 80],
            connectionTypes: [.wifi],
            uniqueIdentifier: nil,
            signalStrength: 85.0
        ))
    }
}
#endif
