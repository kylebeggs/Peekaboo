import Foundation

/// Rewrites Obsidian wikilinks in rendered HTML: `[[Note]]`, `[[Note#Heading]]`,
/// `[[Note|alias]]`, and `[[#Heading]]` become links; `![[image.png]]` embeds
/// become `<img>` tags (picked up downstream by ImageInliner). Cross-note links
/// use the `peekaboo://wikilink` scheme, which the app resolves against the
/// surrounding vault; the Quick Look extension renders them styled but inert.
/// Content inside `<pre>`, `<code>`, and KaTeX `<annotation>` elements is left
/// untouched.
enum WikiLinksPass {
    // Inner brackets are excluded; markup is allowed because inline math in a
    // link target has already been KaTeX-rendered by the time this pass runs.
    private static let pattern = try! NSRegularExpression(pattern: "(!?)\\[\\[([^\\[\\]\\n]+)\\]\\]")
    private static let protectedPattern = try! NSRegularExpression(
        pattern: "<(pre|code|annotation)\\b[^>]*>.*?</\\1>",
        options: [.dotMatchesLineSeparators]
    )
    private static let tagPattern = try! NSRegularExpression(pattern: "<[^>]+>")
    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "svg", "webp", "bmp", "avif"]

    static func transform(html: String) -> String {
        guard html.contains("[[") else { return html }
        let ns = html as NSString
        let all = NSRange(location: 0, length: ns.length)
        let protectedRanges = protectedPattern.matches(in: html, range: all).map(\.range)
        let matches = pattern.matches(in: html, range: all)
        guard !matches.isEmpty else { return html }

        var result = html
        for match in matches.reversed() {
            // Skip only when a delimiter sits inside protected content: rendered
            // math (with its <annotation>) may legitimately appear between them.
            let endpoints = [match.range.location, NSMaxRange(match.range) - 1]
            guard !protectedRanges.contains(where: { range in
                      endpoints.contains { NSLocationInRange($0, range) }
                  }),
                  let replacement = render(
                      inner: ns.substring(with: match.range(at: 2)),
                      isEmbed: match.range(at: 1).length > 0
                  ),
                  let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }

    /// `inner` is the entity-escaped text between the brackets.
    private static func render(inner: String, isEmbed: Bool) -> String? {
        var target = inner
        var alias: String? = nil
        if let pipe = inner.firstIndex(of: "|") {
            target = String(inner[..<pipe])
            let rest = String(inner[inner.index(after: pipe)...])
            if !rest.isEmpty { alias = rest }
        }
        target = target.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return nil }

        if isEmbed {
            // An all-digits second part is a width (`![[pic.png|300]]`), not an alias.
            let width = alias.flatMap { $0.allSatisfy(\.isNumber) ? $0 : nil }
            if width != nil { alias = nil }
            let path = decodeEntities(target)
            if imageExtensions.contains((path as NSString).pathExtension.lowercased()) {
                let widthAttribute = width.map { " width=\"\($0)\"" } ?? ""
                return "<img src=\"\(escapeAttribute(path))\"\(widthAttribute)>"
            }
        }

        let hashIndex = target.firstIndex(of: "#")
        let note = hashIndex.map { String(target[..<$0]) } ?? target
        let heading = hashIndex.map { String(target[target.index(after: $0)...]) } ?? ""

        // `[[#Heading]]`: an anchor within the current document.
        if note.isEmpty {
            guard !heading.isEmpty else { return nil }
            return "<a href=\"#\(HeadingIDs.slugify(heading))\">\(alias ?? heading)</a>"
        }

        var href = "peekaboo://wikilink?target=\(percentEncode(decodeEntities(stripTags(note))))"
        if !heading.isEmpty {
            href += "&amp;heading=\(percentEncode(decodeEntities(stripTags(heading))))"
        }
        return "<a class=\"wikilink\" href=\"\(href)\">\(alias ?? target)</a>"
    }

    private static func stripTags(_ string: String) -> String {
        let ns = string as NSString
        return tagPattern.stringByReplacingMatches(
            in: string, range: NSRange(location: 0, length: ns.length), withTemplate: ""
        )
    }

    private static func percentEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
    }

    private static func decodeEntities(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func escapeAttribute(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
