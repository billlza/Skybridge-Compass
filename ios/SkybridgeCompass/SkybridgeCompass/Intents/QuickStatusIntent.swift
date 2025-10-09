import AppIntents

struct OpenDashboardIntent: AppIntent {
    static var title: LocalizedStringResource = "打开云桥司南"
    static var description = IntentDescription("快速进入云桥司南主控制台，查看实时状态。")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        .result(dialog: "已唤醒云桥司南主控制台")
    }
}

struct SkybridgeAppShortcuts: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor = .blue

    static var appShortcuts: [AppShortcut] {
        [
            AppShortcut(intent: OpenDashboardIntent(), phrases: ["打开<云桥司南>", "查看<云桥司南>"])
        ]
    }
}
