import Foundation
import SwiftUI
import WebKit

@available(macOS 14.0, *)
struct SupabaseTurnstileChallengeContext: Identifiable, Equatable {
    let id = UUID()
    let siteKey: String
    let originURL: URL
    let action: String
}

@available(macOS 14.0, *)
enum SupabaseTurnstileConfig {
    static func current(originURL: URL?) -> SupabaseTurnstileChallengeContext? {
        let environmentSiteKey = ProcessInfo.processInfo.environment["TURNSTILE_SITE_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let bundledSiteKey = (Bundle.main.object(forInfoDictionaryKey: "TURNSTILE_SITE_KEY") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let siteKeyCandidates: [String?] = [environmentSiteKey, bundledSiteKey]
        guard let siteKey = siteKeyCandidates.compactMap({ $0 }).first(where: { !$0.isEmpty }) else {
            return nil
        }

        guard let originURL else { return nil }
        return SupabaseTurnstileChallengeContext(siteKey: siteKey, originURL: originURL, action: "auth")
    }

    static func requiresSiteKey(for originURL: URL?) -> Bool {
        guard let host = originURL?.host?.lowercased(), !host.isEmpty else {
            return false
        }

        return !["localhost", "127.0.0.1", "::1"].contains(host) && !host.hasSuffix(".local")
    }
}

@available(macOS 14.0, *)
struct SupabaseTurnstileSheet: View {
    let context: SupabaseTurnstileChallengeContext
    let onToken: (String) -> Void
    let onCancel: () -> Void
    let onError: (String) -> Void

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 8) {
                Image(systemName: "checkmark.shield")
                    .font(.system(size: 34))
                    .foregroundStyle(
                        LinearGradient(colors: [.cyan, .blue], startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                Text("安全检查")
                    .font(.title3.weight(.semibold))
                Text("请完成 Cloudflare Turnstile 验证后继续。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            MacTurnstileWebView(
                siteKey: context.siteKey,
                originURL: context.originURL,
                action: context.action,
                onToken: onToken,
                onError: onError
            )
            .frame(width: 380, height: 220)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            HStack {
                Spacer()
                Button("取消", role: .cancel, action: onCancel)
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}

@available(macOS 14.0, *)
private struct MacTurnstileWebView: NSViewRepresentable {
    let siteKey: String
    let originURL: URL
    let action: String
    let onToken: (String) -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onToken: onToken, onError: onError)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.add(context.coordinator, name: "turnstile")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.loadHTMLString(
            Self.html(siteKey: siteKey, action: action),
            baseURL: originURL
        )
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "turnstile")
    }

    private static func html(siteKey: String, action: String) -> String {
        let escapedSiteKey = siteKey
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let escapedAction = action
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        return """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <script src="https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit" async defer></script>
          <style>
            body {
              margin: 0;
              font-family: -apple-system, BlinkMacSystemFont, sans-serif;
              background: transparent;
              color: #f5f7fb;
              display: flex;
              align-items: center;
              justify-content: center;
              min-height: 100vh;
            }
            #container {
              width: 100%;
              display: flex;
              align-items: center;
              justify-content: center;
            }
          </style>
        </head>
        <body>
          <div id="container">
            <div id="widget"></div>
          </div>
          <script>
            function post(payload) {
              if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.turnstile) {
                window.webkit.messageHandlers.turnstile.postMessage(payload);
              }
            }

            function renderWidget() {
              if (!window.turnstile) {
                window.setTimeout(renderWidget, 60);
                return;
              }

              try {
                window.turnstile.render("#widget", {
                  sitekey: "\(escapedSiteKey)",
                  action: "\(escapedAction)",
                  callback: function(token) {
                    post({ type: "success", token: token });
                  },
                  "error-callback": function(code) {
                    post({ type: "error", message: String(code || "turnstile_error") });
                  },
                  "expired-callback": function() {
                    post({ type: "error", message: "turnstile_token_expired" });
                  }
                });
              } catch (error) {
                post({ type: "error", message: String(error) });
              }
            }

            window.addEventListener("load", renderWidget);
          </script>
        </body>
        </html>
        """
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        private let onToken: (String) -> Void
        private let onError: (String) -> Void

        init(onToken: @escaping (String) -> Void, onError: @escaping (String) -> Void) {
            self.onToken = onToken
            self.onError = onError
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "turnstile",
                  let payload = message.body as? [String: Any],
                  let type = payload["type"] as? String else {
                onError("turnstile_message_invalid")
                return
            }

            if type == "success",
               let token = payload["token"] as? String,
               !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                onToken(token)
                return
            }

            let message = (payload["message"] as? String) ?? "turnstile_failed"
            onError(message)
        }
    }
}
