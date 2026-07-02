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
    let onToken: @MainActor (String) -> Void
    let onCancel: @MainActor () -> Void
    let onError: @MainActor (String) -> Void

    @State private var isChallengeReady = false

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

            ZStack {
                if !isChallengeReady {
                    VStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在加载安全检查...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                MacTurnstileWebView(
                    siteKey: context.siteKey,
                    originURL: context.originURL,
                    action: context.action,
                    onReady: {
                        isChallengeReady = true
                    },
                    onToken: onToken,
                    onError: onError
                )
            }
            .frame(width: 380, height: 220)
            .background(.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            HStack {
                Spacer()
                Button("取消", role: .cancel, action: onCancel)
            }
        }
        .padding(24)
        .frame(width: 420, height: 360)
    }
}

@available(macOS 14.0, *)
private struct MacTurnstileWebView: NSViewRepresentable {
    let siteKey: String
    let originURL: URL
    let action: String
    let onReady: @MainActor () -> Void
    let onToken: @MainActor (String) -> Void
    let onError: @MainActor (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onReady: onReady, onToken: onToken, onError: onError)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.add(context.coordinator, name: "turnstile")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.loadHTMLString(
            Self.html(siteKey: siteKey, action: action),
            baseURL: originURL
        )
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        coordinator.invalidate()
        nsView.stopLoading()
        nsView.navigationDelegate = nil
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "turnstile")
    }

    private static func html(siteKey: String, action: String) -> String {
        let siteKeyLiteral = javaScriptStringLiteral(siteKey)
        let actionLiteral = javaScriptStringLiteral(action)

        return """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
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

            var terminal = false;
            var rendered = false;
            var apiLoadTimer = null;
            var apiReadyTimer = null;

            function fail(message) {
              if (terminal) {
                return;
              }
              terminal = true;
              if (apiLoadTimer) {
                window.clearTimeout(apiLoadTimer);
              }
              if (apiReadyTimer) {
                window.clearTimeout(apiReadyTimer);
              }
              post({ type: "error", message: message });
            }

            function succeed(token) {
              if (terminal) {
                return;
              }
              terminal = true;
              if (apiLoadTimer) {
                window.clearTimeout(apiLoadTimer);
              }
              if (apiReadyTimer) {
                window.clearTimeout(apiReadyTimer);
              }
              post({ type: "success", token: token });
            }

            function renderWidget() {
              if (terminal || rendered) {
                return;
              }

              if (!window.turnstile) {
                window.setTimeout(renderWidget, 80);
                return;
              }

              try {
                var widgetId = window.turnstile.render("#widget", {
                  sitekey: \(siteKeyLiteral),
                  action: \(actionLiteral),
                  callback: function(token) {
                    succeed(token);
                  },
                  "error-callback": function(code) {
                    fail(String(code || "turnstile_error"));
                  },
                  "expired-callback": function() {
                    fail("turnstile_token_expired");
                  }
                });

                if (widgetId === undefined || widgetId === null) {
                  fail("turnstile_render_failed");
                  return;
                }

                rendered = true;
                if (apiReadyTimer) {
                  window.clearTimeout(apiReadyTimer);
                }
                post({ type: "ready" });
              } catch (error) {
                fail("turnstile_render_exception");
              }
            }

            function loadAPI() {
              if (terminal) {
                return;
              }

              var apiScript = document.createElement("script");
              apiScript.src = "https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit";
              apiScript.async = true;
              apiScript.defer = true;
              apiScript.onload = function() {
                if (apiLoadTimer) {
                  window.clearTimeout(apiLoadTimer);
                }
                apiReadyTimer = window.setTimeout(function() {
                  fail("turnstile_api_ready_timeout");
                }, 5000);
                renderWidget();
              };
              apiScript.onerror = function() {
                fail("turnstile_api_load_failed");
              };

              apiLoadTimer = window.setTimeout(function() {
                fail("turnstile_api_load_timeout");
              }, 15000);
              document.head.appendChild(apiScript);
            }

            window.addEventListener("error", function() {
              fail("turnstile_script_error");
            });
            window.addEventListener("unhandledrejection", function() {
              fail("turnstile_script_rejection");
            });

            if (document.readyState === "loading") {
              document.addEventListener("DOMContentLoaded", loadAPI);
            } else {
              loadAPI();
            }
          </script>
        </body>
        </html>
        """
    }

    private static func javaScriptStringLiteral(_ value: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        return String(data: data, encoding: .utf8)!
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        private let onReady: @MainActor () -> Void
        private let onToken: @MainActor (String) -> Void
        private let onError: @MainActor (String) -> Void
        private var didComplete = false

        init(
            onReady: @escaping @MainActor () -> Void,
            onToken: @escaping @MainActor (String) -> Void,
            onError: @escaping @MainActor (String) -> Void
        ) {
            self.onReady = onReady
            self.onToken = onToken
            self.onError = onError
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "turnstile",
                  let payload = message.body as? [String: Any],
                  let type = payload["type"] as? String else {
                fail("turnstile_message_invalid")
                return
            }

            if type == "ready" {
                markReady()
                return
            }

            if type == "success",
               let token = payload["token"] as? String,
               !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                succeed(token)
                return
            }

            let message = (payload["message"] as? String) ?? "turnstile_failed"
            fail(message)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            fail("turnstile_navigation_failed")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            fail("turnstile_navigation_failed")
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            fail("turnstile_web_content_process_terminated")
        }

        func invalidate() {
            didComplete = true
        }

        private func markReady() {
            guard !didComplete else { return }
            Task { @MainActor [onReady] in
                onReady()
            }
        }

        private func succeed(_ token: String) {
            guard !didComplete else { return }
            didComplete = true
            Task { @MainActor [onToken] in
                onToken(token)
            }
        }

        private func fail(_ message: String) {
            guard !didComplete else { return }
            didComplete = true
            Task { @MainActor [onError] in
                onError(message)
            }
        }
    }
}
