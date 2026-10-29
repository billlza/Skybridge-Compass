import AppIntents
import SkyBridgeCore

@available(macOS 14.0, *)
struct StartSkyBridgeSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "连接云桥司南设备"
    static let description = IntentDescription("通过Siri唤醒云桥司南并准备指定远程终端的连接确认。")
    static let openAppWhenRun = true

    @Parameter(title: "设备名称")
    var deviceName: String

    static var parameterSummary: some ParameterSummary {
        Summary("连接 \(\.$deviceName)")
    }

    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(
            name: .skyBridgeIntentConnect,
            object: nil,
            userInfo: [SkyBridgeIntentPayloadKey.deviceName: deviceName]
        )
        return .result(dialog: "已为您唤醒云桥司南，请在应用内确认连接 \(deviceName)")
    }
}

@available(macOS 14.0, *)
struct SkyBridgeCompassShortcuts: AppShortcutsProvider {
    static let shortcutTileColor: ShortcutTileColor = .blue

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartSkyBridgeSessionIntent(),
 // 每个短语必须包含且仅包含一次 `\(.applicationName)`，遵循 AppIntents 规范。
            phrases: [
                "使用 \(.applicationName)",
                "用 \(.applicationName) 快速连接"
            ],
            shortTitle: "快速连接",
            systemImageName: "rectangle.connected.to.line.below"
        )
    }
}
