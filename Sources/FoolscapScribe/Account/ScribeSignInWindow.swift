import AppKit
import WebKit

/// A small window showing Amazon's sign-in page with the Android user agent
/// (Amazon only serves the notebook web app to a phone browser). When the
/// notebook library appears, the session cookies are copied into the app's
/// cookie jar for `URLSession` and the window closes.
@MainActor
final class ScribeSignInWindow: NSObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    static let timeout: TimeInterval = 120
    private var window: NSWindow?
    private var webView: WKWebView?
    private var poll: Timer?
    private var deadline: Date = .distantFuture
    private var completion: ((Result<Void, Error>) -> Void)?

    enum SignInError: LocalizedError {
        case timedOut, cancelled
        var errorDescription: String? {
            switch self {
            case .timedOut: return "Sign-in timed out after two minutes."
            case .cancelled: return "Sign-in was cancelled."
            }
        }
    }

    var isOpen: Bool { window?.isVisible ?? false }

    func present(completion: @escaping (Result<Void, Error>) -> Void) {
        if isOpen { window?.makeKeyAndOrderFront(nil); return }
        self.completion = completion
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        // WebKit only offers WebAuthn to apps with Apple's web-browser entitlement, so
        // a passkey attempt here can only fail. Hide the API and Amazon's page goes
        // straight to the password flow instead of showing a "Passkey error".
        config.userContentController.addUserScript(WKUserScript(source: """
            (function () {
              try { Object.defineProperty(window, 'PublicKeyCredential', { value: undefined, configurable: true }); } catch (e) {}
              try { Object.defineProperty(Navigator.prototype, 'credentials', { get: function () { return undefined; }, configurable: true }); } catch (e) {}
            })();
            """, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 460, height: 760), configuration: config)
        web.customUserAgent = AmazonScribeClient.userAgent
        web.navigationDelegate = self
        web.uiDelegate = self
        webView = web

        let win = NSWindow(contentRect: web.frame, styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        win.title = "Sign in to Amazon"
        win.contentView = web
        win.delegate = self
        win.isReleasedWhenClosed = false
        win.center()
        win.level = .floating
        window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        deadline = Date().addingTimeInterval(Self.timeout)
        web.load(URLRequest(url: AmazonScribeClient.signInURL))
        poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    private func check() {
        guard let webView else { return }
        if Date() > deadline { finish(.failure(SignInError.timedOut)); return }
        webView.evaluateJavaScript("document.getElementById('web-library-root') !== null") { [weak self] result, _ in
            guard let self, result as? Bool == true else { return }
            MainActor.assumeIsolated { self.captureCookies() }
        }
    }

    private func captureCookies() {
        guard let webView, completion != nil else { return }
        poll?.invalidate(); poll = nil
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            for cookie in cookies where cookie.domain.hasSuffix(AmazonScribeClient.cookieDomainSuffix) {
                HTTPCookieStorage.shared.setCookie(cookie)
            }
            MainActor.assumeIsolated { self?.finish(.success(())) }
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        poll?.invalidate(); poll = nil
        let done = completion
        completion = nil
        webView?.stopLoading()
        window?.orderOut(nil)
        window = nil
        webView = nil
        done?(result)
    }

    // MARK: Delegates

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { check() }

    // Amazon occasionally wants a popup (two-factor prompts); load it in place instead.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        webView.load(navigationAction.request)
        return nil
    }

    func windowWillClose(_ notification: Notification) {
        if completion != nil { finish(.failure(SignInError.cancelled)) }
    }

    /// Forget Amazon in both cookie jars.
    static func clearWebCookies() {
        WKWebsiteDataStore.default().removeData(ofTypes: [WKWebsiteDataTypeCookies, WKWebsiteDataTypeSessionStorage, WKWebsiteDataTypeLocalStorage], modifiedSince: .distantPast) {}
    }
}
