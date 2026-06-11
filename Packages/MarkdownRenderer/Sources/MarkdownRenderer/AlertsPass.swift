import Foundation
import cmark_gfm

/// Transforms GitHub alert blockquotes (`> [!NOTE]` etc.) into styled divs.
/// The blockquote is replaced by raw-HTML sibling blocks bracketing its children,
/// so no custom cmark node types are needed.
enum AlertsPass {
    private static let kinds: [String: String] = [
        "note": "Note", "tip": "Tip", "important": "Important", "warning": "Warning", "caution": "Caution",
    ]

    private static let icons: [String: String] = {
        var result: [String: String] = [:]
        for kind in kinds.keys {
            if let url = Bundle.module.url(forResource: kind, withExtension: "svg", subdirectory: "Resources/alerts"),
               let svg = try? String(contentsOf: url, encoding: .utf8) {
                result[kind] = svg.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return result
    }()

    static func transform(blockquote: CMarkNode) {
        guard cmark_node_get_type(blockquote) == CMARK_NODE_BLOCK_QUOTE,
              let paragraph = cmark_node_first_child(blockquote),
              cmark_node_get_type(paragraph) == CMARK_NODE_PARAGRAPH,
              let marker = cmark_node_first_child(paragraph),
              cmark_node_get_type(marker) == CMARK_NODE_TEXT,
              let cLiteral = cmark_node_get_literal(marker) else { return }

        let literal = String(cString: cLiteral).trimmingCharacters(in: .whitespaces)
        guard literal.hasPrefix("[!"), literal.hasSuffix("]") else { return }
        let kind = String(literal.dropFirst(2).dropLast()).lowercased()
        guard let title = kinds[kind] else { return }

        // The marker must be alone on its line.
        let next = cmark_node_next(marker)
        if let next {
            let type = cmark_node_get_type(next)
            guard type == CMARK_NODE_SOFTBREAK || type == CMARK_NODE_LINEBREAK else { return }
        }

        cmark_node_unlink(marker)
        cmark_node_free(marker)
        if let next {
            cmark_node_unlink(next)
            cmark_node_free(next)
        }
        if cmark_node_first_child(paragraph) == nil {
            cmark_node_unlink(paragraph)
            cmark_node_free(paragraph)
        }

        let icon = icons[kind] ?? ""
        guard let opener = CMarkPipeline.htmlBlock(
                  "<div class=\"markdown-alert markdown-alert-\(kind)\"><p class=\"markdown-alert-title\">\(icon)\(title)</p>\n"),
              let closer = CMarkPipeline.htmlBlock("</div>\n") else { return }

        cmark_node_insert_before(blockquote, opener)
        while let child = cmark_node_first_child(blockquote) {
            cmark_node_unlink(child)
            cmark_node_insert_before(blockquote, child)
        }
        cmark_node_insert_before(blockquote, closer)
        cmark_node_unlink(blockquote)
        cmark_node_free(blockquote)
    }
}
