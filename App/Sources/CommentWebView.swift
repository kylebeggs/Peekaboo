import SwiftUI
import WebKit
import AppKit

/// A content-height web view for one rich comment body. Pages are fully static
/// (math and highlighting are pre-rendered), so the only JavaScript is a one-shot
/// height measurement after load and on width changes.
struct CommentWebView: NSViewRepresentable {
    let html: String
    let onHeight: (CGFloat) -> Void

    private static let configuration = WKWebViewConfiguration()

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SidebarWebView {
        let webView = SidebarWebView(frame: .zero, configuration: Self.configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.onWidthChange = { [weak coordinator = context.coordinator] in coordinator?.measure() }
        context.coordinator.webView = webView
        return webView
    }

    func updateNSView(_ webView: SidebarWebView, context: Context) {
        context.coordinator.onHeight = onHeight
        guard context.coordinator.lastHTML != html else { return }
        context.coordinator.lastHTML = html
        webView.loadHTMLString(html, baseURL: nil)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var webView: WKWebView?
        var lastHTML: String?
        var onHeight: (CGFloat) -> Void = { _ in }
        private var lastReported: CGFloat = 0

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            measure()
        }

        func measure() {
            guard let webView, webView.bounds.width > 0 else { return }
            webView.evaluateJavaScript("document.documentElement.scrollHeight") { [weak self] value, _ in
                guard let self, let number = value as? NSNumber else { return }
                let height = CGFloat(truncating: number)
                guard height > 0, abs(height - self.lastReported) > 0.5 else { return }
                self.lastReported = height
                self.onHeight(height)
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard navigationAction.navigationType == .linkActivated else {
                decisionHandler(.allow)
                return
            }
            if let url = navigationAction.request.url, url.scheme == "http" || url.scheme == "https" {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
        }
    }
}

/// Content-sized: never scrolls itself, re-measures when the sidebar width changes.
final class SidebarWebView: WKWebView {
    var onWidthChange: (() -> Void)?
    private var lastWidth: CGFloat = 0

    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }

    override func layout() {
        super.layout()
        if abs(bounds.width - lastWidth) > 0.5 {
            lastWidth = bounds.width
            onWidthChange?()
        }
    }
}
