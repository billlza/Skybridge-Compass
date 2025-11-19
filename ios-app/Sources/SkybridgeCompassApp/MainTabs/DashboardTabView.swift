import SwiftUI
import Observation
import SkyBridgeCore
import SkyBridgeDesignSystem

struct DashboardTabView: View {
    @Bindable var appState: SkybridgeAppState
    @State private var isCityPickerPresented = false

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 20) {
                WeatherCard(snapshot: appState.dashboardSummary.weather, isLoading: appState.isWeatherRefreshing)
                if let error = appState.weatherError {
                    WeatherErrorBanner(message: error) {
                        Task { await appState.refreshWeather() }
                    }
                }
                if let session = appState.dashboardSummary.activeSession {
                    ActiveSessionCard(session: session)
                }
                SecurityStatusCard(status: appState.dashboardSummary.securityStatus)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 180)
        }
        .overlay(alignment: .bottom) {
            LiquidBottomBar {
                VStack(alignment: .leading, spacing: 12) {
                    Text("快捷操作")
                        .font(.headline)
                    HStack(spacing: 12) {
                        PrimaryActionButton(title: "刷新天气", icon: "arrow.clockwise", isLoading: appState.isWeatherRefreshing) {
                            Task { await appState.refreshWeather() }
                        }
                        PrimaryActionButton(title: "切换城市", icon: "location") {
                            isCityPickerPresented = true
                        }
                        PrimaryActionButton(title: "性能面板", icon: "slider.horizontal.3") {}
                    }
                }
            }
        }
        .sheet(isPresented: $isCityPickerPresented) {
            CityPickerSheet(appState: appState)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }
}

private struct WeatherCard: View {
    let snapshot: WeatherSnapshot
    let isLoading: Bool

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(snapshot.city)
                            .font(.title)
                        Text(snapshot.condition)
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: snapshot.conditionSymbolName)
                        .font(.system(size: 48))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(SkyBridgeColors.accentPrimary)
                }
                Text(snapshot.temperature)
                    .font(.system(size: 60, weight: .semibold, design: .rounded))
                HStack {
                    WeatherMetric(label: "湿度", value: snapshot.humidity)
                    WeatherMetric(label: "能见度", value: snapshot.visibility)
                    WeatherMetric(label: "风速", value: snapshot.wind)
                }
                Divider().background(Color.white.opacity(0.2))
                HStack {
                    Label("AQI \(snapshot.airQualityIndex)", systemImage: "leaf.fill")
                        .font(.subheadline)
                        .foregroundStyle(SkyBridgeColors.successGreen)
                    Spacer()
                    Label("星云安全 · 正常", systemImage: "shield.checkerboard")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .overlay(alignment: .topTrailing) {
                if isLoading {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                }
            }
        }
    }
}

private struct WeatherMetric: View {
    let label: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ActiveSessionCard: View {
    let session: RemoteSessionSummary
    var body: some View {
        GlassCard {
            HStack(alignment: .center, spacing: 16) {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(SkyBridgeGradients.accent)
                    .frame(width: 96, height: 96)
                    .overlay(
                        Text(session.thumbnail.prefix(2).uppercased())
                            .font(.title2)
                            .bold()
                            .foregroundStyle(.white)
                    )
                VStack(alignment: .leading, spacing: 6) {
                    Text(session.deviceName)
                        .font(.headline)
                    Label("\(session.resolution) · \(session.fps) FPS", systemImage: "display")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Label("延迟 \(session.latency) ms", systemImage: "bolt.horizontal.fill")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("模式：\(session.mode)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
    }
}

private struct SecurityStatusCard: View {
    let status: QuantumSecurityStatus
    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("量子安全", systemImage: "lock.shield")
                        .font(.headline)
                    Spacer()
                    Text(status.pqcEnabled ? "PQC ON" : "PQC OFF")
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(status.pqcEnabled ? SkyBridgeColors.successGreen.opacity(0.2) : Color.red.opacity(0.2))
                        .clipShape(Capsule())
                }
                SecurityRow(label: "TLS 混合", value: status.tlsHybridEnabled ? "已启用" : "关闭")
                SecurityRow(label: "Secure Enclave 签名", value: status.secureEnclaveSigning ? "已启用" : "关闭")
                SecurityRow(label: "Secure Enclave KEM", value: status.secureEnclaveKEM ? "已启用" : "软件")
                SecurityRow(label: "算法", value: status.algorithm.rawValue)
            }
        }
    }
}

private struct SecurityRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack {
            Text(label)
                .font(.subheadline)
            Spacer()
            Text(value)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

private struct WeatherErrorBanner: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        GlassCard {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.yellow)
                Text(message)
                    .font(.subheadline)
                Spacer()
                Button("重试", action: retry)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

private struct CityPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var appState: SkybridgeAppState

    var body: some View {
        NavigationStack {
            List(appState.availableCities) { city in
                Button {
                    Task {
                        await appState.changeCity(to: city)
                        dismiss()
                    }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(city.displayName)
                            Text(city.region)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if city == appState.selectedCity {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(SkyBridgeColors.accentPrimary)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
            .listStyle(.insetGrouped)
            .navigationTitle("切换城市")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

struct PrimaryActionButton: View {
    let title: String
    let icon: String
    let action: () -> Void
    var isLoading: Bool = false

    var body: some View {
        Button(action: action) {
            HStack {
                if isLoading {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                } else {
                    Image(systemName: icon)
                }
                Text(title)
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(Color.white.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
    }
}
