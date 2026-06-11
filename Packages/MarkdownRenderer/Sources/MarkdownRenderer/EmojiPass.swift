import Foundation
import cmark_gfm

/// Replaces `:shortcode:` with unicode emoji in cmark TEXT nodes only, so code
/// blocks, code spans, and raw HTML are never touched. Shortcodes that map to
/// GitHub-hosted images (e.g. `:octocat:`) have no unicode and are left as text.
enum EmojiPass {
    private struct Entry: Decodable {
        let emoji: String
        let aliases: [String]
    }

    private static let map: [String: String] = {
        guard let url = Bundle.module.url(forResource: "gemoji", withExtension: "json", subdirectory: "Resources/emoji"),
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [:] }
        var result: [String: String] = [:]
        for entry in entries {
            for alias in entry.aliases { result[alias] = entry.emoji }
        }
        return result
    }()

    private static let pattern = try! NSRegularExpression(pattern: ":([a-zA-Z0-9_+\\-]+):")

    static func apply(to textNode: CMarkNode) {
        guard let cLiteral = cmark_node_get_literal(textNode) else { return }
        let literal = String(cString: cLiteral)
        guard literal.contains(":") else { return }
        let replaced = replaceShortcodes(in: literal)
        if replaced != literal {
            cmark_node_set_literal(textNode, replaced)
        }
    }

    static func replaceShortcodes(in text: String) -> String {
        let ns = text as NSString
        let matches = pattern.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        var result = ""
        var cursor = 0
        for match in matches {
            let alias = ns.substring(with: match.range(at: 1))
            guard let emoji = map[alias] else { continue }
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += emoji
            cursor = match.range.location + match.range.length
        }
        result += ns.substring(from: cursor)
        return result
    }
}
