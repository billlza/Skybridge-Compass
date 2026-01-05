import SwiftUI

struct CustomBackgroundView: View {
    @EnvironmentObject private var themeConfiguration: ThemeConfiguration
    
    var body: some View {
        ZStack {
            if let path = themeConfiguration.customBackgroundImagePath,
               let nsImage = NSImage(contentsOfFile: path) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .ignoresSafeArea()
            } else {
 // Fallback if no image is selected or file is missing
                Color.black
                    .overlay(
                        VStack(spacing: 12) {
                            Image(systemName: "photo.badge.plus")
                                .font(.system(size: 40))
                                .foregroundStyle(.secondary)
                            Text("未设置自定义背景")
                                .font(.headline)
                                .foregroundStyle(.secondary)
                        }
                    )
                    .ignoresSafeArea()
            }
            
 // Apply overlay gradient for readability
            Color.black.opacity(0.2)
                .ignoresSafeArea()
        }
    }
}
