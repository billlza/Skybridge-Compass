import SwiftUI

/// Cross-platform color helpers for shared UI code (SwiftUI).
public enum PlatformColor {
    /// A background color that visually matches macOS `controlBackgroundColor` / iOS secondary background.
    public static var controlBackground: Color {
#if os(macOS)
        return Color(nsColor: .controlBackgroundColor)
#else
        return Color(uiColor: .secondarySystemBackground)
#endif
    }

    /// A slightly elevated background suitable for cards.
    public static var cardBackground: Color {
#if os(macOS)
        return Color(nsColor: .windowBackgroundColor)
#else
        return Color(uiColor: .systemBackground)
#endif
    }
}


