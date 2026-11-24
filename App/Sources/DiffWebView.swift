import SwiftUI
import WebKit
import MarkdownRenderer

/// The web view of a review window. A sibling of `WebView` rather than a mode of it:
/// that one swaps a whole document body and matches comment anchors by text quote,
/// this one patches individual files and marks lines by number.
struct DiffWebView: NSViewRepresentable {
    @ObservedObject var model: ReviewModel
    @AppStorage("pageZoom") private var pageZoom = 1.0

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(
            WKUserScript(source: DiffBridge.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        configuration.userContentController.add(context.coordinator, name: DiffBridge.handlerName)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.pageZoom = pageZoom
        context.coordinator.model = model
        context.coordinator.webView = webView
        model.store.scrollHandler = { [weak coordinator = context.coordinator] id in coordinator?.scrollTo(id) }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        webView.pageZoom = pageZoom
        context.coordinator.model = model
        if let snapshot = model.snapshot { context.coordinator.show(snapshot, in: webView) }
        context.coordinator.syncMarkers(model.markers)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: DiffBridge.handlerName)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var model: ReviewModel?
        weak var webView: WKWebView?
        private var loadedOnce = false
        private var pageReady = false
        /// What the page currently shows: file id → key, in order, plus the summary.
        private var pushedKeys: [String: String] = [:]
        private var pushedOrder: [String] = []
        private var pushedSummary: String?
        private var pushedMarkers: [ReviewModel.Marker]?
        /// The newest snapshot that arrived while the page was still loading.
        private var waiting: ReviewModel.Snapshot?

        func show(_ snapshot: ReviewModel.Snapshot, in webView: WKWebView) {
            if !loadedOnce {
                loadedOnce = true
                record(snapshot)
                webView.loadHTMLString(
                    DiffRenderer.page(title: "Review", summary: snapshot.summary, files: snapshot.files.map(\.html)),
                    baseURL: nil)
                return
            }
            guard pageReady else {
                waiting = snapshot
                return
            }
            let order = snapshot.files.map(\.id)
            let changed = snapshot.files.filter { pushedKeys[$0.id] != $0.key }
            guard !changed.isEmpty || order != pushedOrder || snapshot.summary != pushedSummary else { return }

            struct Update: Encodable {
                let summary: String?
                let order: [String]
                let files: [String: String]
            }
            let update = Update(
                summary: snapshot.summary == pushedSummary ? nil : snapshot.summary,
                order: order,
                files: Dictionary(uniqueKeysWithValues: changed.map { ($0.id, $0.html) }))
            record(snapshot)
            // A JSON literal in the script text, not `callAsyncJavaScript(arguments:)`;
            // see `WebView.Coordinator.show` for the leak that avoids.
            guard let data = try? JSONEncoder().encode(update), let json = String(data: data, encoding: .utf8) else { return }
            webView.evaluateJavaScript("window.__pkbDiff && window.__pkbDiff.patch(\(json));")
        }

        private func record(_ snapshot: ReviewModel.Snapshot) {
            pushedKeys = Dictionary(uniqueKeysWithValues: snapshot.files.map { ($0.id, $0.key) })
            pushedOrder = snapshot.files.map(\.id)
            pushedSummary = snapshot.summary
        }

        func syncMarkers(_ markers: [ReviewModel.Marker]) {
            guard pageReady, markers != pushedMarkers, let webView,
                  let data = try? JSONEncoder().encode(markers), let json = String(data: data, encoding: .utf8) else { return }
            pushedMarkers = markers
            webView.evaluateJavaScript("window.__pkbDiff && window.__pkbDiff.setMarkers(\(json));")
        }

        func scrollTo(_ threadID: String) {
            guard let data = try? JSONEncoder().encode(threadID), let json = String(data: data, encoding: .utf8) else { return }
            webView?.evaluateJavaScript("window.__pkbDiff && window.__pkbDiff.scrollTo(\(json));")
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            pageReady = true
            pushedMarkers = nil
            if let snapshot = waiting {
                waiting = nil
                show(snapshot, in: webView)
            }
            if let model { syncMarkers(model.markers) }
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == DiffBridge.handlerName, let model,
                  let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            switch type {
            case "viewed":
                guard let id = body["id"] as? String, let viewed = body["viewed"] as? Bool else { return }
                // The page already shows the new state; record it as pushed so the
                // next snapshot does not replace the element with an identical one.
                if let key = model.setViewed(viewed, fileID: id) { pushedKeys[id] = key }
            case "load":
                if let id = body["id"] as? String { model.loadFile(id) }
            case "comment":
                guard let id = body["id"] as? String, let start = body["start"] as? Int, let end = body["end"] as? Int,
                      let side = (body["side"] as? String).flatMap(DiffSide.init(rawValue:)) else { return }
                model.beginComment(fileID: id, side: side, start: start, end: end)
            case "select":
                if let thread = body["thread"] as? String { model.store.selectThread(thread) }
            default:
                break
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            // The page has no links of its own; anything clicked is content from a diff.
            guard navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        }
    }
}
