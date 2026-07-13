import SwiftUI
import MarkdownRenderer

/// Dispatches a comment body to the cheapest rendering that displays it faithfully:
/// native attributed text for inline-only markdown, a content-sized web view for
/// bodies with block constructs or math.
struct CommentBodyView: View {
    let text: String
    let cache: CommentRenderCache

    var body: some View {
        if CommentMarkdown.needsWebRendering(text) {
            RichCommentBody(text: text, cache: cache)
        } else if let attributed = try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            Text(attributed).font(.callout).textSelection(.enabled)
        } else {
            Text(text).font(.callout).textSelection(.enabled)
        }
    }
}

private struct RichCommentBody: View {
    let text: String
    let cache: CommentRenderCache

    @State private var page: String?
    @State private var renderFailed = false
    @State private var height: CGFloat = 40

    var body: some View {
        Group {
            if let page {
                CommentWebView(html: page) { measured in
                    height = measured
                    cache.setHeight(measured, for: text)
                }
                .frame(height: height)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(text)
                    .font(.callout)
                    .textSelection(.enabled)
                    .foregroundStyle(renderFailed ? Color.primary : Color.secondary)
            }
        }
        .task(id: text) {
            if let cached = cache.height(for: text) { height = cached }
            page = await cache.page(for: text)
            renderFailed = page == nil
        }
    }
}
