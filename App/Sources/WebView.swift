import SwiftUI
import WebKit
import MarkdownRenderer

struct WebView: NSViewRepresentable {
    let document: RenderedDocument?
    let fileURL: URL?
    let fullWidth: Bool
    @ObservedObject var store: CommentStore
    @AppStorage("pageZoom") private var pageZoom = 1.0

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        if let mermaid = Self.mermaidScript {
            configuration.userContentController.addUserScript(
                WKUserScript(source: mermaid, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
            )
        }
        // Added after Mermaid so it can wrap the shared `__peekabooRender` hook.
        configuration.userContentController.addUserScript(
            WKUserScript(source: CommentBridge.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        )
        configuration.userContentController.add(context.coordinator, name: "pkbComment")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.pageZoom = pageZoom
        context.coordinator.fileURL = fileURL
        context.coordinator.store = store
        context.coordinator.webView = webView
        store.scrollHandler = { [weak coordinator = context.coordinator] id in coordinator?.scrollTo(id) }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        webView.pageZoom = pageZoom
        context.coordinator.fileURL = fileURL
        context.coordinator.store = store
        context.coordinator.fullWidth = fullWidth
        guard let document else { return }
        context.coordinator.show(document, in: webView)
        context.coordinator.applyWidth(in: webView)
        context.coordinator.syncAnchors()
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "pkbComment")
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

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var fileURL: URL?
        var fullWidth = false
        weak var store: CommentStore?
        weak var webView: WKWebView?
        private var loadedOnce = false
        private var lastBody: String?
        private var lastAnchorsJSON: String?
        private var appliedFullWidth: Bool?

        /// Drops the 980px column cap by toggling a class the stylesheet already carries.
        ///
        /// A class beats re-rendering with a width option: the markdown never changes, so a
        /// re-render would redo math and highlighting for one CSS declaration — and `show`
        /// early-outs on unchanged `bodyHTML`, so the new stylesheet would never reach the page.
        /// The class lives on `<body>` itself, which the live-reload `innerHTML` swap leaves
        /// alone, so it survives file edits and rendered/source switches.
        func applyWidth(in webView: WKWebView) {
            guard appliedFullWidth != fullWidth else { return }
            appliedFullWidth = fullWidth
            webView.evaluateJavaScript(
                "document.body.classList.toggle('peekaboo-full-width', \(fullWidth));")
        }

        /// Pushes the open inline anchors to the page for (re)highlighting, skipping
        /// the round-trip when the set is unchanged.
        func syncAnchors() {
            guard let store, let webView else { return }
            let json = CommentBridge.anchorsJSON(store.inlineThreads)
            guard json != lastAnchorsJSON else { return }
            lastAnchorsJSON = json
            webView.evaluateJavaScript("window.__pkb && window.__pkb.apply(\(json));")
        }

        func scrollTo(_ id: String) {
            webView?.evaluateJavaScript("window.__pkb && window.__pkb.scrollTo(\(jsString(id)));")
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            lastAnchorsJSON = nil // page reloaded; force a re-push
            // Showing or hiding the comments sidebar moves the WebView between two branches of
            // DocumentView's Group, which can rebuild the web view and reload from scratch. The
            // fresh page has no class on it, whatever the coordinator last pushed.
            appliedFullWidth = nil
            applyWidth(in: webView)
            syncAnchors()
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "pkbComment",
                  let body = message.body as? [String: Any],
                  let type = body["type"] as? String,
                  let store else { return }
            switch type {
            case "add":
                guard let raw = body["anchor"] as? [String: Any] else { return }
                let anchor = CommentAnchor(
                    quote: raw["quote"] as? String ?? "",
                    prefix: raw["prefix"] as? String ?? "",
                    suffix: raw["suffix"] as? String ?? "")
                guard !anchor.quote.isEmpty else { return }
                store.beginInlineComment(anchor)
            case "select":
                if let id = body["id"] as? String { store.selectThread(id) }
            case "outdated":
                store.setOutdated(body["ids"] as? [String] ?? [], order: body["order"] as? [String] ?? [])
            default:
                break
            }
        }

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
            if url.scheme == "peekaboo", url.host == "wikilink" {
                decisionHandler(.cancel)
                openWikiLink(url)
                return
            }
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        }

        private func openWikiLink(_ url: URL) {
            guard let target = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                      .queryItems?.first(where: { $0.name == "target" })?.value,
                  let origin = fileURL else {
                NSSound.beep()
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let resolved = WikiLinkResolver.resolve(target: target, from: origin)
                DispatchQueue.main.async {
                    guard let resolved else {
                        NSSound.beep()
                        return
                    }
                    // NSDocumentController, not NSWorkspace: Peekaboo registers as an
                    // Alternate handler for markdown, so NSWorkspace would open the
                    // user's default editor instead.
                    NSDocumentController.shared.openDocument(
                        withContentsOf: resolved, display: true
                    ) { _, _, error in
                        if error != nil { NSSound.beep() }
                    }
                }
            }
        }

        private func jsString(_ string: String) -> String {
            guard let data = try? JSONEncoder().encode([string]),
                  let json = String(data: data, encoding: .utf8) else { return "''" }
            return String(json.dropFirst().dropLast())
        }
    }
}
