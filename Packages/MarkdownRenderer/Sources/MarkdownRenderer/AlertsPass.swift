import Foundation
import cmark_gfm

/// Transforms GitHub alert (`> [!NOTE]`) and Obsidian callout (`> [!info] Title`)
/// blockquotes into styled divs — or, for foldable callouts (`[!info]-`/`[!info]+`),
/// native `<details>`/`<summary>` elements. The blockquote is replaced by raw-HTML
/// sibling blocks bracketing its children, so no custom cmark node types are needed.
/// Obsidian-only kinds reuse the closest GitHub alert style class; an optional
/// title after the marker replaces the default kind title.
enum AlertsPass {
    /// Obsidian fold marker after the kind: `[!info]-` collapsed, `[!info]+` expanded.
    private enum Fold {
        case none, closed, open
    }

    private static let styles = ["note", "tip", "important", "warning", "caution"]

    /// kind → (existing style class, default title shown when no custom title).
    private static let kinds: [String: (style: String, title: String)] = [
        "note": ("note", "Note"),
        "info": ("note", "Info"),
        "todo": ("note", "Todo"),
        "abstract": ("note", "Abstract"),
        "summary": ("note", "Summary"),
        "tldr": ("note", "TL;DR"),
        "tip": ("tip", "Tip"),
        "hint": ("tip", "Hint"),
        "success": ("tip", "Success"),
        "check": ("tip", "Check"),
        "done": ("tip", "Done"),
        "important": ("important", "Important"),
        "example": ("important", "Example"),
        "warning": ("warning", "Warning"),
        "attention": ("warning", "Attention"),
        "question": ("warning", "Question"),
        "help": ("warning", "Help"),
        "faq": ("warning", "FAQ"),
        "caution": ("caution", "Caution"),
        "failure": ("caution", "Failure"),
        "fail": ("caution", "Fail"),
        "missing": ("caution", "Missing"),
        "danger": ("caution", "Danger"),
        "error": ("caution", "Error"),
        "bug": ("caution", "Bug"),
        "quote": ("quote", "Quote"),
        "cite": ("quote", "Cite"),
    ]

