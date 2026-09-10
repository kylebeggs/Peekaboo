import Foundation
import MarkdownRenderer

/// Caches rendered comment pages, native attributed bodies, and measured heights so
/// sidecar live-reloads and LazyVStack recycling never re-render or re-measure an
/// unchanged body. Rich pages are cached body-only and wrapped on demand: the shared
/// stylesheet is ~50 KB (~450 KB with KaTeX fonts), too much to duplicate per entry.
@MainActor
final class CommentRenderCache {
    /// Distinct bodies per document stay small; the cap only guards a long review with
    /// many edited messages from growing without bound.
    private static let maxEntries = 256

    nonisolated private let baseURL: URL?
    private var bodies: [String: RenderedDocument] = [:]
    private var attributed: [String: AttributedString] = [:]
    private var heights: [String: CGFloat] = [:]
    private var inFlight: [String: Task<RenderedDocument?, Never>] = [:]

    nonisolated init(baseURL: URL?) {
        self.baseURL = baseURL
    }

    func page(for body: String) async -> String? {
        if let cached = bodies[body] { return Self.wrapPage(cached) }
        if let task = inFlight[body] { return await task.value.map(Self.wrapPage) }
        let base = baseURL
        let task = Task.detached(priority: .userInitiated) { () -> RenderedDocument? in
            autoreleasepool {
                var options = RenderOptions()
                options.baseURL = base
                return try? MarkdownRenderer().renderDocument(markdown: body, options: options)
            }
        }
        inFlight[body] = task
        let document = await task.value
        inFlight[body] = nil
        if let document {
            if bodies.count >= Self.maxEntries { bodies.removeAll(keepingCapacity: true) }
            bodies[body] = document
        }
        return document.map(Self.wrapPage)
    }

    /// Inline-only markdown parsed once per body; `AttributedString(markdown:)` in a view
    /// body would otherwise re-parse every message on every sidebar pass.
    func attributedBody(for body: String) -> AttributedString? {
        if let cached = attributed[body] { return cached }
        guard let parsed = try? AttributedString(
            markdown: body,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else { return nil }
        if attributed.count >= Self.maxEntries { attributed.removeAll(keepingCapacity: true) }
        attributed[body] = parsed
        return parsed
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
