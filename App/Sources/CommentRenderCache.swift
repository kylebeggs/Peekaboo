import Foundation
import MarkdownRenderer

/// Caches rendered comment pages and measured heights so sidecar live-reloads and
/// LazyVStack recycling never re-render or re-measure an unchanged body.
@MainActor
final class CommentRenderCache {
    nonisolated private let baseURL: URL?
    private var pages: [String: String] = [:]
    private var heights: [String: CGFloat] = [:]
    private var inFlight: [String: Task<String?, Never>] = [:]

    nonisolated init(baseURL: URL?) {
        self.baseURL = baseURL
    }

    func page(for body: String) async -> String? {
        if let cached = pages[body] { return cached }
        if let task = inFlight[body] { return await task.value }
        let base = baseURL
        let task = Task.detached(priority: .userInitiated) { () -> String? in
            var options = RenderOptions()
            options.baseURL = base
            guard let document = try? MarkdownRenderer().renderDocument(markdown: body, options: options) else {
                return nil
            }
            return Self.wrapPage(document)
        }
        inFlight[body] = task
        let page = await task.value
        inFlight[body] = nil
        if let page { pages[body] = page }
        return page
    }

    func height(for body: String) -> CGFloat? {
        heights[body]
    }

    func setHeight(_ height: CGFloat, for body: String) {
        heights[body] = height
    }

    /// Mirrors `RenderedDocument.html`, restyled for the sidebar: transparent,
    /// compact, content-sized. The override style comes after `css` so equal
    /// selectors win by order.
    nonisolated private static func wrapPage(_ document: RenderedDocument) -> String {
        """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
        \(document.css)
        body { margin: 0; background: transparent; overflow: hidden; }
        .markdown-body { background: transparent; padding: 0; margin: 0;
                         max-width: none; min-width: 0; font-size: 12px; }
        .markdown-body > :first-child { margin-top: 0 !important; }
        .markdown-body > :last-child { margin-bottom: 0 !important; }
        </style>
        </head>
        <body class="markdown-body">
        \(document.bodyHTML)
        </body>
        </html>
        """
    }
}
