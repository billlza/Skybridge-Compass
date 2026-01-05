// AgentStatusView.swift
// SkyBridgeUI
//
// Agent 连接状态视图 - 显示与本地 SkyBridge Agent 的连接状态
// Created for web-agent-integration spec 13

import SwiftUI
import SkyBridgeCore

/// Agent 连接状态视图
@available(macOS 14.0, *)
public struct AgentStatusView: View {
    
    @ObservedObject var connectionService: AgentConnectionService
    
 /// 是否显示详细信息
    @State private var showDetails: Bool = false
    
    public init(connectionService: AgentConnectionService) {
        self.connectionService = connectionService
    }
    
    public var body: some View {
        HStack(spacing: 8) {
 // 状态指示器
            statusIndicator
            
 // 状态文本
            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle)
                    .font(.caption)
                    .fontWeight(.medium)
                
                if showDetails {
                    Text(statusDescription)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
 // 操作按钮
            actionButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(statusBackgroundColor.opacity(0.1))
        .cornerRadius(8)
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                showDetails.toggle()
            }
        }
    }
    
 // MARK: - Subviews
    
    private var statusIndicator: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 10, height: 10)
            .overlay(
                Circle()
                    .stroke(statusColor.opacity(0.3), lineWidth: 2)
            )
            .animation(.easeInOut(duration: 0.3), value: connectionService.connectionState)
    }
    
    @ViewBuilder
    private var actionButton: some View {
        switch connectionService.connectionState {
        case .disconnected, .failed:
            Button(action: reconnect) {
                Image(systemName: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("重新连接")
            
        case .connecting, .authenticating, .reconnecting:
            ProgressView()
                .scaleEffect(0.6)
                .frame(width: 16, height: 16)
            
        case .connected, .authenticated:
            Button(action: disconnect) {
                Image(systemName: "xmark.circle")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.borderless)
            .help("断开连接")
        }
    }
    
 // MARK: - Computed Properties
    
    private var statusTitle: String {
        switch connectionService.connectionState {
        case .disconnected:
            return "Agent 未连接"
        case .connecting:
            return "正在连接..."
        case .connected:
            return "已连接"
        case .authenticating:
            return "正在认证..."
        case .authenticated:
            return "已认证"
        case .reconnecting:
            return "正在重连..."
        case .failed:
            return "连接失败"
        }
    }
    
    private var statusDescription: String {
        switch connectionService.connectionState {
        case .disconnected:
            return "点击重新连接到本地 Agent"
        case .connecting:
            return "正在建立 WebSocket 连接"
        case .connected:
            return "WebSocket 已连接，等待认证"
        case .authenticating:
            return "正在验证身份"
        case .authenticated:
            return "已准备好进行远程协作"
        case .reconnecting:
            return "连接中断，正在尝试重连"
        case .failed:
            if let error = connectionService.lastError {
                return error.localizedDescription
            }
            return "无法连接到 Agent"
        }
    }
    
    private var statusColor: Color {
        switch connectionService.connectionState {
        case .disconnected:
            return .gray
        case .connecting, .authenticating, .reconnecting:
            return .orange
        case .connected:
            return .blue
        case .authenticated:
            return .green
        case .failed:
            return .red
        }
    }
    
    private var statusBackgroundColor: Color {
        switch connectionService.connectionState {
        case .authenticated:
            return .green
        case .failed:
            return .red
        default:
            return .gray
        }
    }
    
 // MARK: - Actions
    
    private func reconnect() {
        Task {
            try? await connectionService.connect()
        }
    }
    
    private func disconnect() {
        connectionService.disconnect()
    }
}

// MARK: - Compact Status Indicator

/// 紧凑型 Agent 状态指示器（用于工具栏等）
@available(macOS 14.0, *)
public struct AgentStatusIndicator: View {
    
    @ObservedObject var connectionService: AgentConnectionService
    
    public init(connectionService: AgentConnectionService) {
        self.connectionService = connectionService
    }
    
    public var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            
            if connectionService.connectionState == .connecting ||
               connectionService.connectionState == .authenticating ||
               connectionService.connectionState == .reconnecting {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 12, height: 12)
            }
        }
        .help(statusTooltip)
    }
    
    private var statusColor: Color {
        switch connectionService.connectionState {
        case .disconnected:
            return .gray
        case .connecting, .authenticating, .reconnecting:
            return .orange
        case .connected:
            return .blue
        case .authenticated:
            return .green
        case .failed:
            return .red
        }
    }
    
    private var statusTooltip: String {
        switch connectionService.connectionState {
        case .disconnected:
            return "Agent 未连接"
        case .connecting:
            return "正在连接 Agent..."
        case .connected:
            return "已连接，等待认证"
        case .authenticating:
            return "正在认证..."
        case .authenticated:
            return "Agent 已连接"
        case .reconnecting:
            return "正在重连..."
        case .failed:
            return "Agent 连接失败"
        }
    }
}

// MARK: - Preview

#if DEBUG
@available(macOS 14.0, *)
struct AgentStatusView_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 20) {
            AgentStatusView(connectionService: AgentConnectionService())
            AgentStatusIndicator(connectionService: AgentConnectionService())
        }
        .padding()
        .frame(width: 300)
    }
}
#endif
