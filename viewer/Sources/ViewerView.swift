import SwiftUI
import WebKit

struct ViewerView: View {
    @EnvironmentObject private var settings: ViewerSettings
    @State private var reloadToken = 0
    @State private var showMenu = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if let url = settings.url {
                AndroidWebView(url: url, password: settings.password, reloadToken: reloadToken)
                    .ignoresSafeArea()
            }
            Button {
                showMenu = true
            } label: {
                Image(systemName: "ellipsis.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.white.opacity(0.35))
                    .padding(10)
            }
            .confirmationDialog("メニュー", isPresented: $showMenu) {
                Button("再読み込み") { reloadToken += 1 }
                Button("接続先・パスワードを変更") { settings.showSetup = true }
                Button("キャンセル", role: .cancel) {}
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
    }
}

/// サーバーの画面配信（ws-scrcpy）を表示する。認証はクッキー（nginx 側で確認）と Basic 認証の両方で行う
struct AndroidWebView: UIViewRepresentable {
    let url: URL
    let password: String
    let reloadToken: Int

    func makeCoordinator() -> Coordinator { Coordinator(password: password) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isOpaque = false
        webView.backgroundColor = .black
        context.coordinator.lastReloadToken = reloadToken
        load(webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.password = password
        if context.coordinator.lastReloadToken != reloadToken {
            context.coordinator.lastReloadToken = reloadToken
            load(webView)
        }
    }

    private func load(_ webView: WKWebView) {
        guard let host = url.host else { return }
        let cookie = HTTPCookie(properties: [
            .domain: host,
            .path: "/",
            .name: "androidpad_token",
            .value: password,
            .secure: "TRUE",
            .expires: Date().addingTimeInterval(60 * 60 * 24 * 365),
        ])
        if let cookie {
            webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) {
                webView.load(URLRequest(url: url))
            }
        } else {
            webView.load(URLRequest(url: url))
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var password: String
        var lastReloadToken = 0

        init(password: String) { self.password = password }

        func webView(_ webView: WKWebView,
                     didReceive challenge: URLAuthenticationChallenge,
                     completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodHTTPBasic,
               challenge.previousFailureCount == 0 {
                completionHandler(.useCredential, URLCredential(user: "android", password: password, persistence: .forSession))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        }

        // ws-scrcpy は画面を新しいタブで開くことがあるので、同じ画面で開き直す
        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url {
                webView.load(URLRequest(url: url))
            }
            return nil
        }
    }
}
