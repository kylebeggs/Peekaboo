import Foundation

/// Adds GitHub-style slug ids to headings so `[link](#section-name)` anchors work.
enum HeadingIDs {
    private static let pattern = try! NSRegularExpression(
        pattern: "<h([1-6])>(.*?)</h\\1>",
        options: [.dotMatchesLineSeparators]
    )
    private static let tagPattern = try! NSRegularExpression(pattern: "<[^>]+>")

    static func addAnchors(to html: String) -> String {
        let ns = html as NSString
        let matches = pattern.matches(in: html, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return html }

        var result = html
        var seen: [String: Int] = [:]
        var replacements: [(NSRange, String)] = []

        for match in matches {
            let level = ns.substring(with: match.range(at: 1))
            let inner = ns.substring(with: match.range(at: 2))
            var slug = slugify(inner)
            let count = seen[slug, default: 0]
            seen[slug] = count + 1
            if count > 0 { slug += "-\(count)" }
            replacements.append((match.range, "<h\(level) id=\"\(slug)\">\(inner)</h\(level)>"))
        }
        for (range, replacement) in replacements.reversed() {
            if let swiftRange = Range(range, in: result) {
                result.replaceSubrange(swiftRange, with: replacement)
            }
        }
        return result
    }

    private static func slugify(_ headingHTML: String) -> String {
        let ns = headingHTML as NSString
        var text = tagPattern.stringByReplacingMatches(
            in: headingHTML, range: NSRange(location: 0, length: ns.length), withTemplate: ""
        )
        text = text
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .lowercased()
        var slug = ""
        for char in text {
            if char.isLetter || char.isNumber || char == "-" || char == "_" {
                slug.append(char)
            } else if char == " " {
                slug.append("-")
            }
        }
        return slug
    }
}
