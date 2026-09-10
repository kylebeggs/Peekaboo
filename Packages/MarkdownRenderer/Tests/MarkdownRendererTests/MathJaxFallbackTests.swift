import XCTest
@testable import MarkdownRenderer

/// Memoisation of the MathJax SVG fallback, the renderer KaTeX defers to when it
/// cannot parse a segment. MathJax is an order of magnitude slower than KaTeX, so
/// a live reload must not re-convert the same TeX on every pass.
final class MathJaxFallbackTests: XCTestCase {
    func testSecondConversionOfTheSameTeXIsServedFromCache() {
        let renderer = MathJaxRenderer()
        let tex = "\\frac{1}{2} + \\alpha_{cache}"

        let first = renderer.tex2svg(tex, display: false)
        let conversions = renderer.conversionCount
        let second = renderer.tex2svg(tex, display: false)

        print("MathJax fallback: \(conversions) conversion(s), \(first?.utf8.count ?? 0) bytes of SVG")
        XCTAssertNotNil(first, "MathJax should convert TeX KaTeX rejected")
        XCTAssertEqual(conversions, 1, "the first call should convert exactly once")
        XCTAssertEqual(renderer.conversionCount, conversions, "an identical second call must not re-convert")
        XCTAssertEqual(first, second, "the cached SVG must be identical to the freshly converted one")
    }

    func testDisplayModeIsPartOfTheCacheKey() {
        let renderer = MathJaxRenderer()
        let tex = "\\frac{1}{2} + \\alpha_{modekey}"

        let inline = renderer.tex2svg(tex, display: false)
        let conversions = renderer.conversionCount
        let display = renderer.tex2svg(tex, display: true)

        XCTAssertEqual(renderer.conversionCount, conversions + 1, "display and inline are different conversions")
        XCTAssertNotNil(inline)
        XCTAssertNotEqual(inline, display, "display mode must not reuse the inline SVG")
    }

    /// MathJaxSwift throws on a `{0}` group ("Extra open brace or missing close
    /// brace"), which makes it a stable fixture for a conversion that yields no SVG.
    /// The renderer must remember that instead of retrying on every reload.
    func testFailedConversionIsCached() {
        let renderer = MathJaxRenderer()
        let tex = "\\beta_{0}^{failcache}"

        let first = renderer.tex2svg(tex, display: false)
        let conversions = renderer.conversionCount
        let second = renderer.tex2svg(tex, display: false)

        XCTAssertNil(first, "fixture must be TeX MathJax cannot convert")
        XCTAssertEqual(conversions, 1)
        XCTAssertEqual(renderer.conversionCount, conversions, "a deterministic failure must not be retried")
        XCTAssertNil(second)
    }

    func testCacheStaysUnderItsByteCap() {
        let byteLimit = 8 * 1024
        let renderer = MathJaxRenderer(cacheEntryLimit: 256, cacheByteLimit: byteLimit)
        let equations = (1...20).map { "\\beta^{" + String(repeating: "c", count: $0) + "}" }

        for tex in equations {
            _ = renderer.tex2svg(tex, display: false)
        }
        let stats = renderer.cacheStatistics
        print("MathJax cache: \(stats.entries) entries / \(stats.bytes) bytes, limit \(byteLimit)")

        XCTAssertLessThanOrEqual(stats.bytes, byteLimit, "cache must stay under its byte cap")
        XCTAssertGreaterThan(stats.entries, 0, "recent conversions should still be cached")
        XCTAssertLessThan(stats.entries, equations.count, "the cap should have forced evictions")

        let conversions = renderer.conversionCount
        _ = renderer.tex2svg(equations[19], display: false)
        XCTAssertEqual(renderer.conversionCount, conversions, "the most recent equation must still be cached")
    }
}
