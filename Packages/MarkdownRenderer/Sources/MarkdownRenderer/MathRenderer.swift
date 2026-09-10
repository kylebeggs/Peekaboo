import Foundation
import MathJaxSwift

enum MathRenderer {
    private static let tokenPattern = try! NSRegularExpression(
        pattern: "<p>(pkbmath[a-f0-9]+n[0-9]+x)</p>|(pkbmath[a-f0-9]+n[0-9]+x)"
    )

    /// Single pass over the HTML: each placeholder token (display tokens together
    /// with their wrapping `<p>`) is swapped for its rendered math. Identical
    /// segments are rendered once per document.
    static func substitute(registry: MathRegistry, in html: String, allowMathJaxFallback: Bool) -> String {
        guard !registry.isEmpty else { return html }
        var rendered: [String: String] = [:]
        var renderedBySegment: [MathRegistry.Segment: String] = [:]
        for (token, segment) in registry.segments {
            if let segmentHTML = renderedBySegment[segment] {
                rendered[token] = segmentHTML
                continue
            }
            let segmentHTML = render(segment, allowMathJaxFallback: allowMathJaxFallback)
            renderedBySegment[segment] = segmentHTML
            rendered[token] = segmentHTML
        }

        let ns = html as NSString
        var result = ""
        result.reserveCapacity(ns.length)
        var cursor = 0
        for match in tokenPattern.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let tokenRange = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2)
            guard let replacement = rendered[ns.substring(with: tokenRange)] else { continue }
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += replacement
            cursor = match.range.location + match.range.length
        }
        result += ns.substring(from: cursor)
        return result
    }

    private static func render(_ segment: MathRegistry.Segment, allowMathJaxFallback: Bool) -> String {
        switch JSEngine.shared.renderKaTeX(tex: segment.tex, display: segment.display) {
        case .success(let html):
            return html
        case .failure(.parse(let message)):
            if allowMathJaxFallback, let svg = MathJaxRenderer.shared.tex2svg(segment.tex, display: segment.display) {
                return segment.display ? "<div class=\"math-display-svg\">\(svg)</div>" : svg
            }
            return errorBadge(segment, message: message)
        case .failure(.other(let message)):
            return errorBadge(segment, message: message)
        }
    }

    private static func errorBadge(_ segment: MathRegistry.Segment, message: String) -> String {
        let delim = segment.display ? "$$" : "$"
        return "<code class=\"math-error\" title=\"\(escapeHTML(message))\">\(delim)\(escapeHTML(segment.tex))\(delim)</code>"
    }
}

/// MathJax fallback for expressions KaTeX cannot parse. MathJaxSwift owns its own
/// JSContext; initialized lazily on the first KaTeX ParseError so most documents
/// never pay its memory cost (matters under the Quick Look extension memory cap).
///
/// Conversions are memoised in a byte-bounded LRU: MathJax is an order of magnitude
/// slower than KaTeX, and a live reload re-renders every segment. Failures are cached
/// too — for a given input the converter is deterministic.
final class MathJaxRenderer {
    static let shared = MathJaxRenderer()
    static let defaultCacheEntryLimit = 256
    static let defaultCacheByteLimit = 2 * 1024 * 1024

    struct CacheStatistics {
        let entries: Int
        let bytes: Int
    }

    private struct CacheKey: Hashable {
        let tex: String
        let display: Bool
    }

    private let queue = DispatchQueue(label: "com.kylebeggs.peekaboo.mathjax")
    private let cache: LRUCache<CacheKey, String?>
    private var mathjax: MathJax?
    private var initAttempted = false
    private var conversions = 0

    init(cacheEntryLimit: Int = MathJaxRenderer.defaultCacheEntryLimit,
         cacheByteLimit: Int = MathJaxRenderer.defaultCacheByteLimit) {
        cache = LRUCache(entryLimit: cacheEntryLimit, byteLimit: cacheByteLimit)
    }

    /// Number of calls that reached MathJax, i.e. cache misses.
    var conversionCount: Int { queue.sync { conversions } }

    var cacheStatistics: CacheStatistics {
        queue.sync { CacheStatistics(entries: cache.count, bytes: cache.totalBytes) }
    }

    func tex2svg(_ tex: String, display: Bool) -> String? {
        queue.sync { () -> String? in
            let key = CacheKey(tex: tex, display: display)
            if let cached = cache.value(forKey: key) { return cached }
            let svg = autoreleasepool { convert(tex: tex, display: display) }
            cache.insert(svg, forKey: key, cost: tex.utf8.count + (svg?.utf8.count ?? 0))
            return svg
        }
    }

    /// Runs on `queue`.
    private func convert(tex: String, display: Bool) -> String? {
        conversions += 1
        if !initAttempted {
            initAttempted = true
            mathjax = try? MathJax(preferredOutputFormat: .svg)
        }
        guard let mathjax else { return nil }
        return try? mathjax.tex2svg(tex, conversionOptions: ConversionOptions(display: display))
    }
}
