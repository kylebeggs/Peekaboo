import Foundation
import Yams

/// Splits a leading `--- ... ---` YAML block and renders it as a key/value table,
/// like GitHub does. Invalid YAML or a missing closing fence leaves the source intact.
enum FrontMatterPass {
    static func split(source: String) -> (html: String, remainder: String)? {
        guard source.hasPrefix("---") else { return nil }
        let lines = source.components(separatedBy: "\n")
        guard lines[0].trimmingCharacters(in: .whitespaces) == "---" else { return nil }

        var end: Int?
        for index in 1..<lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed == "---" || trimmed == "..." {
                end = index
                break
            }
        }
        guard let end, end > 1 else { return nil }

        let yaml = lines[1..<end].joined(separator: "\n")
        guard let node = try? Yams.compose(yaml: yaml), let mapping = node.mapping, !mapping.isEmpty else { return nil }

        var rows = ""
        for (key, value) in mapping {
            rows += "<tr><th>\(escapeHTML(key.string ?? "?"))</th><td>\(renderValue(value))</td></tr>"
        }
        let html = "<table class=\"frontmatter\"><tbody>\(rows)</tbody></table>\n"
        let remainder = lines[(end + 1)...].joined(separator: "\n")
        return (html, remainder)
    }

    private static func renderValue(_ node: Node) -> String {
        if let scalar = node.scalar {
            return escapeHTML(scalar.string)
        }
        guard let yaml = try? Yams.serialize(node: node) else { return "" }
        return "<code>\(escapeHTML(yaml.trimmingCharacters(in: .whitespacesAndNewlines)))</code>"
    }
}