    private static let icons: [String: String] = {
        var result: [String: String] = [:]
        for style in styles {
            if let url = Bundle.module.url(forResource: style, withExtension: "svg", subdirectory: "Resources/alerts"),
               let svg = try? String(contentsOf: url, encoding: .utf8) {
                result[style] = svg.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return result
    }()

    static func transform(blockquote: CMarkNode, extensions: UnsafeMutablePointer<cmark_llist>?) {
        guard cmark_node_get_type(blockquote) == CMARK_NODE_BLOCK_QUOTE,
              let paragraph = cmark_node_first_child(blockquote),
              cmark_node_get_type(paragraph) == CMARK_NODE_PARAGRAPH,
              let marker = cmark_node_first_child(paragraph),
              cmark_node_get_type(marker) == CMARK_NODE_TEXT,
              let cLiteral = cmark_node_get_literal(marker) else { return }

        let literal = String(cString: cLiteral)
        guard let (kind, fold, markerTitle) = parseMarker(literal), let mapping = kinds[kind] else { return }

        // Title: the marker-line remainder plus any inline nodes up to the first break.
        var titleNodes: [CMarkNode] = []
        if !markerTitle.isEmpty {
            cmark_node_set_literal(marker, markerTitle)
            titleNodes.append(marker)
        }
        var breakNode: CMarkNode? = nil
        var cursor = cmark_node_next(marker)
        while let node = cursor {
            let type = cmark_node_get_type(node)
            if type == CMARK_NODE_SOFTBREAK || type == CMARK_NODE_LINEBREAK {
                breakNode = node
                break
            }
            titleNodes.append(node)
            cursor = cmark_node_next(node)
        }

        let title = titleNodes.isEmpty
            ? escapeHTML(mapping.title)
            : (renderInlineHTML(of: titleNodes, extensions: extensions) ?? escapeHTML(mapping.title))

        if markerTitle.isEmpty {
            cmark_node_unlink(marker)
            cmark_node_free(marker)
        }
        if let breakNode {
            cmark_node_unlink(breakNode)
            cmark_node_free(breakNode)
        }
        if cmark_node_first_child(paragraph) == nil {
            cmark_node_unlink(paragraph)
            cmark_node_free(paragraph)
        }

        let icon = icons[mapping.style] ?? ""
        // The inner span keeps the title a single flex item; otherwise the flex
        // gap separates every text run and inline element in a rich title.
        let titleHTML = "\(icon)<span>\(title)</span>"
        let openerHTML: String
        let closerHTML: String
        if fold == .none {
            openerHTML = "<div class=\"markdown-alert markdown-alert-\(mapping.style)\"><p class=\"markdown-alert-title\">\(titleHTML)</p>\n"
            closerHTML = "</div>\n"
        } else {
            let openAttribute = fold == .open ? " open" : ""
            openerHTML = "<details class=\"markdown-alert markdown-alert-\(mapping.style)\"\(openAttribute)><summary class=\"markdown-alert-title\">\(titleHTML)</summary>\n"
            closerHTML = "</details>\n"
        }
        guard let opener = CMarkPipeline.htmlBlock(openerHTML),
              let closer = CMarkPipeline.htmlBlock(closerHTML) else { return }

        cmark_node_insert_before(blockquote, opener)
        while let child = cmark_node_first_child(blockquote) {
            cmark_node_unlink(child)
            cmark_node_insert_before(blockquote, child)
        }
        cmark_node_insert_before(blockquote, closer)
        cmark_node_unlink(blockquote)
        cmark_node_free(blockquote)
    }

    /// Moves the title's inline nodes into a paragraph of a detached document and
    /// renders it, returning the HTML inside the `<p>` wrapper. The nodes are
    /// consumed. The document wrapper is required: cmark-gfm's paragraph renderer
    /// dereferences the parent node unconditionally (html.c).
    private static func renderInlineHTML(
        of nodes: [CMarkNode], extensions: UnsafeMutablePointer<cmark_llist>?
    ) -> String? {
        guard let document = cmark_node_new(CMARK_NODE_DOCUMENT) else { return nil }
        defer { cmark_node_free(document) }
        guard let container = cmark_node_new(CMARK_NODE_PARAGRAPH) else { return nil }
        guard cmark_node_append_child(document, container) == 1 else {
            cmark_node_free(container)
            return nil
        }
        for node in nodes {
            cmark_node_unlink(node)
            cmark_node_append_child(container, node)
        }
        guard let cRendered = cmark_render_html(document, CMarkOptions.all, extensions) else { return nil }
        defer { free(cRendered) }
        var html = Substring(String(cString: cRendered).trimmingCharacters(in: .whitespacesAndNewlines))
        if html.hasPrefix("<p>") { html = html.dropFirst(3) }
        if html.hasSuffix("</p>") { html = html.dropLast(4) }
        return String(html)
    }

    /// Parses `[!kind]`, an optional Obsidian fold marker (`-`/`+`), and the
    /// remainder of the marker line (the start of a custom title).
    private static func parseMarker(_ literal: String) -> (kind: String, fold: Fold, title: String)? {
        // Trailing whitespace is preserved: it may separate the title head from a
        // following inline node (e.g. `[!info] See **this**`).
        let content = Substring(literal).drop(while: { $0 == " " || $0 == "\t" })
        guard content.hasPrefix("[!"), let close = content.firstIndex(of: "]") else { return nil }
        let kind = String(content[content.index(content.startIndex, offsetBy: 2)..<close]).lowercased()
        guard !kind.isEmpty else { return nil }
        var rest = content[content.index(after: close)...]
        var fold = Fold.none
        if rest.first == "-" {
            fold = .closed
            rest = rest.dropFirst()
        } else if rest.first == "+" {
            fold = .open
            rest = rest.dropFirst()
        }
        return (kind, fold, String(rest.drop(while: { $0 == " " || $0 == "\t" })))
    }
}
