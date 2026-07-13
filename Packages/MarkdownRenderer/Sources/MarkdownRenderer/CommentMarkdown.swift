import Foundation

/// Decides whether a comment body needs the web renderer (block constructs, math,
/// images) or can be drawn natively as inline-only attributed text. Kept UI-free so
/// it is testable. Bias: web when in doubt — the web path is always correct, the
/// native path silently flattens block markdown.
public enum CommentMarkdown {
    public static func needsWebRendering(_ body: String) -> Bool {
        if body.contains("$") {
            // Reuse the fence-aware extractor so literal dollars ("$5 vs $10")
            // stay native and only real math gates to the web renderer.
            let registry = MathRegistry()
            _ = MathExtractor.extract(from: body, into: registry)
            if !registry.isEmpty { return true }
        }
        if body.contains("![") || body.contains("[[") { return true }
        if body.range(of: "</?[A-Za-z]", options: .regularExpression) != nil { return true }

        var previousBlank = true
        for raw in body.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") { return true }
            if line.hasPrefix(">") { return true }
            if line.hasPrefix("|") { return true }
            if line.range(of: "^#{1,6} ", options: .regularExpression) != nil { return true }
            if line.range(of: #"^([-*+]|[0-9]+[.)]) "#, options: .regularExpression) != nil { return true }
            if previousBlank && raw.hasPrefix("    ") && !line.isEmpty { return true }
            previousBlank = line.isEmpty
        }
        return false
    }
}
