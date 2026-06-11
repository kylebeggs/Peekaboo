import SwiftUI
import WebKit
import MarkdownRenderer

struct WebView: NSViewRepresentable {
    let document: RenderedDocument?
    @AppStorage("pageZoom") private var pageZoom = 1.0

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        if let mermaid = Self.mermaidScript {
            configuration.userContentController.addUserScript(
                WKUserScript(source: mermaid, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
            )
        }
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.pageZoom = pageZoom
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        webView.pageZoom = pageZoom
        guard let document else { return }
        context.coordinator.show(document, in: webView)
    }

    /// mermaid.min.js plus an init hook. The hook is re-invoked after live-reload
    /// body swaps; JavaScript is enabled in the app web view solely for this.
    private static let mermaidScript: String? = {
        guard let url = Bundle.main.url(forResource: "mermaid.min", withExtension: "js"),
              let library = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let hook = """

        window.__peekabooRender = function() {
            document.querySelectorAll('pre > code.language-mermaid').forEach(function(code) {
                var div = document.createElement('div');
                div.className = 'mermaid';
                div.textContent = code.textContent;
                code.parentElement.replaceWith(div);
            });
            if (window.mermaid && document.querySelector('.mermaid')) {
                mermaid.initialize({
                    startOnLoad: false,
                    securityLevel: 'strict',
                    theme: window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'default'
                });
                mermaid.run({ querySelector: '.mermaid' });
            }
        };
        window.__peekabooRender();
        """
        return library + hook
    }()

    final class Coordinator: NSObject, WKNavigationDelegate {
        private var loadedOnce = false
        private var lastBody: String?

        func show(_ document: RenderedDocument, in webView: WKWebView) {
            guard document.bodyHTML != lastBody else { return }
            lastBody = document.bodyHTML

            if !loadedOnce {
                loadedOnce = true
                webView.loadHTMLString(document.html, baseURL: nil)
                return
            }
            // Body swap instead of reload: preserves scroll position, no flash.
            let script = """
            document.getElementById('peekaboo-style').textContent = \(jsString(document.css));
            document.body.innerHTML = \(jsString(document.bodyHTML));
            var max = document.body.scrollHeight - window.innerHeight;
            if (window.scrollY > max) { window.scrollTo(0, Math.max(0, max)); }
            if (window.__peekabooRender) { window.__peekabooRender(); }
            """
            webView.evaluateJavaScript(script)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard navigationAction.navigationType == .linkActivated,
                  let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            // Fragment navigation within the loaded document (footnotes, anchors).
            if url.scheme == "about" {
                decisionHandler(.allow)
                return
            }
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        }

        private func jsString(_ string: String) -> String {
            guard let data = try? JSONEncoder().encode([string]),
                  let json = String(data: data, encoding: .utf8) else { return "''" }
            return String(json.dropFirst().dropLast())
        }
    }
}
