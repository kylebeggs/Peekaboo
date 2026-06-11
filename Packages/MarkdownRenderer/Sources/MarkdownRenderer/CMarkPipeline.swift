import Foundation
import cmark_gfm
import cmark_gfm_extensions

typealias CMarkNode = UnsafeMutablePointer<cmark_node>

// cmark-gfm option macros are not imported into Swift; values from cmark-gfm.h.
enum CMarkOptions {
    static let validateUTF8: Int32 = 1 << 9
    static let footnotes: Int32 = 1 << 13
    static let unsafe: Int32 = 1 << 17
    static let all = validateUTF8 | footnotes | unsafe
}

enum CMarkPipeline {
    private static let extensionNames = ["table", "strikethrough", "autolink", "tasklist"]

    static func render(markdown: String, math: MathRegistry, highlightCode: Bool = true) throws -> String {
        cmark_gfm_core_extensions_ensure_registered()
        guard let parser = cmark_parser_new(CMarkOptions.all) else { throw RenderError.parserCreationFailed }
        defer { cmark_parser_free(parser) }

        for name in extensionNames {
            guard let ext = cmark_find_syntax_extension(name) else { throw RenderError.missingExtension(name) }
            cmark_parser_attach_syntax_extension(parser, ext)
        }

        cmark_parser_feed(parser, markdown, markdown.utf8.count)
        guard let doc = cmark_parser_finish(parser) else { throw RenderError.parseFailed }
        defer { cmark_node_free(doc) }

        transform(doc: doc, math: math, highlightCode: highlightCode)

        guard let cHTML = cmark_render_html(doc, CMarkOptions.all, cmark_parser_get_syntax_extensions(parser)) else {
            throw RenderError.renderFailed
        }
        defer { free(cHTML) }
        return String(cString: cHTML)
    }

    private static func transform(doc: CMarkNode, math: MathRegistry, highlightCode: Bool) {
        var codeBlocks: [CMarkNode] = []
        var blockquotes: [CMarkNode] = []

        guard let iter = cmark_iter_new(doc) else { return }
        defer { cmark_iter_free(iter) }
        var event = cmark_iter_next(iter)
        while event != CMARK_EVENT_DONE {
            if event == CMARK_EVENT_ENTER, let node = cmark_iter_get_node(iter) {
                switch cmark_node_get_type(node) {
                case CMARK_NODE_CODE_BLOCK: codeBlocks.append(node)
                case CMARK_NODE_BLOCK_QUOTE: blockquotes.append(node)
                case CMARK_NODE_TEXT: EmojiPass.apply(to: node)
                default: break
                }
            }
            event = cmark_iter_next(iter)
        }

        // Mutations happen after iteration completes; the iterator must not see a changing tree.
        for blockquote in blockquotes { AlertsPass.transform(blockquote: blockquote) }
        for codeBlock in codeBlocks { transformCodeBlock(codeBlock, math: math, highlightCode: highlightCode) }
    }

    private static func transformCodeBlock(_ node: CMarkNode, math: MathRegistry, highlightCode: Bool) {
        let info = cmark_node_get_fence_info(node).map { String(cString: $0) } ?? ""
        let language = info.split(separator: " ").first.map { $0.lowercased() } ?? ""
        guard let cLiteral = cmark_node_get_literal(node) else { return }
        let literal = String(cString: cLiteral)

        if language == "math" {
            let token = math.register(tex: literal.trimmingCharacters(in: .whitespacesAndNewlines), display: true)
            replace(node, withHTML: "<p>\(token)</p>")
            return
        }
        guard highlightCode, !language.isEmpty, language != "mermaid" else { return }
        guard let highlighted = JSEngine.shared.highlight(code: literal, language: language) else { return }
        replace(node, withHTML: "<pre><code class=\"hljs language-\(language)\">\(highlighted)</code></pre>\n")
    }

    static func replace(_ node: CMarkNode, withHTML html: String) {
        guard let replacement = cmark_node_new(CMARK_NODE_HTML_BLOCK) else { return }
        cmark_node_set_literal(replacement, html)
        cmark_node_replace(node, replacement)
        cmark_node_free(node)
    }

    static func htmlBlock(_ html: String) -> CMarkNode? {
        guard let node = cmark_node_new(CMARK_NODE_HTML_BLOCK) else { return nil }
        cmark_node_set_literal(node, html)
        return node
    }
}
