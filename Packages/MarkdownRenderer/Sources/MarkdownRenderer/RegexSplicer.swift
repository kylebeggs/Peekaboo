import Foundation

/// Rebuilds a string in one forward pass, replacing each regex match with the
/// text a closure returns (or leaving it as is when the closure returns nil).
///
/// Passes must never splice with `String.replaceSubrange` in a loop: each splice
/// invalidates the string's UTF-16 breadcrumbs, and the next `Range(NSRange, in:)`
/// rebuilds them by scanning the whole string. On a KaTeX-rendered body (non-ASCII,
/// megabytes) that was ~1 s per render with a few hundred headings; a forward
/// pass over the immutable `NSString` is linear.
enum RegexSplicer {
    static func replacingMatches(
        of pattern: NSRegularExpression,
        in string: String,
        with replacement: (NSTextCheckingResult, NSString) -> String?
    ) -> String {
        let ns = string as NSString
        let matches = pattern.matches(in: string, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return string }

        var result = ""
        result.reserveCapacity(ns.length)
        var cursor = 0
        for match in matches {
            guard let replaced = replacement(match, ns) else { continue }
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += replaced
            cursor = NSMaxRange(match.range)
        }
        result += ns.substring(from: cursor)
        return result
    }
}
